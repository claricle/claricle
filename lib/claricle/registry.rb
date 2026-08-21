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

      # One row per format, for the `formats` command. Capabilities are
      # derived from the handler, so a row cannot advertise an operation
      # the handler has not implemented.
      def capabilities_for(format)
        handler_for(format).capabilities
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
end
