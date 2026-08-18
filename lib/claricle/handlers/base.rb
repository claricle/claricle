# frozen_string_literal: true

require_relative "../errors"

module Claricle
  module Handlers
    # A handler declares the formats it owns and implements the operations
    # it supports. Anything it does not implement raises, naming what was
    # asked for, so an unfinished handler says so rather than returning nil.
    class Base
      class << self
        def formats(*symbols)
          @formats = symbols.freeze
        end

        def supported_formats
          @formats || [].freeze
        end
      end

      # The image's own format, not the first one this handler declares --
      # a handler owning :svg and :svgz would otherwise name :svg however
      # it was reached. The operation named is the user-facing one, so
      # `inspection` reports `inspect` (D2 renamed the method because Ruby
      # owns `inspect`, but the command is still `inspect`).
      def inspection(image)
        raise UnsupportedFormat.new(image.format, operation: :inspect)
      end

      def conformance_report(image)
        raise UnsupportedFormat.new(image.format, operation: :conform)
      end

      def convert(image, to:)
        raise UnsupportedFormat.new(image.format, operation: :convert, target: to)
      end
    end

    private_constant :Base
  end
end
