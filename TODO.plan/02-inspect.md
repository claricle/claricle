# 02 — Inspect: five handlers, `claricle inspect`, `claricle formats`

Can start: after 01.

## Problem

Core dispatches to an empty registry. Nothing can read metadata from
any format, and the CLI has no operation commands.

## Design

Delegate entry points (verified against the real gems 2026-08-10; the
delegates are path- or content-oriented as noted):

| Handler (formats) | Delegate call | Metadata source |
|---|---|---|
| `Handlers::Png` (`:png`) | `PngConform::Services::ValidationService.validate_file(path)` via `image.with_path` | `FileAnalysis#image_info` (width/height/bit depth/color type) |
| `Handlers::Svg` (`:svg`) | `Vectory::Svg.from_content(image.content)` | width/height; root attributes into `meta` |
| `Handlers::Metafile` (`:emf, :wmf`) | `::Emf.parse(image.content)` | header bounds/device dims; `meta[:emf_plus]` from `metafile.emf_plus` |
| `Handlers::Postscript` (`:eps, :ps`) | `Vectory::Eps`/`Ps` (BoundingBox dims) + `::Postscript.parse` structure | dims; DSC header fields into `meta` |
| `Handlers::Pdf` (`:pdf`) | `Pdfrb::Document.open(path)` via `image.with_path` | version, page count |

- Handlers must reference delegates with `::` — `Claricle::Handlers::X`
  shadows top-level constants (`Emf`, `Postscript`).
- Heavy delegates are `require`d lazily inside each handler (D5).
- `capabilities` class macro declares the per-op support the `formats`
  command prints.
- `Inspection#valid`/`#issues` populated from the same parse — cheap
  signal only; full conformance is 03. `dpi`/`color_space` nullable
  where the format has none.
- New deps in gemspec: `png_conform ~> 0.1`, `svg_conform ~> 0.2`,
  `vectory ~> 0.12`, `postscript ~> 0.2`, `pdfrb ~> 0.7` — Bundler
  resolution verified against released versions (D13).
- CLI: `claricle inspect FILE [--json]` (human default, lutaml-model
  `to_json` for `--json`); `claricle formats` prints the format ×
  operation matrix (human + `--json`). Missing file → exit 2 (runner
  spec example deferred from 01 lands here).
- Registry: `HANDLER_CLASSES` gains the five classes. Replace 01's
  "no handler registered" spec example with
  `from_content("x", format: :unregistered)`.

## Do

1. Add deps; verify resolution. One handler at a time, TDD against a
   real fixture per format (delegates' corpora).
2. `capabilities` macro + `formats` command + spec.
3. `inspect` command + `--json` + missing-file exit-2 spec.
4. Registry list + 01 spec example replacement.

## Done when

- `Claricle::Image.from_path(f).inspection` returns a populated
  `Inspection` for a real PNG, SVG, EMF, WMF, EPS, PS, and PDF fixture.
- `claricle inspect`/`claricle formats` work in human and JSON modes;
  exit codes verified (0 / 2 missing file / 3 unknown format).
- Full Pre-Push Review Chain passed.

## Files

`claricle.gemspec`, `lib/claricle/handlers/{png,svg,metafile,
postscript,pdf}.rb`, `lib/claricle/handlers/base.rb` (capabilities),
`lib/claricle/registry.rb` (class list), `lib/claricle/cli.rb`,
`spec/claricle/handlers/*_spec.rb`, `spec/claricle/cli_spec.rb`,
`spec/fixtures/`.
