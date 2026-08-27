# frozen_string_literal: true

module Claricle
  class Error < StandardError; end

  class UnknownFormat < Error; end

  # Bad arguments, conflicting flags, a refused destination. Besides
  # Thor::Error and ENOENT, the only *mapped error class* that means exit
  # 2 -- a command can still request 2 explicitly with a Status, or by
  # exiting, since Runner hands a SystemExit's own status back when it is
  # a valid byte.
  class InvocationError < Error; end

  # A conversion that failed after dispatch. Reaches exit 4 through the
  # ordinary StandardError row; there is no blanket Claricle::Error row.
  class ConversionError < Error; end

  # Raised when a format is recognised but nothing handles it, or handles
  # the operation asked for. The class builds its own sentence: callers
  # pass what they were doing, not a phrase.
  class UnsupportedFormat < Error
    # A target nobody can pass, so "not given" and "given as nil" stay
    # different things. `convert(image, to:)` requires the keyword, so a
    # nil arriving here is a caller who forgot their target, not one who
    # has none, and the message says so.
    ABSENT = Object.new.freeze
    private_constant :ABSENT

    def initialize(format, operation = nil, target: ABSENT)
      super(build_message(format, operation, target))
    end

    private

    # No readers and no state: the arguments exist to compose one sentence.
    # A target without an operation reads as nonsense, so it is ignored
    # rather than rendered.
    #
    # Every supplied target is named, however unhelpful it looks. Tested
    # by truthiness the message dropped `false`; tested for nil it
    # dropped `nil`. Both had been supplied, and both times the error
    # named the operation and hid what it was refused for.
    def build_message(format, operation, target)
      message = "format #{format.inspect} is not supported"
      return message unless operation

      message << " for #{operation}"
      message << " to #{target.inspect}" unless target.equal?(ABSENT)
      message
    end
  end
end
