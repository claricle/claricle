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
  `Claricle.convert(src, to:, output: nil)` writes to the given path;
  stdout for `"-"`; with `output: nil` derives the sibling path (source
  name, target extension — the issue's `convert("diagram.emf", to:
  :svg)` writes `diagram.svg`). `Conversion#output_path` = actual
  written path, nil for stdout/in-memory.
- CLI: `claricle convert SOURCE [--to FORMAT] [--output FILE|-]
  [--json] [--force]`; batch via 03's helper; derived names refuse to
  overwrite without `--force`; `--output -` puts bytes alone on stdout
  (diagnostics → stderr) and rejects `--json` (exit 2); `--json`
  serializes `Conversion` minus content, single object or batch array.
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

1. `Models::Conversion` + lossiness edge table + specs.
2. Handler `convert` methods TDD per edge, real fixtures, one commit
   per format family.
3. Module API write lifecycle + specs (derived name, explicit path,
   stdout, `output_path` values).
4. CLI command + batch + `--force`/`--output -`/`--json` boundary specs.
5. Round-trip + semantic spec suite; upgrade lossiness edges only where
   fixtures prove it.
6. README rewrite + gemspec metadata + RBS cleanup + stub-spec update.

## Done when

- All acceptance-matrix conversions work via API and CLI with correct
  exit codes and lossiness warnings.
- Round-trip/semantic suite green; every `:lossless` edge is
  fixture-proven.
- README describes only verified behavior; issue #1 acceptance
  checklist fully satisfiable.
- Full Pre-Push Review Chain passed.

## Files

`lib/claricle/models/conversion.rb`, `lib/claricle/handlers/
{metafile,postscript,svg}.rb`, `lib/claricle/registry.rb` (edge table),
`lib/claricle.rb`, `lib/claricle/cli.rb`, `README.adoc`,
`claricle.gemspec`, `sig/`, `spec/claricle/conversion/*_spec.rb`,
`spec/claricle/cli_spec.rb`.
