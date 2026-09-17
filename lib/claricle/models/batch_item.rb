# frozen_string_literal: true

require_relative "base"
require_relative "report"
require_relative "uncoerced_integer"

module Claricle
  module Models
    # Why this is not a Models::Issue: an Issue is the document's problem,
    # and this is the operation's. A file that could not be opened, or whose
    # format nothing handles, has no conformance verdict at all -- collapsing
    # the two would blur the one line the envelope exists to draw.
    class BatchError < Base
      attribute :code, :string, required: true
      attribute :message, :string, required: true
    end

    # One slot of a batch, and the only element type a batch ever holds. A
    # heterogeneous array of results and failures would force a consumer to
    # type-switch on whether a field is present, and `jq '.[].result.valid'`
    # would answer null for an operational failure -- indistinguishable from
    # a genuine null.
    class BatchItem < Base
      # The codes a process status can carry, so this cannot record one the
      # shell would misread. The same range Cli::Runner::Status enforces.
      CODES = (0..255)
      private_constant :CODES

      attribute :path, :string, required: true
      # Recomputed in `normalize` from the two fields below, so whatever a
      # caller or a document supplies here is overwritten before the model
      # seals. Three values, not two: "the operation ran and said no" and
      # "the operation could not run" are different answers, and the second
      # is why an operational failure must never read as a verdict.
      #
      # Report#valid derives the same kind of summary through a `with:`
      # mapping instead. That route is closed here: lutaml 0.8.22 invokes a
      # `with:` mapping's `from` method on a throwaway instance built by
      # `mapper_class.new` with no arguments at all
      # (mapping_rule.rb:412-417), and Base's lifecycle validates that
      # instance -- measured, `BatchItem.new` raises ValidationError on the
      # two required attributes above. Report has no required attribute, so
      # it never met this. A `to`-only mapping is refused outright
      # ("`:with` argument for mapping 'status' requires :to and :from").
      attribute :status, :string, values: %w[ok failed error]
      attribute :exit_code, UncoercedInteger, required: true
      # Typed to Report because that is the only result a batch produces
      # today. Item 04 adds conversion and has to widen this.
      attribute :result, Report
      attribute :error, BatchError

      private

      # The verdict is written here rather than read from what arrived, so a
      # document cannot assert a status its own fields contradict, and the
      # stored value cannot drift from them.
      def normalize
        self.status = derived_status
      end

      def derived_status
        return "error" if error
        return "ok" if exit_code.is_a?(::Integer) && exit_code.zero?

        "failed"
      end

      # The declared type keeps the caller's value intact precisely so this
      # can tell `"3"` from the `3` lutaml would have made of it.
      def validate_types
        super
        return if exit_code.is_a?(::Integer) && CODES.cover?(exit_code)

        refuse(:exit_code, "an Integer in #{CODES}", exit_code.inspect)
      end

      def nested_models
        [result, error].compact
      end
    end
  end
end
