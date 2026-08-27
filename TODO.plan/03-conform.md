# 03 — Conform: unified reports, `Claricle.conform?`, batch helper

Can start: after 02. D16 (PDF scope), D22 (EPS/PS) and D23 (pre-pass)
settle what this item builds.

## Problem

Each delegate reports validity in a different shape (typed issues,
error strings, exceptions, or parse-error lists). The issue demands one
typed `Report` with uniform `Issue{severity, code, message, location}`
across every format that has a conformance basis, a module-level API,
and a batch-capable CLI
command that exits 1 on nonconformance.

## Design

Mapping layer per handler — `location` is nullable throughout;
synthetic stable codes where upstream has none; never invent
coordinates:

| Delegate result | → Issue mapping |
|---|---|
| png_conform, **not** via `validate_file` | Build `Readers::FullLoadReader.new(path)`, pass it to `ValidationService.new(reader, path)`, call `validate`, then read **all three buckets — `context.all_errors`, `all_warnings`, `all_info`**. Location lives on the **context object only**: both `validate_file` and `result.validation_result.errors` return `chunk_type: nil, chunk_offset: nil` for the same input. `all_errors` alone silently drops warnings and info, which would break D8's tri-state and `--strict`. Measured error shape: `{chunk_type: "IDAT", message: "CRC error in IDAT chunk", severity: :error, offset: 33}`. Map `severity` as-is, `location: {chunk: chunk_type, byte_offset: offset}` (offset may be nil, e.g. a missing IEND). **`byte_length` has no source here** — png_conform reports a start offset only, so the issue's "byte range" is delivered as offset-plus-chunk for PNG, and `byte_length` stays nil unless the pre-pass (D23) computes it from the chunk header, which it can. `code` synthesized stably since there is no upstream type. **Never use `validate_file`** — it returns a `FileAnalysis` with chunk and offset discarded. See D23: this path misses duplicate `IHDR`/`IEND` and trailing bytes entirely |
| svg_conform `ValidationIssue` | Severity is `severity || type` — `ErrorTracker#add_error` hardcodes `type: :error`, and `severity` was measured **nil** on some issues, so neither field alone is reliable. Normalize `:validity_error` to `error`. Collect errors, warnings **and** validity errors, not just one bucket. `code: requirement_id`. `line` and `column` were nil on every issue measured, so `location` is usually nil; populate only when present. Run under the `base` profile (D21), and call `Profiles.clear_cache!` or enumerate eagerly — `available_profiles` collapses to just the last-loaded profile after any validation. Note UTF-32 input was measured passing every profile silently, so the structural pre-pass (D23) must settle encoding before profile validation runs — but note D23: `base` returns 0 errors for raw binary, so it cannot stand alone |
| emf | `Emf.parse` → `Metafile` exposing `ok?` and `errors`. **`ok?` is not sufficient on its own**: a file with its final EOF record removed measured `ok? == true, errors == [], records == 15` against 16 for the intact file. Require an EOF record on top of `ok?` (D23). **Do not naively compare the declared record count to the parsed count** — the intact fixture reports `header.n_records == 17` against 16 parsed records, so that offset means something not yet understood. Either work out what it counts and then cross-check, or restrict the pre-pass to EOF presence and trailing-byte detection, both of which were measured catching real corruption. Map `errors` (message, offset, record_code) to `severity: "error"`, `code: "EMF_PARSE"`, `location: {byte_offset}`. Truncation raises **`IOError`** at some cut points and `Emf::FormatError` at others — both belong on the conform allowlist, or a corrupt file exits 4 instead of 1 |
| postscript | **No mapping — EPS/PS conform is unsupported in v1 (D22).** `Postscript.parse` was measured accepting an unmatched `}`, an undefined operator, a missing operand and raw binary; only an unterminated string raised. There is nothing here that answers "does this conform?", so the handler declares no `conform` capability and the registry raises `UnsupportedFormat` → exit 3 |
| pdfrb `Validator.validate` | Structural, class method taking a `Document`. Measured `[]` on a valid file. **Failure reporting is not uniform** — a catalog-less document raises `Pdfrb::Error`, a `/Pages` reference to a missing object raises `NoMethodError`, and a dangling unrelated reference comes back as an error string. The allowlist must cover the raising cases including `NoMethodError` from this call path specifically, which means wrapping the call rather than allowlisting `NoMethodError` globally. When it returns strings: `severity: "error"`, `code: "PDF_STRUCTURE"`, `message` the string, `location: nil` |
| pdfrb `Conformance::*` `Violation` | Only via `--profile`. Measured `PdfA.validate(doc, level: :a1b)` → `ValidationResult` whose violations are `Violation{rule_id, message, object, severity, spec_clause}`, e.g. `rule_id="6.1-2", message="PDF/A requires /Catalog/Metadata XMP stream", object="Catalog", severity=:error`. So `code: rule_id`, `message` as-is (it has real prose — no composition needed), severity as-is, `location: {node_path: object}` — note `object` was the string `"Catalog"`, not a path, so treat it as an opaque label. **`PdfA`/`PdfX`/`PdfVT` take `level:`; `PdfUA` does not** — the adapter is per-profile |

- **One `--profile` flag, two formats.** PDF and SVG both have a
  generic check and a set of named stricter standards, so they share
  one mechanism rather than inventing two.
  - PDF: generic `conform` runs `Validator.validate` (structural).
    `--profile pdf_a --level a1b` reaches `Pdfrb::Conformance::*`.
    **A profile run must pass structural validation first** — measured
    on a catalog-less file, most profiles raise a raw `NoMethodError`
    while `Pdf2AF` returns zero violations and "passes". Never report a
    profile pass for a document that is not structurally sound.
    **Claricle validates the level itself**: `PdfA`, `PdfX`, `PdfVT`
    and `Pades` accept `level:`; `PdfUA`, `Ltv`, `Pdf2AF` and
    `TaggedPdf` do not. An invalid level is **silently ignored**
    upstream — `level: :nonsense` returned the same result as
    `level: :a1b` — so an unrecognised level must be rejected here with
    `InvocationError`, and passing `--level` to a profile that takes
    none is equally an error. Enumerate the accepted names and levels
    in one table; do not pass user input through unchecked.
  - SVG: generic `conform` runs the **`base`** profile (D21).
    `--profile metanorma`, `svg_1_2_rfc`, `svg_1_2_rfc_with_rdf`,
    `no_external_css`, `lucid_fix` reach the stricter sets.
  - An unknown profile name, or `--profile` on a format with no profile
    system, is an `InvocationError` → exit 2.
  - `Report#profile` always records what actually ran, so no result is
    ambiguous about which standard it was judged against.
  "Valid PDF" and "valid PDF/A" are different claims, and so are
  "well-formed SVG" and "SVG that satisfies the RFC colour rules".
  Neither is silently substituted for the other.
- **Arlington is not delivered in v1.** Released pdfrb exposes
  `Arlington::Loader` (`list_object_names`, `object_definition`),
  `Predicate`, `ObjectDefinition`, `FieldDefinition` — the grammar, not
  a validator. No `Conformance` profile references it. Driving those
  predicates across a document is a validator we would be writing, not
  a delegate call. Issue #1 asks for Arlington, so this omission is the
  one part of D16 that needs the author's sign-off. Say it plainly in
  the README rather than letting "conform" imply it.
- **`conform` still means different things per format, so say so.**
  PNG gets chunk-level validation, SVG the `base` requirement set, EMF
  a parse plus `ok?`, PDF a structural check. Those are not comparable
  claims even after D22 removed the worst offender. `Report#profile`
  and the validator version record what actually ran, and the README
  states it per format rather than implying uniformity.
- Module API: `Claricle.conform?(path = nil, pattern: nil,
  strict: false, profile: nil)` — exactly one of positional path or
  `pattern:` (`InvocationError` otherwise; the issue's examples use
  both shapes); `pattern:` is true only if every matched file conforms.
  `Claricle.conformance_report(path, profile: nil)` → `Models::Report`.
  `profile:` is accepted for PDF and SVG (D16, D21); on any other
  format, or with a name that format does not define, it raises
  `InvocationError`. `Report#profile` records which one ran, so a
  result is never ambiguous about what it checked.
- **A batch predicate loses information, so give callers the full
  result too.** `Claricle.conformance_batch(pattern:)` returns ordered
  per-file outcomes plus an aggregate status, so Ruby callers can get
  what the CLI gets. Without it the CLI records per-file failures and
  keeps going while the Ruby predicate aborts on the first one, and
  there's no way to reach the complete picture from Ruby. The batch
  predicate must collect every outcome — no `all?` short-circuiting —
  and then deterministically raise the highest-severity operational
  failure, so the same input always fails the same way.
- **`conform?` is a predicate, so it answers about conformance and
  raises about everything else.** A nonconformant file returns `false`.
  An operational failure — unknown format, unsupported format, missing
  file, delegate crash — raises, and raises out of the batch shape too;
  it never silently becomes `false`. `pattern:` matching zero files
  raises `InvocationError` (matching the CLI's exit 2, not a vacuous
  `true`).
- **The batch helper** (owned here, reused by 04): a positional
  argument is a literal path when it names an existing file and a glob
  otherwise; `--pattern` forces glob interpretation for a filename that
  legitimately contains glob characters (D19). Expand
  `Dir.glob(pattern).sort`; zero matches → exit 2; per-file failures
  don't stop the batch; final exit = highest code.
- **One envelope type, never a mixed array.** Every slot is a
  `Models::BatchItem{path, status, exit_code, result, error}` — one
  homogeneous element type, with `result` holding the `Report` (or in
  04 the `Conversion`) and `error` holding code and message. A
  heterogeneous `Array<Report | Failure>` would force consumers to
  type-switch on a field's presence, and `jq '.[].result.valid'` would
  return null for an operational failure, indistinguishable from a
  genuine null. Human output prints one stderr line per failed file.
  Because 04 needs the same helper with a different success predicate,
  keep it operation-neutral — something like
  `Batch.run(argument, classify:, &operation)` returning ordered
  envelopes plus aggregate status — rather than baking conform's exit
  0/1 rule into it and forcing 04 to work around it.
- CLI: `claricle conform FILE... [--pattern GLOB] [--json] [--strict]`;
  conformance failure returns 1 as an ordinary integer from the runner,
  never a raised `SystemExit`; `--strict` requires tri-state `yes`
  (D8). Batch-capable JSON
  is **always an array**, single result included; a single-file failure
  must produce the same JSON envelope as a batch one, so CI consumers
  never get JSON in one case and bare stderr text in the other.
  Human output prints, per file: the path, the tri-state verdict, and
  every mapped issue as one line carrying severity, code, message, and
  the location fields that are populated. A conformant file prints its
  path and verdict, nothing more.
- **One stable JSON cardinality**: batch-capable commands always emit
  an array of `BatchItem`, single result included. Shape can't follow
  invocation syntax — a filename may legally contain glob characters,
  and an unquoted glob is expanded by the shell before Claricle sees
  the argument, so "which form did the user type" isn't knowable. 04's
  `convert --json` uses the same rule.
- `capabilities` gains `conform` per handler **in the same commit that
  implements that handler's `conformance_report`**, alongside the
  `formats` output spec — so `formats` never claims an operation that
  isn't working yet, not even between commits inside this item.
- Fixtures: one valid + one invalid sample per format, sourced from the
  delegates' canonical corpora (PngSuite, svg_conform fixtures, emf
  corpus, pdfrb specs).

## Do

Same shape as 02 — command plumbing first, then one handler per commit,
so no commit declares a capability the CLI can't yet deliver.

1. `Models::BatchItem` + operation-neutral batch helper + module API +
   `conform` command, with the exit codes reachable now (2 for zero
   matches, 3 for a format no handler conforms). Extend the exact command
   inventory with `conform` in the same commit. No capability changes.
2. Module API argument specs — both call shapes, `InvocationError`
   cases, and `conformance_batch` collecting every outcome without
   short-circuiting.
3. One handler per commit: `conformance_report` TDD against valid and
   invalid fixtures, the derived `conform` capability, and the `formats`
   expected-output update, together. Exit codes 0 and 1 get their
   end-to-end specs with the first handler.
4. Per-delegate malformed-input allowlist, per operation and stage, so
   a recognised-but-corrupt file exits 1 rather than 4 — **for the
   formats that have conform at all**. EPS and PS are excluded by D22:
   they exit 3 whatever their content, since there is no conformance
   verdict to give. `Emf::FormatError`
   raised while conforming a truncated EMF goes **on** that allowlist:
   the delegate reports it as an exception before any `metafile.errors`
   result exists, but the user-visible meaning is the same
   nonconformance that malformed PostScript produces, and the exit code
   must follow the meaning rather than the delegate's reporting style.
   Then prove exit 4 with a deliberately faulting handler — an
   off-allowlist exception — since every recognised-but-corrupt fixture
   now correctly lands on 1.
5. `--strict` + tri-state boundary specs (warnings-only file,
   info-only file).
6. README section for `conform` (D1), stating per-format what conform
   actually checks.

## Done when

- `Claricle.conform?` correct for png, svg, emf and pdf, both call
  shapes; eps/ps raise `UnsupportedFormat` per D22.
- Invalid fixture of each format yields a `Report` with populated,
  correctly-mapped issues; exit codes verified end-to-end.
- Batch glob over mixed formats returns highest-code exit and a
  positionally complete JSON array of `BatchItem`, failures included.
- A single-file failure emits the same JSON envelope as a batch one.
- Exit code 4 is reached end-to-end. A corrupt-but-recognised fixture
  exits 1 for png, svg, emf and pdf; eps and ps exit 3 regardless of
  content (D22).
- `formats` now reports conform, and its spec says so.
- Full Pre-Push Review Chain passed.

## Files

`lib/claricle.rb` (module API), `lib/claricle/handlers/*.rb`,
`lib/claricle/models/batch_item.rb`, `lib/claricle/cli.rb` + batch
helper file, `README.adoc`, `spec/claricle/conformance/*_spec.rb`,
`spec/fixtures/`.
