# frozen_string_literal: true

module Claricle
  module Handlers
    module PdfArlington
      # Maps a Ruby value read from pdfrb onto the Arlington type names it
      # satisfies. A kind of nil means "not one pdfrb type this table knows",
      # and the caller then makes no claim about the value.
      module Kind
        ACCEPTS = {
          "integer" => %i[integer], "bitmask" => %i[integer], "number" => %i[integer number],
          "boolean" => %i[boolean], "name" => %i[name], "null" => %i[null], "stream" => %i[stream],
          "string" => %i[string], "string-ascii" => %i[string], "string-byte" => %i[string],
          "string-text" => %i[string], "date" => %i[string],
          "dictionary" => %i[dictionary], "name-tree" => %i[dictionary],
          "number-tree" => %i[dictionary],
          "array" => %i[array], "rectangle" => %i[array], "matrix" => %i[array]
        }.freeze

        CLASS_KINDS = {
          ::Hash => :dictionary, ::Array => :array, ::Symbol => :name, ::Integer => :integer,
          ::Float => :number, ::String => :string, ::NilClass => :null,
          ::TrueClass => :boolean, ::FalseClass => :boolean
        }.freeze

        CONTAINERS = %i[dictionary stream array].freeze

        module_function

        # A stream keeps its wrapper (the dictionary is only part of it); any
        # other pdfrb object is reduced to the plain value it holds.
        def plain(object)
          return object if stream?(object)

          object.respond_to?(:value) ? object.value : object
        end

        def stream?(object)
          ::Pdfrb::Model::Cos::Stream === object # rubocop:disable Style/CaseEquality
        end

        def of(value)
          return :stream if stream?(value)

          CLASS_KINDS.find { |klass, _| value.is_a?(klass) }&.last
        end

        # The Arlington type names of a field, or nil when any of them is a
        # predicate (`fn:SinceVersion(1.3,dictionary)`) this walker does not
        # evaluate -- a partly understood type list is not checked.
        def types(field)
          names = field.types_raw.split(";").map(&:strip)
          names if names.any? && names.all? { |name| ACCEPTS.key?(name) }
        end

        def allows?(names, kind)
          names.any? { |name| ACCEPTS.fetch(name).include?(kind) }
        end
      end
    end
  end
end
