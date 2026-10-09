# frozen_string_literal: true

require_relative "kind"

module Claricle
  module Handlers
    module PdfArlington
      # Chooses the Arlington table a value is checked against.
      module Definitions
        LINK_GROUP = /\A\[([\w,-]+)\]\z/

        module_function

        # The one candidate table for this value, or nil. With several
        # candidates (`[PageTreeNode,PageObject]`) the value's own /Type
        # must single one out; otherwise no claim is made.
        def pick(names, dict)
          candidates = names.filter_map { |name| load(name) }
          return candidates.first if candidates.one?

          matching = candidates.select { |candidate| types_of(candidate).include?(dict&.fetch(:Type, nil).to_s) }
          matching.first if matching.one?
        end

        def types_of(definition)
          definition.field_for("Type")&.possible_value_list || []
        end

        def load(name)
          ::Pdfrb::Arlington::Loader.object_definition(name)
        rescue ::Pdfrb::Error
          nil
        end

        # One link group per type in the field's type list (`array;stream`
        # pairs with `[A];[B]`): the group of the type the value really is.
        def link_names(field, kind)
          match = LINK_GROUP.match(link_group(field, kind).to_s)
          match && match[1].split(",")
        end

        def link_group(field, kind)
          types = field.types_raw.split(";").map(&:strip)
          groups = field.link.to_s.split(";")
          return groups.first if types.one?
          return unless groups.size == types.size

          index = types.index { |type| Kind::ACCEPTS[type]&.include?(kind) }
          groups[index] if index
        end
      end
    end
  end
end
