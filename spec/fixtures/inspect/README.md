# Inspect fixtures

Built, not sniffed. The detector fixtures next door are valid
*signatures*; these have to survive being parsed.

## EMF

`valid.emf` is `detector/valid.emf` with two fields repaired, both
verified by an independent raw walk rather than by the parser — which
checks none of them:

| Field | Was | Is | Why |
|---|---|---|---|
| `nBytes` | 0 | 364 | the file's real length |
| `nHandles` | 1 | 4 | object indexes 1-4 are used, and MS-EMF sizes the table at `Handles + 1` |
| `nRecords` | 17 | 17 | **correct already.** A raw walk finds 17 records ending at byte 364; `metafile.records` returns 16 only because it excludes the header record |

The variants exist to adjudicate designs a single fixture cannot:

| Fixture | What it discriminates |
|---|---|
| `distinct_device.emf` | bounds 120x60 against device 300x200, non-zero origin — a handler reading the reference device instead of the picture bounds gives the wrong answer |
| `second_device.emf` | 254.0 dpi against the baseline's 97.69 — a hardcoded constant fails |
| `unequal_device.emf` | unequal *ratios*, not merely unequal axes: the baseline is 100x50 over 26x13, whose axes differ while both ratios are 97.69 |
| `zero_device_x.emf`, `zero_device_y.emf` | a zero on each axis separately |
| `emf_plus.emf` | a standards-derived carrier: header comment `nSize=44`/`cbData=32`, EOF comment `nSize=28`/`cbData=16`, 436 bytes, 19 records, 40-byte unpadded payload |

Failure routes, each reaching a different arm:

| Fixture | Raises | Status |
|---|---|---|
| `garbage.emf`, `empty.emf` | `Emf::FormatError` | failed |
| `truncated_44.emf`, `truncated_87.emf` | `Emf::FormatError` | failed |
| `nsize_44.emf` | `EOFError` | failed |
| `nsize_87.emf` | `IOError` | failed |
| `truncated_99.emf` | none — parses, `ok? == false` | **ok** |
| `truncated_117.emf` | `IOError` | **ok** |

The last two are the point. `truncated_117` and `nsize_87` raise the
same class with the same message, and one must be ok while the other
fails — which is why the handler validates the declared header size
before parsing.

Headers carrying a description, which emf 0.1.0 cannot read:

| Fixture | Purpose |
|---|---|
| `described_92.emf`, `described_96.emf` | standards-valid headers whose optional **null-terminated** UTF-16LE description puts `nSize` at 92 and 96. The terminator is part of the declared character count, as MS-EMF requires. The delegate reads anything above 88 as the extension records, so it raises `EOFError` on both — on the declared prefix *and* on the full stream. The handler normalises `nSize` to 88 and parses the fixed header instead |
| `header_100.emf` | declares 100, a size the delegate does accept. Paired with `valid.emf` (88) it pins that pass one always receives exactly 88 bytes, whatever the file declares |

The EMF+ probe's framing rules. Each of these is built so the *wrong*
behaviour is observable — corrupting a byte is not enough, because
dropping a guard usually still ends in "no EMF+", which is the same
answer the guard produces. Every one survived its matching mutation
before it existed:

| Fixture | What it discriminates |
|---|---|
| `bad_comment.emf` | a comment declaring `cbData=4` in a 12-byte record. The outer framing is perfect — aligned, in bounds, EOF intact — so an outer-framing check alone passes it. `Emf.parse` raises `NoMethodError` here |
| `overrun_comment.emf` | `cbData` reaching past the record into the next one, where the bytes it would read begin with `EMF+`. Unbounded, the probe reports 4 bytes the file never declared |
| `misaligned_record.emf` | a record size of 13, with a well-formed EMF+ carrier at the misaligned offset. Without the alignment rule the walk lands on it and reports EMF+ |
| `zero_record.emf` | a record declaring size zero. Without the minimum-size rule the walk never advances, so this fails by hanging rather than by answering wrongly |
| `described_emf_plus.emf` | an EMF+ carrier immediately after a 92-byte described header. A walk starting at a fixed 88 reads the description as a record and loses the carrier |
| `after_eof.emf` | an EMF+ carrier placed after `EMR_EOF`, which is not part of the stream |
| `short_eof.emf` | a type-14 record of only 12 bytes standing before a real EMF+ carrier. `EMR_EOF` is Type, Size, nPalEntries, offPalEntries and SizeLast, so 20 bytes is its minimum — a shorter one is not an end of stream, and the delegate records it as `Raw` and keeps going. Treating any type-14 as EOF loses the carrier |
| `short_eof_16.emf` | the same, at `nSize` 16 — the nearest aligned value below 20, so it is the size that separates the correct minimum from a plausible wrong one. With a 16-byte minimum `short_eof.emf` still passes and this one does not |
| `broken_suffix.emf` | two intact EMF+ carriers followed by a final `EMR_EOF` declaring `nSize` 0. The walk stops at the break but keeps what it already validated: discarding the total reported no EMF+ for a file the delegate reads as carrying 40 bytes |
| `overrun_then_carrier.emf` | a first carrier whose `cbData` overruns its own record and whose marker is broken, followed by an INTACT second carrier. An overrun `cbData` is not broken framing — MS-EMF keeps the whole-record `Size` and the inner `DataSize` separate, and the outer size was already validated — so the walk must contribute zero and carry on. Stopping reported no EMF+ where the delegate reads 12 bytes |
| `comment_shaped_record.emf` | a type-38 record whose bytes read as a comment look exactly like a carrier: `cbData` 16 at +8 and `EMF+` at +12. Every other fixture's non-comment records fail the `cbData` bound by accident, so this is the only one that catches a walk skipping the record-type check |
| `padded_comment.emf` | a carrier with alignment padding: `nSize=20` leaves 8 bytes of room while `cbData` declares 5, so only 1 byte is payload after the signature. Both carriers in `emf_plus.emf` are padding-free, so `size - 16` gives the same answer there and the mutation survives. **The delegate reports 4 for this file** — it counts the padding, which MS-EMF excludes |


## PostScript

`inspect` for `:eps` and `:ps`, both handled by one class.

| Fixture | Purpose |
|---|---|
| `basic.eps` | the baseline: a genuine EPSF header, an integer box, and every comment the delegate populates |
| `plain.ps` | a genuine NON-EPSF program. Relabelling the EPS bytes would not catch extraction wrongly gated on the EPSF field |
| `offset.eps` | a non-zero origin, so width is proven to be a subtraction rather than `urx` |
| `hires.eps` | both boxes declared, so the hires preference is provable |
| `hires_offset.eps` | a non-zero-origin hires box, so the hires path subtracts too rather than inheriting that from the integer path |
| `hires_only.eps` | only the hires box declared |
| `no_box.ps`, `bare.ps` | no box at all — `"ok"` with nil dimensions, since a program need not declare one |
| `garbage.ps` | plain prose. **`Postscript.parse` succeeds on it**, so this is the fixture that fails a handler wired to "the delegate did not raise" |
| `empty.ps` | an empty file |
| `prefixed.ps`, `pdf_header.ps` | a signature present but not at offset zero. These two alone still leave `lstrip.start_with?` passing |
| `leading_space.ps`, `leading_newline.ps` | which is why these exist — they are what makes the anchor load-bearing |
| `unmatched_brace.ps` | structurally odd and **accepted** by the delegate. Reporting it failed would make `inspect` quietly mean `conform` (D22) |
| `lex_error.ps` | an unterminated string — `Postscript::LexError`. The text after `(` matters: a bare `(` parses cleanly |
| `syntax_error.ps` | an unmatched opening brace — `Postscript::SyntaxError`, which is why the allowlist is `ParseError` and not `LexError` alone |
| `overflow_endpoint.ps` | an endpoint that overflows outright |
| `overflow_width.ps` | every endpoint finite while the computed width is `Infinity`. An endpoint check misses this, and the array is still JSON-safe — so the dimension and the `meta` entry are decided separately |
| `overflow_hires_axis.ps` | a hires box overflowing on ONE axis beside a usable coarse box. The whole coarse pair is reported: a per-axis hybrid would give `10.0 x 50.0`, a rectangle nobody declared |
| `overflow_hires_only.ps` | the same overflow with no coarse box, so the fallback can be told from "hires is ignored" |
| `two_arg_pages.ps` | `%%Pages: 3 1`, the only form that populates `page_count` and `pages`. Both stay out of `meta` |
| `one_arg_pages.ps` | `%%Pages: 3` leaves both nil and lands in `custom` instead — that asymmetry is why the fields are omitted deliberately rather than incidentally |
| `bad_title.eps` | a `%%Title` whose bytes are not valid UTF-8, beside a `%%Creator` that is. Driven path-born as well as content-born, since `File.binread` gives ASCII-8BIT where `valid_encoding?` is true for any bytes |
| `utf8_title.eps` | a `%%Title` that IS valid UTF-8 but arrives tagged ASCII-8BIT. It must be carried, and carried tagged UTF-8 — json 2.21 serializes a BINARY-tagged UTF-8 string while warning it will raise in json 3.0 |
| `cr_only.ps` | CR-only line endings, whose DSC comments 0.2.0 does not read. Pinned as a known delegate gap rather than worked around: pre-normalising the bytes would make `inspect` report something the parser never saw |

### PostScript, second round

Fixtures for the DSC header boundary and the boxes the delegate
fabricates. Each exists because the wrong behaviour is otherwise
invisible.

| Fixture | What it discriminates |
|---|---|
| `nested_document.ps` | an outer `200x100 / Outer` containing a `%%BeginDocument` child declaring `10x20 / Inner`. 0.2.0 applies every DSC token globally and lets later values win, so parsing the whole file reports the CHILD's box and title |
| `float_domain.ps` | `1e9999 idiv` in the body, which raises `FloatDomainError` out of the delegate |
| `deep_nesting.ps` | 3000 levels of nesting, which raises `SystemStackError` — **not a `StandardError`**, so no allowlist would have caught it |
| `no_end_comments.ps` | a header with no `%%EndComments`, so the "first non-comment line" rule is the only thing ending it. Its body raises if reached; every other fixture has `%%EndComments`, so nothing else exercises that rule |
| `crlf_header.ps` | CRLF line boundaries, which DSC allows and Ruby's line splitting does not give for free |
| `fabricated_hires.ps` | `%%HiResBoundingBox: e e e e` beside a valid coarse box. The grammar accepts the lexemes and `to_f` turns them into four zeroes, which then beat the real box — reporting a **0x0 page as a fact** |
| `fabricated_coarse.ps` | the same fabrication with nothing to fall back to, so the answer is nil rather than zeroes |
| `duplicate_box.ps` | two `%%BoundingBox` lines. DSC gives precedence to the FIRST; 0.2.0 keeps the last. The box is refused because publishing a value that came from a different declaration than the one validated is its own kind of wrong |
| `atend_box.ps` | `%%BoundingBox: (atend)`, which defers to the trailer. Valid, so it is unresolved rather than malformed |
| `atend_with_hires.ps` | the same, beside a concrete hires box that is used instead |

### PostScript, third round — the DSC header's real boundary

| Fixture | What it discriminates |
|---|---|
| `body_comment.ps`, `lone_percent.ps`, `percent_tab.ps` | DSC makes `% `, `%\t` and a lone `%` implicit **terminators** — they are body comments, not header ones. Treating every `%` line as header let a body box leak into the inspection |
| `vendor_comment.ps` | `%GBDNodeName:` — `%X` continues the header for any printable non-whitespace `X`, and this form appears in Adobe's own DSC examples. The over-correction of allowing only `%%` and `%!` dropped the entire header at the first vendor comment |
| `endcomments_bogus.ps` | `%%EndComments-Bogus` is an ordinary comment, not the sentinel. Matching it as the terminator silently suppressed every header comment after it |
| `duplicate_title.ps` | a repeated `%%Title`. DSC's first-occurrence rule covers **every** header comment, not just boxes, and 0.2.0 is last-wins throughout |
| `hex_first_box.ps` | `%%BoundingBox: 0x10 0 116 50` followed by `%%BoundingBox: 16 0 116 50`. This is the fixture that **disproved my own claim** that the strict DSC number grammar was ceremony: `0x10` is not a DSC real, but Ruby's `Float` reads it as `16.0`, which agrees with the delegate's value from the *second* declaration. A loosened grammar publishes a box built from a hex literal the file never legally declared |

### PostScript, fourth round — grammars, continuations and ordering

| Fixture | What it discriminates |
|---|---|
| `real_coarse_box.ps`, `exponent_coarse.ps` | `%%BoundingBox` takes four **integers**; only `%%HiResBoundingBox` takes reals. Applying real syntax to both published `0.5 0 100.5 50` and `1e2 0 2e2 50` as coarse boxes |
| `continued_title.ps` | a `%%Title` continued by `%%+`. 0.2.0 leaves the first fragment in the field and puts the rest in `custom`, so publishing the field reports a **truncated** value as a complete one |
| `reversed_box.ps` | `100 50 0 0`. DSC orders the box lower-left then upper-right, so this is malformed rather than merely flipped — unlike PDF, which permits either diagonal and is normalised with `abs`. It published `-100.0 x -50.0` |
| `padded_level.ps` | `%%LanguageLevel: 02`, a valid unsigned integer that 0.2.0 reads as `2`. A textual first-declaration comparison rejected it, because `"02" != "2"` |

Note that `overflow_endpoint.ps` and `overflow_width.ps` declare
**HiRes** boxes. They test finiteness, and a coarse box carrying
`1e9999` or `-1e308` is refused on grammar alone before finiteness is
ever reached.

