# frozen_string_literal: true

require "lutaml/model"

require_relative "base"
require_relative "uncoerced_integer"

module Claricle
  module Models
    # Where an issue sits in its source. Every field is nullable, because
    # what a delegate can report varies by format. `byte_offset` and
    # `byte_length` are a zero-based half-open range -- issue #1 asks for a
    # byte range, which a bare offset cannot express.
    class Location < Base
      # Every position this model carries, and none of them can be
      # negative: an offset into the source, the length that runs from
      # it, and a line and a column, which are counts into a document.
      POSITIONS = %i[byte_offset byte_length line column].freeze
      # Only `validate_types` below reads it, and that is private. The two
      # enums on `Inspection` and `Issue` are vocabulary a caller builds a
      # model from; this is the loop counter for a check they never run.
      private_constant :POSITIONS

      attribute :byte_offset, UncoercedInteger
      attribute :byte_length, UncoercedInteger
      attribute :line, UncoercedInteger
      attribute :column, UncoercedInteger
      attribute :chunk, :string
      attribute :node_path, :string

      private

      # Absent is fine -- every field is nullable. Anything present has
      # to BE a non-negative Integer, not merely convert to one: the
      # declared type keeps the caller's value intact precisely so this
      # can tell `-0.5` from the `0` lutaml would have made of it.
      #
      # `inspect`, so `"3"` and `3` do not read as the same rejected
      # value in the message.
      def validate_types
        super
        POSITIONS.each do |name|
          value = public_send(name)
          next if value.nil? || (value.is_a?(::Integer) && !value.negative?)

          refuse(name, "a non-negative integer", value.inspect)
        end
      end
    end
  end
end
