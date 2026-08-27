# frozen_string_literal: true

require "lutaml/model"

module Claricle
  module Models
    # A Hash attribute for a plain JSON data graph.
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
    # So this type does no key-name normalisation in either direction.
    # It accepts only an exact core Hash at the outer boundary and copies
    # that container without invoking virtual traversal. `Inspection`
    # owns and validates the complete graph before sealing it.
    class FreeFormHash < Lutaml::Model::Type::Hash
      CORE_INSTANCE = ::Object.instance_method(:instance_of?)
      CLASS_OF = ::Object.instance_method(:class)
      DUPLICATE = ::Object.instance_method(:dup)
      private_constant :CORE_INSTANCE, :CLASS_OF, :DUPLICATE

      # lutaml's `hash_type?` compares the class EXACTLY, so a subclass
      # is not recognised as a hash and the value arrives wrapped in an
      # instance of this type rather than as a bare Hash.
      def self.cast(value)
        return super if Lutaml::Model::Utils.uninitialized?(value)
        return nil if value.nil?

        value = value.value if CORE_INSTANCE.bind_call(value, self)
        refuse(value) unless CORE_INSTANCE.bind_call(value, ::Hash)

        copy(value)
      end

      # Measured on 0.8.19: the key_value pipeline never reaches this --
      # `cast` runs in both directions and does the whole job. It stays
      # because it is the other half of the Type contract, and what it
      # would otherwise inherit is the XML-shaped `serialize` this class
      # exists to keep away from `meta`.
      def self.serialize(value)
        return nil if value.nil?

        cast(value)
      end

      def self.copy(value)
        DUPLICATE.bind_call(value)
      end
      private_class_method :copy

      def self.refuse(value)
        got = CLASS_OF.bind_call(value)
        raise Lutaml::Model::ValidationError,
              [TypeError.new("meta expects core JSON values under String keys, got #{got}")]
      end
      private_class_method :refuse
    end

    # A workaround for one measured lutaml-model behaviour, not a type a
    # caller ever names: `meta` is declared with it here, and what comes
    # back out of a model is a plain Hash either way. Private where it is
    # defined, so the guarantee survives this file being required on its
    # own.
    private_constant :FreeFormHash
  end
end
