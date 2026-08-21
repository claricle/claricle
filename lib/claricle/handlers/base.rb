# frozen_string_literal: true

require_relative "../errors"

module Claricle
  module Handlers
    # A handler declares the formats it owns and implements the operations
    # it supports. Anything it does not implement raises, naming what was
    # asked for, so an unfinished handler says so rather than returning nil.
    class Base
      class << self
        # One declaration per handler, refused on a second call. The
        # registry derives a frozen map at load, so a later redeclaration
        # would leave the two disagreeing about who owns a format --
        # measured: after `Png.formats(:svg)` the registry still answered
        # :png while the handler claimed :svg. Refusing makes that
        # unrepresentable rather than merely unlikely.
        def formats(*symbols)
          raise Error, "#{self} already declared formats #{@formats.inspect}" if @formats

          # Symbols only. The registry keys its map on these and sorts the
          # keys for `Registry.formats`, so one String among them is not a
          # near miss -- measured: after `formats "png", :svg` the sort
          # raises `comparison of String with :svg failed`, and
          # `handler_for(:png)` calls :png unsupported. Refused where the
          # typo is rather than at the first call that trips over it.
          bad = symbols.grep_v(Symbol)
          raise Error, "#{self} declared non-Symbol formats #{bad.inspect}" if bad.any?

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
