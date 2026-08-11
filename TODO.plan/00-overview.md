# Claricle Unified Library Plan

**Date**: 2026-08-11. Restructured from the reviewed single-file plan
(git history: `docs/plans/issue-1-unified-library.md`, removed in this
restructure — these files are self-contained).
**Goal**: turn `claricle` from a placeholder shim into the real umbrella
library for issue #1 — one Ruby API and one CLI providing **inspect**,
**conformance check**, and **conversion** over PNG, SVG, EMF/WMF, PS/EPS,
and PDF, delegating to the org's specialist gems.

> Local working docs under `docs/plans/*` live only on the maintainer's
> machine and are never committed. The plan files here are the
> authoritative, self-contained copy.

## Architecture

```mermaid
flowchart TD
    API["Claricle.conform? / Claricle.convert / Claricle::Image"]
    DET["Detector<br/>magic-byte sniffer"]
    REG["Registry<br/>frozen format→handler map"]
    API --> DET
    DET --> REG
    REG --> HPNG[Handlers::Png]
    REG --> HSVG[Handlers::Svg]
    REG --> HMET["Handlers::Metafile<br/>(:emf, :wmf)"]
    REG --> HPS["Handlers::Postscript<br/>(:eps, :ps)"]
    REG --> HPDF[Handlers::Pdf]
    HPNG --> png_conform
    HSVG --> svg_conform
    HSVG --> vectory
    HMET --> emf
    HMET --> vectory
    HPS --> postscript
    HPS --> vectory
    HPDF --> pdfrb
    HPNG -. maps results into .-> MOD["Models::Inspection / Report /<br/>Issue / Location / Conversion<br/>(lutaml-model)"]
    HSVG -.-> MOD
    HMET -.-> MOD
    HPS -.-> MOD
    HPDF -.-> MOD
```

Every handler is a plain subclass declaring its formats once; the
registry derives a frozen map from one class list. Adding a format =
one handler class + one entry in `Registry::HANDLER_CLASSES`.

## Item topology

Strictly sequential — each item is an independently green, shippable
PR building on the previous one. 04 depends on 03 because the CLI
batch helper is built in 03 and reused verbatim in 04.

```mermaid
flowchart LR
    I01[01 core] --> I02[02 inspect] --> I03[03 conform] --> I04[04 convert]
```

## Items

| # | Item | Delivers | Can start |
|---|------|----------|-----------|
| 01 | Core | errors, models, detector, registry, `Image`, CLI runner + exit codes, stub removal, Ruby 3.2 floor | now |
| 02 | Inspect | five handlers' `inspection`, `claricle inspect`, `claricle formats`, `--json` | after 01 |
| 03 | Conform | five conformance mappings, `Claricle.conform?`, `claricle conform`, batch helper, `--strict` | after 02 |
| 04 | Convert | vectory-backed conversion, lossiness classification, `claricle convert`, README rewrite | after 03 |

## Decisions of record (Claude + Codex consensus, 2026-08-10)

Thirteen decisions. Three deviate from the issue text and need sign-off
from the issue author before their behavior ships — post them as an
issue #1 comment at the start of implementation.

| # | Decision | Status |
|---|----------|--------|
| D1 | Four vertical-slice PRs; docs land inside each PR; README fully rewritten by 04 | settled |
| D2 | `Image#inspect` → `Image#inspection` (`Object#inspect` stays Ruby's debugging protocol; no module-level facade — it would shadow `Module#inspect`) | **needs issue sign-off** |
| D3 | Plain handler subclasses + `formats` declaration macro; frozen derived registry, no runtime mutation, no self-registration | settled |
| D4 | All unified models are lutaml-model classes; `lutaml-model ~> 0.8` is a direct dependency (resolves with png_conform `~> 0.7` / svg_conform `~> 0.8.0`) | settled |
| D5 | Hard deps on all delegates; Ruby floor **3.2** (pdfrb); `libpng` dropped (FFI codec, no v1 operation needs it). Heavy gems required lazily inside handlers; `emf` (bindata-only, powers the detector) is the sole eager require | **needs issue sign-off** |
| D6 | Keep Thor; `Runner` wraps `Cli.start(argv, debug: true)` and maps errors → exit codes (matrix below) | settled |
| D7 | Hand-rolled magic-byte detector (no marcel): PNG signature, `%PDF-`, `%!PS` + `EPSF` first-line split, `Emf.detect_format`, XML-aware `<svg` root sniff | settled |
| D8 | Tri-state `valid`: `yes` = no issues, `suspicious` = warnings only, `no` = any error. Non-strict `conform?` passes `yes` AND `suspicious`; `--strict`/`strict:` requires `yes` | settled |
| D9 | Conversion via vectory only: EMF↔SVG, PS/EPS↔SVG, SVG→EPS/PS. PNG/PDF inspect+conform only. WMF inspect+conform via `emf`, no convert. EMF+ surfaces as inspection metadata | settled |
| D10 | Lossiness = static per-edge enum `:lossless/:lossy/:unknown`; SVG→EMF is `:lossy` (documented); lossy/unknown warn on stderr + carry classification in the result; no consent-gate flag | settled |
| D11 | Round-trip narrowed: byte-identical A→B→A across formats NOT promised (vectory's own specs are semantic); same-format parse→serialize identity where the delegate guarantees it, semantic checks for conversions | **needs issue sign-off** |
| D12 | Batch: `Dir.glob(pattern).sort`; zero matches → 2; failures don't stop the batch; exit = highest code; JSON batch = array; `--output` single-source only; derived names, `--force` to overwrite; `--output -` = bytes-only stdout, rejects `--json`. ONE batch helper (built in 03, reused in 04) | settled |
| D13 | Pin against released delegate versions (pdfrb published 0.7.1, not repo head); Bundler resolution verified in 01/02 | settled |

## Exit codes (all commands)

| Code | Meaning |
|------|---------|
| 0 | success / conformance passed |
| 1 | conformance failed (issues found) |
| 2 | invocation error (bad args, file not found) |
| 3 | unsupported format or conversion |
| 4 | internal error / parser crash |

## Format × operation target matrix

| Format | Inspect | Conform | Convert to |
|--------|---------|---------|------------|
| png | 02 | 03 | — |
| svg | 02 | 03 | emf, eps, ps (04) |
| emf | 02 | 03 | svg (04) |
| wmf | 02 | 03 | — |
| eps / ps | 02 | 03 | svg (04) |
| pdf | 02 | 03 | — |

Only the D9-verified edges ship in v1 (EMF↔SVG, PS/EPS↔SVG,
SVG→EPS/PS); vectory offers more pairs, but unexposed edges stay out
until fixture evidence justifies them.

## Acceptance criteria → items

- [ ] `Claricle::Image.from_path(...).inspection` for PNG, SVG, EMF, PS/EPS, PDF → 02
- [ ] `Claricle.conform?` delegates for all five formats → 03
- [ ] `Claricle.convert` covers EMF↔SVG, PS/EPS↔SVG, SVG→EPS → 04
- [ ] CLI inspect/conform/convert, human + JSON → 02/03/04
- [ ] `claricle formats` support matrix → 02
- [ ] Handler registry documented; adding a format = one handler class → 01 (code), 04 (README)
- [ ] Exit codes match the matrix → 01 (runner), verified per command in 02/03/04
- [ ] Conformance specs on canonical fixtures; round-trip specs per D11 → 03/04
- [ ] `compress` stub removed → 01
- [ ] README.adoc rewritten → 04 (honesty pass in 01)

## Global constraints (every item)

- Ruby >= 3.2; CI matrix `['3.2', '3.3']`; RuboCop `TargetRubyVersion: 3.2`.
- Pure Ruby; `frozen_string_literal: true` in every file; RuboCop clean;
  `bundle exec rake` (spec + rubocop) green at every commit.
- lutaml-model for every model — no hand-rolled `to_h`/`from_h`.
- Real specs, no `double()`; fixtures from the delegates' canonical corpora.
- Commit subjects: one line, under 10 words.
- Every item passes the full Pre-Push Review Chain before push
  (thermo-nuclear → dependency-contract-check → execution-diff → Codex → copilot-review).
- Out of scope entirely: compression, rendering/rasterization, editing,
  `arroolio`, WMF conversion, `libpng`, gem release (maintainer-driven, post-04).
