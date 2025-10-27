# frozen_string_literal: true

require "thor"
require_relative "claricle/version"

module Claricle
  class Error < StandardError; end

  # Future component loading will go here:
  # require_relative "claricle/png_validator"
  # require_relative "claricle/svg_processor"
  # require_relative "claricle/vector_converter"
  # require_relative "claricle/image_compressor"

  require_relative "claricle/cli"
end
