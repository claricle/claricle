# frozen_string_literal: true

require_relative "../../models/issue"
require_relative "../../models/location"
require_relative "kind"
require_relative "predicate_gate"

module Claricle
  module Handlers
    module PdfArlington
      # What Arlington says about ONE dictionary or ONE value, as Issues.
      # Knows nothing about traversal.
      class Rules
        REQUIRED_CODE = "PDF_ARLINGTON_REQUIRED_KEY"
        TYPE_CODE = "PDF_ARLINGTON_TYPE"
        VALUE_CODE = "PDF_ARLINGTON_VALUE"

        # `[Pages]` or `[1.0,1.1]`: plain tokens only, so a predicate
        # (`[fn:Eval(...)]`) or a wildcard is never read as a literal.
        PLAIN_VALUES = /\A\[([^\[\]()@*;]+)\]\z/

        def initialize(version)
          @version = version
          @gate = PredicateGate.new(version)
        end

        # `inherited` answers "does an ancestor supply this key", for the
        # fields Arlington marks inheritable (a Page's /Resources, /MediaBox).
        def dictionary_issues(definition, dict, path, inherited)
          definition.fields.filter_map do |field|
            next unless missing_required?(field, dict, inherited)

            issue(REQUIRED_CODE, "#{definition.name} is missing required key /#{field.key}", path)
          end
        end

        def value_issues(field, kind, value, path)
          return [] if kind.nil?

          [type_issue(field, kind, path), name_issue(field, kind, value, path)].compact
        end

        private

        def missing_required?(field, dict, inherited)
          return false if field.key == "*" || !dict[field.key.to_sym].nil? || !applies?(field)
          return false if field.inheritable? && inherited.call(field.key)

          required_now?(field, dict)
        end

        def required_now?(field, dict)
          field.required? || (field.required_predicate? && @gate.required?(field.required_literal, dict))
        end

        # A key added after the document's version, or by an extension, is
        # not required of it.
        def applies?(field)
          field.since_version.extensions.empty? && (field.since_version <=> @version) <= 0
        end

        def type_issue(field, kind, path)
          names = Kind.types(field)
          return if names.nil? || kind == :null || Kind.allows?(names, kind)

          issue(TYPE_CODE, "#{path} is a #{kind}; Arlington allows #{names.join(" or ")}", path)
        end

        def name_issue(field, kind, value, path)
          return unless kind == :name && field.types_raw == "name"

          match = PLAIN_VALUES.match(field.possible_values.to_s)
          allowed = match && match[1].split(",").map(&:strip)
          return if allowed.nil? || allowed.include?(value.to_s)

          issue(VALUE_CODE, "#{path} is /#{value}; Arlington allows #{allowed.join(", ")}", path)
        end

        def issue(code, message, path)
          Models::Issue.new(severity: "error", code: code, message: message,
                            location: Models::Location.new(node_path: path))
        end
      end
    end
  end
end
