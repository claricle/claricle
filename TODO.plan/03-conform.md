# 03 — Conform: unified reports, `Claricle.conform?`, batch helper

Can start: after 02.

## Problem

Each delegate reports validity in a different shape (typed issues,
error strings, exceptions, or parse-error lists). The issue demands one
typed `Report` with uniform `Issue{severity, code, message, location}`
across all five formats, a module-level API, and a batch-capable CLI
command that exits 1 on nonconformance.

## Design

Mapping layer per handler — `location` is nullable throughout;
synthetic stable codes where upstream has none; never invent
coordinates:

| Delegate result | → Issue mapping |
|---|---|
| png_conform `ValidationError{severity, error_type, message, chunk_type, chunk_offset}` | severity as-is; `code: error_type`; `location: {chunk, byte_offset}` |
| svg_conform `ValidationIssue{type, requirement_id, message, line, column}` | `severity: type`; `code: requirement_id`; `location: {line, column}` |
| emf `metafile.errors` (message, offset, record_code) | `severity: "error"`; `code: "EMF_PARSE"`; `location: {byte_offset}`; clean parse + serialize round-trip identity = conformant |
| postscript exceptions (`ParseError`/`LexError`/`SyntaxError`) | single `Issue{severity: "error", code: <exception class>}`; clean parse = conformant |
| pdfrb `Validator.validate` strings | `severity: "error"`; `code: "PDF_STRUCTURE"`; `message` = the string as-is |
| pdfrb `Conformance::*` `Violation{rule_id, severity, spec_clause, object}` | `code: rule_id`; severity as-is; `location: {node_path: object}`; `message` = the violation's own message when it has one, else `"<rule_id> (<spec_clause>)"` ⚙ confirm which attribute carries prose before writing the spec |

- **PDF has two conformance layers and generic `conform` runs only the
  first.** `claricle conform x.pdf` runs `Validator.validate`
  (structural integrity) — that is the whole contract by default. The
  `Conformance::*` profile checkers are opt-in via
  `--profile NAME`/`profile:`, where NAME names a pdfrb profile; an
  unknown name exits 2. No profile is enabled by default, because
  "valid PDF" and "valid PDF/A" are different claims and the issue asks
  for the former. Non-PDF formats reject `--profile` with exit 2.
- Module API: `Claricle.conform?(path = nil, pattern: nil, strict: false,
  profile: nil)` — exactly one of positional path or `pattern:`
  (ArgumentError otherwise; the issue's examples use both shapes);
  `pattern:` is true only if every matched file conforms.
  `Claricle.conformance_report(path, profile: nil)` → `Models::Report`.
  `profile:` on a non-PDF raises `ArgumentError`.
- **`conform?` is a predicate, so it answers about conformance and
  raises about everything else.** A nonconformant file returns `false`.
  An operational failure — unknown format, unsupported format, missing
  file, delegate crash — raises, and raises out of the batch shape too;
  it never silently becomes `false`. `pattern:` matching zero files
  raises `ArgumentError` (matching the CLI's exit 2, not a vacuous
  `true`).
- **The batch helper** (owned here, reused verbatim by 04): expand
  `Dir.glob(pattern).sort`; zero matches → exit 2; per-file failures
  don't stop the batch; final exit = highest code across files; JSON
  batch output = array (D12).
- **A failed file still occupies its array slot.** Add
  `Models::BatchFailure{path, exit_code, code, message}` (lutaml-model,
  same as everything else) — the helper substitutes one wherever a file
  raised instead of producing a result, so the JSON array is
  positionally complete and a consumer can tell success from failure by
  the presence of `code`. Human output prints the same information as
  one stderr line per failed file. 04 reuses this class unchanged.
- CLI: `claricle conform FILE|PATTERN [--json] [--strict]
  [--profile NAME]`; conformance failure exits 1 (through `SystemExit`
  passthrough in the runner); `--strict` requires tri-state `yes` (D8).
  Human output prints, per file: the path, the tri-state verdict, and
  every mapped issue as one line carrying severity, code, message, and
  the location fields that are populated. A conformant file prints its
  path and verdict, nothing more.
- **JSON shape follows the invocation, not the match count**: a single
  file argument emits one `Report` object; a pattern always emits an
  array, even when it matches exactly one file. 04's `convert --json`
  uses the same rule.
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

1. `Models::BatchFailure` + batch helper + module API + `conform`
   command, with the exit codes reachable now (2 for zero matches, 3
   for a format no handler conforms). No capability changes yet.
2. Module API argument specs — both call shapes, ArgumentError cases.
3. One handler per commit: `conformance_report` TDD against valid and
   invalid fixtures, `capabilities :conform`, and the `formats`
   expected-output update, together. Exit codes 0 and 1 get their
   end-to-end specs with the first handler.
4. Exit code 4 end-to-end from a truncated fixture that makes a
   delegate raise a non-`Claricle::Error`.
5. `--strict` + tri-state boundary specs (warnings-only file,
   info-only file).
6. PDF `--profile`/`profile:` routing + unknown-name and wrong-format
   specs (exit 2 at CLI, `ArgumentError` at API).
7. README section for `conform` (D1).

## Done when

- `Claricle.conform?` correct for all five formats, both call shapes.
- Invalid fixture of each format yields a `Report` with populated,
  correctly-mapped issues; exit codes verified end-to-end.
- Batch glob over mixed formats returns highest-code exit and a
  positionally complete JSON array, failures included.
- Exit code 4 is reached end-to-end, not just at runner unit level.
- `formats` now reports conform, and its spec says so.
- Full Pre-Push Review Chain passed.

## Files

`lib/claricle.rb` (module API), `lib/claricle/handlers/*.rb`,
`lib/claricle/models/batch_failure.rb`, `lib/claricle/cli.rb` + batch
helper file, `README.adoc`, `spec/claricle/conformance/*_spec.rb`,
`spec/fixtures/`.
