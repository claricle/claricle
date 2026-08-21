# frozen_string_literal: true

require_relative "base"

module Claricle
  module Models
    # Where an issue sits in its source. Every field is nullable, because
    # what a delegate can report varies by format. `byte_offset` and
    # `byte_length` are a zero-based half-open range -- issue #1 asks for a
    # byte range, which a bare offset cannot express.
    class Location < Base
      # The two ends of that range. Neither can be negative, and lutaml
      # coerces the type without ever looking at the value -- measured:
      # `{"byte_offset":-1,"byte_length":-4}` deserialized, froze, and
      # rendered both numbers straight back out.
      BYTE_RANGE = %i[byte_offset byte_length].freeze

      attribute :byte_offset, :integer
      attribute :byte_length, :integer
      attribute :line, :integer
      attribute :column, :integer
      attribute :chunk, :string
      attribute :node_path, :string

      private

      def validate_types
        super
        BYTE_RANGE.each do |name|
          value = public_send(name)
          next unless value.is_a?(Integer) && value.negative?

          refuse(name, "a non-negative integer", value)
        end
      end
    end
  end
end
