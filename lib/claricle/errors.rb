# frozen_string_literal: true

module Claricle
  class Error < StandardError; end

  class UnknownFormat < Error; end

  # Raised when a format is recognised but nothing handles it, or handles
  # the operation asked for. The class builds its own sentence: callers
  # pass what they were doing, not a phrase.
  class UnsupportedFormat < Error
    def initialize(format, operation = nil, target: nil)
      super(build_message(format, operation, target))
    end

    private

    # No readers and no state: the arguments exist to compose one sentence.
    # A target without an operation reads as nonsense, so it is ignored
    # rather than rendered.
    def build_message(format, operation, target)
      message = "format #{format.inspect} is not supported"
      return message unless operation

      message << " for #{operation}"
      message << " to #{target.inspect}" if target
      message
    end
  end
end
