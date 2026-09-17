# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../../support/pdf_builder"

RSpec.describe "Claricle conformance API" do
  fixtures = File.expand_path("../../fixtures/inspect", __dir__)
  png = File.join(fixtures, "valid.png")
  eps = File.join(fixtures, "basic.eps")
  pdf = PdfBuilder.path(name: "module-api-valid")

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

    # pdf now conforms: a real, structurally valid document reads as
    # `true` through the predicate, driven by a live handler rather than
    # a stub.
    it "answers a real conformance verdict for a format that conforms" do
      workspace(["a.pdf", pdf]) do
        expect(Claricle.conform?("a.pdf")).to be(true)
      end
    end

    # Mixed with a real success on purpose: a.pdf now conforms, so this
    # proves the raise survives even when it is not the only outcome.
    it "raises out of the batch shape too" do
      workspace(["a.pdf", pdf], ["b.eps", eps]) do
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

    # A real Report from a real handler, through the literal-path route --
    # contrasted with the raise above, which is the same format family's
    # other member (png, still unsupported).
    it "returns a real Report for a format that conforms" do
      report = Claricle.conformance_report(pdf)

      expect(report).to be_a(Claricle::Models::Report)
      expect(report.valid).to eq(:yes)
      expect(report.format).to eq("pdf")
    end

    # The literal-path route, contrasted with the glob route above: this one
    # opens the name it was given and says so when it is not there.
    it "raises the file's own error for a missing path" do
      expect { Claricle.conformance_report("no/such.png") }
        .to raise_error(Errno::ENOENT)
    end
  end

  # A profile is refused on TWO different grounds, and they are separate
  # answers a caller fixes by different means: a name no format defines at
  # all is a typo, and a name some format defines but this file's format
  # does not is the wrong pairing. EMF, PDF and PNG conform now but
  # declare no profile (03-conform.md: only PDF and SVG will eventually),
  # so the flag is never accepted and ignored for them either.
  # `checked_profile` is format-agnostic (it runs before any handler is
  # reached), so this holds for every format, conforming or not, until a
  # per-format profile table exists.
  describe "profile:" do
    let(:svg) { File.join(__dir__, "..", "..", "fixtures", "conform", "valid.svg") }

    it "refuses a name no format defines, naming it" do
      expect { Claricle.conformance_report(svg, profile: "no-such-profile") }
        .to raise_error(Claricle::InvocationError, /no format defines a profile named "no-such-profile"/)
    end

    # PNG has a conform handler on a sibling branch and declares no
    # profiles either way, so this stays the "defines none" case. The
    # message says which, rather than leaving the caller to guess whether
    # they mistyped the profile or brought the wrong file.
    # A unit test, because no CLI input can reach this branch TODAY:
    # a name only survives `checked_profile` if some format defines it,
    # and SVG is the only format that defines any, so anything reaching
    # the per-format check for :svg is by construction in SVG's own list.
    # The branch becomes reachable the moment a second format declares a
    # different set, and this is what will already be pinning it.
    it "names what the format does accept, when it accepts anything" do
      error = Claricle::UnsupportedProfile.new(:svg, "nope", %i[base metanorma])

      expect(error.message)
        .to eq('format :svg does not define profile "nope"; it defines :base, :metanorma')
    end

    it "refuses a name the file's own format does not define" do
      expect { Claricle.conformance_report(png, profile: "base") }
        .to raise_error(Claricle::UnsupportedProfile, /:png does not define profile "base"/)
    end

    it "accepts a profile the format does define, and records it" do
      expect(Claricle.conformance_report(svg, profile: "base"))
        .to have_attributes(profile: "base", valid: :yes)
    end

    # The report names the profile it ran under, and the same public API
    # accepts that name back. Those two disagreeing is the defect this
    # example exists to catch, so it asserts the round trip rather than
    # either half.
    it "accepts back the profile a plain report says it ran" do
      ran = Claricle.conformance_report(svg).profile

      expect(Claricle.conformance_report(svg, profile: ran).profile).to eq(ran)
    end

    # The regex pins the current message, not just the profile name: the
    # old wording ("no format defines a profile yet: ...") also contained
    # the name, so a looser pattern here would pass unchanged against
    # code that never checks `Registry.profiles` at all -- measured by
    # mutation-check.sh, which is exactly the gap this file's other
    # `/no format defines a profile named/` pattern (above) already
    # closes.
    it "refuses a bad profile on conform?" do
      workspace(["a.svg", File.join(__dir__, "..", "..", "fixtures", "conform", "valid.svg")]) do
        expect { Claricle.conform?("a.svg", profile: "no-such-profile") }
          .to raise_error(Claricle::InvocationError, /no format defines a profile named "no-such-profile"/)
      end
    end

    # Once per call, not once per file: an unknown name is one invocation
    # error about the command, never a row in a report. Same pinning as
    # above, for the same measured reason.
    it "refuses an unknown profile before the batch runs" do
      workspace(["a.png", png], ["b.eps", eps]) do
        expect { Claricle.conformance_batch(pattern: "*", profile: "no-such-profile") }
          .to raise_error(Claricle::InvocationError, /no format defines a profile named "no-such-profile"/)
      end
    end
  end

  describe ".conformance_batch" do
    # pdf now conforms (status "ok", exit 0) and eps still cannot (status
    # "error", exit 3) -- the aggregate is unaffected, since 3 was already
    # the max, but the per-item shape below is what actually changed.
    it "returns one ordered envelope per file, with the aggregate code" do
      workspace(["a.pdf", pdf], ["b.eps", eps]) do
        result = Claricle.conformance_batch(pattern: "*")

        expect(result.items.map(&:path)).to eq(%w[a.pdf b.eps])
        expect(result.items.map(&:status)).to eq(%w[ok error])
        expect(result.items.map(&:exit_code)).to eq([0, 3])
        expect(result.exit_code).to eq(3)
      end
    end

    # Collected, not short-circuited: the second file is reached even
    # though the first one succeeded. Asserted on the paths, so dropping
    # either outcome would not pass.
    it "collects every outcome rather than stopping at the first one" do
      workspace(["a.pdf", pdf], ["b.eps", eps]) do
        result = Claricle.conformance_batch("a.pdf", "b.eps")

        expect(result.items.map(&:path)).to eq(%w[a.pdf b.eps])
        expect(result.items.map { |item| item.error&.code }).to eq([nil, "Claricle::UnsupportedFormat"])
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
