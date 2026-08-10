# Claricle Issue #1 — Unified Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `claricle` placeholder gem into a real umbrella library: one Ruby API and one CLI providing inspect, conformance check, and conversion over PNG, SVG, EMF/WMF, PS/EPS, and PDF by delegating to the org's specialist gems.

**Architecture:** A handler registry (one plain-Ruby handler class per format family, self-registering at load) fronted by `Claricle::Image` and a Thor CLI wrapped in an exit-code-mapping runner. Unified `Issue`/`Report`/`Inspection` models are lutaml-model classes; each handler maps its specialist gem's native result shape into them. Format detection is a hand-rolled magic-byte sniffer.

**Tech Stack:** Ruby >= 3.2, Thor ~> 1.0, lutaml-model ~> 0.8, and the specialist gems: `emf`, `png_conform`, `svg_conform`, `vectory`, `postscript`, `pdfrb`.

## Global Constraints

- Ruby floor: `>= 3.2.0` (forced by `pdfrb`; update gemspec, `.rubocop.yml` TargetRubyVersion, CI matrix to `['3.2', '3.3']`).
- Pure Ruby only. `libpng` (FFI) is **excluded** — no v1 operation needs a raster codec; PNG metadata comes from `png_conform`.
- No hand-rolled `to_h`/`from_h` on models — all unified models are `Lutaml::Model::Serializable`.
- Real specs, no `double()`. Conformance specs run against fixtures (specialist gems ship canonical corpora; claricle keeps a small local fixture set per format).
- RuboCop clean (double quotes, NewCops enable); `bundle exec rake` (spec + rubocop) green at every commit.
- Every new Ruby file starts with `# frozen_string_literal: true` — the plan's code blocks omit it for brevity; the real files must not.
- Commit messages: single one-line subject, under 10 words.
- Exit codes: 0 success/conformant, 1 nonconformant, 2 invocation error, 3 unsupported format/conversion, 4 internal error.

---

## Decisions of record (consensus: Claude + Codex, 2026-08-10)

All ten design questions were settled between Claude and Codex with no unresolved disagreement. Deviations from the issue text are marked **[deviation]** — these should be posted back to issue #1 for the author's sign-off.

| # | Decision |
|---|----------|
| D1 | Four PRs, vertical slices: PR1 core, PR2 inspect, PR3 conform, PR4 convert. Docs land inside each PR; README fully rewritten by end of PR4. |
| D2 | **[deviation]** `Image#inspect` renamed to `Image#inspection` — `Object#inspect` is Ruby's universal debugging protocol and must keep returning a diagnostic string. No module-level facade (`Claricle.inspect(src)` would shadow `Module#inspect` and break `p Claricle`). |
| D3 | Handlers are plain subclasses with ordinary methods (`inspection`, `conformance_report`, `convert`) + a `formats` class macro that declares supported formats. No block DSL. The registry is a frozen map derived from one list of handler classes — no runtime mutation, no self-registration side effects (thermo-nuclear amendment to the original "register at load" idea; formats stay declared once, in the handler). |
| D4 | Unified models (`Issue`, `Location`, `Report`, `Inspection`, later `Conversion` result) are lutaml-model classes; `lutaml-model` is a direct dependency (`~> 0.8`, compatible with png_conform `~> 0.7` and svg_conform `~> 0.8.0` constraints — verify resolution at bundle time). |
| D5 | **[deviation]** Hard dependencies on all delegates, Ruby floor 3.2, `libpng` dropped from scope. Heavy gems are `require`d lazily inside their handlers so `claricle version` stays fast. |
| D6 | Keep Thor. A `Runner` wraps `Cli.start(argv, debug: true)` (Thor re-raises `Thor::Error` when `config[:debug]` is set — verify against installed Thor with dependency-contract-check) and maps: `Thor::Error`/`Errno::ENOENT` → 2, `UnknownFormat`/`UnsupportedFormat` → 3, other `StandardError` → 4. Conformance failure exits 1 from the command itself. |
| D7 | Hand-rolled detector: PNG 8-byte signature, `%PDF-`, `%!PS` (+ `EPSF` in first line → `:eps`, else `:ps`), EMF/WMF via `Emf.detect_format`, SVG via XML-aware root sniff. Marcel not used. |
| D8 | Tri-state `valid` kept: `yes` = no issues, `suspicious` = warnings only, `no` = any error. `conform?` passes `yes`+`suspicious`; `--strict`/`strict:` requires `yes`. |
| D9 | Conversion routes through `vectory` only; v1 matrix is the vector set (EMF↔SVG, PS/EPS↔SVG, SVG→EPS/PS). PNG and PDF are inspect/conform-only. WMF gets inspect/conform via the `emf` gem but **no** conversion (vectory has no WMF class). EMF+ surfaces as inspection metadata (`metafile.emf_plus`), not a separate format symbol. |
| D10 | Lossiness is a static per-edge enum in the registry: `:lossless` / `:lossy` / `:unknown`. SVG→EMF is `:lossy` (documented "lossy matcher"); unproven edges stay `:unknown` until fixture evidence upgrades them. Lossy/unknown conversions warn on stderr and carry the classification in the result — **no** consent-gate flag (the issue requires disclosure, not consent). |
| D11 | **[deviation]** Round-trip acceptance narrowed: byte-identical A→B→A across formats is NOT promised (vectory's own specs are semantic, not byte-identical; only emf's same-format parse→serialize is byte-identical). Claricle asserts: same-format round-trip identity where the delegate guarantees it, and semantic checks (dimensions, delegate fixtures) for conversions. |
| D12 | Batch semantics: `Dir.glob(pattern).sort`; zero matches → exit 2; per-file failures don't stop the batch; final exit = highest code across files; JSON batch output is an array. `--output` only valid for a single source; batch convert derives target name by swapping the extension and refuses to overwrite without `--force`. With `--output -`, stdout carries bytes only (diagnostics → stderr) and `--json` is rejected (exit 2). These rules live in ONE CLI batch helper introduced by PR3 and reused verbatim by PR4 — never two loops. |
| D13 | Pin against **released** delegate versions (e.g. pdfrb published 0.7.1, not the 0.7.8 repo head). Bundler resolution is verified in PR1/PR2 tasks. |

**Formats registered in v1:** `:png`, `:svg`, `:emf`, `:wmf`, `:eps`, `:ps`, `:pdf`.

## PR roadmap

Each PR gets its own detailed task plan when picked up (this document fully details PR1). Every PR independently passes `bundle exec rake` and the Pre-Push Review Chain.

### PR1 — Core (detailed below)
Errors, unified models, detector, registry + handler base, `Image`, CLI rebuild (stubs removed, `version` kept), exit-code runner, tooling floor bump. Registry ships empty: every operation raises `UnsupportedFormat` through the real dispatch path until PR2.

### PR2 — Inspect
- Adds deps: `png_conform`, `svg_conform`, `vectory`, `postscript`, `pdfrb`.
- Five handler classes (`Handlers::Png`, `Svg`, `Metafile` (:emf/:wmf), `Postscript` (:eps/:ps), `Pdf`) implementing `inspection(image)`.
  - PNG: `PngConform::Services::ValidationService.validate_file` → `image_info` (width/height/bit depth/color type). Uses `image.with_path`.
  - SVG: `Vectory::Svg.from_content` → width/height; meta from root attributes.
  - EMF/WMF: `::Emf.parse(image.content)` → header bounds/device dims; `meta[:emf_plus]`. (Handlers must reference delegates with `::` — `Claricle::Handlers::X` shadows top-level constants.)
  - EPS/PS: `Vectory::Eps`/`Ps` BoundingBox dims; structure via `::Postscript.parse`.
  - PDF: `Pdfrb::Document.open` → version, page count. Uses `image.with_path`.
- `capabilities` macro on handlers; `claricle formats` command printing the format × operation matrix (human + `--json`).
- `claricle inspect FILE [--json]` command.
- Inspection `valid`/`issues` populated from the same parse (cheap conformance signal only; full reports are PR3).

**Interfaces produced:** `Handlers::<X>#inspection(image) -> Models::Inspection`; `Cli#inspect`; `Cli#formats`.

### PR3 — Conform
- `conformance_report(image)` per handler, each mapping native shapes → `Models::Issue`:
  - png_conform `ValidationError{severity, error_type, message, chunk_type, chunk_offset}` → `Issue{severity, code: error_type, location: {chunk, byte_offset}}`.
  - svg_conform `ValidationIssue{type, requirement_id, message, line, column}` → `Issue{severity: type, code: requirement_id, location: {line, column}}`.
  - emf: `metafile.errors` (message, offset, record_code) → `Issue{severity: "error", code: "EMF_PARSE", location: {byte_offset}}`; clean parse + serialize round-trip identity = conformant.
  - postscript: exceptions (`ParseError`, `LexError`, `SyntaxError`) → single `Issue{severity: "error", code: exception class}`; clean parse = conformant.
  - pdfrb: `Validator.validate` strings → `Issue{severity: "error", code: "PDF_STRUCTURE"}`; `Conformance::*` `Violation{rule_id, severity, spec_clause, object}` → `Issue{code: rule_id, location: {node_path: object}}`.
  - `location` is nullable throughout; synthetic stable codes where upstream has none; never invent coordinates.
- Module API: `Claricle.conform?(path_or_pattern, strict: false)`, `Claricle.conformance_report(path)`.
- `claricle conform FILE|PATTERN [--json] [--strict]` with batch semantics (D12) and exit 1 on nonconformance.
- Fixture set: valid + invalid sample per format (sourced from delegates' corpora).

**Interfaces produced:** `Handlers::<X>#conformance_report(image) -> Models::Report`; `Claricle.conform?`; `Claricle.conformance_report`.

### PR4 — Convert
- `Models::Conversion` (lutaml-model): `source_format`, `target_format`, `lossiness`, `content` (excluded from JSON serialization), `output_path`.
- `Handlers::Metafile#convert` / `Postscript#convert` / `Svg#convert` via vectory (`Vectory::Emf.from_content(...).to_svg` etc.); static lossiness edge table (D10).
- `Claricle.convert(src, to:, output: nil)`; `Image#convert(to:)` returning the in-memory result.
- `claricle convert SOURCE [--to FORMAT] [--output FILE|-] [--force]`, batch per D12.
- Round-trip/semantic specs per D11; edge table upgraded only on fixture evidence.
- README.adoc fully rewritten (real API + CLI, format matrix, exit codes); gemspec description/homepage refreshed (org moved ribose → claricle); stale `sig/claricle.rbs` replaced or removed.

**Interfaces produced:** `Handlers::<X>#convert(image, to:) -> Models::Conversion`; `Claricle.convert`.

## Out of scope (entire issue)

Compression (stub deleted in PR1, no replacement), rendering/rasterization, image editing, `arroolio`, WMF conversion, `libpng`, releasing the gem (post-PR4, maintainer-driven).

---

# PR1 — Core: detailed tasks

**File structure:**

```
lib/claricle.rb                 modify — require tree, drop stale comments
lib/claricle/errors.rb          create — error taxonomy
lib/claricle/models/location.rb create — nullable location model
lib/claricle/models/issue.rb    create — unified issue model
lib/claricle/models/report.rb   create — conformance report + tri-state
lib/claricle/models/inspection.rb create — inspect result model
lib/claricle/detector.rb        create — magic-byte sniffer
lib/claricle/registry.rb        create — format → handler map
lib/claricle/handlers/base.rb   create — abstract handler + formats macro
lib/claricle/image.rb           create — path/content entry object
lib/claricle/cli.rb             modify — remove stubs, keep version, add Runner
exe/claricle                    modify — exit Runner.run(ARGV)
claricle.gemspec                modify — floor 3.2, add emf + lutaml-model
.rubocop.yml                    modify — TargetRubyVersion 3.2
.github/workflows/main.yml      modify — matrix ['3.2', '3.3']
spec/claricle/*_spec.rb         create — one per unit above
spec/fixtures/detector/         create — minimal real files per format
```

### Task 1: Tooling floor + gemspec

**Files:** Modify `claricle.gemspec`, `.rubocop.yml`, `.github/workflows/main.yml`.

- [ ] Set `spec.required_ruby_version = ">= 3.2.0"`; add `spec.add_dependency "emf", "~> 0.1"` and `spec.add_dependency "lutaml-model", "~> 0.8"` (keep thor).
- [ ] `.rubocop.yml`: `TargetRubyVersion: 3.2`.
- [ ] CI matrix: `ruby: ['3.2', '3.3']`.
- [ ] Run `bundle install` — must resolve cleanly against released gems (D13).
- [ ] Run `bundle exec rake` — green.
- [ ] Commit: `chore: raise floor, add emf and lutaml-model`

### Task 2: Error taxonomy

**Files:** Create `lib/claricle/errors.rb`, `spec/claricle/errors_spec.rb`; modify `lib/claricle.rb` (require; delete the "Future component loading" comment block).

**Produces:** `Claricle::UnknownFormat`, `Claricle::UnsupportedFormat.new(format, operation = nil)`, `Claricle::ConversionError`, all `< Claricle::Error`.

- [ ] Failing spec:

```ruby
RSpec.describe "Claricle errors" do
  it "describes an unsupported operation" do
    error = Claricle::UnsupportedFormat.new(:wmf, :convert)
    expect(error.message).to eq("format :wmf is not supported for convert")
    expect(error).to be_a(Claricle::Error)
  end

  it "describes an unsupported format without operation" do
    expect(Claricle::UnsupportedFormat.new(:tiff).message)
      .to eq("format :tiff is not supported")
  end
end
```

- [ ] Implement:

```ruby
module Claricle
  class UnknownFormat < Error; end

  class UnsupportedFormat < Error
    def initialize(format, operation = nil)
      suffix = operation ? " for #{operation}" : ""
      super("format #{format.inspect} is not supported#{suffix}")
    end
  end

  class ConversionError < Error; end
end
```

(`Claricle::Error` already exists in `lib/claricle.rb`; move it into `errors.rb`.)

- [ ] `bundle exec rspec spec/claricle/errors_spec.rb` — PASS; rubocop touched files.
- [ ] Commit: `feat: add error taxonomy`

### Task 3: Unified models

**Files:** Create `lib/claricle/models/{location,issue,report,inspection}.rb`, `spec/claricle/models_spec.rb`; modify `lib/claricle.rb` (requires: `lutaml/model` then models in dependency order).

**Produces:** `Models::Location{byte_offset, line, column, chunk, node_path}` (all nullable), `Models::Issue{severity, code, message, location}`, `Models::Report.build(path:, format:, issues:)` with tri-state `valid`, `Models::Inspection{format, width, height, dpi, color_space, meta, valid, issues}`. All serialize to JSON via lutaml-model (`to_json`).

- [ ] Failing spec:

```ruby
RSpec.describe Claricle::Models::Report do
  def issue(severity)
    Claricle::Models::Issue.new(severity: severity, code: "X1", message: "m")
  end

  it "is yes with no issues" do
    expect(described_class.build(path: "a.png", format: "png", issues: []).valid)
      .to eq("yes")
  end

  it "is suspicious with warnings only" do
    report = described_class.build(path: "a.png", format: "png",
                                   issues: [issue("warning")])
    expect(report.valid).to eq("suspicious")
  end

  it "is no with any error" do
    report = described_class.build(path: "a.png", format: "png",
                                   issues: [issue("warning"), issue("error")])
    expect(report.valid).to eq("no")
  end

  it "serializes to JSON without hand-rolled mapping" do
    report = described_class.build(path: "a.png", format: "png", issues: [])
    expect(JSON.parse(report.to_json)).to include("valid" => "yes")
  end
end
```

- [ ] Implement (pattern per png_conform's models; severity values documented as `error|warning|info`):

```ruby
module Claricle
  module Models
    class Location < Lutaml::Model::Serializable
      attribute :byte_offset, :integer
      attribute :line, :integer
      attribute :column, :integer
      attribute :chunk, :string
      attribute :node_path, :string
    end

    class Issue < Lutaml::Model::Serializable
      attribute :severity, :string # error | warning | info
      attribute :code, :string
      attribute :message, :string
      attribute :location, Location
    end

    class Report < Lutaml::Model::Serializable
      attribute :path, :string
      attribute :format, :string
      attribute :valid, :string # yes | suspicious | no
      attribute :issues, Issue, collection: true

      def self.build(path:, format:, issues:)
        new(path: path, format: format, issues: issues,
            valid: tri_state(issues))
      end

      def self.tri_state(issues)
        return "no" if issues.any? { |i| i.severity == "error" }
        return "suspicious" if issues.any? { |i| i.severity == "warning" }

        "yes"
      end
    end

    class Inspection < Lutaml::Model::Serializable
      attribute :format, :string
      attribute :width, :integer
      attribute :height, :integer
      attribute :dpi, :integer
      attribute :color_space, :string
      attribute :meta, :hash
      attribute :valid, :string
      attribute :issues, Issue, collection: true
    end
  end
end
```

- [ ] Contract check (dependency-contract-check discipline): in `bin/console`, construct each model and run `to_json`/`from_json` against the real installed lutaml-model before trusting the spec; adjust attribute types if the DSL differs.
- [ ] Specs pass; rubocop clean. Commit: `feat: add unified issue and report models`

### Task 4: Detector

**Files:** Create `lib/claricle/detector.rb`, `spec/claricle/detector_spec.rb`, `spec/fixtures/detector/` (copy the smallest real `.emf` and `.wmf` fixtures from the `emf` gem's spec corpus); modify `lib/claricle.rb` (require "emf" + detector).

**Produces:** `Detector.detect(bytes) -> Symbol` (raises `UnknownFormat`), `Detector.detect_path(path)`. Symbols: `:png :svg :emf :wmf :eps :ps :pdf`.

- [ ] Failing spec:

```ruby
RSpec.describe Claricle::Detector do
  FIXTURES = File.expand_path("../fixtures/detector", __dir__)

  it "detects png" do
    expect(described_class.detect("\x89PNG\r\n\x1a\n#{"\x00" * 8}".b)).to eq(:png)
  end

  it "detects pdf" do
    expect(described_class.detect("%PDF-1.7\n%rest")).to eq(:pdf)
  end

  it "splits eps from ps on the DSC header" do
    expect(described_class.detect("%!PS-Adobe-3.0 EPSF-3.0\n")).to eq(:eps)
    expect(described_class.detect("%!PS-Adobe-3.0\n")).to eq(:ps)
  end

  it "detects emf and wmf from real fixtures" do
    expect(described_class.detect_path("#{FIXTURES}/sample.emf")).to eq(:emf)
    expect(described_class.detect_path("#{FIXTURES}/sample.wmf")).to eq(:wmf)
  end

  it "detects svg with xml prolog, doctype and leading comment" do
    svg = "\uFEFF<?xml version=\"1.0\"?>\n<!-- c -->\n<!DOCTYPE svg>\n<svg xmlns=\"x\"/>"
    expect(described_class.detect(svg)).to eq(:svg)
  end

  it "raises UnknownFormat on unrecognized bytes" do
    expect { described_class.detect("GIF89a") }
      .to raise_error(Claricle::UnknownFormat)
  end
end
```

- [ ] Implement:

```ruby
module Claricle
  module Detector
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b
    # 4096, not 512: real-world SVGs carry multi-KB license comments before <svg>.
    HEADER_BYTES = 4096
    SVG_ROOT = /\A\s*(?:<\?xml[^>]*\?>\s*)?(?:<!--.*?-->\s*)*(?:<!DOCTYPE[^>]*>\s*)?<svg[\s>\/]/m

    module_function

    def detect_path(path)
      detect(File.binread(path, HEADER_BYTES).to_s)
    end

    def detect(bytes)
      bytes = bytes.to_s.b # callers may hand UTF-8 strings; compare in binary
      return :png if bytes.start_with?(PNG_SIGNATURE)
      return :pdf if bytes.start_with?("%PDF-")
      return postscript_flavor(bytes) if bytes.start_with?("%!PS")

      metafile = ::Emf.detect_format(bytes)
      return metafile if metafile
      return :svg if svg?(bytes)

      raise UnknownFormat, "no known image signature in leading bytes"
    end

    def postscript_flavor(bytes)
      bytes.lines.first.to_s.include?("EPSF") ? :eps : :ps
    end

    def svg?(bytes)
      head = bytes.dup.force_encoding(Encoding::UTF_8)
      head.valid_encoding? && head.sub(/\A\uFEFF/, "").match?(SVG_ROOT)
    end
  end
end
```

- [ ] Contract check: run `::Emf.detect_format` in `bin/console` against both fixtures — confirm `:emf`/`:wmf` return values and nil (not raise) on junk.
- [ ] Specs pass; rubocop clean. Commit: `feat: add magic-byte format detector`

### Task 5: Registry + handler base

**Files:** Create `lib/claricle/registry.rb`, `lib/claricle/handlers/base.rb`, `spec/claricle/registry_spec.rb`; modify `lib/claricle.rb`.

**Produces:** `Registry::HANDLER_CLASSES` (the one list PR2+ extends), `Registry.handler_for(format) -> Class` (raises `UnsupportedFormat`), `Registry.formats -> [Symbol]`; `Handlers::Base.formats(*syms)` macro (pure declaration — no registration side effect), instance methods `inspection(image)`, `conformance_report(image)`, `convert(image, to:)` raising `UnsupportedFormat` by default. The registry is a frozen map derived from `HANDLER_CLASSES`; nothing mutates it at runtime and specs never need cleanup hooks.

- [ ] Failing spec:

```ruby
RSpec.describe Claricle::Registry do
  it "raises UnsupportedFormat for an unregistered format" do
    expect { described_class.handler_for(:nope) }
      .to raise_error(Claricle::UnsupportedFormat, /:nope/)
  end

  it "lists no formats before handlers exist" do
    expect(described_class.formats).to eq([])
  end
end

RSpec.describe Claricle::Handlers::Base do
  it "declares formats without touching the registry" do
    handler = Class.new(described_class) { formats :fake }
    expect(handler.supported_formats).to eq([:fake])
    expect { Claricle::Registry.handler_for(:fake) }
      .to raise_error(Claricle::UnsupportedFormat)
  end
end
```

(The "unimplemented operation raises" example needs `Image` and lives in Task 6's spec.)

- [ ] Implement:

```ruby
module Claricle
  module Registry
    HANDLER_CLASSES = [].freeze # PR2: [Handlers::Png, Handlers::Svg, ...]

    HANDLERS = HANDLER_CLASSES.flat_map { |handler|
      handler.supported_formats.map { |format| [format, handler] }
    }.to_h.freeze

    module_function

    def handler_for(format)
      HANDLERS.fetch(format) { raise UnsupportedFormat, format }
    end

    def formats
      HANDLERS.keys.sort
    end
  end
end

module Claricle
  module Handlers
    class Base
      class << self
        attr_reader :supported_formats

        def formats(*symbols)
          @supported_formats = symbols.flatten
        end
      end

      def inspection(image)
        raise UnsupportedFormat.new(image.format, :inspect)
      end

      def conformance_report(image)
        raise UnsupportedFormat.new(image.format, :conform)
      end

      def convert(image, to:)
        raise UnsupportedFormat.new(image.format, "convert to #{to}")
      end
    end
  end
end
```

(`to` is interpolated into the error rather than ignored — clearer message and no
`Lint/UnusedMethodArgument` offense, confirmed by running RuboCop on the block.)

- [ ] Specs pass; rubocop clean. Commit: `feat: add handler registry and base class`

### Task 6: Image entry object

**Files:** Create `lib/claricle/image.rb`, `spec/claricle/image_spec.rb`; modify `lib/claricle.rb`.

**Produces:** `Image.from_path(path)`, `Image.from_content(content, format: nil)`, `#format -> Symbol`, `#content -> String`, `#inspection`, `#conformance_report`, `#convert(to:)` (dispatch via registry), `#with_path { |path| }` (real path, or auto-cleaned Tempfile for content-born images — PR2's path-oriented delegates consume this).

- [ ] Failing spec:

```ruby
RSpec.describe Claricle::Image do
  let(:png_bytes) { "\x89PNG\r\n\x1a\n#{"\x00" * 8}".b }

  it "detects format from content" do
    expect(described_class.from_content(png_bytes).format).to eq(:png)
  end

  it "honors an explicit format" do
    expect(described_class.from_content("x", format: :svg).format).to eq(:svg)
  end

  it "yields a temporary path for content-born images and cleans it up" do
    seen = nil
    described_class.from_content(png_bytes).with_path do |path|
      seen = path
      expect(File.binread(path)).to eq(png_bytes)
    end
    expect(File.exist?(seen)).to be(false)
  end

  it "yields the original path when created from a file" do
    Tempfile.create(["claricle", ".png"]) do |file|
      file.binmode
      file.write(png_bytes)
      file.flush
      image = described_class.from_path(file.path)
      image.with_path { |path| expect(path).to eq(file.path) }
    end
  end

  it "raises UnsupportedFormat when no handler is registered" do
    expect { described_class.from_content(png_bytes).inspection }
      .to raise_error(Claricle::UnsupportedFormat)
  end

  it "raises UnsupportedFormat for operations a handler leaves unimplemented" do
    handler = Class.new(Claricle::Handlers::Base) { formats :fake }.new
    image = described_class.from_content("x", format: :fake)
    expect { handler.inspection(image) }
      .to raise_error(Claricle::UnsupportedFormat, /inspect/)
  end
end
```

- [ ] Implement:

```ruby
module Claricle
  class Image
    def self.from_path(path)
      new(path: path, format: Detector.detect_path(path))
    end

    def self.from_content(content, format: nil)
      new(content: content, format: format || Detector.detect(content))
    end

    attr_reader :format

    def initialize(format:, path: nil, content: nil)
      @path = path
      @content = content
      @format = format
    end

    def content
      @content ||= File.binread(@path)
    end

    def inspection
      handler.inspection(self)
    end

    def conformance_report
      handler.conformance_report(self)
    end

    def convert(to:)
      handler.convert(self, to: to)
    end

    def with_path(&block)
      return yield(@path) if @path

      Tempfile.create(["claricle", ".#{format}"]) do |file|
        file.binmode
        file.write(@content)
        file.flush
        block.call(file.path)
      end
    end

    private

    def handler
      Registry.handler_for(format).new
    end
  end
end
```

- [ ] Specs pass; rubocop clean. Commit: `feat: add image entry object`

### Task 7: CLI rebuild + exit-code runner

**Files:** Modify `lib/claricle/cli.rb` (delete `validate`/`convert`/`compress` stubs and their long_desc blocks; keep `version`; add the nested `Runner` module — the rebuilt file is ~50 lines, no separate runner file until the CLI grows in PR2/PR3), `exe/claricle`; create `spec/claricle/runner_spec.rb`.

**Produces:** `Cli::Runner.run(argv) -> Integer` exit code per the matrix; `exe/claricle` becomes `exit Claricle::Cli::Runner.run(ARGV)`.

- [ ] Failing spec:

```ruby
RSpec.describe Claricle::Cli::Runner do
  it "returns 0 for version" do
    expect { @code = described_class.run(["version"]) }
      .to output(/Claricle version/).to_stdout
    expect(@code).to eq(0)
  end

  it "returns 2 for an unknown command" do
    expect { @code = described_class.run(["frobnicate"]) }
      .to output(/frobnicate/).to_stderr
    expect(@code).to eq(2)
  end

  it "no longer exposes stub commands" do
    expect(Claricle::Cli.commands.keys)
      .not_to include("validate", "compress")
  end
end
```

(A missing-file → exit 2 example needs a file-taking command; that lands with `inspect` in PR2's plan.)

- [ ] Implement (inside the existing `class Cli < Thor` body in `cli.rb`, after the commands):

```ruby
module Claricle
  class Cli < Thor
    module Runner
      EXIT_OK = 0
      EXIT_NONCONFORMANT = 1
      EXIT_INVOCATION = 2
      EXIT_UNSUPPORTED = 3
      EXIT_INTERNAL = 4

      module_function

      def run(argv)
        Cli.start(argv, debug: true)
        EXIT_OK
      rescue SystemExit => e
        e.status
      rescue Thor::Error, Errno::ENOENT => e
        warn(e.message)
        EXIT_INVOCATION
      rescue UnknownFormat, UnsupportedFormat => e
        warn(e.message)
        EXIT_UNSUPPORTED
      rescue StandardError => e
        warn("internal error: #{e.class}: #{e.message}")
        EXIT_INTERNAL
      end
    end
  end
end
```

- [ ] Contract check (dependency-contract-check discipline): against the installed Thor, confirm `Cli.start(argv, debug: true)` re-raises `Thor::UndefinedCommandError` instead of printing-and-exiting; if the `config[:debug]` contract differs in this Thor version, fall back to `ENV["THOR_DEBUG"]` scoped around the call, and record which mechanism was used.
- [ ] Specs pass; rubocop clean; run `bundle exec exe/claricle version` and `bundle exec exe/claricle nope; echo $?` → prints 2.
- [ ] Commit: `feat: rebuild cli with exit-code runner`

### Task 8: Final wiring + full suite

**Files:** Modify `lib/claricle.rb` (final require order: thor, emf, lutaml/model, version, errors, models, detector, handlers/base, registry, image, cli — registry AFTER handlers/base since `HANDLERS` derives from handler classes at load), `spec/claricle_spec.rb` (drop the stale "loads the CLI module" trio if superseded; keep version + Error checks).

- [ ] `bundle exec rake` — full suite + rubocop green.
- [ ] `/execution-diff` gate: run `exe/claricle version`, `exe/claricle help`, `exe/claricle validate x.png; echo $?` on main vs branch; expected diffs ONLY: stubs gone (unknown command → exit 2), version unchanged. Any other diff is a bug.
- [ ] Commit: `chore: finalize core wiring`

---

## Review gates (every PR)

Per the Pre-Push Review Chain: `/thermo-nuclear-review` → `/dependency-contract-check` (mandatory here: lutaml-model DSL, `Emf.detect_format`, Thor `debug:` contract) → `/execution-diff` (CLI behavior) → Codex (high, diff-scoped) → `/copilot-review` last, then push.

## Open items to post back to issue #1 (needs maintainer eyes, not blocking PR1)

1. D2 rename (`inspection`), D5 (`libpng` dropped, floor 3.2), D11 (round-trip narrowed) — the three real deviations.
2. WMF: in for inspect/conform, out for convert (D9) — matches delegation map, extends acceptance list.
3. Gemspec homepage/metadata still points at `ribose/claricle`; org is now `claricle` — fix in PR4 docs pass.
