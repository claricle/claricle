# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "Claricle conformance API" do
  fixtures = File.expand_path("../../fixtures/inspect", __dir__)
  png = File.join(fixtures, "valid.png")
  eps = File.join(fixtures, "basic.eps")

  # A real tree with real bytes, so detection is the real detector and the
  # UnsupportedFormat below is the handler's own answer rather than a
  # stand-in for it.
  def workspace(*sources)
    Dir.mktmpdir do |dir|
      sources.each { |name, source| FileUtils.cp(source, File.join(dir, name)) }
      Dir.chdir(dir) { yield dir }
    end
  end

  describe ".conform?" do
    it "refuses a call with neither a path nor a pattern" do
      expect { Claricle.conform? }
        .to raise_error(Claricle::InvocationError, /exactly one/)
    end

    it "refuses a call with both a path and a pattern" do
      workspace(["a.png", png]) do
        expect { Claricle.conform?("a.png", pattern: "*.png") }
          .to raise_error(Claricle::InvocationError, /exactly one/)
      end
    end

    # A predicate answers about conformance and raises about everything
    # else. EPS never conforms (D22), so it stays the permanent exit-3
    # story here -- and it must not quietly become false.
    it "raises rather than answering false when the format is unsupported" do
      workspace(["a.eps", eps]) do
        expect { Claricle.conform?("a.eps") }
          .to raise_error(Claricle::UnsupportedFormat, /:eps is not supported for conform/)
      end
    end

    # Mixed with a real success on purpose: a.png now conforms, so this
    # proves the raise survives even when it is not the only outcome.
    it "raises out of the batch shape too" do
      workspace(["a.png", png], ["b.eps", eps]) do
        expect { Claricle.conform?(pattern: "*") }
          .to raise_error(Claricle::UnsupportedFormat)
      end
    end

    # Two failures of equal severity, so the choice between them has to be
    # made rather than fallen into. Asserted twice: the same input must fail
    # the same way every time.
    it "fails the same way every time when two files fail equally" do
      workspace(["a.eps", eps], ["b.eps", eps]) do
        messages = Array.new(2) do
          Claricle.conform?(pattern: "*.eps")
        rescue Claricle::UnsupportedFormat => e
          e.message
        end

        expect(messages).to eq(["format :eps is not supported for conform"] * 2)
      end
    end

    # Not a vacuous true, and not a false either -- zero matches is a bad
    # invocation, which is the CLI's exit 2.
    it "refuses a pattern that matched nothing" do
      workspace do
        expect { Claricle.conform?(pattern: "nothing-here-*.png") }
          .to raise_error(Claricle::InvocationError, /no files matched/)
      end
    end

    # A positional follows the same rule the CLI's arguments follow, so the
    # Ruby predicate and the command cannot drift about what one means.
    it "treats a positional that names nothing as a glob that matched nothing" do
      workspace do
        expect { Claricle.conform?("no/such.png") }
          .to raise_error(Claricle::InvocationError, /no files matched/)
      end
    end

    # D8: non-strict passes yes AND suspicious; strict requires yes.
    # Driven against real Reports, because no handler produces one yet.
    describe "the tri-state verdict" do
      severities = {
        "a clean file" => [],
        "an info-only file" => ["info"],
        "a warnings-only file" => ["warning"],
        "a file with an error" => %w[error]
      }
      expectations = {
        "a clean file" => [true, true],
        "an info-only file" => [true, true],
        "a warnings-only file" => [true, false],
        "a file with an error" => [false, false]
      }

      severities.each do |label, list|
        it "passes #{label} non-strict: #{expectations[label][0]}, strict: #{expectations[label][1]}" do
          workspace(["a.png", png]) do
            report = Claricle::Models::Report.new(
              source_path: "a.png", format: "png",
              issues: list.map { |s| Claricle::Models::Issue.new(severity: s, message: "m") }
            )
            image = instance_double(Claricle::Image, conformance_report: report)
            allow(Claricle::Image).to receive(:from_path).and_return(image)

            expect([Claricle.conform?("a.png"), Claricle.conform?("a.png", strict: true)])
              .to eq(expectations[label])
          end
        end
      end
    end
  end

  describe ".conformance_report" do
    it "raises for a format no handler conforms" do
      expect { Claricle.conformance_report(eps) }
        .to raise_error(Claricle::UnsupportedFormat, /:eps is not supported for conform/)
    end

    # The literal-path route, contrasted with the glob route above: this one
    # opens the name it was given and says so when it is not there.
    it "raises the file's own error for a missing path" do
      expect { Claricle.conformance_report("no/such.png") }
        .to raise_error(Errno::ENOENT)
    end
  end

  # PNG conforms now, but declares no profile (03-conform.md: only PDF and
  # SVG will), so a profile it does not define is still a bad invocation.
  # The flag is not silently accepted and then ignored.
  describe "profile:" do
    it "refuses a profile on conformance_report, naming it" do
      expect { Claricle.conformance_report(png, profile: "base") }
        .to raise_error(Claricle::InvocationError, /"base"/)
    end

    it "refuses a profile on conform?" do
      workspace(["a.png", png]) do
        expect { Claricle.conform?("a.png", profile: "base") }
          .to raise_error(Claricle::InvocationError, /"base"/)
      end
    end

    # Once per call, not once per file: a bad profile is one invocation
    # error about the command, never a row in a report.
    it "refuses a profile before the batch runs" do
      workspace(["a.png", png], ["b.eps", eps]) do
        expect { Claricle.conformance_batch(pattern: "*", profile: "base") }
          .to raise_error(Claricle::InvocationError, /"base"/)
      end
    end
  end

  describe ".conformance_batch" do
    # png now conforms (status "ok", exit 0) and eps still cannot (status
    # "error", exit 3) -- the aggregate is unaffected, since 3 was already
    # the max, but the per-item shape below is what actually changed.
    it "returns one ordered envelope per file, with the aggregate code" do
      workspace(["a.png", png], ["b.eps", eps]) do
        result = Claricle.conformance_batch(pattern: "*")

        expect(result.items.map(&:path)).to eq(%w[a.png b.eps])
        expect(result.items.map(&:status)).to eq(%w[ok error])
        expect(result.items.map(&:exit_code)).to eq([0, 3])
        expect(result.exit_code).to eq(3)
      end
    end

    # Collected, not short-circuited: the second file is reached even though
    # the first one succeeded. Asserted on the paths, so dropping either
    # outcome would not pass.
    it "collects every outcome rather than stopping at the first one" do
      workspace(["a.png", png], ["b.eps", eps]) do
        result = Claricle.conformance_batch("a.png", "b.eps")

        expect(result.items.map(&:path)).to eq(%w[a.png b.eps])
        expect(result.items.map { |item| item.error&.code })
          .to eq([nil, "Claricle::UnsupportedFormat"])
      end
    end

    it "takes positionals and a pattern together" do
      workspace(["a.png", png], ["b.eps", eps]) do
        result = Claricle.conformance_batch("a.png", pattern: "*.eps")

        expect(result.items.map(&:path)).to eq(%w[a.png b.eps])
      end
    end
  end
end
