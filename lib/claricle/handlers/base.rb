# frozen_string_literal: true

require_relative "../errors"
require_relative "../models/inspection"
require_relative "../models/issue"

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
        # :png while the handler claimed :svg.
        #
        # What this refuses is a change of mind, not a late first
        # declaration. A class that has declared nothing by the time
        # registry.rb reads the list owns nothing in the map, and
        # declaring afterwards leaves it claiming a format the registry
        # does not route. No handler does that -- the declaration sits in
        # the class body, which has run before the list is read -- so the
        # guarantee here is "no take-backs", not "the two can never
        # disagree".
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

      private

      # The one shape every handler needs and none of them differ on: a
      # parse that did not get far enough to report anything, carrying the
      # single error that says why. Severity is not a parameter because
      # there is only one answer -- an inspection that failed to parse has
      # nothing to warn about.
      #
      # The image's own format, for the same reason `inspection` names it:
      # a handler owning :svg and :svgz must not report :svg for both.
      #
      # `parse_status: "failed"` makes no validity claim; that belongs to
      # conform alone (D17).
      def failed_inspection(image, code:, message:)
        Models::Inspection.new(
          format: image.format.to_s,
          parse_status: "failed",
          issues: [Models::Issue.new(severity: "error", code: code, message: message)]
        )
      end
    end

    private_constant :Base
  end

  # Private where it is defined, so the guarantee survives this file
  # being required on its own rather than through the entry point.
  private_constant :Handlers
end
