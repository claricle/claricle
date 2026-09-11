# frozen_string_literal: true

require "thor"
require_relative "claricle/version"
require_relative "claricle/errors"
require_relative "claricle/models/location"
require_relative "claricle/models/issue"
require_relative "claricle/models/report"
require_relative "claricle/models/inspection"
require_relative "claricle/models/batch_item"
require_relative "claricle/fault"
require_relative "claricle/batch"
require_relative "claricle/writer"
require_relative "claricle/registry"
require_relative "claricle/detector"
require_relative "claricle/image"
require_relative "claricle/cli"

module Claricle
  # Detects the format of `source`, a String of image content or an IO.
  #
  # An IO is read from wherever it is currently positioned -- it is never
  # rewound, so a caller who has already consumed part of it gets a
  # verdict on the remainder. Bytes are pulled in incrementally and
  # classification is retried after each read, so a short, conclusive
  # image (its signature or root tag already present) returns without
  # waiting for more. Plain PostScript and EPSF are the exception: a byte
  # that hasn't arrived yet can still turn one into the other, so that
  # verdict waits for the probe bound -- the largest amount any detector
  # probe consults -- or end of stream. A binary-preview EPS has its own
  # conclusive magic and returns immediately. A source that stays open
  # and never supplies enough to decide blocks until one of those is
  # reached; content beyond the bound is left unread on the IO rather
  # than buffered. It should be in binary mode; newline translation
  # would corrupt the signatures this matches on. Pass a path to
  # `Image.from_path` to stream from a file instead of buffering.
  def self.detect(source)
    return Detector.detect(source) unless source.respond_to?(:read)

    Detector.detect(accumulate(source))
  end

  # Grows `buffer` by reading from `source` a chunk at a time, stopping
  # as soon as the buffer classifies, hits the probe bound, or the
  # source ends -- so a complete short image on a stream that never
  # closes doesn't wait for bytes nothing needs.
  def self.accumulate(source)
    buffer = "".b
    loop do
      return buffer if conclusive?(buffer) || buffer.bytesize >= Detector::MAX_PROBE_BYTES

      begin
        buffer << source.readpartial(Detector::MAX_PROBE_BYTES - buffer.bytesize)
      rescue EOFError
        return buffer
      end
    end
  end

  def self.conclusive?(buffer)
    return true if EpsBinary.wrapped?(buffer)

    format = Detector.detect(buffer)
    # A plain PostScript verdict is provisional until the underlying line
    # scan is certain: a byte that hasn't arrived yet can still flip EPSF
    # from a trusted match to a disqualified one, so this loop must not
    # settle for less than a real end of stream or the probe bound.
    !%i[ps eps].include?(format)
  rescue UnknownFormat
    false
  end

  # Does everything named here conform? Exactly one of a positional path or
  # `pattern:` -- issue #1's own examples use both shapes.
  #
  # A predicate answers about conformance and raises about everything else.
  # A nonconformant file is `false`; an unknown format, an unsupported one,
  # a missing file or a delegate crash raises, out of the batch shape too,
  # so an operational failure never reads as a verdict.
  #
  # Both shapes reach the same expansion, so a positional means here exactly
  # what it means on the command line: a literal path when it names a file,
  # and a glob otherwise.
  def self.conform?(path = nil, pattern: nil, strict: false, profile: nil)
    raise InvocationError, "give exactly one of a path or pattern" unless path.nil? ^ pattern.nil?

    result = conformance_batch(*[path].compact, pattern: pattern,
                                                strict: strict, profile: profile)
    raise result.highest_error if result.highest_error

    result.exit_code.zero?
  end

  def self.conformance_report(path, profile: nil)
    checked_profile(profile)
    Image.from_path(path).conformance_report
  end

  # A batch predicate loses information, so a caller can have the whole
  # result instead: ordered per-file outcomes plus the aggregate status,
  # which is what the command prints. Takes the command's own argument
  # shape -- files, a pattern, or both -- so the two cannot drift about
  # what conformance means.
  def self.conformance_batch(*paths, pattern: nil, strict: false, profile: nil)
    # Checked eagerly here, before the batch runs, so a profile no format
    # defines is one invocation error about the call and never a row in a
    # report -- `conformance_report` checks it again per file, but only as a
    # no-op once this call has already passed.
    checked_profile(profile)
    Batch.run(paths, pattern: pattern,
                     classify: ->(report) { conformant?(report, strict: strict) ? 0 : 1 }) do |file|
      conformance_report(file, profile: profile)
    end
  end

  # Any error means no; a warning alone means suspicious, which passes
  # unless the caller asked for strict; info never downgrades anything.
  def self.conformant?(report, strict:)
    strict ? report.valid == :yes : report.valid != :no
  end

  # No handler implements conformance yet, so no format defines a profile
  # yet -- and a profile a format does not define is a bad invocation, not
  # a flag to accept and quietly drop. The per-format table of profile names
  # arrives with the handlers that have them.
  def self.checked_profile(profile)
    return if profile.nil?

    raise InvocationError, "no format defines a profile yet: #{profile.inspect}"
  end

  # A batch predicate loses information, so a caller can have the whole
  # result instead: ordered per-file outcomes plus the aggregate status.
  # Same argument shape as `conformance_batch` (paths, pattern:), plus
  # `to:`/`output:`/`force:` for the target and the write lifecycle, so
  # the CLI command and the Ruby API cannot drift about what "which files"
  # or "where to" mean.
  #
  # There is no single-file `Claricle.convert` convenience wrapper yet. It
  # is deferred until there is a real per-conversion result worth returning
  # from one -- building it ahead of that would be an API surface with
  # nothing honest to answer for `output_path`/lossiness yet.
  #
  # The whole destination set is preflighted -- collision, overwrite,
  # case-fold aliasing -- BEFORE any file is converted. That is why this
  # resolves the expanded file list and every destination up front, rather
  # than letting `Batch.run` derive them one file at a time the way
  # `conformance_batch` does.
  #
  # Target resolution runs before the single-source check below, so a
  # `--to`/`--output` mismatch is reported even when the source count is
  # also wrong -- the more specific problem surfaces first rather than
  # being masked by the more generic one.
  def self.convert_batch(*paths, to: nil, output: nil, force: false, pattern: nil)
    files = Batch.expand(paths, pattern)
    target = resolved_convert_target(to: to, output: output)
    raise InvocationError, "--output takes a single source; #{files.length} files matched" if output && files.length > 1

    destinations = files.to_h { |file| [file, convert_destination(file, target: target, output: output)] }
    writer = Writer.new(destinations.values, sources: files, force: force)

    # `classify` always answers 0: the block below either returns normally
    # -- always `nil`, since `Models::BatchItem#result` is still typed to
    # `Report` and stays that way until a handler produces a real
    # conversion result to widen it for -- or raises, which `Batch.run`'s
    # own rescue already turns into a failed item with its own exit code.
    # There is no success/failure distinction left for `classify` to make.
    #
    # `run_files`, not `run`: `files` is already the expanded list built
    # above for the destination preflight. `run` would expand it a SECOND
    # time -- redundant stat/realpath work on every file, and a real gap:
    # a file removed between the two expansions would silently drop out of
    # the second one with no error, even though a destination was already
    # preflighted for it.
    Batch.run_files(files, classify: ->(_result) { 0 }) do |file|
      convert_one(file, target: target, destination: destinations.fetch(file), writer: writer)
    end
  end

  def self.convert_one(file, target:, destination:, writer:)
    image = Image.from_path(file)
    raise InvocationError, "#{file} is already #{target}; nothing to convert to" if image.format == target

    # No handler implements `convert` yet, so this always raises
    # `UnsupportedFormat` today -- exit 3, the same state `conform` is in
    # until its own first handler lands.
    bytes = image.convert(to: target)
    writer.write(bytes, to: destination)
    nil
  end

  # `--to` wins outright when given, once it does not conflict with a
  # recognised `--output` extension. `--output` alone must name a
  # recognised extension to infer from; `--output -` alone cannot, since
  # stdout has no extension.
  #
  # `--to` is case-folded to the registry's own spelling (`Registry.formats`
  # is always lowercase symbols) so `--to SVG` and `--to svg` resolve
  # identically -- unfolded, `--to SVG --output copy.svg` reported a false
  # "conflicts with --output" (the two sides compared `:SVG` against the
  # inferred `:svg`), a same-format `--to SVG` on an already-SVG source
  # skipped the guard below entirely, and the derived destination for a
  # bare `--to SVG` carried the wrong-cased extension.
  def self.resolved_convert_target(to:, output:)
    return resolved_to_target(to, output) if to
    if output == Writer::STDOUT_DESTINATION
      raise InvocationError, "--output - needs --to; there is no extension to infer from"
    end
    raise InvocationError, "give --to, or an --output with a recognised format extension" if output.nil?

    convert_extension_format(output) ||
      raise(InvocationError, "--output #{output.inspect} has no recognised format extension; give --to")
  end

  def self.resolved_to_target(to, output)
    target = to.to_s.downcase.to_sym
    check_to_output_conflict(target, output)
    target
  end

  # A conflict, not a preference: one silently winning over the other would
  # surprise whichever the caller meant. `output:` naming stdout or an
  # unrecognised extension carries no claim about the target, so there is
  # nothing for `--to` to conflict with in either case. `target` arrives
  # already case-folded from `resolved_convert_target`.
  def self.check_to_output_conflict(target, output)
    return if output.nil? || output == Writer::STDOUT_DESTINATION

    inferred = convert_extension_format(output)
    return if inferred.nil? || inferred == target

    raise InvocationError, "--to #{target} conflicts with --output #{output} (looks like #{inferred})"
  end

  # The canonical extension for a target is the format symbol itself --
  # there is no central extension table, only `Registry.formats`.
  def self.convert_extension_format(name)
    ext = File.extname(name.to_s).delete_prefix(".").downcase
    return nil if ext.empty?

    format = ext.to_sym
    Registry.formats.include?(format) ? format : nil
  end

  # The issue's own example: `convert("diagram.emf", to: :svg)` writes
  # `diagram.svg` -- the source's own name, the target's extension,
  # alongside the source.
  def self.convert_destination(file, target:, output:)
    return output if output

    File.join(File.dirname(file), "#{File.basename(file, ".*")}.#{target}")
  end

  private_class_method :accumulate, :conclusive?, :conformant?, :checked_profile,
                       :convert_one, :resolved_convert_target, :resolved_to_target,
                       :check_to_output_conflict, :convert_extension_format, :convert_destination
end
