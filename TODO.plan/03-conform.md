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
| pdfrb `Validator.validate` strings | `severity: "error"`; `code: "PDF_STRUCTURE"` |
| pdfrb `Conformance::*` `Violation{rule_id, severity, spec_clause, object}` | `code: rule_id`; `location: {node_path: object}` |

- Module API: `Claricle.conform?(path = nil, pattern: nil, strict: false)`
  — exactly one of positional path or `pattern:` (ArgumentError
  otherwise; the issue's examples use both shapes); `pattern:` is true
  only if every matched file conforms. `Claricle.conformance_report(path)`
  → `Models::Report`.
- **The batch helper** (owned here, reused verbatim by 04): expand
  `Dir.glob(pattern).sort`; zero matches → exit 2; per-file failures
  don't stop the batch; final exit = highest code across files; JSON
  batch output = array (D12).
- CLI: `claricle conform FILE|PATTERN [--json] [--strict]`; conformance
  failure exits 1 (through `SystemExit` passthrough in the runner);
  `--strict` requires tri-state `yes` (D8).
- Fixtures: one valid + one invalid sample per format, sourced from the
  delegates' canonical corpora (PngSuite, svg_conform fixtures, emf
  corpus, pdfrb specs).

## Do

1. Per-handler `conformance_report` TDD against valid+invalid fixtures,
   one handler per commit.
2. Module API + ArgumentError spec.
3. Batch helper + `conform` command + exit-code specs (0/1/2/3).
4. `--strict` + tri-state boundary specs (warnings-only file).

## Done when

- `Claricle.conform?` correct for all five formats, both call shapes.
- Invalid fixture of each format yields a `Report` with populated,
  correctly-mapped issues; exit codes verified end-to-end.
- Batch glob over mixed formats returns highest-code exit and JSON array.
- Full Pre-Push Review Chain passed.

## Files

`lib/claricle.rb` (module API), `lib/claricle/handlers/*.rb`,
`lib/claricle/cli.rb` + batch helper file, `spec/claricle/conformance/
*_spec.rb`, `spec/fixtures/`.
