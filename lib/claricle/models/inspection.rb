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

      # Base freezes Strings and collections; `meta` is a Hash and needs
      # saying so here. Left writable, a sealed Inspection could still
      # have `meta["x"] = 1` written through it and its JSON changed
      # afterwards, which is what sealing is for. Through the reader, so
      # the wrapper deserialization stores is unwrapped first and both
      # doors seal the same object. Shallow, because the copy is: what a
      # handler nested inside `meta` is still the handler's.
      def freeze_attributes
        super
        meta&.freeze
      end

      def nested_models
        issues
      end
    end
  end
end
