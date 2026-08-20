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
  # An IO is read to EOF from wherever it is currently positioned -- it is
  # never rewound, so a caller who has already consumed part of it gets a
  # verdict on the remainder. It should be in binary mode; newline
  # translation would corrupt the signatures this matches on. Pass a path to
  # `Image.from_path` to stream from a file instead of buffering.
  def self.detect(source)
    source.respond_to?(:read) ? Detector.detect(source.read) : Detector.detect(source)
  end

  private_constant :Detector, :EpsHeader, :AttributeDefaults, :Registry, :Handlers
end
