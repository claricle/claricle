# frozen_string_literal: true

require "thor"
require_relative "claricle/version"
require_relative "claricle/errors"
require_relative "claricle/detector"
require_relative "claricle/cli"

module Claricle
  # Detects the format of `source`, a String of image content or an IO.
  #
  # An IO is read to EOF from wherever it is currently positioned -- it is
  # never rewound, so a caller who has already consumed part of it gets a
  # verdict on the remainder. It should be in binary mode; newline
  # translation would corrupt the signatures this matches on. Pass a path to
  # `detect_path` to stream from a file instead of buffering.
  def self.detect(source)
    source.respond_to?(:read) ? Detector.detect(source.read) : Detector.detect(source)
  end

  def self.detect_path(path)
    Detector.detect_path(path)
  end

  private_constant :Detector, :EpsHeader
end
