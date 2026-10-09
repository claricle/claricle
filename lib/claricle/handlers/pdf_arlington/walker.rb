# frozen_string_literal: true

require_relative "../../models/issue"
require_relative "definitions"
require_relative "kind"
require_relative "rules"

module Claricle
  module Handlers
    module PdfArlington
      # Walks a parsed document breadth-first from the Catalog, following
      # every link Arlington's tables name, and collects what `Rules` finds.
      #
      # Bounded three ways: an object reached through a reference is
      # visited once (cycles end), the walk is a worklist rather than
      # recursion (depth costs no stack), and it stops after MAX_NODES
      # values with a warning that says it stopped.
      class Walker
        MAX_NODES = 50_000
        LIMIT_CODE = "PDF_ARLINGTON_LIMIT"
        MAX_ANCESTORS = 64

        Item = Data.define(:value, :field, :names, :path)

        def initialize(document, version)
          @document = document
          @rules = Rules.new(version)
          @issues = []
          @seen = {}
        end

        def issues
          queue = [Item.new(@document.catalog, nil, %w[Catalog], "Catalog")]
          count = 0
          until queue.empty?
            return limit_reached if (count += 1) > MAX_NODES || count + queue.size > MAX_NODES * 2

            visit(queue.shift, queue)
          end
          @issues
        end

        private

        def visit(item, queue)
          value = Kind.plain(resolve(item.value))
          kind = Kind.of(value)
          @issues.concat(@rules.value_issues(item.field, kind, value, item.path)) if item.field
          return unless Kind::CONTAINERS.include?(kind) && first_visit?(item.value)

          definition = definition_for(item, value, kind)
          descend(definition, value, kind, item.path, queue) if definition
        end

        def definition_for(item, value, kind)
          names = item.names || Definitions.link_names(item.field, kind)
          names && Definitions.pick(names, kind == :array ? nil : dictionary_of(value))
        end

        def descend(definition, value, kind, path, queue)
          dict = kind == :array ? nil : dictionary_of(value)
          check(definition, dict, path) if dict
          entries(dict || value).each do |key, child, child_path|
            field = definition.field_for(key.to_s) || definition.field_for("*")
            queue << Item.new(child, field, nil, "#{path}#{child_path}") if field
          end
        end

        def check(definition, dict, path)
          @issues.concat(@rules.dictionary_issues(definition, dict, path, ->(key) { inherited?(dict, key) }))
        end

        def entries(container)
          if container.is_a?(::Hash)
            container.map { |key, child| [key, child, "/#{key}"] }
          else
            container.each_with_index.map { |child, index| [index, child, "[#{index}]"] }
          end
        end

        def dictionary_of(value)
          Kind.stream?(value) ? value.value : value
        end

        def first_visit?(raw)
          return true unless raw.is_a?(::Pdfrb::Model::Reference)

          @seen.key?(raw.oid) ? false : (@seen[raw.oid] = true)
        end

        # Walks /Parent upward, never revisiting an object and never more
        # than MAX_ANCESTORS steps, so a looping page tree ends.
        def inherited?(dict, key)
          seen = {}
          current = dict
          MAX_ANCESTORS.times do
            current = parent_of(current, seen)
            return false unless current
            return true unless current[key.to_sym].nil?
          end
          false
        end

        def parent_of(dict, seen)
          parent = dict[:Parent]
          return unless parent.is_a?(::Pdfrb::Model::Reference) && !seen.key?(parent.oid)

          seen[parent.oid] = true
          resolved = Kind.plain(resolve(parent))
          resolved if resolved.is_a?(::Hash)
        end

        # nil when pdfrb cannot produce the object. Everything pdfrb
        # reports by raising on a malformed file is "no object here"; the
        # structural check owns reporting the file as broken.
        def resolve(value)
          @document.object(value)
        rescue ::Pdfrb::Error, NoMethodError, TypeError, ArgumentError
          nil
        end

        def limit_reached
          @issues << Models::Issue.new(
            severity: "warning", code: LIMIT_CODE,
            message: "Arlington check stopped after #{MAX_NODES} values; the rest was not checked"
          )
        end
      end
    end
  end
end
