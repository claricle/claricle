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
| png_conform via `validate_file` ⚙ | **Message text only.** `result_builder#add_context_messages` calls `result.error(e[:message])`, dropping `error_type`, `chunk_type` and `chunk_offset`. So: `severity` from which bucket it came (error/warning/info), `location: nil`, and a stable synthetic `code` — there is no upstream type to carry. If a richer png_conform entry point exists, use it and restore type/chunk/offset; otherwise say plainly that PNG issues have no coordinates |
| svg_conform `ValidationIssue` ⚙ | **Map severity from `severity`, not `type`.** `ErrorTracker#add_error` hardcodes `type: :error` and keeps the real classification in a separate `severity` field, so mapping from `type` would flatten every info and warning into an error and defeat D8's tri-state. Treat `validity_error` as error; fall back to `type` only when `severity` is nil. `code: requirement_id`; `location: {line, column}` |
| emf `metafile.errors` (message, offset, record_code) | `severity: "error"`; `code: "EMF_PARSE"`; `location: {byte_offset}`; clean parse + serialize round-trip identity = conformant |
| postscript exceptions ‡ | Unverified — the gem is not installed. Assumed: a single `Issue{severity: "error", code: <exception class>}`, clean parse = conformant. Confirm at the gate |
| pdfrb ‡ | Unverified — the gem is not installed. The plan previously asserted a `Validator.validate` / `Conformance::*` surface as fact; it is not. Confirm at the gate, then decide D16 |

- **PDF conformance scope is deferred to D16.** An earlier draft here
  specified structural-only conform with `--profile` opt-in; that rested
  on a pdfrb surface nobody has executed. Issue #1 asks for Arlington
  predicates, and whether released pdfrb exposes a general Arlington
  runner is unknown. The gate resolves what exists, then D16 gets
  signed off, then this section gets written. Ship no PDF conformance
  claim before that — a weaker check under the name "conform" would
  silently narrow the issue's requirement.
- **`conform` needs one stated baseline across formats.** Today it
  would mean extensive validation for PNG, a default profile for SVG,
  parse-plus-round-trip for EMF, and a bare syntactic parse for PS/EPS.
  Those are not comparable claims. Record what each format's conform
  actually checks, in the `Report` provenance fields, and say so in the
  README rather than implying uniformity.
- Module API: `Claricle.conform?(path = nil, pattern: nil,
  strict: false)` — exactly one of positional path or `pattern:`
  (`InvocationError` otherwise; the issue's examples use both shapes);
  `pattern:` is true only if every matched file conforms.
  `Claricle.conformance_report(path)` → `Models::Report`. No `profile:`
  until D16 settles.
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
  raises `ArgumentError` (matching the CLI's exit 2, not a vacuous
  `true`).
- **The batch helper** (owned here, reused by 04): positional `FILE...`
  arguments are literal paths; globbing needs an explicit `--pattern`
  (D12). Expand `Dir.glob(pattern).sort`; zero matches → exit 2;
  per-file failures don't stop the batch; final exit = highest code.
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
   matches, 3 for a format no handler conforms). No capability changes.
2. Module API argument specs — both call shapes, `InvocationError`
   cases, and `conformance_batch` collecting every outcome without
   short-circuiting.
3. One handler per commit: `conformance_report` TDD against valid and
   invalid fixtures, `capabilities :conform`, and the `formats`
   expected-output update, together. Exit codes 0 and 1 get their
   end-to-end specs with the first handler. PS and PDF handlers are
   blocked on the verification gate.
4. Per-delegate malformed-input allowlist, per operation and stage, so
   a recognised-but-corrupt file exits 1 rather than 4. `Emf::FormatError`
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

- `Claricle.conform?` correct for all five formats, both call shapes.
- Invalid fixture of each format yields a `Report` with populated,
  correctly-mapped issues; exit codes verified end-to-end.
- Batch glob over mixed formats returns highest-code exit and a
  positionally complete JSON array of `BatchItem`, failures included.
- A single-file failure emits the same JSON envelope as a batch one.
- Exit code 4 is reached end-to-end, and a corrupt-but-recognised
  fixture of every format exits 1 rather than 4.
- `formats` now reports conform, and its spec says so.
- Full Pre-Push Review Chain passed.

## Files

`lib/claricle.rb` (module API), `lib/claricle/handlers/*.rb`,
`lib/claricle/models/batch_item.rb`, `lib/claricle/cli.rb` + batch
helper file, `README.adoc`, `spec/claricle/conformance/*_spec.rb`,
`spec/fixtures/`.
