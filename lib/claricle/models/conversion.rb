# frozen_string_literal: true

require "lutaml/model"

require_relative "base"
require_relative "../lossiness"

# Nested `module Claricle` / `module Models`, never the compact
# `module Claricle::Models`. Measured: the compact form leaves `Claricle` out of
# Module.nesting, so the unqualified `Lossiness` below raises
# `NameError: uninitialized constant Claricle::Models::Conversion::Lossiness`.
# Reproduce with:
#   ruby -e 'module A; module B; end; end; module A::B; p Module.nesting; end'
module Claricle
  module Models
    # Holds bytes lutaml must not try to render.
    #
    # `Models::Base#own_string` runs `JSON.generate` over every String
    # attribute at seal time (base.rb:466-475, reached from freeze_attributes
    # at base.rb:448-458), so a `:string` attribute REFUSES binary content --
    # measured, `ValidationError: content expects a String JSON can render, got
    # "\xFF" from ASCII-8BIT to UTF-8`. Excluding the attribute from the
    # key_value mapping does not help: the check is on the stored String, not
    # on what gets rendered. So the value is stored wrapped, where
    # freeze_attributes does not reach it.
    class BinaryContent < Lutaml::Model::Type::Value
      def self.cast(value, _options = {})
        return value if Lutaml::Model::Utils.uninitialized?(value)
        return nil if value.nil?
        return value if value.instance_of?(self)

        refuse(value) unless value.instance_of?(::String)

        wrap(::String.new(value).freeze)
      end

      # `allocate`, not `new`: `Type::Value#initialize` calls `self.class.cast`
      # (lutaml-model-0.8.22/lib/lutaml/model/type/value.rb:52), so building
      # the wrapper through the constructor recurses to SystemStackError --
      # measured. Reproduce with:
      #   ruby -e 'c = Class.new(Lutaml::Model::Type::Value) do
      #              def self.cast(v, _o = {}) = new(v)
      #            end; c.cast("x")'
      # The String is copied before freezing, so this does not take the
      # caller's own String away from them -- the reason base.rb:445 dups.
      def self.wrap(frozen_bytes)
        allocate.tap do |wrapper|
          wrapper.instance_variable_set(:@value, frozen_bytes)
          wrapper.freeze
        end
      end
      private_class_method :wrap

      def self.serialize(value)
        value.nil? ? nil : cast(value)
      end

      def self.refuse(value)
        raise Lutaml::Model::ValidationError,
              [TypeError.new("content expects a String, got #{value.class}")]
      end
      private_class_method :refuse
    end

    # One conversion's result. `lossiness` is decided per conversion from what
    # the source contains (D23), never from a table of edges.
    class Conversion < Base
      LOSSINESS_LEVELS = Lossiness::LEVELS

      attribute :source_path, :string
      attribute :source_format, :string
      attribute :target_format, :string
      attribute :lossiness, :string, values: LOSSINESS_LEVELS
      attribute :output_path, :string
      attribute :content, BinaryContent

      key_value do
        map "source_path", to: :source_path
        map "source_format", to: :source_format
        map "target_format", to: :target_format
        map "lossiness", to: :lossiness
        map "output_path", to: :output_path
        # `content` is deliberately unmapped: the bytes are an in-memory
        # payload, not part of the document. Measured -- an attribute absent
        # from an explicit key_value block is excluded from to_json, to_yaml
        # and to_hash alike, and a "content" key in an incoming document is
        # ignored rather than resurrected.
        #
        # It is also OPTIONAL rather than required, and that is forced: a
        # required attribute excluded from the mapping cannot reload its own
        # output -- measured, `from_json(to_json)` raises
        # `ValidationError: Missing required attribute: content`.
      end

      # Unwraps the stored BinaryContent. The `*args` form, because lutaml
      # defines attribute readers with `define_method` on this class and the
      # generated reader doubles as the builder-block setter -- a zero-arity
      # reader would make `content` the one attribute that form cannot set.
      # Same shape as Inspection#meta (inspection.rb:160).
      def content(*args)
        unless args.empty?
          self.content = args.first
          return args.first
        end

        @content&.value
      end

      private

      # Required at the model rather than through `required: true`, so the
      # message names the attribute and both doors agree.
      def validate_types
        super
        %i[source_format target_format lossiness].each do |name|
          next unless public_send(name).nil?

          refuse(name, "a value", "nothing")
        end
      end
    end

    private_constant :BinaryContent
  end
end
