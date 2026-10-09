# frozen_string_literal: true

# Requires live here, next to the derivation that needs them, so there is
# no load order for the entry point to get wrong. Every file in handlers/
# is loaded, so a new format is one new file there and nothing else.
require_relative "errors"
require_relative "handlers/base"
Dir[File.join(__dir__, "handlers", "*.rb")].each { |file| require file }

module Claricle
  module Registry
    # Every handler class loaded above, in name order so nothing depends on
    # the order the filesystem listed the files in.
    HANDLER_CLASSES = Handlers.const_get(:Base).subclasses.sort_by(&:to_s).freeze

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

      # The profile names one format accepts. Sorted, so the order a
      # handler happens to declare them in never leaks into a message.
      def profiles_for(format)
        handler_for(format).supported_profiles.sort
      end

      # Every profile name ANY registered format accepts. This is what
      # lets a batch reject a typo before it opens a single file --
      # whether the name fits the format in hand is a per-file question
      # and is asked again there.
      def profiles
        HANDLERS.values.flat_map(&:supported_profiles).uniq.sort
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
      #
      # Targets another handler declared it can produce from this format
      # (`convert_from`) are included, so adding a format makes it a target
      # of every source it accepts without editing any of them.
      def convert_targets_for(format)
        (handler_for(format).convert_targets + inbound_targets(format)).uniq - [format]
      end

      # The handler to convert a `from` image to `to`, when `to` is a format
      # whose own handler declared it accepts `from` and `from`'s handler
      # does not already list `to`. nil means "ask the source's handler".
      def inbound_handler(from:, to:)
        return if HANDLERS[from]&.convert_targets&.include?(to)

        owner = HANDLERS[to]
        owner if owner&.convert_sources&.include?(from)
      end

      # The format a handler's declared detector recognises in these leading
      # bytes, or nil. Reached by the detector only after its built-in
      # probes have all declined.
      def detect(header)
        HANDLER_CLASSES.each do |handler|
          format = handler.detect_format(header)
          return format if format
        end
        nil
      end

      private

      def inbound_targets(format)
        HANDLERS.values.uniq.select { |handler| handler.convert_sources.include?(format) }
                .flat_map(&:supported_formats)
      end

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
