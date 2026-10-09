# frozen_string_literal: true

require_relative "base"

module Claricle
  module Models
    # One row of `claricle formats --json`.
    class FormatCapability < Base
      attribute :format, :string
      # Not :inspect, which would replace Object#inspect with a boolean.
      attribute :inspectable, :boolean
      attribute :conform, :boolean
      attribute :convert, :boolean
      attribute :convert_to, :string, collection: true

      key_value do
        map "format", to: :format
        map "inspect", to: :inspectable
        map "conform", to: :conform
        map "convert", to: :convert
        # Without render_empty an empty list is dropped from the row.
        map "convert_to", to: :convert_to, render_empty: true
      end
    end
  end
end
