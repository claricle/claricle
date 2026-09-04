# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Claricle::Batch" do
  batch = Claricle.const_get(:Batch)

  # A real tree, never a stubbed Dir: the whole helper is a set of claims
  # about what the filesystem answers, and a stub would restate the
  # assumption instead of testing it.
  def tree
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  # The operation under test is irrelevant to the helper, so the default is
  # the cheapest thing that produces a result: a Report naming the path.
  report = ->(path) { Claricle::Models::Report.new(source_path: path) }
  clean = ->(_result) { 0 }

  def run(batch, arguments, pattern: nil, classify: nil, &operation)
    batch.run(arguments, pattern: pattern, classify: classify, &operation)
  end

  describe "which files an argument names" do
    # D19: a positional is a literal path when it names an existing file.
    it "takes a positional that names a file literally" do
      tree do
        File.write("a.png", "x")
        result = run(batch, ["a.png"], classify: clean, &report)

        expect(result.items.map(&:path)).to eq(["a.png"])
      end
    end

    it "expands a positional that names nothing as a glob" do
      tree do
        File.write("a.png", "x")
        File.write("b.png", "x")
        result = run(batch, ["*.png"], classify: clean, &report)

        expect(result.items.map(&:path)).to eq(%w[a.png b.png])
      end
    end

    # The case D19 exists for. Measured: Dir.glob("star[1].png") is empty
    # while the file is right there, because the brackets are a character
    # class. The literal rule finds it; --pattern is how a caller asks for
    # the other reading.
    it "finds a filename that legitimately contains glob characters" do
      tree do
        File.write("star[1].png", "x")

        expect(run(batch, ["star[1].png"], classify: clean, &report).items.map(&:path))
          .to eq(["star[1].png"])
        expect { run(batch, [], pattern: "star[1].png", classify: clean, &report) }
          .to raise_error(Claricle::InvocationError)
      end
    end

    # D12: --pattern ADDS to the positionals rather than replacing them.
    it "adds a pattern to the positionals rather than replacing them" do
      tree do
        File.write("a.png", "x")
        File.write("b.svg", "x")
        result = run(batch, ["a.png"], pattern: "*.svg", classify: clean, &report)

        expect(result.items.map(&:path)).to eq(%w[a.png b.svg])
      end
    end

    it "processes the combined set in sorted order" do
      tree do
        %w[c.png a.png b.png].each { |name| File.write(name, "x") }
        result = run(batch, %w[c.png b.png a.png], classify: clean, &report)

        expect(result.items.map(&:path)).to eq(%w[a.png b.png c.png])
      end
    end

    # D12: deduplicated by realpath. Both spellings reach the same file, so
    # the operation must run once -- and which spelling survives must not
    # depend on the order the two were given in, or the same input reports
    # itself under different names.
    it "collapses two names for one file, whatever order they arrive in" do
      tree do
        File.write("a.png", "x")
        File.symlink("a.png", "z_link.png")
        forwards = run(batch, %w[a.png z_link.png], classify: clean, &report)
        backwards = run(batch, %w[z_link.png a.png], classify: clean, &report)

        expect(forwards.items.map(&:path)).to eq(["a.png"])
        expect(backwards.items.map(&:path)).to eq(["a.png"])
      end
    end

    # Dir.glob returns directories and dangling symlinks, and handing either
    # to an operation costs exit 4 -- the internal-defect code -- for what is
    # really "your glob matched something that is not a file".
    it "ignores a directory and a dangling symlink a glob matched" do
      tree do
        File.write("a.png", "x")
        Dir.mkdir("dir.png")
        File.symlink("missing", "dangling.png")
        result = run(batch, ["*.png"], classify: clean, &report)

        expect(result.items.map(&:path)).to eq(["a.png"])
      end
    end

    it "treats a glob that matched only a directory as no match at all" do
      tree do
        Dir.mkdir("dir.png")

        expect { run(batch, ["*.png"], classify: clean, &report) }
          .to raise_error(Claricle::InvocationError)
      end
    end

    # Not a vacuous success: zero matches is the CLI's exit 2.
    it "refuses zero matches, naming what it was given" do
      tree do
        expect { run(batch, ["nope*.png"], pattern: "also*.svg", classify: clean, &report) }
          .to raise_error(Claricle::InvocationError, /"nope\*\.png".*"also\*\.svg"/)
      end
    end

    # A different mistake, so a different sentence. "no files matched" with
    # an empty list names neither what was asked for nor what was wrong.
    it "says nothing was given when nothing was given" do
      tree do
        expect { run(batch, [], classify: clean, &report) }
          .to raise_error(Claricle::InvocationError, "no files given")
      end
    end

    # Dir.glob's brace alternation is combinatorial, not linear: measured,
    # a bare 20-repeat `{a,b}` pattern took over ten seconds to expand and
    # a 22-repeat one did not return inside fifteen -- entirely before any
    # filesystem match is attempted. A CLI argument is untrusted, so this
    # must be refused before Dir.glob ever sees it, not merely slow.
    it "refuses a pattern with too many brace groups rather than hanging" do
      tree do
        expect { run(batch, [], pattern: "{a,b}" * 20, classify: clean, &report) }
          .to raise_error(Claricle::InvocationError, /too many/)
      end
    end

    it "refuses a positional glob with too many brace groups rather than hanging" do
      tree do
        expect { run(batch, ["{a,b}" * 20], classify: clean, &report) }
          .to raise_error(Claricle::InvocationError, /too many/)
      end
    end

    # The cap must not make ordinary usage unreachable.
    it "still expands a pattern with a modest number of brace groups" do
      tree do
        File.write("a.png", "x")
        File.write("b.svg", "x")
        result = run(batch, [], pattern: "*.{png,svg}", classify: clean, &report)

        expect(result.items.map(&:path)).to eq(%w[a.png b.svg])
      end
    end

    # The group count alone does not bound the danger: a handful of groups
    # with many alternatives each multiplies just as badly as many groups
    # with few. Eight groups of eight alternatives stays under MAX_BRACES
    # and never returned before this cap existed -- measured.
    it "refuses a pattern under the brace-group cap but over the combination cap" do
      tree do
        alternatives = (1..8).map { |n| "x#{n}" }.join(",")
        pattern = "{#{alternatives}}" * 8

        expect { run(batch, [], pattern: pattern, classify: clean, &report) }
          .to raise_error(Claricle::InvocationError, /too many/)
      end
    end

    # A single group with many alternatives is linear, not exponential, and
    # is exactly the legitimate shape the brace cap's own comment cites.
    it "still accepts a single group with many alternatives" do
      tree do
        File.write("a.png", "x")
        pattern = "a.{png,svg,eps,pdf,gif,bmp,tiff,webp}"

        expect(run(batch, [], pattern: pattern, classify: clean, &report).items.map(&:path))
          .to eq(["a.png"])
      end
    end
  end

  describe "collecting every outcome" do
    # No all? short-circuiting: a failure in the middle must not cost the
    # files after it. Asserted on the paths, not the count, so a rescue that
    # dropped the failing file and kept a later one still fails.
    it "keeps going past a failure, in path order" do
      tree do
        %w[a.png b.png c.png].each { |name| File.write(name, "x") }
        result = run(batch, ["*.png"], classify: clean) do |path|
          raise Claricle::UnknownFormat, "no signature" if path == "b.png"

          report.call(path)
        end

        expect(result.items.map(&:path)).to eq(%w[a.png b.png c.png])
        expect(result.items.map(&:status)).to eq(%w[ok error ok])
      end
    end

    it "records the failure's class, message and mapped exit code" do
      tree do
        File.write("a.png", "x")
        result = run(batch, ["a.png"], classify: clean) do |_path|
          raise Claricle::UnsupportedFormat.new(:png, :conform)
        end
        item = result.items.first

        expect(item.exit_code).to eq(3)
        expect(item.error.code).to eq("Claricle::UnsupportedFormat")
        expect(item.error.message).to eq("format :png is not supported for conform")
      end
    end

    # A delegate's message is not guaranteed to be valid UTF-8, and
    # Models::Base refuses a String JSON cannot render -- so without
    # normalizing it the batch dies building its own error envelope.
    it "survives a failure whose message is not valid UTF-8" do
      tree do
        File.write("a.png", "x")
        result = run(batch, ["a.png"], classify: clean) do |_path|
          raise StandardError, "broken \xFF".b
        end

        expect(result.items.first.error.message).to be_valid_encoding
        expect(result.items.first.exit_code).to eq(4)
      end
    end

    # The rescue clause is wider than StandardError on purpose: a missing
    # delegate gem raises LoadError, and a broken one can raise
    # NotImplementedError, both ScriptError -- not StandardError. Either
    # must still become one file's failure rather than aborting the whole
    # batch. NotImplementedError, not a bare ScriptError.new: it is the
    # one ScriptError subclass Ruby raises for real, and RuboCop's own
    # Lint/InheritException would silently rewrite a raw
    # `Class.new(Exception)` back inside StandardError.
    it "collects a ScriptError as a per-file failure rather than aborting the batch" do
      tree do
        %w[a.png b.png].each { |name| File.write(name, "x") }
        result = run(batch, ["*.png"], classify: clean) do |path|
          raise NotImplementedError, "no delegate" if path == "a.png"

          report.call(path)
        end

        expect(result.items.map(&:status)).to eq(%w[error ok])
        expect(result.items.first.error.code).to eq("NotImplementedError")
      end
    end

    # `Class#name` is nil for an anonymous class, and a delegate raising
    # `Class.new(StandardError).new(...)` is real Ruby. `BatchError#code`
    # is required, so an unguarded nil there raised inside the one rescue
    # that exists to keep a bad file from taking down the batch -- measured,
    # before the `Class#to_s` fallback existed, this aborted the whole
    # `Batch.run` call instead of recording one failed item.
    it "collects a failure whose class has no name" do
      tree do
        File.write("a.png", "x")
        anonymous = Class.new(StandardError)
        result = run(batch, ["a.png"], classify: clean) { raise anonymous, "boom" }

        expect(result.items.first.status).to eq("error")
        expect(result.items.first.error.code).to match(/\A#<Class:0x\h+>\z/)
      end
    end

    # The set Runner.run rescues stops at StandardError and friends, so
    # Ctrl-C still behaves like Ctrl-C rather than becoming one row of a
    # report.
    it "lets Interrupt through rather than collecting it" do
      tree do
        File.write("a.png", "x")

        expect { run(batch, ["a.png"], classify: clean) { raise Interrupt } }
          .to raise_error(Interrupt)
      end
    end

    it "asks classify for the code of a result that did not raise" do
      tree do
        File.write("a.png", "x")
        result = run(batch, ["a.png"], classify: ->(_r) { 1 }, &report)

        expect([result.items.first.exit_code, result.items.first.status])
          .to eq([1, "failed"])
      end
    end
  end

  describe "the aggregate" do
    # The maximum, not the first or the last: the highest code sits in the
    # middle here, so a fold that took either end would pass without it.
    it "is the highest exit code in the batch" do
      tree do
        %w[a.png b.png c.png].each { |name| File.write(name, "x") }
        codes = { "a.png" => 0, "b.png" => 3, "c.png" => 1 }
        result = run(batch, ["*.png"], classify: ->(r) { codes.fetch(r.source_path) }, &report)

        expect(result.exit_code).to eq(3)
      end
    end

    it "has no error to raise when nothing failed" do
      tree do
        File.write("a.png", "x")

        expect(run(batch, ["a.png"], classify: clean, &report).highest_error).to be_nil
      end
    end

    it "raises the failure with the highest code, not the first one seen" do
      tree do
        File.write("a.png", "x")
        File.write("b.png", "x")
        result = run(batch, ["*.png"], classify: clean) do |path|
          raise Claricle::InvocationError, "bad" if path == "a.png"

          raise Claricle::UnknownFormat, "no signature"
        end

        expect(result.highest_error).to be_a(Claricle::UnknownFormat)
      end
    end

    # Determinism on a tie, which is what makes "the same input always fails
    # the same way" true. Driven from both argument orders, so a choice that
    # depended on iteration order could not pass.
    it "breaks a tie on the earliest path, whatever order the arguments came in" do
      tree do
        File.write("a.png", "x")
        File.write("b.png", "x")
        operation = ->(path) { raise Claricle::UnknownFormat, "failed at #{path}" }

        %w[a.png b.png].permutation.each do |arguments|
          result = run(batch, arguments, classify: clean, &operation)
          expect(result.highest_error.message).to eq("failed at a.png")
        end
      end
    end
  end

  # Reused verbatim by item 04, so the helper must not know conform's rule.
  # The report here is nonconformant by D8 -- Report#valid answers :no --
  # and classify says 0 anyway. A helper that consulted the verdict itself
  # would answer 1 and fail this.
  it "takes the exit code from classify, never from the result's own verdict" do
    tree do
      File.write("a.png", "x")
      nonconformant = lambda do |path|
        Claricle::Models::Report.new(
          source_path: path,
          issues: [Claricle::Models::Issue.new(severity: "error", message: "broken")]
        )
      end
      result = run(batch, ["a.png"], classify: clean, &nonconformant)

      expect(result.items.first.result.valid).to eq(:no)
      expect([result.exit_code, result.items.first.status]).to eq([0, "ok"])
    end
  end

  it "stays a private constant" do
    expect { Claricle::Batch }.to raise_error(NameError, /private constant/)
  end
end
