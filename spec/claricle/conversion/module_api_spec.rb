# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Mirrors spec/claricle/conformance/module_api_spec.rb's structure and
# fixtures: `Claricle.convert_batch` takes the same argument shape as
# `Claricle.conformance_batch` (paths, pattern:), so the two module APIs
# should not drift about what "which files" means, and the same real-tree
# approach keeps detection real rather than stood in for.
#
# No handler implements `convert` yet (item 04), so every real conversion
# attempt still raises `UnsupportedFormat` -- exit 3 via the CLI, a plain
# raise here. These specs are the boundary/plumbing 04-convert.md's item 3
# asks for: argument validation, `--to`/`--output` resolution, and the
# whole-batch destination preflight, driven directly against the Ruby API
# rather than through the CLI's argument parsing.
RSpec.describe "Claricle conversion API" do
  fixtures = File.expand_path("../../fixtures/inspect", __dir__)
  png = File.join(fixtures, "valid.png")
  eps = File.join(fixtures, "basic.eps")
  emf = File.join(fixtures, "valid.emf")
  svg = File.join(fixtures, "valid.svg")

  def workspace(*sources)
    Dir.mktmpdir do |dir|
      sources.each { |name, source| FileUtils.cp(source, File.join(dir, name)) }
      Dir.chdir(dir) { yield dir }
    end
  end

  # Names and bytes of every file in dir, so "nothing was written" holds
  # against any route rather than the one an assertion names.
  def snapshot(dir)
    Dir.children(dir).sort.to_h { |name| [name, File.binread(File.join(dir, name))] }
  end

  # Independent of the Writer's own probe: write an upcased name, ask for
  # the downcased one.
  def folds_case?(dir)
    upper = File.join(dir, "ZZZ-VOLUME-CHECK")
    File.binwrite(upper, "")
    File.exist?(File.join(dir, "zzz-volume-check"))
  ensure
    FileUtils.rm_f(upper)
  end

  describe ".convert_batch" do
    it "refuses a call with neither --to nor --output" do
      workspace(["a.png", png]) do
        expect { Claricle.convert_batch("a.png") }
          .to raise_error(Claricle::InvocationError, /give --to, or an --output/)
      end
    end

    it "refuses --output - with no --to, since there is no extension to infer from" do
      workspace(["a.png", png]) do
        expect { Claricle.convert_batch("a.png", output: "-") }
          .to raise_error(Claricle::InvocationError, /--output - needs --to/)
      end
    end

    it "refuses an --output extension nothing recognises, with no --to" do
      workspace(["a.png", png]) do
        expect { Claricle.convert_batch("a.png", output: "out.bogus") }
          .to raise_error(Claricle::InvocationError, /has no recognised format extension/)
      end
    end

    it "refuses --to and --output naming different formats" do
      workspace(["a.png", png]) do
        expect { Claricle.convert_batch("a.png", to: "svg", output: "result.emf") }
          .to raise_error(Claricle::InvocationError,
                          /--to svg conflicts with --output result\.emf \(looks like emf\)/)
      end
    end

    it "refuses --output naming a single destination when more than one source matches" do
      workspace(["a.png", png], ["b.png", png]) do
        expect { Claricle.convert_batch(pattern: "*.png", to: "svg", output: "out.svg") }
          .to raise_error(Claricle::InvocationError, /--output takes a single source; 2 files matched/)
      end
    end

    # A predicate about the batch shape, not about any one file's
    # convertibility -- proven the same way conformance_batch's own
    # nothing-matched spec is, one directory up.
    it "raises for a pattern that matched nothing" do
      workspace do
        expect { Claricle.convert_batch(pattern: "nothing-here-*.png") }
          .to raise_error(Claricle::InvocationError, /no files matched/)
      end
    end

    # `convert_batch` mirrors `conformance_batch`, not the raising `conform?`
    # predicate: a per-file failure is collected into the result, not
    # raised. `result.highest_error` is the batch's own way to hand the
    # underlying exception back, proven the same way `BatchResult`'s own
    # spec proves it one directory up.
    it "collects a real conversion attempt as a per-file failure, naming the format and target" do
      workspace(["a.png", png]) do
        result = Claricle.convert_batch("a.png", to: "svg")

        expect(result.exit_code).to eq(3)
        expect(result.highest_error).to be_a(Claricle::UnsupportedFormat)
        expect(result.highest_error.message).to match(/:png is not supported for convert to :svg/)
      end
    end

    it "collects a per-file failure out of the batch shape too" do
      workspace(["a.png", png], ["b.eps", eps]) do
        result = Claricle.convert_batch(pattern: "*", to: "emf")

        expect(result.exit_code).to eq(3)
        expect(result.highest_error).to be_a(Claricle::UnsupportedFormat)
        expect(result.highest_error.message).to match(/is not supported for convert to :emf/)
      end
    end

    # `--to` equal to the source's own detected format, with an explicit
    # `--output` distinct from the source -- so this reaches convert's own
    # same-format guard rather than Writer's would-overwrite-an-input check
    # (see the CLI-level spec for the bare `--to <own format>` case, where
    # no `--output` derives a destination identical to the source itself
    # and that check fires first instead). A per-file failure again
    # (Batch's own per-file rescue catches it), not a raise -- proven the
    # same way the two examples above are.
    it "collects a same-format --to as a per-file failure, before any delegate is touched" do
      workspace(["a.eps", eps]) do
        result = Claricle.convert_batch("a.eps", to: "eps", output: "copy.eps")

        expect(result.exit_code).to eq(2)
        expect(result.highest_error).to be_a(Claricle::InvocationError)
        expect(result.highest_error.message).to match(/a\.eps is already eps; nothing to convert to/)
      end
    end

    # The whole destination set is preflighted before any file is
    # converted (04-convert.md's whole-batch-atomic rule) -- proven here by
    # asserting no image is even opened, the same technique the CLI-level
    # spec uses. Two real fixtures, same target, same derived basename.
    it "refuses the whole batch before any file is converted, on a derived-destination collision" do
      workspace(["x.emf", emf], ["x.eps", eps]) do
        expect(Claricle::Image).not_to receive(:from_path)

        expect { Claricle.convert_batch(pattern: "x.*", to: "svg") }
          .to raise_error(Claricle::InvocationError, /two outputs are the same file/)
      end
    end

    # 04-convert.md's four concrete batch cases, each driven through the
    # module API with --force (which authorises replacing an unrelated
    # file, never an input) and each asserting the refusal AND that the
    # directory is byte-for-byte what it was: refused before any write.
    describe "the four preflight cases, under --force" do
      [
        ["a destination that is also a later input",
         [["a.emf", :emf], ["a.svg", :svg]], { paths: %w[a.emf a.svg], to: "svg" },
         /output would overwrite an input/],
        ["two sources deriving the same destination",
         [["a.eps", :eps], ["a.ps", :eps]], { paths: %w[a.eps a.ps], to: "svg" },
         /two outputs are the same file/],
        ["a single source whose --output is itself (reaches the overwrite check)",
         [["logo.svg", :svg]], { paths: %w[logo.svg], output: "logo.svg" },
         /output would overwrite an input/],
        ["the literal plan command, --to emf --output logo.svg (refused earlier by the suffix conflict)",
         [["logo.svg", :svg]], { paths: %w[logo.svg], to: "emf", output: "logo.svg" },
         /--to emf conflicts with --output logo\.svg/]
      ].each do |label, files, args, message|
        it "refuses #{label}, leaving the directory unchanged" do
          sources = files.map { |name, kind| [name, { emf: emf, eps: eps, svg: svg }.fetch(kind)] }
          workspace(*sources) do |dir|
            before = snapshot(dir)

            expect { Claricle.convert_batch(*args[:paths], **args.except(:paths), force: true) }
              .to raise_error(Claricle::InvocationError, message)
            expect(snapshot(dir)).to eq(before)
          end
        end
      end

      it "refuses a destination that is a hardlink to an input" do
        workspace(["a.emf", emf]) do |dir|
          File.link("a.emf", "twin.svg")
          before = snapshot(dir)

          expect { Claricle.convert_batch("a.emf", "twin.svg", to: "svg", force: true) }
            .to raise_error(Claricle::InvocationError, /output would overwrite an input/)
          expect(snapshot(dir)).to eq(before)
        end
      end

      # The oracle is the volume under test, probed independently of the
      # Writer: a case-insensitive volume must refuse; a case-sensitive
      # one must not call the pair a collision.
      it "treats Logo.eps/logo.ps deriving Logo.svg/logo.svg as this volume treats it" do
        workspace(["Logo.eps", eps], ["logo.ps", eps]) do |dir|
          before = snapshot(dir)
          folds = folds_case?(dir)
          error = begin
            Claricle.convert_batch("Logo.eps", "logo.ps", to: "svg", force: true)
            nil
          rescue Claricle::InvocationError => e
            e
          end

          if folds
            expect(error&.message).to match(/collide on a case-insensitive filesystem/)
            expect(snapshot(dir)).to eq(before)
          else
            expect(error&.message).not_to match(/case-insensitive|same file/)
          end
        end
      end
    end

    # `--force` reaching the write lifecycle at the module level, mirroring
    # the CLI spec's own end-to-end proof: without it, no real conversion
    # gets far enough to ask Writer anything in this milestone, so a
    # pre-existing destination refused-then-accepted is the only available
    # signal that `force:` was actually forwarded.
    it "forwards force: to the write lifecycle" do
      workspace(["a.png", png]) do
        File.write("a.svg", "already here")

        expect { Claricle.convert_batch("a.png", to: "svg") }
          .to raise_error(Claricle::InvocationError, /output file exists/)

        result = Claricle.convert_batch("a.png", to: "svg", force: true)
        expect(result.highest_error).to be_a(Claricle::UnsupportedFormat)
        expect(result.highest_error.message).to match(/:png is not supported for convert to :svg/)
      end
    end
  end

  # The pure resolution helpers behind `convert_batch`, driven directly --
  # `registry_spec.rb` and `image_spec.rb` set the precedent for reaching a
  # private class method with `.send` rather than only through its public
  # caller.
  describe "the target-resolution helpers" do
    it "prefers --to outright when there is no conflicting --output" do
      expect(Claricle.send(:resolved_convert_target, to: "svg", output: nil)).to eq(:svg)
      expect(Claricle.send(:resolved_convert_target, to: "svg", output: "-")).to eq(:svg)
    end

    # `Registry.formats` is always lowercase symbols, so `--to` is folded
    # to match -- unfolded, `--to SVG --output copy.svg` compared `:SVG`
    # against the inferred `:svg` and raised a false conflict.
    it "case-folds --to to the registry's own lowercase spelling" do
      expect(Claricle.send(:resolved_convert_target, to: "SVG", output: nil)).to eq(:svg)
      expect(Claricle.send(:resolved_convert_target, to: "SVG", output: "copy.svg")).to eq(:svg)
    end

    # `to: ""` is truthy in Ruby, so `if to` alone treated it as given --
    # building the bogus target `:""` instead of falling through to this
    # same "no target given" error, and going on to a garbled "not
    # supported for convert to :\"\"" instead.
    it "treats an empty --to the same as no --to at all" do
      expect { Claricle.send(:resolved_convert_target, to: "", output: nil) }
        .to raise_error(Claricle::InvocationError, /give --to, or an --output/)
    end

    it "infers the target from a recognised --output extension" do
      expect(Claricle.send(:resolved_convert_target, to: nil, output: "result.emf")).to eq(:emf)
    end

    it "maps only a recognised extension, case-insensitively" do
      expect(Claricle.send(:convert_extension_format, "result.EMF")).to eq(:emf)
      expect(Claricle.send(:convert_extension_format, "result.bogus")).to be_nil
      expect(Claricle.send(:convert_extension_format, "noextension")).to be_nil
    end

    it "derives the sibling destination from the source name and target extension" do
      # File.join(File.dirname("diagram.emf"), ...) is "./diagram.svg", not
      # "diagram.svg" -- File.dirname answers "." for a bare filename, and
      # convert_destination does not strip that, the same way File.join
      # itself does not.
      expect(Claricle.send(:convert_destination, "diagram.emf", target: :svg, output: nil))
        .to eq("./diagram.svg")
      expect(Claricle.send(:convert_destination, "dir/diagram.emf", target: :svg, output: nil))
        .to eq("dir/diagram.svg")
    end

    it "returns the given --output untouched, including stdout, when one is given" do
      expect(Claricle.send(:convert_destination, "diagram.emf", target: :svg, output: "out.svg"))
        .to eq("out.svg")
      expect(Claricle.send(:convert_destination, "diagram.emf", target: :svg, output: "-"))
        .to eq("-")
    end
  end
end
