# 01 — Core: models, detection, registry, CLI runner

Can start: now. Everything else builds on this item; it ships with an
empty registry, so every operation raises `UnsupportedFormat` through
the real dispatch path until 02. The model shape is settled by D15
(dimensions), D17 (`parse_status`) and D23 (structural pre-pass) — read
those before writing `Handlers::Base`.

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
  `ConversionError`, `InvocationError` (bad arguments, conflicting
  flags, refused destination — the only thing besides `Thor::Error` and
  `ENOENT` that maps to exit 2) — all `< Claricle::Error` (moved here
  from `claricle.rb`).
- **Models** (`lib/claricle/models/`): lutaml-model `Serializable`
  classes ⚙ (construct + `to_json`/`from_json` against the installed gem
  before trusting specs). `Location{byte_offset, byte_length, line,
  column, chunk, node_path}` all nullable — the offset/length pair is a
  zero-based half-open range, because issue #1 asks for a byte *range*
  and a bare offset can't express one. `Issue{severity:
  error|warning|info, code, message, location}` — `message` is always
  present, never nil. `Report{source_path, format, issues, profile,
  validator_version}` — provenance matters once conformance can mean
  more than one thing, and `source_path` is what lets a batch result be
  traced back to its input (nil for content-born images; never expose a
  Tempfile path). `Report#valid` is **derived on read**, not stored, so
  appending an issue or deserializing JSON can't leave a stale verdict;
  it decides in D8 order error → warning → else `yes`.
  `Inspection{format, width, height, dpi, color_space, meta,
  parse_status, issues}` — see the inspection contract below.
- **Invariants are enforced, not just described** ⚙: lutaml-model
  0.8.19 constructs and serializes a bogus enum value happily until
  `validate!` is called explicitly. Validate and normalize on
  construction AND on deserialization, then deep-freeze the issue
  collection. Contract specs must cover an invalid severity, a missing
  message, post-build mutation, and inconsistent JSON.
- **Inspection means "did the metadata parse", nothing more.**
  `parse_status` is `:ok` or `:failed`, and it replaces a `valid` field
  outright — `valid` would mean five different things across five
  delegates, and vectory parses SVG in Nokogiri's default RECOVER mode
  ⚙, so a repaired malformed SVG would read as valid. Validity claims
  belong to `conform` alone. An **allowlisted** parse failure gives
  `:failed` and exits 0 — the command succeeded in reporting that the
  file doesn't parse. A fault off the allowlist is not absorbed; it
  propagates and exits 4. **`parse_status` comes from Claricle's own
  structural check (D23), never from delegate silence** — measured, a
  PNG reader yields zero chunks without raising, svg_conform's `base`
  profile returns no errors for raw binary, and vectory raises on a
  *valid* dimensionless SVG. "The delegate didn't complain" is not
  evidence the file parsed.
- **Detector** (`lib/claricle/detector.rb`): `detect(bytes)` /
  `detect_path(path)` → `:png :svg :emf :wmf :eps :ps :pdf` or raise
  `UnknownFormat`. Load-bearing details, each corrected by execution on
  2026-08-12 — do not trust the earlier wording, it was wrong:
  - Normalize `bytes.to_s.b` first (callers hand UTF-8 strings;
    comparisons must be binary).
  - `%!PS` + `EPSF` in first line → `:eps` else `:ps`.
  - **`::Emf.detect_format` raises `Emf::FormatError` on every
    unrecognised input** ⚙ — verified against emf 0.1.0 with empty,
    2-byte, plain-text, XML and PNG input; it never returned nil. Wrap
    the metafile probe in `rescue Emf::FormatError` and continue to the
    next probe. Rescue that class only, never bare. Without this, every
    ordinary unknown file becomes exit 4 instead of `UnknownFormat`/3.
  - **SVG detection is encoding-aware XML root detection, not a
    regex** ⚙. A 4096-byte binary `<svg` scan rejects input vectory
    accepts: UTF-16LE+BOM, `<s:svg xmlns:s=...>` prefixed roots, and a
    root sitting at byte 5028 behind a long licence comment all failed
    the regex and all parsed fine in vectory 0.12.0. Decode the BOM and
    XML declaration, resolve the root **QName**, and require the SVG
    namespace — local name alone would accept a non-SVG `<svg>` in
    another namespace. Disable external entity resolution and DTD
    expansion (XXE); a detector must never fetch a URL. Any byte limit
    on the preamble is a deliberate product restriction, so state it —
    it is not delegate compatibility.
  - `:wmf` is still detected even though nothing handles it (D14), so
    the user gets `UnsupportedFormat`/3 rather than a misleading
    "unknown format".
- **Registry** (`lib/claricle/registry.rb`): `HANDLER_CLASSES` (one
  list, empty here) → `HANDLERS` frozen map derived via each class's
  `supported_formats`; `handler_for(format)` fetches or raises
  `UnsupportedFormat`; `formats -> [Symbol]` (sorted; feeds 02's
  `formats` command); no runtime mutation, no test-only APIs.
- **Handler metadata carries what the registry derives.** The advertised
  "adding a format = one handler class" is **not** true under the settled
  design: a new format needs a handler class, an entry in
  `HANDLER_CLASSES`, and a probe in the detector (detection is a
  hand-rolled sequence, not a per-handler sniffer), plus — for an
  inbound conversion — an entry in the source handler's target list and
  its feature-loss rules. Step 7b corrects the README
  claim; making the promise true would mean redesigning discovery and
  loss-rule ownership, which is out of scope for item 01.
  A handler declares its formats, its capabilities, its conversion
  targets, the **feature-loss rules** for each of those targets (per
  D23, lossiness is classified per conversion from the source's
  content, so a handler declares which source features a target
  discards, not a flat per-edge label), and its canonical file
  extensions (needed by 04's `--to` inference from an `--output`
  suffix). **Detection is not among them** — probes live in the detector
  as one ordered sequence, because they are heterogeneous (prefix
  matches, a delegate call, an XML parse) and their order is
  load-bearing. That is the central table the README has to be honest
  about rather than pretend away.
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
  `Thor::Error`/`Errno::ENOENT`/`InvocationError` → 2,
  `UnknownFormat`/`UnsupportedFormat` → 3, other `StandardError` → 4,
  **`LoadError` → 4 and `SystemStackError` → 4, both caught
  explicitly** — neither is a `StandardError`, so a missing lazy
  delegate or a deeply recursive PostScript file would otherwise escape
  as process status 1, the code reserved for nonconformance. Recursive
  PS through `Vectory::Ps#to_svg` was measured raising
  `SystemStackError`. Catch `ScriptError` and `SystemStackError`
  narrowly; never rescue `Exception`.
  Never blanket-map `ArgumentError`: a delegate raising one
  accidentally is an internal defect, not bad user input. Split into
  `run` / `exit_code` / `error_message` to stay under
  `Metrics/MethodLength`. `Runner.run` **returns** an integer and never
  calls `exit`; only `exe/claricle` exits, via
  `exit Claricle::Cli::Runner.run(ARGV)`. `run` does rescue `SystemExit`
  and return its status, bounded to 0-255 with anything outside becoming
  4 — that replaced the original prescription's "no `SystemExit`
  passthrough". Nothing is thrown through the runner either way, and
  03's nonconformant exit 1 stays a returned integer like every other
  code.
- **Tooling**: gemspec floor `>= 3.2.0`, add `emf` + `lutaml-model`
  (only what 01 uses; 02 adds the rest) with three-segment constraints
  on the reviewed line — `~> 0.7` is not a pin, it admits every 0.x
  (D13), and this gem commits no lockfile. `.rubocop.yml`
  `TargetRubyVersion: 3.2` + `Metrics/BlockLength` exclude `spec/**/*`
  (rubocop-rspec isn't wired in); CI matrix `['3.2', '3.3']`, extended
  to the newest stable Ruby the gemspec actually admits.
- **Honesty baseline**: README.adoc and the gemspec description
  describe reality as of 01 — the current README
  advertises validation, conversion, compression and a fictional
  `Claricle::Validator` API, and the gemspec advertises compression.
  Later items extend this baseline; 04 does the final rewrite. Merged
  source should never claim capabilities it lacks, release or no
  release.
- **Require order is load-bearing for one pair only.** Every file under
  `lib/` loads standalone except `lib/claricle/cli.rb`, which names
  `Thor` at class-definition time and raises `uninitialized constant
  Claricle::Thor` unless `thor` was required first — so `lib/claricle.rb`
  requiring `thor` ahead of `cli` is a real dependency, not reading
  order. `detector`, `image`, `registry`, `errors`, `handlers/base` and
  the models each load on their own, and `lib/claricle.rb` may require
  them in any order. `detector` is standalone only as far as loading
  goes: it does not require `errors`, so raising `UnknownFormat` needs
  `errors` already loaded. That replaced the original prescription
  (thor, emf, lutaml/model, version, errors, models, detector,
  handlers/base, registry, image, cli), which existed because every file
  relied on the entry point to have loaded its constants first.
  `registry.rb` requires `handlers/base` itself, next to the
  `HANDLER_CLASSES` entries that name those classes; `detector.rb`
  requires `emf` and `rexml`; `models/base.rb` requires `lutaml/model`.

## Do

TDD each step (failing spec → implement → green → rubocop → commit,
subjects in quotes):

1. Tooling floor + gemspec deps; `bundle install` must resolve against
   released gems (D13). "chore: raise floor, add emf and lutaml-model"
2. Error taxonomy + spec. "feat: add error taxonomy"
3. Models + derived tri-state spec + JSON round-trip spec + invariant
   specs (invalid severity, nil message, post-build mutation,
   inconsistent JSON); run the lutaml-model validation contract check in
   `bin/console` first — 0.8.19 does not validate until told to.
   "feat: add unified issue and report models"
4. Detector + spec. Fixtures: smallest real `.emf`/`.wmf` from the emf
   corpus into `spec/fixtures/detector/`; inline byte strings for the
   rest. Must include the cases the old regex failed — UTF-16LE+BOM,
   `<s:svg>` prefixed root, internal DTD subset, root behind a
   5000-byte comment — plus rejection cases: an `<svg>` in a foreign
   namespace, an `<svg` decoy inside a comment, and an entity referring
   to an external file (must not be fetched). Assert that plain text
   reaches `UnknownFormat` and PNG bytes detect as `:png` — neither may
   leak `Emf::FormatError`, which both trigger on the metafile probe.
   "feat: add format detector"
5. Registry + Base + specs (anonymous subclasses are fine — real
   classes, not doubles). "feat: add handler registry and base class"
6. Image + spec (tempfile lifecycle both directions; the
   "no handler registered" example must be replaced in 02 with an
   explicitly-passed unregistered format). "feat: add image entry object"
7. CLI rebuild + Runner + spec (version → 0, unknown command → 2,
   `LoadError` → 4, `InvocationError` → 2, all three stubs gone).
   "feat: rebuild cli with exit-code runner"
7b. Honesty baseline: README.adoc and the gemspec description
   describe only what exists; `sig/` is deleted rather than kept
   honest, because RBS is not maintained here.
   "docs: describe only shipped behaviour"
8. Final wiring; full `bundle exec rake`; execution-diff against main —
   `bundle exec exe/claricle version`, `bundle exec exe/claricle help`,
   `bundle exec exe/claricle validate x.png; echo $?`, on BOTH revisions
   (bare `exe/` can't resolve `lib/` from a checkout).
   "chore: finalize core wiring"

## Done when

- `bundle exec rake` green on a clean install.
- `bundle exec exe/claricle version` → 0; `bundle exec exe/claricle
  nope; echo $?` → 2; stub commands absent from `claricle help`.
- Runner spec covers every row of the exit-code matrix including 4
  (a raised `StandardError` that is not a `Claricle::Error`); 03
  exercises 4 end-to-end through a deliberately faulting handler
  raising an off-allowlist exception. A real crashing delegate is the
  wrong probe — once the allowlists exist, a corrupt fixture is
  nonconformance and exits 1.
- `Report#valid` spec covers info-only and warning-plus-info inputs,
  proves the frozen issue collection refuses mutation rather than
  silently accepting it, and proves the verdict is correct after a
  deserialization round trip.
- The detector accepts every SVG form vectory accepts, rejects foreign
  namespaces and decoys, and never resolves an external entity.
- Execution-diff vs main shows ONLY: stubs gone, version unchanged,
  README/gemspec/RBS truthful.
- Every ⚙ contract check ran against the installed gem and its outcome
  is recorded in the PR description. `Emf.detect_format` raising, the
  SVG root cases, lutaml-model's deferred validation and `tempfile`'s
  non-autoloading are the known ones; treat any new delegate assumption
  the same way.
- Full Pre-Push Review Chain passed.

## Files

`claricle.gemspec`, `.rubocop.yml`, `.github/workflows/main.yml`,
`lib/claricle.rb`, `lib/claricle/errors.rb`, `lib/claricle/models/
{base,free_form_hash,location,issue,report,inspection}.rb`,
`lib/claricle/detector.rb`,
`lib/claricle/registry.rb`, `lib/claricle/handlers/base.rb`,
`lib/claricle/image.rb`, `lib/claricle/cli.rb`, `exe/claricle`,
`README.adoc`, `spec/claricle/*_spec.rb`,
`spec/fixtures/detector/`.
