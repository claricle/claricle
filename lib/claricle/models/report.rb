# frozen_string_literal: true

require_relative "base"
require_relative "issue"

module Claricle
  module Models
    class Report < Base
      attribute :source_path, :string
      attribute :format, :string
      attribute :issues, Issue, collection: true
      attribute :profile, :string
      attribute :validator_version, :string

      key_value do
        map "source_path", to: :source_path
        map "format", to: :format
        # Without render_empty an empty collection is dropped from the
        # document entirely, and a consumer sees no issues key at all.
        map "issues", to: :issues, render_empty: true
        map "profile", to: :profile
        map "validator_version", to: :validator_version
        map "valid", with: { to: :valid_to_doc, from: :valid_from_doc }
      end

      # Derived on read, never stored, so it cannot go stale -- reloading
      # recomputes it, and the collection is frozen against appends anyway.
      # D8 order: info never downgrades.
      def valid
        return :no if issues.any? { |issue| issue.severity == "error" }
        return :suspicious if issues.any? { |issue| issue.severity == "warning" }

        :yes
      end

      def valid_to_doc(model, doc)
        doc["valid"] = model.valid.to_s
      end

      # Whatever arrived is discarded; `valid` is recomputed from issues.
      def valid_from_doc(_model, _value); end

      private

      def normalize
        self.issues = [] if issues.nil?
      end

      def nested_models
        issues
      end
    end
  end
end
