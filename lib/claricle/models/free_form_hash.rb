# frozen_string_literal: true

require "lutaml/model"

module Claricle
  module Models
    # A Hash attribute that stores exactly what it was given.
    #
    # lutaml-model's own `:hash` type is shaped for XML, and it treats
    # two key names as structure rather than data. Measured on 0.8.19:
    #
    #   {"node" => {"text" => "hi", "lang" => "en"}}  ->  {"node" => {"lang" => "en"}}
    #   {"elements" => {"width" => 1}}                ->  {"width" => 1}
    #   {"text" => "hi"}                              ->  raises NoMethodError
    #
    # The first silently discards a value, the second unwraps a level,
    # and the third is not representable at all. That is correct for
    # markup, where those names carry meaning, and wrong for `meta`,
    # which is whatever a handler read out of a file -- an SVG root
    # legitimately carries `elements` or `text` as an attribute name, and
    # inspecting one crashed the CLI.
    #
    # So this type does no normalisation in either direction. Every key
    # and value goes in and comes back untouched. The container itself is
    # a copy, so a handler that kept its reference cannot rewrite what an
    # inspection already reported.
    class FreeFormHash < Lutaml::Model::Type::Hash
      # lutaml's `hash_type?` compares the class EXACTLY, so a subclass
      # is not recognised as a hash and the value arrives wrapped in an
      # instance of this type rather than as a bare Hash.
      def self.cast(value)
        return super if Lutaml::Model::Utils.uninitialized?(value)
        return nil if value.nil?

        value = value.value if value.is_a?(Lutaml::Model::Type::Value)
        # `.dup`, because `Hash#to_h` returns SELF for a Hash. Without it
        # the model shares the caller's object, and a handler holding a
        # reference could mutate what an inspection already reported.
        #
        # Not frozen here, even though what Inspection ends up storing is:
        # measured, lutaml runs this same cast on the way OUT, so a freeze
        # here would also reach the `meta` inside a rendered document and
        # take it away from whoever asked for the Hash.
        value.to_h.dup
      end

      # Measured on 0.8.19: the key_value pipeline never reaches this --
      # `cast` runs in both directions and does the whole job. It stays
      # because it is the other half of the Type contract, and what it
      # would otherwise inherit is the XML-shaped `serialize` this class
      # exists to keep away from `meta`.
      def self.serialize(value)
        return nil if value.nil?

        value = value.value if value.is_a?(Lutaml::Model::Type::Value)
        value.to_h
      end
    end
  end
end
