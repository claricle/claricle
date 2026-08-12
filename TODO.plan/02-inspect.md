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
  command prints. **02 declares `inspect` only** — nothing else works
  yet, and `formats` must not advertise it. 03 and 04 extend the
  declarations as they ship (see 00's capabilities rule).
- `Inspection#valid`/`#issues` are a cheap parse-time signal, not
  conformance. Scope for 02: `issues` carries only what the inspection
  call itself surfaces — a raised delegate error becomes one
  `Issue{severity: "error"}` and `valid: "no"`; a clean parse is
  `valid: "yes"` with no issues. Handlers do NOT run a second
  validation pass here. Codes reuse the scheme 03 formalizes (delegate
  error class or error type), so 03 extends this mapping instead of
  replacing it. `dpi`/`color_space` nullable where the format has none.
- New deps in gemspec: `png_conform ~> 0.1`, `svg_conform ~> 0.2`,
  `vectory ~> 0.12`, `postscript ~> 0.2`, `pdfrb ~> 0.7` — Bundler
  resolution verified against released versions (D13).
- CLI: `claricle inspect FILE [--json]`; human output prints format,
  dimensions, each populated metadata field one per line, the tri-state
  `valid`, and every issue — a delegate that failed to parse shows up
  there and nowhere else, so omitting it would print a blank-looking
  success. JSON uses lutaml-model `to_json`. `claricle formats` prints the format ×
  operation matrix (human + `--json`). `formats --json` is an array of
  `{"format": "svg", "inspect": true, "conform": false, "convert_to":
  []}` objects, sorted by format — the keys stay fixed across items, so
  03 and 04 flip booleans and fill `convert_to` without reshaping the
  schema. Missing file → exit 2 (runner spec example deferred from 01
  lands here).
- Registry: `HANDLER_CLASSES` gains the five classes. Each handler file
  must be required in `lib/claricle.rb` **before** `registry` — the
  frozen map derives at load time and there is no autoloading, so a
  missing require is a `NameError` at boot, not a lazy failure. Replace
  01's "no handler registered" spec example with
  `from_content("x", format: :unregistered)`.

## Do

Plumbing first, then one handler per commit. The order matters: the
`formats` command has to exist before any handler can be truthful in
it, and after that every handler arrives as a complete slice.

1. Add deps; verify resolution.
2. `capabilities` macro on `Handlers::Base` + `formats` command + spec
   against the still-empty registry (prints no formats).
3. `inspect` command + `--json` + missing-file exit-2 spec, still
   against the empty registry.
4. One handler per commit, each commit carrying the whole slice: the
   handler class, its `capabilities :inspect` declaration, its
   `require` in `lib/claricle.rb`, its `HANDLER_CLASSES` entry, its
   spec against a real fixture, and the `formats` expected-output
   update. No commit ever advertises an operation it didn't ship.
5. Replace 01's "no handler registered" spec example.
6. README section for `inspect` and `formats` (D1) — real commands
   only, no forward promises.

## Done when

- `Claricle::Image.from_path(f).inspection` returns a populated
  `Inspection` for a real PNG, SVG, EMF, WMF, EPS, PS, and PDF fixture.
- `claricle inspect`/`claricle formats` work in human and JSON modes;
  exit codes verified (0 / 2 missing file / 3 unknown format).
- `formats` reports `inspect` only — the spec asserts `conform` is
  false and `convert_to` is empty for every format.
- Full Pre-Push Review Chain passed.

## Files

`claricle.gemspec`, `lib/claricle.rb` (handler requires, before
registry), `lib/claricle/handlers/{png,svg,metafile,postscript,pdf}.rb`,
`lib/claricle/handlers/base.rb` (capabilities),
`lib/claricle/registry.rb` (class list), `lib/claricle/cli.rb`,
`README.adoc`, `spec/claricle/handlers/*_spec.rb`,
`spec/claricle/cli_spec.rb`, `spec/fixtures/`.
