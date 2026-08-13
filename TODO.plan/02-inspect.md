# 02 — Inspect: five handlers, `claricle inspect`, `claricle formats`

Can start: after 01. D14 (WMF) and D18 (EMF+) settle what this item
registers.

## Problem

Core dispatches to an empty registry. Nothing can read metadata from
any format, and the CLI has no operation commands.

## Design

Delegate entry points (verified against the real gems 2026-08-10; the
delegates are path- or content-oriented as noted):

| Handler (formats) | Delegate call | Metadata source |
|---|---|---|
| `Handlers::Png` (`:png`) | A chunk **reader**, not the validator — `PngConform::Readers::FullLoadReader` was measured exposing `each_chunk`, `signature`, `png`, `file_size`. It accepts signature-only or signature-plus-junk input and simply yields zero chunks, so "no exception" cannot mean `parse_status: :ok` — require a readable `IHDR` before declaring success. Routing inspection through `ValidationService` would make `inspect` mean conformance for PNG and metadata for everything else | header chunk: width/height/bit depth/colour type |
| `Handlers::Svg` (`:svg`) | `Vectory::Svg.from_content(image.content)`. **`Vectory::NotImplementedError` means "no dimensions", not "parse failed"** — measured: a *valid* SVG with no width/height/viewBox raises it, while a *malformed* SVG carrying `width="7"` returns 7. So dimensions are nullable, that error maps to nil dimensions, and `parse_status` must come from Claricle's own structural check (D23), never from whether the dimension read raised | width/height (nullable); root attributes into `meta` |
| `Handlers::Metafile` (`:emf` only) | `::Emf.parse(image.content)` | header bounds/device dims. `metafile.emf_plus` was nil on our fixture, and when present it is packed binary — putting it straight into `meta` risks `JSON::GeneratorError`, so expose presence, byte size and optionally Base64, never the raw bytes ⚙ confirm against a real EMF+ file before writing the spec |
| `Handlers::Postscript` (`:eps, :ps`) | `Vectory::Eps`/`Ps` for dims — measured `100.0x50.0`, **floats not integers**. `::Postscript.parse` for DSC structure only; it is not a validity signal (D22), so a successful parse says nothing about conformance | dims; DSC header fields into `meta` |
| `Handlers::Pdf` (`:pdf`) | `Pdfrb::Document.open(path)` via `image.with_path` — measured returning version `1.4` and a page count. It **opens a structurally broken PDF without complaint**, so a successful `open` cannot by itself yield `parse_status: :ok`; the status comes from Claricle's structural pre-pass (D23), consistent with 01 | version, page count |

Every row above was executed against a real fixture on 2026-08-13; see
the measured-contracts section in 00. Re-run them if a delegate version
moves — that section exists because six confidently-asserted contracts
turned out false.

- **WMF is out (D14).** Released `emf` 0.1.0 raises `WMF parser not yet
  implemented`, so `Handlers::Metafile` claims `:emf` alone. The
  detector still returns `:wmf`; with no handler registered it raises
  `UnsupportedFormat` → exit 3. That needs its own spec: a real WMF
  fixture is recognised and refused, not reported unknown.

- Handlers must reference delegates with `::` — `Claricle::Handlers::X`
  shadows top-level constants (`Emf`, `Postscript`).
- Heavy delegates are `require`d lazily inside each handler (D5).
- `capabilities` class macro declares the per-op support the `formats`
  command prints. **02 declares `inspect` only** — nothing else works
  yet, and `formats` must not advertise it. 03 and 04 extend the
  declarations as they ship (see 00's capabilities rule).
- `Inspection#parse_status` is `:ok` or `:failed` — "did the metadata
  parse", never a validity claim (01's inspection contract). An
  **allowlisted** parse error becomes `:failed` plus one
  `Issue{severity: "error"}` and still exits 0; a fault off the
  allowlist propagates and exits 4, so a genuine bug in a delegate is
  never disguised as a tidy `:failed` result. A clean parse is `:ok`
  with no issues. Handlers do NOT run a second validation pass here,
  and PNG must not route inspection through the conformance validator
  just because it has one — that would make `inspect` mean something
  different for PNG than for everything else.
  Codes reuse the scheme 03 formalizes, so 03 extends this mapping
  instead of replacing it. `dpi`/`color_space` nullable where the
  format has none. Note that a `:failed` inspection still exits 0.
- New deps in gemspec: `png_conform`, `svg_conform`, `vectory`,
  `postscript`, `pdfrb` — three-segment constraints on the reviewed
  line (D13), not a floating `~> 0.x`. Locally installed and reviewed:
  png_conform 0.1.4, svg_conform 0.2.1, vectory 0.12.0, postscript
  0.2.0, pdfrb 0.7.10. The earlier plan's `png_conform ~> 0.7` /
  `svg_conform ~> 0.8.0` figures were wrong and contradicted this list.
  No direct `libpng` dep — it arrives via `vectory → emfsvg` already
  (D5). Verify Bundler resolution.
- CLI: `claricle inspect FILE [--json]`; human output prints format,
  dimensions, each populated metadata field one per line, the
  `parse_status`, and every issue — a delegate that failed to parse
  shows up there and nowhere else, so omitting it would print a
  blank-looking success. JSON uses lutaml-model `to_json`, and empty
  collections must still serialize as `[]` rather than being omitted —
  lutaml-model drops them by default unless the mapping says otherwise.
  Dimensions carry whatever D15's sign-off decides; until then do not
  assert cross-format dimension equality anywhere. `claricle formats` prints the format ×
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
  `Inspection` for a real PNG, SVG, EMF, EPS, PS, and PDF fixture.
- A real WMF fixture is detected as `:wmf` and refused with exit 3.
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
