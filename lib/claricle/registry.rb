# frozen_string_literal: true

# Requires live here, next to the list that names the classes, so there is
# no load order for the entry point to get wrong.
require_relative "errors"
require_relative "handlers/base"
require_relative "handlers/metafile"
require_relative "handlers/png"
require_relative "handlers/postscript"
require_relative "handlers/svg"

module Claricle
  module Registry
    # One list. A new format adds its handler file above and its class here.
    HANDLER_CLASSES = [Handlers::Metafile, Handlers::Png,
                       Handlers::Postscript, Handlers::Svg].freeze

    class << self
      def handler_for(format)
        HANDLERS.fetch(format) { raise UnsupportedFormat, format }
      end

      def formats
        HANDLERS.keys.sort
      end

      # What one format's handler can actually do -- the `formats`
      # command builds its row from this. Derived from the handler, so a
      # row cannot advertise an operation it has not implemented.
      def capabilities_for(format)
        handler_for(format).capabilities
      end

      # What one format's handler can convert to -- the `formats` command's
      # `convert_to` column builds from this, the same way `capabilities_for`
      # builds the operations column.
      #
      # `- [format]` matters only for a handler owning more than one format
      # (Handlers::Postscript, :eps and :ps): its `convert_to` declares the
      # union both can reach, since a class-level declaration cannot vary
      # per image, so the declared list itself still names the format asked
      # about as one of its own targets. Every single-format handler's own
      # format was never in its declared list to begin with, so this is a
      # no-op for them.
      def convert_targets_for(format)
        handler_for(format).convert_targets - [format]
      end

      private

      # Two classes claiming a format is a configuration defect, not a
      # last-one-wins: the design has one immutable owner per format.
      def build(handler_classes)
        handler_classes.each_with_object({}) do |handler, map|
          handler.supported_formats.each do |format|
            if map.key?(format)
              raise Error, "duplicate handler for #{format.inspect}: " \
                           "#{map[format]} and #{handler}"
            end

            map[format] = handler
          end
        end.freeze
      end
    end

    HANDLERS = send(:build, HANDLER_CLASSES)

    private_constant :HANDLER_CLASSES, :HANDLERS
  end

  # Here rather than in the entry point, for the same reason the requires
  # above are: requiring this file on its own is a supported path, and it
  # used to leave Registry public until claricle.rb happened to run.
  private_constant :Registry
end
