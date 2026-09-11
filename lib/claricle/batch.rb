# frozen_string_literal: true

require_relative "errors"
require_relative "fault"
require_relative "models/batch_item"

module Claricle
  # Ordered per-file outcomes plus the batch's aggregate status, so a Ruby
  # caller reaches everything the CLI reaches. Built by Batch; read by
  # everyone else.
  class BatchResult
    attr_reader :items

    # `BatchResult` is public -- item 04 reuses it -- so the "never empty"
    # invariant `exit_code` relies on has to hold here, not only in
    # `Batch.run`'s own call. A caller building one directly with `[]` would
    # otherwise get a silently nil `exit_code`, exactly what the comment
    # below claims cannot happen.
    def initialize(outcomes)
      raise ArgumentError, "outcomes must not be empty" if outcomes.empty?

      @outcomes = outcomes.freeze
      @items = outcomes.map(&:item).freeze
      freeze
    end

    # Never nil: enforced above, and `Batch.run` never reaches here with an
    # empty batch either -- `expand` raises first. Two guards for one
    # invariant because this class is public and `Batch.run` is not.
    def exit_code
      @items.map(&:exit_code).max
    end

    # The operational failure a predicate should raise: the highest code,
    # and on a tie the earliest path. `find` rather than `max_by`, so which
    # of two equal failures wins is a property of this code rather than of
    # an undocumented tie rule -- the same input has to fail the same way
    # every time.
    def highest_error
      failed = @outcomes.reject { |outcome| outcome.error.nil? }
      return if failed.empty?

      highest = failed.map { |outcome| outcome.item.exit_code }.max
      failed.find { |outcome| outcome.item.exit_code == highest }.error
    end
  end

  # One batch helper, owned here and reused by conversion. It knows how to
  # turn arguments into files and how to keep going past a failure; it knows
  # nothing about what the operation means. `classify` decides that, so a
  # second operation does not have to work around the first one's rule.
  module Batch
    # The raised exception is kept beside its envelope rather than inside
    # it: a predicate has to re-raise the real thing, and an envelope holds
    # only what serializes.
    Outcome = Data.define(:item, :error)
    private_constant :Outcome

    # `{a,b}` brace alternation is combinatorial in Ruby's Dir.glob, not
    # linear in the pattern's length -- measured, a bare 100-character
    # --pattern value (`"{a,b}" * 20`) took over ten seconds and a
    # 110-character one did not return inside fifteen, entirely before any
    # filesystem match is attempted. A CLI argument is untrusted input, so
    # it must not be able to turn a short string into an unbounded CPU
    # stall. Eight groups is a generous cap for a real extension list
    # (`*.{png,svg,eps,pdf,gif,bmp,tiff,webp}` is one group of eight
    # alternatives, not eight groups) and costs nothing measurable even at
    # the cap.
    MAX_BRACES = 8
    private_constant :MAX_BRACES

    # The group count alone is not enough: a FEW groups with MANY
    # alternatives each multiply just as badly as many groups with few --
    # measured, eight groups of eight alternatives (`{x1,...,x8}` repeated
    # eight times, still under MAX_BRACES) never returned. Estimated as the
    # product of (alternatives + 1) per non-nested `{...}` group -- it
    # undercounts a nested pattern, but nesting was measured far cheaper
    # than flat repetition for the same brace count (a 4-level-deep,
    # 8-alternative-per-level pattern returned in under a millisecond), so
    # MAX_BRACES is what bounds nesting and this bounds flat alternation.
    MAX_GLOB_COMBINATIONS = 1024
    private_constant :MAX_GLOB_COMBINATIONS

    class << self
      def run(arguments, classify:, pattern: nil, &operation)
        BatchResult.new(
          expand(arguments, pattern).map { |path| outcome(path, classify, &operation) }
        )
      end

      private

      def outcome(path, classify)
        result = yield(path)
        Outcome.new(
          item: Models::BatchItem.new(path: path, exit_code: classify.call(result),
                                      result: result),
          error: nil
        )
      # The set the CLI runner rescues, so Interrupt still propagates and
      # Ctrl-C does not become a row in a report.
      rescue StandardError, ScriptError, SystemStackError => e
        Outcome.new(item: failed_item(path, e), error: e)
      end

      # `Class#name` is nil for an anonymous class -- rare, but a delegate
      # raising `Class.new(StandardError).new(...)` is real Ruby, and
      # `BatchError#code` is required: an unguarded nil there raised
      # `ValidationError` building THIS envelope, uncaught, aborting the
      # whole batch from inside the one rescue that exists to keep a
      # single bad file from doing exactly that. `Class#to_s` is never nil.
      def failed_item(path, error)
        Models::BatchItem.new(
          path: path,
          exit_code: Fault.exit_code(error),
          error: Models::BatchError.new(code: error.class.name || error.class.to_s,
                                        message: Fault.message(error))
        )
      end

      # A positional is a literal path when it names an existing file and a
      # glob otherwise; a pattern is always a glob, which is how a filename
      # that legitimately contains glob characters is reached the other way.
      # `--pattern` adds to the positionals rather than replacing them.
      #
      # `File.file?` decides both times, and it also drops what a glob
      # returns that no operation can open: a directory, or a symlink whose
      # target is gone. Either would otherwise cost exit 4 -- the code for
      # an internal defect -- for an ordinary mismatch.
      #
      # Sorted before deduplicating, so which spelling of two names for one
      # file survives does not depend on the order they were given in.
      def expand(arguments, pattern)
        found = arguments.flat_map do |argument|
          File.file?(argument) ? [argument] : glob(argument)
        end
        found.concat(glob(pattern)) if pattern
        files = found.select { |path| File.file?(path) }
                     .sort.uniq { |path| File.realpath(path) }
        raise InvocationError, nothing_matched(arguments, pattern) if files.empty?

        files
      end

      def glob(text)
        if text.count("{") > MAX_BRACES
          raise InvocationError,
                "glob #{text.inspect} has too many { groups (max #{MAX_BRACES})"
        end

        if glob_combinations(text) > MAX_GLOB_COMBINATIONS
          raise InvocationError,
                "glob #{text.inspect} would expand to too many combinations " \
                "(max #{MAX_GLOB_COMBINATIONS})"
        end

        Dir.glob(text)
      end

      def glob_combinations(text)
        text.scan(/\{[^{}]*\}/).reduce(1) { |total, group| total * (group.count(",") + 1) }
      end

      # Two different mistakes, so two different sentences: naming nothing
      # is not the same as naming something that matched nothing, and
      # "no files matched " with an empty list tells a user neither.
      def nothing_matched(arguments, pattern)
        given = [*arguments, pattern].compact
        return "no files given" if given.empty?

        "no files matched #{given.map(&:inspect).join(", ")}"
      end
    end
  end

  private_constant :Batch
end
