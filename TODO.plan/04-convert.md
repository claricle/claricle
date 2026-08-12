# 04 — Convert: vectory routing, lossiness, README rewrite

Can start: after 03 (reuses its batch helper).

## Problem

No conversion exists. The issue requires EMF↔SVG, PS/EPS↔SVG, and
SVG→EPS with explicit lossiness — no silent lossy conversions — plus
the final README describing the real library.

## Design

- `Models::Conversion` (lutaml-model): `source_format`, `target_format`,
  `lossiness`, `output_path`, `content` (excluded from JSON
  serialization).
- Conversion routes through vectory's verified matrix only:
  `Vectory::Emf.from_content(...).to_svg` and siblings (D9). WMF has no
  vectory class — `UnsupportedFormat`.
- **Lossiness** (D10): static per-edge enum in the registry —
  `:lossless` / `:lossy` / `:unknown`. SVG→EMF starts `:lossy`
  (emfsvg documents its reverse direction as a "lossy matcher"); every
  other edge starts `:unknown` and is upgraded only on fixture
  evidence. Lossy/unknown conversions warn on stderr and always carry
  the classification in the result. No consent-gate flag — the issue
  requires disclosure, not consent.
- **Write lifecycle**: `Image#convert(to:)` never touches disk.
  `Claricle.convert(src, to:, output: nil, force: false)` writes to the
  given path; stdout for `"-"`; with `output: nil` derives the sibling
  path (source name, target extension — the issue's
  `convert("diagram.emf", to: :svg)` writes `diagram.svg`).
  `Conversion#output_path` = actual written path, nil for
  stdout/in-memory.
- **One overwrite rule, both layers**: an existing destination is never
  overwritten without `force: true`/`--force`, and it makes no
  difference whether the path was derived or given explicitly. Refusing
  raises at API level and exits 2 at CLI level. Two rules here would be
  a trap — the derived path is the one the user didn't type and so the
  one they're least likely to be watching.
- CLI: `claricle convert SOURCE [--to FORMAT] [--output FILE|-]
  [--json] [--force]`; batch via 03's helper, failed files land as
  `Models::BatchFailure` entries. `--to` may be omitted **only** when
  `--output` names a file whose extension maps to a known format; that
  extension then decides the target. Omitting both, or giving an
  extension that maps to nothing, exits 2 with a message naming the
  problem — there is no default target and no guessing from the source
  format. `--output -` puts bytes alone on stdout, and rejects `--json`
  and a missing `--to` (exit 2, since there's no extension to infer
  from). Everything else — the human summary, lossiness warnings, error
  text — goes to stderr in that mode, so the stdout stream stays pipe-
  safe. `--json` serializes `Conversion` minus content, following 03's
  rule: one object for a single file argument, an array for a pattern.
  Human output prints one line per file: source, target format, written
  path (or `-`), and the lossiness classification.
- `capabilities` gains `convert` plus that handler's target list in the
  same commit that implements the edge (per 00's rule), with the
  `formats` output spec moving alongside. The last such commit is what
  finally makes `claricle formats` the full support matrix the issue
  asks for.
- **Round-trip specs** (D11): same-format parse→serialize identity
  where the delegate guarantees it (EMF); semantic checks for
  cross-format conversions (dimension preservation, delegate fixtures).
  Byte-identical cross-format round-trips are NOT asserted.
- Docs closure: README.adoc fully rewritten — real API + CLI, the
  format × operation matrix, exit codes, and the registry extension
  workflow (adding a format = one handler class + one
  `Registry::HANDLER_CLASSES` entry; an explicit issue acceptance
  item). Gemspec description/homepage refreshed (org moved
  ribose → claricle). Stale `sig/claricle.rbs` replaced or removed.
  Drop `"convert"` from 01's stub-removal spec assertion (a real
  `convert` now exists).

## Do

Plumbing first again, then one edge family per commit.

1. `Models::Conversion` + lossiness edge table + specs.
2. Module API write lifecycle + `convert` command + batch +
   `--force`/`--output -`/`--json` boundary specs + `--to` inference
   and its exit-2 cases; `--output -` spec asserts stdout carries bytes
   only. Drive the lifecycle through an anonymous handler subclass
   (01's pattern — real class, not a double) so writes are exercised
   before any real edge exists; every real format still exits 3 here
   and no capability changes yet.
3. One edge family per commit: handler `convert` TDD against real
   fixtures, `capabilities :convert` with that handler's target list,
   and the `formats` expected-output update, together.
4. Round-trip + semantic spec suite; upgrade lossiness edges only where
   fixtures prove it.
5. `formats` full-matrix spec once the last edge lands.
6. README rewrite + gemspec metadata + RBS cleanup + stub-spec update.

## Done when

- All acceptance-matrix conversions work via API and CLI with correct
  exit codes and lossiness warnings.
- Round-trip/semantic suite green; every `:lossless` edge is
  fixture-proven.
- `claricle formats` prints the complete support matrix — every cell
  matches what actually works.
- README describes only verified behavior; issue #1 acceptance
  checklist fully satisfiable.
- Full Pre-Push Review Chain passed.

## Files

`lib/claricle/models/conversion.rb`, `lib/claricle/handlers/
{metafile,postscript,svg}.rb`, `lib/claricle/registry.rb` (edge table),
`lib/claricle.rb`, `lib/claricle/cli.rb`, `README.adoc`,
`claricle.gemspec`, `sig/`, `spec/claricle/conversion/*_spec.rb`,
`spec/claricle/cli_spec.rb`.
