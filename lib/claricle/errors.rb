# frozen_string_literal: true

module Claricle
  class Error < StandardError; end

  class UnknownFormat < Error; end

  # Bad arguments, conflicting flags, a refused destination. The only
  # thing besides Thor::Error and ENOENT that means exit 2.
  class InvocationError < Error; end

  # A conversion that failed after dispatch. Reaches exit 4 through the
  # ordinary StandardError row; there is no blanket Claricle::Error row.
  class ConversionError < Error; end

  # Raised when a format is recognised but nothing handles it, or handles
  # the operation asked for. The class builds its own sentence: callers
  # pass what they were doing, not a phrase.
  class UnsupportedFormat < Error
    # Positional operation, per the settled contract. Keyword-only would
    # make a caller following it raise ArgumentError and land on exit 4.
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
