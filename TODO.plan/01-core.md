# 01 — Core: models, detection, registry, CLI runner

Can start: now. Everything else builds on this; ships with an empty
registry, so every operation raises `UnsupportedFormat` through the
real dispatch path until 02.

## Problem

The gem is a placeholder: a Thor CLI whose `validate`/`convert`/
`compress` commands print "coming soon". Nothing exists to detect
formats, dispatch to handlers, model results, or map errors to exit
codes — and the README advertises the fake commands.

## Design

Contracts an implementer must honor (each verified against the real
dependency where marked ⚙):

- **Errors** (`lib/claricle/errors.rb`): `UnknownFormat` (bytes match no
  signature), `UnsupportedFormat.new(format, operation = nil)` with
  message `format :wmf is not supported for convert to :svg` style,
  `ConversionError` — all `< Claricle::Error` (moved here from
  `claricle.rb`).
- **Models** (`lib/claricle/models/`): lutaml-model `Serializable`
  classes ⚙ (construct + `to_json`/`from_json` against the installed gem
  before trusting specs). `Location{byte_offset, line, column, chunk,
  node_path}` all nullable; `Issue{severity: error|warning|info, code,
  message, location}`; `Report.build(path:, format:, issues:)` computes
  tri-state `valid` per D8; `Inspection{format, width, height, dpi,
  color_space, meta, valid, issues}`.
- **Detector** (`lib/claricle/detector.rb`): `detect(bytes)` /
  `detect_path(path)` → `:png :svg :emf :wmf :eps :ps :pdf` or raise
  `UnknownFormat`. Load-bearing details: normalize `bytes.to_s.b`
  first (callers hand UTF-8 strings; comparisons must be binary); read
  4096 header bytes (512 misses SVGs with long license comments);
  `%!PS` + `EPSF` in first line → `:eps` else `:ps`;
  `::Emf.detect_format` returns `:emf`/`:wmf`/nil, never raises ⚙; SVG
  root regex must be `%r{...}` (RuboCop) and tolerate BOM, XML prolog,
  comments, DOCTYPE.
- **Registry** (`lib/claricle/registry.rb`): `HANDLER_CLASSES` (one
  list, empty here) → `HANDLERS` frozen map derived via each class's
  `supported_formats`; `handler_for(format)` fetches or raises
  `UnsupportedFormat`; `formats -> [Symbol]` (sorted; feeds 02's
  `formats` command); no runtime mutation, no test-only APIs.
- **Handlers::Base** (`lib/claricle/handlers/base.rb`): `formats(*syms)`
  class macro is pure declaration; instance `inspection(image)`,
  `conformance_report(image)`, `convert(image, to:)` all raise
  `UnsupportedFormat` (interpolate `to` into the message — unused-arg
  lint otherwise).
- **Image** (`lib/claricle/image.rb`): `from_path` (detects),
  `from_content(content, format: nil)` (detects when format omitted);
  `#content` lazy-reads; ops dispatch through the registry;
  `#with_path { |p| }` yields the real path or a binmode Tempfile
  (auto-cleaned) for content-born images — `require "tempfile"` is
  load-bearing (stdlib, NOT autoloaded ⚙).
- **CLI + Runner** (`lib/claricle/cli.rb`): stubs deleted, `version`
  kept, nested `Runner` module maps `run(argv)` → exit code:
  `Cli.start(argv, debug: true)` makes Thor re-raise `Thor::Error`
  instead of printing-and-exiting ⚙ (fallback: `ENV["THOR_DEBUG"]`
  scoped around the call; record which mechanism was used).
  `Thor::Error`/`Errno::ENOENT` → 2, `UnknownFormat`/
  `UnsupportedFormat` → 3, other `StandardError` → 4, `SystemExit`
  passes through (lets 03's conform exit 1). Split into `run` /
  `exit_code` / `error_message` to stay under `Metrics/MethodLength`.
  `exe/claricle` becomes `exit Claricle::Cli::Runner.run(ARGV)`.
- **Tooling**: gemspec floor `>= 3.2.0`, add `emf ~> 0.1` +
  `lutaml-model ~> 0.8` (only what 01 uses; 02 adds the rest);
  `.rubocop.yml` `TargetRubyVersion: 3.2` + `Metrics/BlockLength`
  exclude `spec/**/*` (rubocop-rspec isn't wired in); CI matrix
  `['3.2', '3.3']`.
- **Require order** in `lib/claricle.rb`: thor, emf, lutaml/model,
  version, errors, models, detector, handlers/base, registry (AFTER
  handlers — `HANDLERS` derives at load), image, cli.

## Do

TDD each step (failing spec → implement → green → rubocop → commit,
subjects in quotes):

1. Tooling floor + gemspec deps; `bundle install` must resolve against
   released gems (D13). "chore: raise floor, add emf and lutaml-model"
2. Error taxonomy + spec. "feat: add error taxonomy"
3. Models + tri-state spec + JSON round-trip spec; run the lutaml-model
   contract check in `bin/console` first. "feat: add unified issue and
   report models"
4. Detector + spec (fixture files: smallest real `.emf`/`.wmf` from the
   emf gem corpus into `spec/fixtures/detector/`; inline byte strings
   for the rest). "feat: add magic-byte format detector"
5. Registry + Base + specs (anonymous subclasses are fine — real
   classes, not doubles). "feat: add handler registry and base class"
6. Image + spec (tempfile lifecycle both directions; the
   "no handler registered" example must be replaced in 02 with an
   explicitly-passed unregistered format). "feat: add image entry object"
7. CLI rebuild + Runner + spec (version → 0, unknown command → 2, all
   three stubs gone); README honesty pass (drop placeholder command
   docs; full rewrite stays in 04). "feat: rebuild cli with exit-code
   runner"
8. Final wiring; full `bundle exec rake`; execution-diff against main —
   `bundle exec exe/claricle version`, `bundle exec exe/claricle help`,
   `bundle exec exe/claricle validate x.png; echo $?`, on BOTH revisions
   (bare `exe/` can't resolve `lib/` from a checkout).
   "chore: finalize core wiring"

## Done when

- `bundle exec rake` green on a clean install.
- `bundle exec exe/claricle version` → 0; `bundle exec exe/claricle
  nope; echo $?` → 2; stub commands absent from `claricle help`.
- Execution-diff vs main shows ONLY: stubs gone, version unchanged.
- The three ⚙ contract checks ran against installed gems and their
  outcomes are recorded in the PR description.
- Full Pre-Push Review Chain passed.

## Files

`claricle.gemspec`, `.rubocop.yml`, `.github/workflows/main.yml`,
`lib/claricle.rb`, `lib/claricle/errors.rb`, `lib/claricle/models/
{location,issue,report,inspection}.rb`, `lib/claricle/detector.rb`,
`lib/claricle/registry.rb`, `lib/claricle/handlers/base.rb`,
`lib/claricle/image.rb`, `lib/claricle/cli.rb`, `exe/claricle`,
`README.adoc`, `spec/claricle/*_spec.rb`, `spec/fixtures/detector/`.
