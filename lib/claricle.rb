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

  private_class_method :accumulate, :conclusive?, :conformant?, :checked_profile
end
