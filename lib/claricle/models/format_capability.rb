# frozen_string_literal: true

require_relative "base"

module Claricle
  module Models
    # One row of `claricle formats --json`.
    class FormatCapability < Base
      # Lutaml's Boolean accepts lexical aliases such as "false" and 0.
      # Capability rows are structured data, so only JSON booleans belong.
      class StrictBoolean < Lutaml::Model::Type::Boolean
        def self.cast(value, _options = {})
          return value if value.equal?(true) || value.equal?(false)
          return value if value.nil? || Lutaml::Model::Utils.uninitialized?(value)

          raise Lutaml::Model::ValidationError,
                [TypeError.new("boolean expects true or false")]
        end
      end

      attribute :format, :string, required: true
      # Not :inspect, which would replace Object#inspect with a boolean.
      attribute :inspectable, StrictBoolean, required: true
      attribute :conform, StrictBoolean, required: true
      attribute :convert, StrictBoolean, required: true
      attribute :convert_to, :string, collection: true

      key_value do
        map "format", to: :format
        map "inspect", to: :inspectable
        map "conform", to: :conform
        map "convert", to: :convert
        # Without render_empty an empty list is dropped from the row.
        map "convert_to", to: :convert_to, render_empty: true
      end

      private_constant :StrictBoolean
    end
  end
end
