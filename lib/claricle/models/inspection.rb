# frozen_string_literal: true

require_relative "base"
require_relative "free_form_hash"
require_relative "issue"

module Claricle
  module Models
    # Inspection reports whether metadata parsed, and makes no validity
    # claim -- that belongs to conform alone (D17).
    class Inspection < Base
      PARSE_STATUSES = %w[ok failed].freeze

      attribute :format, :string
      attribute :width, :float
      attribute :height, :float
      attribute :dpi, :float
      attribute :color_space, :string
      attribute :meta, FreeFormHash
      attribute :parse_status, :string, values: PARSE_STATUSES, required: true
      attribute :issues, Issue, collection: true

      key_value do
        map "format", to: :format
        map "width", to: :width
        map "height", to: :height
        map "dpi", to: :dpi
        map "color_space", to: :color_space
        # render_empty, so a handler that deliberately reported an empty
        # `meta` gets `{}` back rather than nil. Without it the key is
        # omitted from JSON and reloads as nil, turning "I looked and
        # there was nothing" into "I did not look".
        map "meta", to: :meta, render_empty: true
        map "parse_status", to: :parse_status
        map "issues", to: :issues, render_empty: true
      end

      # Deserialization wraps the value in the type instance rather than
      # casting it back: lutaml wraps any Hash whose attribute type is
      # not EXACTLY `Type::Hash`, and `FreeFormHash` is a subclass. A
      # caller asked for a Hash and gets one whichever way the model was
      # built.
      #
      # The ivar directly, not `super`: 0.8.19 defines attribute readers
      # with `define_method` on this very class, so writing one here
      # replaces it and there is no superclass method to reach.
      #
      # `*args` because the generated reader doubles as the builder-form
      # setter -- `Inspection.new { |i| i.meta("a" => 1) }`. A zero-arity
      # reader made `meta` the one attribute that form could not set.
      def meta(*args)
        unless args.empty?
          self.meta = args.first
          return args.first
        end

        raw = @meta
        raw.is_a?(Lutaml::Model::Type::Value) ? raw.value : raw
      end

      private

      def normalize
        self.issues = [] if issues.nil?
      end

      def validate_types
        super
        refuse_infinite(meta)
      end

      # A handler that divided by zero can leave Infinity in `meta`, and
      # JSON has none: the model took it, froze around it, and then could
      # not produce a document at all -- measured, `to_json` raised
      # `JSON::GeneratorError`. Everything else meta holds survives as a
      # String -- a Symbol, a Range and a bare Object all render -- so
      # this is the one value worth walking the container for.
      #
      # `seen`, because meta is stored verbatim and a handler is free to
      # point a container back at itself. A Hash yields its pairs as
      # Arrays, so keys are walked by the same branch as values.
      def refuse_infinite(value, seen = {}.compare_by_identity)
        case value
        when Numeric
          refuse("meta", "finite numbers throughout", value) unless value.finite?
        when Hash, Array
          return if seen[value]

          seen[value] = true
          value.each { |element| refuse_infinite(element, seen) }
        end
      end

      # Base freezes Strings and collections, so a Hash has to be sealed
      # here. Without it a sealed Inspection still takes `meta["x"] = 1`
      # and reports the change in its JSON.
      #
      # Through the reader, because deserialization stores the value
      # wrapped and the reader unwraps it -- both doors then seal the
      # same object. The freeze is shallow, matching the copy that cast
      # made: what a handler nested inside `meta` stays the handler's.
      def freeze_attributes
        super
        meta&.freeze
        # And the wrapper the reader unwraps. Freezing only what `meta`
        # hands back leaves the FreeFormHash deserialization stored in
        # the ivar writable -- measured: after `from_json`,
        # `@meta.instance_variable_set(:@value, {"changed" => true})`
        # gave a frozen Inspection a different `meta` and different JSON,
        # without ever touching a frozen object.
        @meta.freeze
      end

      def nested_models
        issues
      end
    end
  end
end
