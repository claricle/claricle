# frozen_string_literal: true

require_relative "base"
require_relative "report"
require_relative "conversion"
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
      # A union rather than a plain `Report`, now that a batch can also hold
      # a conversion. Lutaml resolves which member a Hash/JSON value is by
      # key coverage (`Union.conform_model`, lutaml-model union.rb:163-180):
      # every input key must belong to the member's mapped fields. Report and
      # Conversion both map "source_path", but are disjoint on every OTHER
      # field -- Report also maps "format"/"issues"/"valid", Conversion also
      # maps "source_format"/"target_format"/"lossiness"/"output_path" -- so
      # a real document built by either one always carries at least one of
      # those and resolves unambiguously. Only a Hash bearing "source_path"
      # and nothing else would be genuinely ambiguous, and nothing in this
      # codebase builds one. Declared order does not matter for any real
      # input; Report is listed first as it is the existing, more common
      # case.
      #
      # Known gap, not closed by this change: `Attribute#cast_union` is
      # `match&.last` (lutaml-model attribute.rb:875-879) -- a value that
      # matches NEITHER member silently casts to nil rather than raising, the
      # same silent-nil shape as any other failed cast. Nothing in this
      # codebase can currently produce such a value here (every writer of
      # `result` is Report or Conversion), so it is unreached, not verified
      # unreachable by a guard.
      attribute :result, [Report, Conversion]
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
