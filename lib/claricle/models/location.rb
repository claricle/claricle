# frozen_string_literal: true

require "lutaml/model"

require_relative "base"

module Claricle
  module Models
    # An integer attribute that hands validation the value it was given,
    # rather than a coercion of it.
    #
    # lutaml's own `:integer` casts before anything can look at the
    # value, and the cast destroys the evidence a check would need --
    # measured on 0.8.19, at construction and through `from_json` alike:
    # `-0.5` becomes `0`, `1.5` becomes `1`, `true` becomes `1`, `false`
    # becomes `0` and `"3"` becomes `3`. A non-negative check running
    # after that sees only the result, so `{"byte_offset":-0.5}`
    # deserialized, sealed, and rendered `0` for a position the document
    # never carried.
    #
    # So the cast is the identity, and `Location#validate_types` decides.
    # One rule, in one place, with the value the caller actually supplied
    # still in hand to name in the message. Everything a model stores is
    # an Integer or nil by the time the lifecycle seals it, so
    # `Type::Integer.serialize` -- which renders through this same cast
    # -- has nothing left to convert.
    class UncoercedInteger < Lutaml::Model::Type::Integer
      def self.cast(value, _options = {})
        value
      end
    end

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

    # Location's own coercion problem, not a type a caller ever names.
    private_constant :UncoercedInteger
  end
end
