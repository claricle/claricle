# frozen_string_literal: true

require_relative "../errors"

module Claricle
  module Handlers
    # A handler declares the formats it owns and implements the operations
    # it supports. Anything it does not implement raises, naming what was
    # asked for, so an unfinished handler says so rather than returning nil.
    class Base
      # Each operation, mapped to the method a handler overrides to
      # support it. The names are the vocabulary of the public API; the
      # CLI happens to print them, but does not own them.
      OPERATIONS = {
        inspect: :inspection,
        conform: :conformance_report,
        convert: :convert
      }.freeze
      private_constant :OPERATIONS

      class << self
        # One declaration per handler, refused on a second call. The
        # registry derives a frozen map at load, so a later redeclaration
        # would leave the two disagreeing about who owns a format --
        # measured: after `Png.formats(:svg)` the registry still answered
        # :png while the handler claimed :svg. Refusing makes that
        # unrepresentable rather than merely unlikely.
        def formats(*symbols)
          raise Error, "#{self} already declared formats #{@formats.inspect}" if @formats

          @formats = symbols.freeze
        end

        def supported_formats
          @formats || [].freeze
        end

        # Derived, never declared. A declaration is a second place to say
        # what the code already says, and it can advertise an operation
        # that is still Base's raising stub -- exactly the lie `formats`
        # exists to avoid. Overriding the method is the only way to claim
        # the capability. Item 04's conversion targets stay declared,
        # because a list of targets is data rather than a boolean.
        def capabilities
          OPERATIONS.reject { |_, method| instance_method(method).owner == Base }.keys
        end
      end

      # The image's own format, not the first one this handler declares --
      # a handler owning :svg and :svgz would otherwise name :svg however
      # it was reached. The operation named is the user-facing one, so
      # `inspection` reports `inspect` (D2 renamed the method because Ruby
      # owns `inspect`, but the command is still `inspect`).
      def inspection(image)
        raise UnsupportedFormat.new(image.format, :inspect)
      end

      def conformance_report(image)
        raise UnsupportedFormat.new(image.format, :conform)
      end

      def convert(image, to:)
        raise UnsupportedFormat.new(image.format, :convert, target: to)
      end
    end

    private_constant :Base
  end
end
