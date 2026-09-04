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
    # stall. Eight groups already covers any legitimate extension list
    # (`*.{png,svg,eps,pdf,gif,bmp,tiff,webp}`) and costs nothing
    # measurable even at the cap.
    MAX_BRACES = 8
    private_constant :MAX_BRACES

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

      def failed_item(path, error)
        Models::BatchItem.new(
          path: path,
          exit_code: Fault.exit_code(error),
          error: Models::BatchError.new(code: error.class.name, message: Fault.message(error))
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

        Dir.glob(text)
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
