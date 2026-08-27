# 04 — Convert: vectory routing, lossiness, README rewrite

Can start: after 03 (reuses its batch helper). D11 (round-trip
assertions) and D23 (lossiness classification) settle what it asserts.

## Problem

No conversion exists. The issue requires EMF↔SVG, PS/EPS↔SVG and
SVG→EPS with explicit lossiness — no silent lossy conversions — plus
the final README describing the real library. All twelve edges between
svg/emf/eps/ps were measured working, so v1 ships the full matrix.

## Design

- `Models::Conversion` (lutaml-model): `source_path`, `source_format`,
  `target_format`, `lossiness`, `output_path`, `content` (excluded from
  JSON serialization). `source_path` is populated whenever the image
  came from disk, and nil for a content-born one — `Image#convert`
  works in memory and has no path to report. It is required in every
  path that batching can reach, since that is where a result must be
  traceable to its input; never substitute a Tempfile path to fill it.
- Conversion routes through vectory: `Vectory::Emf.from_content(...)
  .to_svg` and siblings. All twelve svg/emf/eps/ps edges succeed **on a
  rect-and-line fixture** (D9) — that is what "the matrix works" means,
  and no more. Richer content fails in ways the matrix cannot express:
  gradients raise on SVG→EMF, and the SVG→EPS path raised
  `NameError: uninitialized constant Postsvg::Model::UnknownOperator`
  on a cold process for an embedded raster, then succeeded once an
  unrelated conversion had run first. That load-order bug will present
  as intermittent, so the spec suite must exercise each edge in a fresh
  process, not only after other conversions have warmed the constants. WMF is out of v1 entirely (D14)
  and never reaches a handler; png and pdf have no vectory class.
- **Lossiness is per-conversion, not per-edge (D10 superseded, D23).**
  Measured: SVG→EPS silently turns a gradient solid black, silently
  removes a clip path, and silently deletes an embedded raster, while
  the same edge is perfectly clean for a rect. SVG→EMF *raises* on a
  gradient (`Emfsvg::FormatError: unsupported SVG color`) but silently
  makes a clipped object invisible. A static per-edge label would
  therefore call SVG→EPS lossless on rect evidence and then destroy a
  gradient without a word — the exact silent lossy conversion issue #1
  forbids. So: inspect the source document for the features known to be
  dropped on that edge, and classify **this** conversion. The
  `:lossless` / `:lossy` / `:unknown` vocabulary stands; the static
  table becomes a pessimistic floor, never the answer. Build the
  feature list from the fixture corpus and grow it as more losses are
  found. Lossy/unknown conversions warn on stderr and carry the
  classification in the result. No consent-gate flag — the issue
  requires disclosure, not consent.
- **Write lifecycle**: `Image#convert(to:)` never touches disk.
  `Claricle.convert(src, to:, output: nil, force: false)` writes to the
  given path; stdout for `"-"`; with `output: nil` derives the sibling
  path (source name, target extension — the issue's
  `convert("diagram.emf", to: :svg)` writes `diagram.svg`).
  `Conversion#output_path` = actual written path, nil for
  stdout/in-memory.
- **Same-format conversion is an invocation error, not a crash.**
  `Vectory::Svg#to_svg` does not exist — every same-format pair raises
  `NoMethodError`, which would exit 4 as an internal fault. Reject
  `--to` equal to the detected source format up front with
  `InvocationError` → exit 2, before any delegate is touched.
- **A successful `from_content` proves nothing about the content.**
  Measured: EPS bytes into `Vectory::Emf`, EMF bytes into
  `Vectory::Eps` and raw SVG into `Vectory::Emf` all construct without
  complaint and only fail at the conversion call. Detection remains the
  only authority on what a file is; never infer it from a delegate
  accepting the bytes.
- **One overwrite rule, both layers**: an existing destination is never
  overwritten without `force: true`/`--force`, and it makes no
  difference whether the path was derived or given explicitly. Refusing
  raises `InvocationError` at API level and exits 2 at CLI level. Two
  rules here would be a trap — the derived path is the one the user
  didn't type and so the one they're least likely to be watching.
- **Batch conversion must preflight the whole write set before writing
  anything.** Derived sibling names plus batching plus `--force` is a
  data-loss machine otherwise. Real cases: `a.emf` and `a.svg` in one
  run targeting SVG, where converting the EMF overwrites a later input;
  `a.eps` and `a.ps` both deriving `a.svg`, where one result destroys
  the other; `Logo.eps` and `logo.ps` colliding on a case-insensitive
  filesystem; and `convert logo.svg --to emf --output logo.svg --force`
  destroying its own source. So: resolve every source/destination pair
  up front, compare by **filesystem identity** rather than string
  equality (symlinks, hardlinks, case folding), reject any destination
  that is also a source, and reject non-unique destinations even under
  `--force`. Note a **nonexistent** destination has no inode to compare
  — `Logo.svg` and `logo.svg` collide on a case-insensitive filesystem
  before either exists. So canonicalize planned destinations by probing
  the target directory's case sensitivity once, and compare
  canonicalized strings for paths that do not yet exist. A preflight
  collision **fails the whole batch before any write**, rather than
  producing per-item failures — half-written output is worse than none,
  and the user can fix the input set and re-run. `--force` authorises replacing an unrelated existing file,
  never clobbering an input.
- **Writes are atomic in both directions.** Without `--force`, stage to
  a temp file in the destination's own directory and publish with a
  no-replace atomic operation, so a concurrent writer can't slip
  between the existence check and the write. With `--force`, stage the
  same way and atomically rename over the target, so a serialization or
  disk failure can't truncate a good existing file. For `--output -`,
  generate the bytes fully before writing and use binary
  `stdout.write` — never `puts`, which appends a newline and corrupts
  binary output. Spec it byte-for-byte.
- CLI: `claricle convert SOURCE... [--pattern GLOB] [--to FORMAT]
  [--output FILE|-] [--json] [--force]` — same invocation shape as
  `conform` (D19): a positional source is a literal path when it names
  an existing file and a glob otherwise, with `--pattern` forcing glob
  interpretation. Batch runs via 03's helper, every file landing in a
  uniform `Models::BatchItem` slot, failures included. `--output` names
  a single destination, so it is rejected with exit 2 whenever more
  than one source resolves; multi-source runs use derived names. `--to` may be omitted **only** when
  `--output` names a file whose extension maps to a known format; that
  extension then decides the target. Omitting both, or giving an
  extension that maps to nothing, exits 2 with a message naming the
  problem — there is no default target and no guessing from the source
  format, drawn from the handlers' declared canonical extensions rather
  than a central table. `--to svg --output result.emf` is a conflict,
  not a preference — exit 2 rather than silently letting one win.
  `--output -` puts bytes alone on stdout, and rejects `--json` and a
  missing `--to` (exit 2, since there's no extension to infer from).
  Everything else — the human summary, lossiness warnings, error text —
  goes to stderr in that mode, so the stdout stream stays pipe-safe.
  `--json` serializes `Conversion` minus content, always as an array of
  `BatchItem` per 03's rule. Human output prints one line per file:
  source, target format, written path (or `-`), and the lossiness
  classification.
- `capabilities` gains `convert` plus that handler's target list in the
  same commit that implements the edge (per 00's rule), with the
  `formats` output spec moving alongside. The last such commit is what
  finally makes `claricle formats` the full support matrix the issue
  asks for.
- **There is no general round-trip invariant, and that is measured
  (D11).** Byte identity against the original never held — the first
  pass always rewrites. Idempotence held for a rect-and-line fixture
  and then failed outright once the document contained a single
  `<text>` element: three cycles gave three different hashes on both
  the EMF and EPS chains, with a text baseline drifting 24.4 → 23.4 →
  22.4 and an EPS viewBox growing `0 0 100 50` → `0 -25 100 75` →
  `0 -25 100 100`. So do **not** write a general `cycle N == cycle N+1`
  spec; it passes only because the fixture is trivial, and that is how
  this claim survived two review rounds.
  What can honestly be asserted: conversion is **deterministic** (same
  input, identical bytes — measured true); same-format parse→serialize
  identity for EMF; and per-feature semantic properties over a fixture
  corpus, each naming the property it checks. Pending D11 sign-off on
  what replaces the issue's stated backbone.
  Also note "dimension preservation" is not assertable until D15
  settles units — the same SVG reports `3×1` through vectory and
  `96×48` as EPS, so an equality check would be testing a coincidence.
- Docs closure: README.adoc fully rewritten on top of 01's honesty
  baseline — real API + CLI, the format × operation matrix, exit codes,
  and the registry extension workflow. That workflow must describe what
  adding a format **actually** costs: if handlers don't yet declare
  their sniffer, capabilities, targets, extensions and lossiness, then
  it is a handler class plus a detector edit plus a require plus a
  registry entry plus a lossiness edge, and the README says so rather
  than repeating the one-class claim. Gemspec description refreshed for
  the operations that now exist; its URLs moved to the `claricle` org in
  01 and need no further edit. `sig/` stays deleted (01's docs rule).
  Drop `"convert"` from 01's stub-removal spec assertion (a real
  `convert` now exists).

## Do

Plumbing first again, then one edge family per commit.

1. `Models::Conversion` + the per-target feature-loss rules (D23) +
   specs. Not a flat edge table — a rule says "this target discards
   gradients / clip paths / embedded rasters", and the classifier
   inspects the source for those features.
2. Extract the write lifecycle as its own injectable service and spec
   it directly — preflight collision set, filesystem-identity aliasing,
   no-replace atomic create, force-mode temp-and-rename, binary stdout.
   01 freezes the registry and bans runtime mutation and test-only
   APIs, so there is no honest route from a detected real format to a
   stand-in handler; testing the service directly avoids needing one.
3. `convert` command + batch + `--force`/`--output -`/`--json`
   boundary specs + `--to` inference, its exit-2 cases, and the
   `--to`/`--output` suffix conflict; `--output -` spec asserts stdout
   carries bytes only, with no trailing newline.
4. One edge family per commit: handler `convert` TDD against real
   fixtures, `capabilities :convert` with that handler's target list,
   and the `formats` expected-output update, together.
5. Semantic spec suite over the fixture corpus, each spec naming the
   property it checks (D11 leaves the overall invariant open, so do not
   write a general round-trip assertion). Add a feature-loss rule only
   when a fixture demonstrates the loss.
6. `formats` full-matrix spec once the last edge lands.
7. README rewrite + gemspec metadata + stub-spec update.

## Done when

- All acceptance-matrix conversions work via API and CLI with correct
  exit codes and lossiness warnings.
- Semantic suite green; every `:lossless` classification is
  fixture-proven for the features present in that fixture, and the
  gradient, clip-path and embedded-raster cases each produce a
  `:lossy` classification with a warning rather than silent loss.
- A batch that would collide or overwrite an input is refused before
  anything is written, and specs cover the four concrete cases.
- `claricle formats` prints the complete support matrix — every cell
  matches what actually works.
- README describes only verified behavior; issue #1 acceptance
  checklist fully satisfiable, or the gaps are signed off.
- Full Pre-Push Review Chain passed.

## Files

`lib/claricle/models/conversion.rb`, `lib/claricle/handlers/
{metafile,postscript,svg}.rb`, `lib/claricle/writer.rb` (write
lifecycle service), `lib/claricle/registry.rb`, `lib/claricle.rb`,
`lib/claricle/cli.rb`, `README.adoc`, `claricle.gemspec`,
`spec/claricle/conversion/*_spec.rb`, `spec/claricle/writer_spec.rb`,
`spec/claricle/cli_spec.rb`.
