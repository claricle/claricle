# frozen_string_literal: true

# A NEW pattern in spec/, and stated as new: claricle.rb does not require
# writer.rb yet (that wiring is a later step), so spec_helper's
# `require "claricle"` does not load it. There is no require_relative
# precedent in spec/ -- grep returns zero hits repo-wide -- so this is a
# plain require off the gem's own load path.
require "claricle/writer"
require "fileutils"
require "pathname"
require "tmpdir"

RSpec.describe "Claricle::Writer" do
  # const_get, as registry_spec.rb and image_spec.rb do: Writer is a
  # private constant of Claricle and its units are private constants of
  # Writer, and const_get is the documented way past that.
  writer = Claricle.const_get(:Writer)
  naming = writer.const_get(:Naming)
  case_probe = writer.const_get(:CaseProbe)
  preflight = writer.const_get(:Preflight)
  stdout_destination = writer.const_get(:STDOUT_DESTINATION)

  # Under uid 0 the permission bits these examples depend on stop biting:
  # root writes a 0500 directory, stats a 0000 one and searches a 0644 one.
  # They would FAIL outright rather than pass vacuously, so they skip with
  # the reason stated. This branch introduces the repo's first
  # permission-dependent specs, so there is no precedent to copy.
  root_skip = Process.uid.zero? && "root ignores the permission bits this example depends on"

  # Independent of the Writer's own probe: write an upcased name, ask for
  # the downcased one. End-to-end rows branch on this; unit rows never do.
  folds_case = lambda do |dir|
    upper = File.join(dir, "ZZZ-VOLUME-CHECK")
    File.binwrite(upper, "")
    File.exist?(File.join(dir, "zzz-volume-check"))
  ensure
    FileUtils.rm_f(upper)
  end

  outcome_of = lambda do |dests, sources: [], force: false|
    writer.new(dests, sources: sources, force: force)
    :constructed
  rescue Claricle::InvocationError
    :refused
  end

  # Whole tree, not one expected filename, so "wrote nothing" holds against
  # any route rather than against the route the assertion happens to name.
  tree_snapshot = lambda do |root|
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.filter_map do |rel|
      next if [".", ".."].include?(rel.split("/").last)

      full = File.join(root, rel)
      type = File.lstat(full).ftype
      [rel, type, (File.binread(full) if type == "file")]
    end
  end

  probe_opens = lambda do |paths|
    paths.count { |path| path.downcase.include?(case_probe.const_get(:PROBE_PREFIX)) }
  end

  around do |example|
    Dir.mktmpdir("claricle-writer") do |tmp|
      @dir = tmp
      example.run
    end
  end

  let(:dir) { @dir }

  # A `let`, never a constant and never a bare local: a constant inside
  # RSpec.describe trips Lint/ConstantDefinitionInBlock, and the
  # autocorrect to a block-local made an unrelated example's assignment
  # leak into every later example, silently emptying three stdout specs
  # while the suite stayed green.
  let(:payload) { "\xFF\x00<svg/>\x7F".b }

  describe "naming" do
    it "folds the nine measured pairs to a hardcoded vector" do # U1
      # Escapes, not literal characters: several of these pairs are
      # visually identical on screen (NFC vs NFD, CAPITAL SHARP S vs sharp
      # s), so a literal spelling hides whether the row asserts anything.
      # KELVIN SIGN, DOTLESS I and the FI LIGATURE are the same trap.
      pairs = [%W[\u212A k],
               %W[\u00E9 e\u0301],
               %W[SS \u00DF],
               %W[Stra\u00DFe STRASSE],
               %W[I \u0131],
               %W[\uFB01le FILE],
               %w[A a],
               %W[\u00C4 \u00E4],
               %W[\u1E9E \u00DF]]

      # A hardcoded vector, with no filesystem involved: `fold` agreeing
      # with APFS is why this primitive was CHOSEN, not a property of it,
      # so the oracle is the same on every platform.
      expect(pairs.map { |left, right| naming.fold(left) == naming.fold(right) })
        .to eq([true, true, true, true, false, true, true, true, true])
    end

    it "ASCII-case-folds a non-UTF-8 name without over-folding a different letter" do # U2
      expect(naming.fold("A\xFF.svg".b)).to eq(naming.fold("a\xFF.svg".b))
      expect(naming.fold("B\xFF.svg".b)).not_to eq(naming.fold("A\xFF.svg".b))
    end

    it "folds a binary-tagged name exactly as its UTF-8 twin, leaving other bytes alone" do # U9
      expect(naming.fold("Logo.svg".b)).to eq(naming.fold("Logo.svg"))
      expect(naming.fold("\xFE\xFF.svg".b)).to eq("\xFE\xFF.svg".b)
    end

    it "resolves a symlinked directory to its real path" do # U3
      real = File.join(dir, "real")
      Dir.mkdir(real)
      File.symlink(real, File.join(dir, "link"))

      expect(naming.raw_canonical(File.join(dir, "link", "x.svg")))
        .to eq(File.join(File.realpath(real), "x.svg"))
    end

    it "keys an existing path by inode and a missing one by canonical string" do # U4
      here = File.join(dir, "here.svg")
      File.binwrite(here, "x")
      gone = File.join(dir, "gone.svg")

      expect(naming.key_for(here)).to eq([File.stat(here).dev, File.stat(here).ino])
      expect(naming.key_for(gone)).to eq(File.join(File.realpath(dir), "gone.svg"))
      expect(naming.key_for(here)).not_to eq(naming.key_for(gone))
    end
  end

  describe "the case probe" do
    it "agrees with this volume's independently measured folding" do # U5
      expect(case_probe.measure(dir)).to eq(folds_case.call(dir))
    end

    it "reports undecidable rather than guessing when the directory is unwritable", skip: root_skip do # U6
      locked = File.join(dir, "locked")
      Dir.mkdir(locked)
      File.chmod(0o500, locked)

      begin
        expect(case_probe.measure(locked)).to eq(case_probe.const_get(:UNDECIDABLE))
      ensure
        File.chmod(0o700, locked)
      end
    end

    it "leaves nothing behind" do # U7
      before = tree_snapshot.call(dir)
      case_probe.measure(dir)

      expect(tree_snapshot.call(dir)).to eq(before)
    end

    it "never deletes a file it did not create" do # U11
      allow(Random).to receive(:urandom).with(8).and_return(("\xAB" * 8).b)
      base = "#{case_probe.const_get(:PROBE_PREFIX)}#{Process.pid}-#{"ab" * 8}"
      victim = File.join(dir, base.upcase)
      File.binwrite(victim, "PLANTED")

      expect(case_probe.measure(dir)).to eq(case_probe.const_get(:UNDECIDABLE))
      expect(File.binread(victim)).to eq("PLANTED")
    end
  end

  describe "preflight" do
    it "groups two routes to one directory into a single fold group" do # U8
      real = File.join(dir, "out")
      Dir.mkdir(real)
      File.symlink(real, File.join(dir, "linkdir"))
      upper = File.join(real, "Q.svg")
      lower = File.join(dir, "linkdir", "q.svg")
      keys = [upper, lower].map { |dest| [dest, naming.key_for(dest)] }

      groups = preflight.new([upper, lower], sources: []).send(:fold_groups, keys)

      expect(groups.size).to eq(1)
      expect(groups.values.first.map(&:first)).to eq([upper, lower])
    end

    # The verdict handling, isolated from the volume. Deleting the whole
    # collision rule failed only E5 and E7 on a case-sensitive volume, and
    # both are root-guarded -- so under a root container on Linux the
    # branch's central rule had NO pin at all.
    it "acts on the probe's verdict in all three directions" do # U12
      upper = File.join(dir, "Q.svg")
      lower = File.join(dir, "q.svg")

      outcomes = [true, case_probe.const_get(:UNDECIDABLE), false].map do |verdict|
        allow(case_probe).to receive(:measure).and_return(verdict)
        outcome_of.call([upper, lower])
      end

      expect(outcomes).to eq(%i[refused refused constructed])
    end

    # "At most one probe per directory" is the declared card deviation, and
    # it was false: a case-sensitive volume never refuses, so every group
    # probed. Stubbing the verdict to false makes this hold on any volume.
    it "probes a directory at most once, however many groups collide in it" do # U13
      probed = []
      allow(case_probe).to receive(:measure) do |target|
        probed << target
        false
      end
      destinations = %w[A a B b C c].map { |name| File.join(dir, "#{name}.svg") }

      writer.new(destinations, sources: [])

      expect(probed).to eq([File.realpath(dir)])
    end

    # A Pathname reaches here in practice -- image.rb converts one for the
    # same reason -- and both of these worked until the name guards were
    # added on the object instead of on its name.
    it "accepts a Pathname destination, guarding on the name not the object" do # E35
      missing = Pathname.new(File.join(dir, "missing.svg"))
      zero = Pathname.new(File.join(dir, "zero.svg"))
      zero.write("")

      expect(writer.new([missing], sources: []).write(payload, to: missing)).to eq(missing)
      writer.new([zero], sources: [], force: true).write(payload, to: zero)

      expect([missing.binread, zero.binread]).to eq([payload, payload])

      # ...and an object that is not a path is NOT reinterpreted as one.
      # File.path refuses it exactly as File.dirname did before these
      # guards existed, so a caller's bug stays a caller's bug instead of
      # being reported to the user as their invocation mistake.
      [nil, [File.join(dir, "x.svg")]].each do |not_a_path|
        expect { writer.new([not_a_path], sources: []) }.to raise_error(TypeError)
      end
    end

    it "refuses a destination that is an input, by hardlink or symlink alias, even with force" do # E1
      source = File.join(dir, "source.svg")
      File.binwrite(source, "SOURCE")
      File.link(source, File.join(dir, "hard.svg"))
      File.symlink(source, File.join(dir, "soft.svg"))

      # The offending destination is NOT at index 0 and there is more than
      # one source, so a preflight that examined only the first of either
      # would accept this batch. Three such truncations survived the whole
      # suite while it looked green.
      innocent = File.join(dir, "innocent.svg")
      other_source = File.join(dir, "other.svg")
      File.binwrite(other_source, "OTHER")

      trailer = File.join(dir, "trailer.svg")

      %w[hard.svg soft.svg].each do |name|
        offender = File.join(dir, name)
        [[offender], [innocent, offender, trailer]].each do |destinations|
          expect { writer.new(destinations, sources: [other_source, source], force: true) }
            .to raise_error(Claricle::InvocationError, /overwrite an input/)
        end
      end
      expect(File.binread(source)).to eq("SOURCE")
      expect(Dir.children(dir)).not_to include("innocent.svg")
    end

    it "refuses two destinations that are the same file, even with force" do # E2
      # Both pairs sit AFTER an innocent destination, for the reason
      # given in E1.
      innocent = File.join(dir, "innocent.svg")
      repeat = File.join(dir, "fresh.svg")
      expect { writer.new([innocent, repeat, repeat], sources: [], force: true) }
        .to raise_error(Claricle::InvocationError, /same file/)

      one = File.join(dir, "one.svg")
      File.binwrite(one, "X")
      two = File.join(dir, "two.svg")
      File.link(one, two)
      expect { writer.new([innocent, one, two], sources: [], force: true) }
        .to raise_error(Claricle::InvocationError, /same file/)
    end

    it "treats a Logo.svg/logo.svg pair as this volume treats it" do # E3
      upper = File.join(dir, "Logo.svg")
      lower = File.join(dir, "logo.svg")

      if folds_case.call(dir)
        expect { writer.new([upper, lower], sources: []) }
          .to raise_error(Claricle::InvocationError, /case-insensitive/)
      else
        subject = writer.new([upper, lower], sources: [])
        subject.write("UPPER".b, to: upper)
        subject.write("lower".b, to: lower)
        expect([File.binread(upper), File.binread(lower)]).to eq(%w[UPPER lower])
      end
    end

    it "treats an SS.svg/ß.svg pair as this volume treats it" do # E4
      sharp = File.join(dir, "SS.svg")
      esszett = File.join(dir, "ß.svg")

      if folds_case.call(dir)
        expect { writer.new([sharp, esszett], sources: []) }
          .to raise_error(Claricle::InvocationError, /case-insensitive/)
      else
        subject = writer.new([sharp, esszett], sources: [])
        subject.write("SHARP".b, to: sharp)
        subject.write("ESZETT".b, to: esszett)
        expect([File.binread(sharp), File.binread(esszett)]).to eq(%w[SHARP ESZETT])
      end
    end

    # Three signals, and they are not interchangeable. (a) carries the
    # property: in a 0500 directory a probe is impossible by ANY route, so
    # there is no interception list to keep complete, and it asserts that
    # the lazy design SUCCEEDS where an eager one cannot. (b) catches a
    # self-cleaning probe by any route. (c) is a diagnostic naming the
    # planned route -- delete it and you lose precision, delete (a) or (b)
    # and you lose the property.
    it "probes exactly when a fold-collision candidate exists, and not otherwise", skip: root_skip do # E5
      locked = File.join(dir, "locked")
      Dir.mkdir(locked)
      File.chmod(0o500, locked)
      outcomes = begin
        [outcome_of.call([File.join(locked, "solo.svg")]),
         outcome_of.call([File.join(locked, "Q.svg"), File.join(locked, "q.svg")])]
      ensure
        File.chmod(0o700, locked)
      end
      expect(outcomes).to eq(%i[constructed refused])

      open_dir = File.join(dir, "open")
      Dir.mkdir(open_dir)
      before_mtime = File.stat(open_dir).mtime
      opened = []
      allow(File).to receive(:open).and_wrap_original do |original, *args, &block|
        opened << args.first.to_s
        original.call(*args, &block)
      end

      writer.new([File.join(open_dir, "solo.svg")], sources: [])
      expect(File.stat(open_dir).mtime).to eq(before_mtime)
      expect(probe_opens.call(opened)).to eq(0)

      opened.clear
      outcome_of.call([File.join(open_dir, "Q.svg"), File.join(open_dir, "q.svg")])
      expect(probe_opens.call(opened)).to be >= 1
    end

    # Distinct contribution: zero -- it shares its kill with ten other
    # examples, and its on-disk half is close to a tautology because
    # preflight lives in the constructor. Kept because it is the only row
    # labelled to the card's "fails the whole batch before any write";
    # do not read it as load-bearing.
    it "leaves the filesystem byte-identical when the batch collides" do # E6
      File.binwrite(File.join(dir, "bystander.svg"), "KEEP")
      repeat = File.join(dir, "out.svg")
      before = tree_snapshot.call(dir)

      expect { writer.new([repeat, repeat], sources: [], force: true) }
        .to raise_error(Claricle::InvocationError)
      expect(tree_snapshot.call(dir)).to eq(before)
    end

    it "refuses the batch when the probe is undecidable", skip: root_skip do # E7
      locked = File.join(dir, "locked")
      Dir.mkdir(locked)
      File.chmod(0o500, locked)

      begin
        expect { writer.new([File.join(locked, "Q.svg"), File.join(locked, "q.svg")], sources: []) }
          .to raise_error(Claricle::InvocationError, /distinguishes case/)
      ensure
        File.chmod(0o700, locked)
      end
    end

    # The stage NAME shape, not the substring "claricle-": the tmpdir this
    # example runs in is itself prefixed "claricle-writer", so a substring
    # check fails against a message that leaks nothing.
    it "refuses a directory destination with and without force, never naming the stage" do # E8
      destination = File.join(dir, "outdir")
      Dir.mkdir(destination)

      [false, true].each do |force|
        expect { writer.new([destination], sources: [], force: force) }
          .to raise_error(Claricle::InvocationError) { |error|
            expect(error.message).to match(/is a directory/)
            expect(error.message).not_to match(/\.claricle-\d+-[0-9a-f]+/)
          }
      end
    end

    # A trailing separator and an empty name reach preflight through
    # File.dirname/File.basename, which silently drop them, so both were
    # accepted and then failed out of File.link at exit 4 WITH the stage
    # filename in the message. "build/" is a plausible invocation: shell
    # completion appends the slash.
    it "refuses a destination that names a directory or nothing, never naming the stage" do # E34
      Dir.chdir(dir) do
        # The offender leads and an innocent name trails it, which is the
        # opposite order to E1/E2/E10. take(1) proves the walk does not
        # stop at the front; this proves it does not stop at the back. A
        # last-only truncation survived all 46 examples without it.
        innocent = File.join(dir, "innocent.svg")

        ["build/", "", File.join(dir, "sub/")].each do |destination|
          expect { writer.new([destination, innocent], sources: []) }
            .to raise_error(Claricle::InvocationError) { |error|
              expect(error.message).to match(/output path (names a directory|is empty)/)
              expect(error.message).not_to match(/\.claricle-\d+-[0-9a-f]+/)
            }
        end
        expect(Dir.children(dir)).to eq([])
      end
    end

    it "names the directory when the parent is missing or is not a directory" do # E9
      plain = File.join(dir, "plain")
      File.binwrite(plain, "x")

      expect { writer.new([File.join(dir, "nope", "a.svg")], sources: []) }
        .to raise_error(Claricle::InvocationError, /directory does not exist: #{Regexp.escape(File.join(dir, "nope"))}/)
      expect { writer.new([File.join(plain, "a.svg")], sources: []) }
        .to raise_error(Claricle::InvocationError, /#{Regexp.escape(plain)}/)
    end

    it "refuses an existing destination without force, a dangling symlink included" do # E10
      plain = File.join(dir, "plain.svg")
      File.binwrite(plain, "OLD")
      dangling = File.join(dir, "dangling.svg")
      File.symlink(File.join(dir, "absent"), dangling)

      # Behind an innocent destination, so a preflight that examined only
      # the first entry would accept the batch. This is the `examine` half
      # of the iteration property E1 and E2 carry for the later passes.
      innocent = File.join(dir, "innocent.svg")

      trailer = File.join(dir, "trailer.svg")

      [plain, dangling].each do |dest|
        [[dest], [innocent, dest, trailer]].each do |destinations|
          expect { writer.new(destinations, sources: []) }
            .to raise_error(Claricle::InvocationError, /exists/)
        end
      end
    end

    it "says a parent cannot be examined rather than that it does not exist", skip: root_skip do # E29
      grandparent = File.join(dir, "gp")
      parent = File.join(grandparent, "sub")
      FileUtils.mkdir_p(parent)
      File.chmod(0o000, grandparent)

      begin
        expect { writer.new([File.join(parent, "a.svg")], sources: []) }
          .to raise_error(Claricle::InvocationError, /cannot be examined/)
      ensure
        File.chmod(0o700, grandparent)
      end
    end

    it "says the destination cannot be examined under a statable but unsearchable parent", skip: root_skip do # E30
      parent = File.join(dir, "parent")
      Dir.mkdir(parent)
      File.chmod(0o644, parent)

      begin
        expect { writer.new([File.join(parent, "a.svg")], sources: []) }
          .to raise_error(Claricle::InvocationError, /output path cannot be examined/)
      ensure
        File.chmod(0o700, parent)
      end
    end

    it "refuses two routes to one directory before either is written" do # E27
      real = File.join(dir, "out")
      Dir.mkdir(real)
      File.symlink(real, File.join(dir, "linkdir"))
      before = tree_snapshot.call(real)

      expect { writer.new([File.join(real, "x.svg"), File.join(dir, "linkdir", "x.svg")], sources: []) }
        .to raise_error(Claricle::InvocationError, /same file/)
      expect(tree_snapshot.call(real)).to eq(before)
    end

    it "treats a case-different basename reached through a symlinked directory as this volume does" do # E28
      real = File.join(dir, "out")
      Dir.mkdir(real)
      File.symlink(real, File.join(dir, "linkdir"))
      upper = File.join(real, "Q.svg")
      lower = File.join(dir, "linkdir", "q.svg")

      if folds_case.call(real)
        expect { writer.new([upper, lower], sources: []) }
          .to raise_error(Claricle::InvocationError, /case-insensitive/)
      else
        subject = writer.new([upper, lower], sources: [])
        subject.write("UPPER".b, to: upper)
        subject.write("lower".b, to: lower)
        expect([File.binread(upper), File.binread(lower)]).to eq(%w[UPPER lower])
      end
    end

    # The verdict, not a write: APFS refuses to CREATE an invalid-UTF-8
    # name (EILSEQ) on either case setting, while lstat on one answers
    # ENOENT, so planned destinations reach the grouping on both volumes.
    it "treats two invalid-UTF-8 names differing only in ASCII case as this volume does" do # E31
      upper = File.join(dir, "A\xFF.svg".b)
      lower = File.join(dir, "a\xFF.svg".b)

      expect(outcome_of.call([upper, lower])).to eq(folds_case.call(dir) ? :refused : :constructed)
    end
  end

  describe "publishing" do
    it "does not replace a destination that appears after preflight" do # E11
      %i[plain live dangling].each do |kind|
        dest = File.join(dir, "#{kind}.svg")
        target = File.join(dir, "#{kind}-target")
        subject = writer.new([dest], sources: [])

        case kind
        when :plain then File.binwrite(dest, "OLD")
        when :live then File.binwrite(target, "OLD") && File.symlink(target, dest)
        when :dangling then File.symlink(File.join(dir, "absent"), dest)
        end

        expect { subject.write(payload, to: dest) }.to raise_error(Claricle::InvocationError, /exists/)
        expect(File.binread(dest)).to eq("OLD") unless kind == :dangling
        expect(File.symlink?(dest)).to be(true) unless kind == :plain
      end
    end

    # and_wrap_original calls through to the real File.link, so this is a
    # synchronization point rather than a stubbed behaviour, and the card
    # names the mechanism. verify_partial_doubles is FALSE repo-wide, so
    # the two-part rule stands in for it: File.link exists, and this
    # expectation fails against the check-then-write mutant.
    it "loses a publish race to a concurrent writer rather than overwriting it" do # E12
      dest = File.join(dir, "race.svg")
      subject = writer.new([dest], sources: [])
      allow(File).to receive(:link).and_wrap_original do |original, *args|
        File.binwrite(dest, "CONCURRENT")
        original.call(*args)
      end

      expect { subject.write(payload, to: dest) }.to raise_error(Claricle::InvocationError, /exists/)
      expect(File.binread(dest)).to eq("CONCURRENT")
    end

    it "publishes the complete bytes at the instant the name appears" do # E13
      big_payload = ("\x01\xFE".b * 500)
      dest = File.join(dir, "big.svg")

      writer.new([dest], sources: []).write(big_payload, to: dest)

      expect(File.binread(dest).bytesize).to eq(1000)
      expect(File.binread(dest)).to eq(big_payload)
    end

    # A whole batch through ONE Writer, across two directories. Every other
    # multi-write example (E3, E4, E28) reaches its "both written" branch
    # only on a case-sensitive volume, so without this row nothing on a
    # folding filesystem ever publishes two destinations successfully --
    # a property the whole corpus shared that nobody chose. Distinct
    # payloads, so cross-contamination cannot pass for success.
    it "publishes every destination of a batch and leaves no stage behind" do # E14
      Dir.mkdir(File.join(dir, "sub"))
      destinations = [File.join(dir, "a.svg"), File.join(dir, "b.svg"), File.join(dir, "sub", "c.svg")]
      subject = writer.new(destinations, sources: [])

      returned = destinations.map { |dest| subject.write(File.basename(dest).b, to: dest) }

      expect(returned).to eq(destinations)
      expect(destinations.map { |dest| File.binread(dest) }).to eq(%w[a.svg b.svg c.svg])
      expect(Dir.children(dir).sort).to eq(%w[a.svg b.svg sub])
      expect(Dir.children(File.join(dir, "sub"))).to eq(["c.svg"])
    end

    # The stage's half of the rule U11 pins for the probe. The plan states
    # it -- "armed before the open, an EEXIST clash on the stage name would
    # make cleanup unlink a file the Writer never created" -- and its spec
    # table left it unpinned, so walking the RULES rather than the specs is
    # what surfaced it. Random.urandom is stubbed so a victim can be
    # planted at the stage's own name.
    it "never unlinks a file it did not create when the stage name clashes" do # E33
      dest = File.join(dir, "clash.svg")
      subject = writer.new([dest], sources: [])
      allow(Random).to receive(:urandom).with(8).and_return(("\xCD" * 8).b)
      victim = File.join(dir, ".#{File.basename(dest)}.claricle-#{Process.pid}-#{"cd" * 8}")
      File.binwrite(victim, "PLANTED")

      expect { subject.write(payload, to: dest) }.to raise_error(Errno::EEXIST)
      expect(File.binread(victim)).to eq("PLANTED")
    end

    it "leaves no staged file behind when the publish fails" do # E15
      dest = File.join(dir, "clash.svg")
      subject = writer.new([dest], sources: [])
      File.binwrite(dest, "OLD")

      expect { subject.write(payload, to: dest) }.to raise_error(Claricle::InvocationError)
      expect(Dir.children(dir)).to eq(["clash.svg"])
    end

    it "replaces with exactly the new bytes under force" do # E16
      dest = File.join(dir, "replace.svg")
      File.binwrite(dest, "OLD CONTENT THAT IS LONGER")

      writer.new([dest], sources: [], force: true).write(payload, to: dest)

      expect(File.binread(dest)).to eq(payload)
      expect(Dir.children(dir)).to eq(["replace.svg"])
    end

    it "replaces a symlink under force, not its target" do # E17
      target = File.join(dir, "target.bin")
      File.binwrite(target, "TARGET")
      dest = File.join(dir, "link.svg")
      File.symlink(target, dest)

      writer.new([dest], sources: [], force: true).write(payload, to: dest)

      expect(File.symlink?(dest)).to be(false)
      expect(File.binread(dest)).to eq(payload)
      expect(File.binread(target)).to eq("TARGET")
    end

    it "publishes a fresh destination at the same mode with and without force" do # E18
      reference = File.join(dir, "reference.bin")
      File.binwrite(reference, "x")
      expected = File.stat(reference).mode & 0o777

      modes = [false, true].map do |force|
        dest = File.join(dir, "fresh-#{force}.svg")
        writer.new([dest], sources: [], force: force).write(payload, to: dest)
        File.stat(dest).mode & 0o777
      end

      expect(modes).to eq([expected, expected])
    end

    it "keeps the destination's own permissions under force", skip: root_skip do # E19
      dest = File.join(dir, "private.svg")
      File.binwrite(dest, "OLD")
      File.chmod(0o400, dest)

      writer.new([dest], sources: [], force: true).write(payload, to: dest)

      expect(File.stat(dest).mode & 0o777).to eq(0o400)
      expect(File.binread(dest)).to eq(payload)
    end

    # The WINDOW, not the final mode: observed at the chmod call, the one
    # instant between "the bytes are written" and "the name is published".
    # It asserts the stage's SIZE too, so an empty stage cannot make it
    # pass for the wrong reason.
    it "keeps the staged replacement owner-only while its bytes are on disk", skip: root_skip do # E32
      dest = File.join(dir, "private.svg")
      File.binwrite(dest, "OLD")
      File.chmod(0o400, dest)
      observed = []
      allow(File).to receive(:chmod).and_wrap_original do |original, mode, *paths|
        observed << paths.map { |path| [File.stat(path).mode & 0o777, File.stat(path).size] }
        original.call(mode, *paths)
      end

      writer.new([dest], sources: [], force: true).write(payload, to: dest)

      expect(observed).to eq([[[0o600, payload.bytesize]]])
    end

    it "does not carry setuid onto replaced content", skip: root_skip do # E20
      dest = File.join(dir, "setuid.svg")
      File.binwrite(dest, "OLD")
      File.chmod(0o4755, dest)

      writer.new([dest], sources: [], force: true).write(payload, to: dest)

      expect(File.stat(dest).mode & 0o7777).to eq(0o755)
    end

    it "never gives a published file a symlink target's mode" do # E21
      target = File.join(dir, "target.bin")
      File.binwrite(target, "TARGET")
      File.chmod(0o600, target)
      dest = File.join(dir, "link.svg")
      File.symlink(target, dest)
      reference = File.join(dir, "reference.bin")
      File.binwrite(reference, "x")

      writer.new([dest], sources: [], force: true).write(payload, to: dest)

      expect(File.lstat(dest).ftype).to eq("file")
      expect(File.stat(dest).mode & 0o777).to eq(File.stat(reference).mode & 0o777)
      expect(File.stat(target).mode & 0o777).to eq(0o600)
    end

    it "returns the caller's spelling, through a symlinked directory" do # E25
      real = File.join(dir, "out")
      Dir.mkdir(real)
      File.symlink(real, File.join(dir, "linkdir"))
      dest = File.join(dir, "linkdir", "x.svg")

      expect(writer.new([dest], sources: []).write(payload, to: dest)).to eq(dest)
      expect(File.binread(File.join(real, "x.svg"))).to eq(payload)
    end

    it "refuses to write to an unpreflighted destination" do # E26
      expect { writer.new([], sources: []).write(payload, to: File.join(dir, "stranger.svg")) }
        .to raise_error(ArgumentError, /not preflighted/)
    end
  end

  describe "stdout" do
    it "writes exactly the bytes, adding no newline" do # E22
      fixture = "<svg/>".b
      reader, output = IO.pipe

      begin
        expect(writer.new([stdout_destination], sources: [], stdout: output).write(fixture, to: "-")).to be_nil
        output.close
        expect(reader.read.b).to eq(fixture)
      ensure
        reader.close unless reader.closed?
        output.close unless output.closed?
      end
    end

    it "survives a stdout that has a text encoding set" do # E23
      reader, output = IO.pipe
      output.set_encoding(Encoding::UTF_8)

      begin
        writer.new([stdout_destination], sources: [], stdout: output).write(payload, to: "-")
        output.close
        expect(reader.read.b).to eq(payload)
      ensure
        reader.close unless reader.closed?
        output.close unless output.closed?
      end
    end

    # Dir.chdir's block form and an injected pipe, never the real $stdout:
    # binmode on the process stream is irreversible and would put a NUL
    # into the RSpec report.
    it "never treats - as a path, even with a file named - present" do # E24
      Dir.chdir(dir) do
        File.binwrite("-", "VICTIM")
        reader, output = IO.pipe

        begin
          writer.new([stdout_destination], sources: [], stdout: output).write(payload, to: "-")
          output.close
          expect(reader.read.b).to eq(payload)
        ensure
          reader.close unless reader.closed?
          output.close unless output.closed?
        end

        expect(File.binread("-")).to eq("VICTIM")
      end
    end
  end
end
