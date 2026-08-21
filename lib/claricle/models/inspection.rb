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
        map "meta", to: :meta
        map "parse_status", to: :parse_status
        map "issues", to: :issues, render_empty: true
      end

      # Deserialization wraps the value in the type instance rather than
      # casting it back: lutaml wraps any Hash whose attribute type is
      # not EXACTLY `Type::Hash`, and `FreeFormHash` is a subclass. A
      # caller asked for a Hash and gets one whichever way the model was
      # built.
      #
      # The ivar directly, not `super` -- lutaml defines its readers
      # through `method_missing`, so there is no superclass method here.
      def meta
        raw = @meta
        raw.is_a?(Lutaml::Model::Type::Value) ? raw.value : raw
      end

      private

      def normalize
        self.issues = [] if issues.nil?
      end

      def nested_models
        issues
      end
    end
  end
end
