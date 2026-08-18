# frozen_string_literal: true

require_relative "base"
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
      attribute :meta, :hash
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
