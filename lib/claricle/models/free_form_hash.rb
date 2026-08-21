# frozen_string_literal: true

require "lutaml/model"

module Claricle
  module Models
    # A Hash attribute that stores exactly what it was given.
    #
    # lutaml-model's own `:hash` type is shaped for XML, and it treats
    # three key names as structure rather than data. Measured on 0.8.19:
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
    # So this type does no normalisation in either direction. It is a
    # Hash going in and the same Hash coming out.
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
        # `.freeze` on that copy for the other half of the same promise:
        # a sealed Inspection could otherwise still have `meta["x"] = 1`
        # written straight through it, and its JSON changed after the
        # fact. Here rather than in `Base#freeze_attributes`, because this
        # is the one place both doors meet -- deserialization wraps the
        # value afterwards but the wrapped Hash came through here too.
        # The copy is shallow, so what a handler nested inside stays the
        # handler's and stays writable.
        value.to_h.dup.freeze
      end

      def self.serialize(value)
        return nil if value.nil?

        value = value.value if value.is_a?(Lutaml::Model::Type::Value)
        value.to_h
      end
    end
  end
end
