# 04 — Convert: vectory routing, lossiness, README rewrite

Can start: after 03 (reuses its batch helper).

## Problem

No conversion exists. The issue requires EMF↔SVG, PS/EPS↔SVG, and
SVG→EPS with explicit lossiness — no silent lossy conversions — plus
the final README describing the real library.

## Design

- `Models::Conversion` (lutaml-model): `source_path`, `source_format`,
  `target_format`, `lossiness`, `output_path`, `content` (excluded from
  JSON serialization). `source_path` is populated whenever the image
  came from disk, and nil for a content-born one — `Image#convert`
  works in memory and has no path to report. It is required in every
  path that batching can reach, since that is where a result must be
  traceable to its input; never substitute a Tempfile path to fill it.
- Conversion routes through vectory's verified matrix only:
  `Vectory::Emf.from_content(...).to_svg` and siblings (D9). WMF is out
  of v1 entirely (D14) and never reaches a handler.
- **Lossiness** (D10): static per-edge enum — `:lossless` / `:lossy` /
  `:unknown`. **EMF→SVG starts `:lossy`**, because issue #1 names it as
  the direction that drops metafile semantics. SVG→EMF starts
  `:unknown`. Every other edge is `:unknown` and is upgraded only on
  edge-specific fixture evidence. The earlier plan had this backwards
  on the strength of emfsvg's "lossy `SvgMatcher`" — that phrase
  describes a 0.1px comparison tolerance in their spec suite, not a
  lossy direction, and it is no longer cited as evidence for anything.
  Lossy/unknown conversions warn on stderr and always carry the
  classification in the result. No consent-gate flag — the issue
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
  `--force`. `--force` authorises replacing an unrelated existing file,
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
  `conform` (D12): positional sources are literal paths, globbing needs
  `--pattern`. Batch runs via 03's helper, every file landing in a
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
- **Round-trip specs** (D11): same-format parse→serialize identity
  where the delegate guarantees it (EMF); semantic checks for
  cross-format conversions. Byte-identical cross-format round-trips are
  NOT asserted. Note that "dimension preservation" is not assertable
  until D15 settles units and coordinate space — the same SVG reports
  `3×1` through vectory and `96×48` as EPS, so an equality check would
  be testing a coincidence. Until then, name the specific property each
  semantic spec checks.
- Docs closure: README.adoc fully rewritten on top of 01's honesty
  baseline — real API + CLI, the format × operation matrix, exit codes,
  and the registry extension workflow. That workflow must describe what
  adding a format **actually** costs: if handlers don't yet declare
  their sniffer, capabilities, targets, extensions and lossiness, then
  it is a handler class plus a detector edit plus a require plus a
  registry entry plus a lossiness edge, and the README says so rather
  than repeating the one-class claim. Gemspec description/homepage
  refreshed (org moved ribose → claricle). `sig/` brought up to date.
  Drop `"convert"` from 01's stub-removal spec assertion (a real
  `convert` now exists).

## Do

Plumbing first again, then one edge family per commit.

1. `Models::Conversion` + lossiness edge table + specs.
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
5. Round-trip + semantic spec suite; upgrade lossiness edges only where
   edge-specific fixtures prove it.
6. `formats` full-matrix spec once the last edge lands.
7. README rewrite + gemspec metadata + RBS update + stub-spec update.

## Done when

- All acceptance-matrix conversions work via API and CLI with correct
  exit codes and lossiness warnings.
- Round-trip/semantic suite green; every `:lossless` edge is
  fixture-proven.
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
`lib/claricle/cli.rb`, `README.adoc`, `claricle.gemspec`, `sig/`,
`spec/claricle/conversion/*_spec.rb`, `spec/claricle/writer_spec.rb`,
`spec/claricle/cli_spec.rb`.
