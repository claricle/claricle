# frozen_string_literal: true

# Required here rather than from the entry point: claricle.rb does not
# require this file yet, so requiring it on its own is the only load path
# it has. registry.rb also carries its own requires, though for its own
# stated reason -- it IS required from claricle.rb:10.
require_relative "errors"

module Claricle
  # Everything between "the bytes exist" and "the bytes are on disk or on
  # stdout". Preflight is the constructor, so it cannot be skipped.
  class Writer
    STDOUT_DESTINATION = "-"

    # The three ways a name is compared, and they are not interchangeable:
    # `fold` compares spellings, `raw_canonical` compares locations, and
    # `key_for` compares files.
    module Naming
      module_function

      # TOTAL, and the property is what makes it total rather than a list
      # of cases. `unicode_normalize` and `downcase(:fold)` are defined for
      # exactly those strings whose BYTES are valid UTF-8 read as UTF-8;
      # everything else raises Encoding::CompatibilityError (a non-Unicode
      # encoding) or ArgumentError (an invalid byte sequence). So the guard
      # reinterprets the bytes as UTF-8 and tests validity THERE -- one
      # predicate covering both failure modes. Testing the name AS TAGGED
      # is not enough: "Logo.svg".b is valid ASCII-8BIT and still raises.
      #
      # The fallback ASCII-case-folds rather than returning the name raw.
      # Returning it raw misses a collision the card forbids -- A\xFF.svg
      # and a\xFF.svg are one file on a case-folding volume. Full Unicode
      # folding is undefined on invalid bytes; ASCII case folding is
      # defined on any byte string, and it cannot over-reject, because
      # folding decides only GROUPING and a grouped pair is then handed to
      # the probe, which answers "distinct" on a case-sensitive volume.
      def fold(name)
        utf8 = name.dup.force_encoding(Encoding::UTF_8)
        return name.b.tr("A-Z", "a-z") unless utf8.valid_encoding?

        utf8.unicode_normalize(:nfc).downcase(:fold)
      end

      # File.realdirpath is unusable here: it resolved /var to /private/var
      # but left an existing Foo spelled foo, so it canonicalizes the half
      # that does not need it and not the half that does.
      def raw_canonical(path)
        File.join(resolved_dir(File.dirname(path)), File.basename(path))
      end

      # File.stat, NOT lstat, and the split is deliberate: the identity
      # that matters here is the file a write would touch, so a symlink
      # must key as its target. Preflight's existence and type checks use
      # lstat, because there what matters is the directory entry occupying
      # the name -- see `entry_at`.
      #
      # A String key means File.stat did not resolve. That is usually "does
      # not exist", but also covers a dangling symlink, where the name IS
      # occupied; that routing is correct, because a dangling-symlink pair
      # is String-keyed on both sides, lands in one fold group, fires the
      # probe and is refused.
      def key_for(path)
        stat = File.stat(path)
        [stat.dev, stat.ino]
      rescue SystemCallError
        raw_canonical(path)
      end

      def resolved_dir(dir)
        File.realpath(dir)
      rescue SystemCallError
        File.expand_path(dir)
      end
    end

    # Interrogating one directory's case folding. Lazy: zero probes on an
    # ordinary batch, at most one per directory that holds a raw-distinct
    # collision candidate.
    module CaseProbe
      PROBE_PREFIX = ".claricle-case-probe-"
      UNDECIDABLE = :undecidable

      module_function

      # Returns true (folds), false (distinguishes) or UNDECIDABLE.
      #
      # The BASENAME is upcased, never the whole path: upcasing the path
      # uppercases every directory component, which on a case-sensitive
      # filesystem does not exist, so the probe would report undecidable
      # everywhere on Linux and refuse every legitimate batch.
      #
      # UNDECIDABLE REFUSES the batch upstream. Treating an unprobeable
      # directory as case-sensitive would be fail-OPEN: it compares more
      # names as distinct and lets a real collision through.
      def measure(dir)
        base = "#{PROBE_PREFIX}#{Process.pid}-#{Random.urandom(8).unpack1("H*")}"
        created = create_probe(File.join(dir, base.upcase))
        File.exist?(File.join(dir, base.downcase))
      rescue SystemCallError
        UNDECIDABLE
      ensure
        File.unlink(created) if created
      end

      # Returns the path ONLY once the EXCL open has returned, so a name
      # this probe did not create never becomes something the caller then
      # deletes. Armed before the open, an EEXIST clash would make the
      # cleanup unlink a planted file.
      def create_probe(path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) do
          # Created only to see whether the name folds; nothing is written.
        end
        path
      end
    end

    # The collision rules. Everything a user can cause here is an
    # InvocationError, which cli.rb maps to exit 2: the path is unusable
    # and that is knowable before any bytes are generated.
    class Preflight
      def initialize(destinations, sources:, force: false)
        @destinations = destinations
        @sources = sources
        @force = force
        @probed = {}
      end

      def check
        @destinations.each { |dest| examine(dest) }
        # A list of pairs, never a Hash keyed by destination: a Hash
        # collapses an exact repeat into one entry, and an exact repeat is
        # precisely what pass 1 catches among destinations that do not yet
        # exist. Measured -- ["a.svg", "a.svg"] was accepted.
        keys = @destinations.map { |dest| [dest, Naming.key_for(dest)] }
        refuse_sources(keys)
        refuse_duplicates(keys)
        refuse_fold_collisions(keys)
      end

      private

      # File.dirname and File.basename silently drop a trailing separator,
      # so "build/" was examined as "build", accepted whenever nothing of
      # that name existed, and then failed out of File.link with the STAGE
      # FILENAME in the message -- the leak the directory refusal exists to
      # prevent, reached by a shape that skipped it. That one was already
      # exit 2, since cli.rb:308 maps ENOENT; the neighbouring EISDIR case
      # is the one that reached exit 4. An empty destination leaked the
      # same way. Both are refused here, before any bytes exist.
      #
      # Guard on the NAME, never on the object: a caller may pass a
      # Pathname -- image.rb converts one for the same reason -- and
      # Pathname#empty? tests whether the FILE is empty rather than the
      # string, while Pathname has no #end_with? at all. Guarding on the
      # object refused a zero-byte destination as "empty" and crashed on a
      # missing one with NoMethodError, both of which worked before.
      def examine(dest)
        name = dest.to_s
        raise InvocationError, "output path is empty" if name.empty?
        raise InvocationError, "output path names a directory: #{name}" if name.end_with?(File::SEPARATOR)

        parent = File.dirname(name)
        raise InvocationError, "output directory is not a directory: #{parent}" unless directory_stat(parent).directory?

        entry = entry_at(dest)
        return if entry.nil?

        raise InvocationError, "output path is a directory: #{dest}" if entry.directory?
        raise InvocationError, "output file exists: #{dest} (use --force to replace it)" unless @force
      end

      # THREE distinguishable outcomes, not two. File.directory? cannot do
      # this: it swallows EACCES and returns false, so an unreadable
      # directory that does exist was reported as missing, sending the user
      # to create something already there.
      def directory_stat(dir)
        File.stat(dir)
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise InvocationError, "output directory does not exist: #{dir}"
      rescue SystemCallError => e
        raise InvocationError, "output directory cannot be examined: #{dir} (#{e.class})"
      end

      # lstat, not exist?: a dangling symlink occupies the name and is
      # refused by both File.link and an EXCL open, while exist? calls it
      # absent. ENOENT alone means absent; every other errno means the name
      # cannot be examined. A parent at 0644 is statable but not
      # searchable, so the parent check passes and this raises EACCES --
      # the second of two reachable permission routes, and it answers the
      # same way as the first rather than falling through to a bare errno.
      def entry_at(dest)
        File.lstat(dest)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise InvocationError, "output path cannot be examined: #{dest} (#{e.class})"
      end

      def refuse_sources(keys)
        by_key = @sources.to_h { |source| [Naming.key_for(source), source] }
        keys.each do |dest, key|
          source = by_key[key]
          next unless source

          raise InvocationError, "output would overwrite an input: #{dest} (same file as #{source})"
        end
      end

      # Pass 1, by inode. Catches every destination that ALREADY EXISTS --
      # hardlinks, symlinks to one file, case aliases the filesystem itself
      # resolves -- plus exact string repeats among those that do not.
      # Both passes are required: this one misses Logo.svg/logo.svg before
      # either exists, and pass 2 misses hardlinked existing destinations.
      def refuse_duplicates(keys)
        keys.group_by { |_dest, key| key }.each_value do |group|
          next if group.size == 1

          raise InvocationError, "two outputs are the same file: #{group.map(&:first).join(", ")}"
        end
      end

      def refuse_fold_collisions(keys)
        fold_groups(keys).each do |(dir, _folded), group|
          next if group.size == 1

          refuse_group(dir, group.map(&:first))
        end
      end

      # The dirname comes from the KEY, which `key_for` has already
      # realpath-resolved -- NOT from the raw destination. Grouping by the
      # raw dirname makes both passes miss the same file: out/Q.svg and
      # linkdir/q.svg where linkdir -> out land in different groups, and
      # the second write destroys the first.
      def fold_groups(keys)
        keys.select { |_dest, key| key.is_a?(String) }
            .group_by { |_dest, key| [File.dirname(key), Naming.fold(File.basename(key))] }
      end

      # fetch with a block, never `||=`: `measure` returns FALSE on a
      # case-sensitive volume, so `||=` would re-probe on every group there
      # -- which is the very bug this memo removes, wearing the shape of
      # its own fix. Measured before the memo: 4 colliding groups in one
      # directory produced 4 probe files on a case-sensitive volume and 1
      # on a folding one, because a folding volume refuses at the first.
      def refuse_group(dir, names)
        verdict = @probed.fetch(dir) { @probed[dir] = CaseProbe.measure(dir) }
        if verdict == CaseProbe::UNDECIDABLE
          raise InvocationError,
                "cannot determine whether #{dir} distinguishes case, so refusing: #{names.join(", ")}"
        end

        raise InvocationError, "two outputs collide on a case-insensitive filesystem: #{names.join(", ")}" if verdict
      end
    end

    # Staging, publishing, the mode, and cleanup. Publisher rather than
    # Stage: it does four things and only one of them is staging.
    class Publisher
      def initialize(path, force: false)
        @path = path
        @force = force
      end

      def publish(bytes)
        @replaced_mode = @force ? mode_of_replaced : nil
        write_stage(bytes)
        publish_stage
      ensure
        # rename consumes the stage and clears the name, so this does
        # nothing there. link does not, so on that path this IS the "then
        # unlink the stage" step rather than a failure path. It runs on
        # success too, which is why the name is cleared rather than
        # unlinked unconditionally.
        File.unlink(@staged) if @staged
      end

      private

      # The stage name is recorded INSIDE the block, so it is recorded only
      # after the EXCL open has returned: armed before it, an EEXIST clash
      # on the stage name would make the cleanup unlink a file this Writer
      # never created. Closing the block flushes, which is what makes a
      # truncated publish structurally impossible -- an unflushed stage
      # publishes an EMPTY file for any payload under 8 KiB. Do not
      # simplify this to the non-block form; Style/FileOpen forbids it too.
      def write_stage(bytes)
        path = File.join(File.dirname(@path), stage_basename)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, stage_mode) do |file|
          @staged = path
          file.binmode
          file.write(bytes)
        end
      end

      def stage_basename
        ".#{File.basename(@path)}.claricle-#{Process.pid}-#{Random.urandom(8).unpack1("H*")}"
      end

      # Restrictive-create-then-chmod, and only when something is being
      # replaced. On the force path the stage briefly holds the replacement
      # bytes, so creating it 0666 left them world-readable while the file
      # being replaced was private. Creating it AT the destination's mode
      # does not fix that: umask strips bits, so 0666 becomes 0644 and a
      # chmod is still needed. Staging 0600 and chmod'ing up is the safe
      # direction; the window is never wider than the final state.
      #
      # A no-force publish creates a file that did not exist, so there is
      # nothing to disclose and no window. It stages 0666 & ~umask, which
      # is also what keeps the published mode independent of `force`
      # without reading the umask.
      def stage_mode
        @replaced_mode ? 0o600 : 0o666
      end

      def publish_stage
        return link_stage unless @force

        File.chmod(@replaced_mode, @staged) if @replaced_mode
        File.rename(@staged, @path)
        @staged = nil
      end

      # EEXIST here is genuinely exit 4 becoming exit 2: a destination that
      # appeared after preflight is still the user's argument being wrong.
      # link, not an EXCL open on the destination, because link publishes
      # the name only once the content is complete.
      def link_stage
        File.link(@staged, @path)
      rescue Errno::EEXIST
        raise InvocationError, "output file exists: #{@path} (use --force to replace it)"
      end

      # lstat decides the TYPE, so a symlink is not "file" and the
      # published file never inherits the symlink target's mode; stat reads
      # the mode. Regular files only, and & 0o777 rather than & 0o7777, or
      # a setuid bit survives onto content claricle entirely replaced.
      #
      # rename gives the destination the stage's mode, which is why this
      # exists at all. It also gives the destination the stage's OWNER, so
      # replacing another user's file changes its owner -- inherent to the
      # stage-and-rename the card mandates, not something this can fix.
      def mode_of_replaced
        return nil unless File.lstat(@path).ftype == "file"

        File.stat(@path).mode & 0o777
      rescue SystemCallError
        nil
      end
    end

    private_constant :Naming, :CaseProbe, :Preflight, :Publisher

    # sources: is required rather than defaulted. Defaulting it defaults
    # away the strongest rule the card states, and image.rb refuses rather
    # than defaults in the same position.
    def initialize(destinations, sources:, stdout: $stdout, force: false)
      @stdout = stdout
      @force = force
      @planned = destinations.reject { |dest| dest == STDOUT_DESTINATION }
      Preflight.new(@planned, sources: sources, force: force).check
    end

    # Returns the destination exactly as the caller spelled it, or nil for
    # stdout. The canonical form exists only to compare names.
    def write(bytes, to:)
      return write_stdout(bytes) if to == STDOUT_DESTINATION

      raise ArgumentError, "destination was not preflighted: #{to.inspect}" unless @planned.include?(to)

      Publisher.new(to, force: @force).publish(bytes)
      to
    end

    private

    # Never puts, which appends a newline to bytes that do not already end
    # in one and corrupts binary output. binmode first, or a stdout with an
    # encoding set raises Encoding::UndefinedConversionError on real bytes.
    def write_stdout(bytes)
      @stdout.binmode
      @stdout.write(bytes)
      nil
    end
  end

  private_constant :Writer
end
