# frozen_string_literal: true

require "thor"
require_relative "claricle/version"
require_relative "claricle/errors"
require_relative "claricle/models/location"
require_relative "claricle/models/issue"
require_relative "claricle/models/report"
require_relative "claricle/models/inspection"
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
  # waiting for more. PostScript and EPS are the exception: a byte that
  # hasn't arrived yet can still turn one into the other, so that verdict
  # always waits for the probe bound -- the largest amount any detector
  # probe consults -- or end of stream. A source that stays open and
  # never supplies enough to decide blocks until one of those is
  # reached; content beyond the bound is left unread on the IO rather
  # than buffered. It should be in binary mode; newline translation
  # would corrupt the signatures this matches on. Pass a path to
  # `detect_path` to stream from a file instead of buffering.
  def self.detect(source)
    return Detector.detect(source) unless source.respond_to?(:read)

    Detector.detect(accumulate(source))
  end

  def self.detect_path(path)
    Detector.detect_path(path)
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
    format = Detector.detect(buffer)
    # A PostScript verdict is provisional until the underlying line scan
    # is certain: a byte that hasn't arrived yet can still flip EPSF from
    # a trusted match to a disqualified one, so this loop must not settle
    # for less than a real end of stream or the probe bound.
    !%i[ps eps].include?(format)
  rescue UnknownFormat
    false
  end

  private_class_method :accumulate, :conclusive?
  private_constant :Detector, :EpsHeader, :ReservedNamespace, :Registry, :Handlers
end
