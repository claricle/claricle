# frozen_string_literal: true

require "lutaml/model"

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
    # So the cast is the identity, and the declaring model's
    # `validate_types` decides. One rule, in one place, with the value the
    # caller actually supplied still in hand to name in the message.
    # Everything a model stores is an Integer or nil by the time the
    # lifecycle seals it, so `Type::Integer.serialize` -- which renders
    # through this same cast -- has nothing left to convert.
    #
    # Its own file rather than Location's, because BatchItem's `exit_code`
    # needs it for the same reason and this codebase requires what it names
    # rather than leaning on a transitive require.
    class UncoercedInteger < Lutaml::Model::Type::Integer
      def self.cast(value, _options = {})
        value
      end
    end

    # A coercion workaround, not a type a caller ever names.
    private_constant :UncoercedInteger
  end
end
