# frozen_string_literal: true

require_relative "base"
require_relative "location"

module Claricle
  module Models
    class Issue < Base
      SEVERITIES = %w[error warning info].freeze

      attribute :severity, :string, values: SEVERITIES, required: true
      attribute :code, :string
      attribute :message, :string, required: true
      attribute :location, Location

      private

      def nested_models
        [location].compact
      end
    end
  end
end
