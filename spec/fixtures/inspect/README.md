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
| `zero_device_both.emf` | zeros on BOTH axes. The one-axis fixtures trigger the zero check but cannot detect it — take it away and the cross product rejects them anyway, 100 x 13 against 50 x 0 and 100 x 0 against 50 x 26. With both zero it reads 0 == 0, calls the resolution uniform, and divides by zero: the dpi comes out `Infinity`, which `to_json` refuses |
| `emf_plus.emf` | a standards-derived carrier: header comment `nSize=44`/`cbData=32`, EOF comment `nSize=28`/`cbData=16`, 436 bytes, 19 records, 40-byte unpadded payload |

Two groups have no fixture on purpose, and live in the spec instead:

- **Negative device dimensions, and zero device *pixels*.** The zeroed
  `device_mm` cases above are fixtures; these are not. MS-EMF's SIZEL
  is signed, so they are one-field edits to `valid.emf` at offsets 72
  (`device_pixels`) and 80 (`device_mm`) — a binary file per sign
  combination would say less than the pair of numbers does. The spec
  pins both offsets against the baseline first, so an edit cannot land
  somewhere else and pass for the wrong reason.
- **Framing boundaries.** The fixtures below all pin a guard from the
  side that REFUSES. The other edge — the largest thing a rule must
  still accept, the smallest overrun it must still reject — usually
  turns on a single byte, and a file would bury that byte. The spec
  builds those streams from the fixed 88-byte header, each one at the
  widest value its rule must still handle: an 8-byte `EMR_SAVEDC`, a
  carrier ending on the last byte of the file, a carrier followed by
  seven bytes of nothing, a 24-byte `EMR_EOF` in front of a carrier, a
  record declaring 20 with 19 left, a comment with room for four
  declaring five, and a comment declaring three bytes in front of an
  `EMF+` marker. The header's own rules get the same treatment: the
  baseline's first 88 bytes standing alone as a whole file, and a
  seven-byte file with no room for a size field.

What the DELEGATE does with each of these, and what the handler
reports. The two columns are independent: measured, the handler calls
`Emf.parse` zero times for all six of the failed ones, because
`declared_size` refuses them first. The `Raises` column is what happens
when the delegate is handed the file directly, and it is there to show
that six files are broken in three different ways rather than one way
six times.

| Fixture | Delegate raises | Status |
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
| `described_92.emf`, `described_96.emf` | standards-valid headers whose optional **null-terminated** UTF-16LE description puts `nSize` at 92 and 96. The terminator is part of the declared character count, as MS-EMF requires. An `nSize` above 88 makes the delegate read the Win95 optional header fields — `cbPixelFormat`, `offPixelFormat`, `bOpenGL` — so it wants a full 100 bytes and raises `EOFError` on both, on the declared prefix *and* on the full stream. Measured over aligned sizes 88 to 356, exactly three fail: 92, 96 and 104. The handler normalises `nSize` to 88 and parses the fixed header instead |
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
| `short_comment.emf` | a comment record of 8 bytes standing last in the stream. The outer framing is clean, so only the comment minimum stops it — and it has to be last, because anywhere else the four bytes after the header read as a `cbData` that fails the bound anyway. Here there are none, so `unpack1` gives nil and the bound raises `NoMethodError`. Its two earlier carriers must still be reported |
| `record_size_10.emf` | a record size of 10 — even, but not four-byte aligned — with a carrier at 98, the offset it advances to. `misaligned_record.emf` uses 13, which an alignment weakened to `% 2` still rejects, so that one alone leaves the weakening alive |
| `record_size_4.emf` | a record size of 4, below the eight a record header needs. The carrier cannot sit at 88 + 4 — that is the record's own size field, so the type read there is 4 — so that field frames a 28-byte record and the carrier sits at 120. `zero_record.emf` only covers size zero, which a minimum weakened to a zero-only check still rejects |
| `declared_100_have_99.emf` | a header declaring `nSize` 100 in a 99-byte file: aligned and above the minimum, so it isolates the in-bounds check from the two guards beside it |


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
| `prefixed.ps` | a real `%!PS` present, one byte past offset zero |
| `pdf_header.ps` | `%!PDF`, which shares three bytes with the signature and carries no `%!PS` at all. A shorter prefix compare reads it as PostScript |
| `leading_space.ps`, `leading_newline.ps` | a real `%!PS` behind whitespace. These are what makes the anchor load-bearing: `prefixed.ps` alone still leaves `lstrip.start_with?` passing |
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
| `deep_nesting.ps` | 3000 levels of nesting, which raises `SystemStackError` — **not a `StandardError`**, so no list of the delegate's own error classes would have caught it |
| `no_end_comments.ps` | a header with no `%%EndComments`, so the "first non-header-comment line" rule is the only thing ending it. Several fixtures reach that rule; this is the one where the header it has to keep is a real one, and where the body past the boundary raises if it is read |
| `begin_data.ps` | `%%BeginData` declaring the lines after it opaque, with a `%%BoundingBox` among them. A section is never header, so those are bytes that happen to look like a comment — they were published as the page size |
| `query_section.ps` | a `%!PS-Adobe-3.0 Query` file opening `%%?BeginVMStatus` straight after its header comments, with no `%%EndComments` anywhere. `%%?` is DSC's query prefix, so a rule matching only `%%Begin` read the query body as header |
| `eof_comment.ps` | a `%%BoundingBox` behind `%%EOF`. The document has ended, so that box is not the file's — it was published as the page size |
| `end_prolog.ps` | a real header box and title, then body ones behind `%%EndProlog`. DSC allows that comment alone for an empty prolog, so it is the one `%%End` form reachable while the header is still being read — and reading past it dropped both real values for disagreeing with the body's |
| `include_resource.ps` | `%%IncludeResource: font Helvetica` ahead of a body box. An Include comment cannot appear in a header, and reading past one published that box as the page size |
| `page_bogus.ps` | `%%Page-Bogus`, an ordinary comment DSC allows in a header. `\b` treats the `-` as a word boundary, so the boundary rule ended the header there and lost the box and title behind it — `%%EndComments-Bogus` is the same mistake on the other sentinel |
| `page_comment.ps`, `trailer_comment.ps` | a real header box, then a body one behind `%%Page:` or `%%Trailer`. The cost runs the other way here: reading past either boundary made the body's `10x20` the delegate's last-wins value, which disagreed with the header's first declaration and took the real box down with it |
| `begin_document.ps` | a `%%BeginDocument` child in a file with no outer `%%EndComments`. The same rule, costing a real box instead of inventing one: the scan ran into the child's header, the delegate's last-wins value became the CHILD's `10x20`, and the outer `200x100` was dropped for disagreeing with it. `nested_document.ps` cannot reach this — its `%%EndComments` stops the scan earlier for another reason |
| `crlf_header.ps` | CRLF line boundaries, with a vendor comment and a second box behind the sentinel. Splitting on LF alone leaves a `\r` on the end of every line, so a sentinel that does not allow for it reads those two and the header's own box is refused for disagreeing with them. Ending the file at `showpage` instead makes the non-comment rule give the same answer either way |
| `mixed_endings.ps` | a CR-delimited `10x20` box followed by an LF-delimited `100x200` one. Ruby's `^` starts a line only after LF, so it walked past the first declaration onto the second — where it agreed with the delegate's last-wins value and published a box that was not the file's first |
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
| `control_byte_comment.ps` | a NUL byte straight after the `%`. DSC requires that character to be **printable**, so this ends the header — and a body box sits behind it. `[^ \t\r\n]` admits NUL, ESC, VT, FF, DEL and high bytes, so the vendor-comment rule alone still reads that box |
| `endcomments_bogus.ps` | `%%EndComments-Bogus` is an ordinary comment, not the sentinel. Matching it as the terminator silently suppressed every header comment after it |
| `duplicate_title.ps` | a repeated `%%Title`. DSC's first-occurrence rule covers **every** header comment, not just boxes, and 0.2.0 is last-wins throughout |
| `hex_first_box.ps` | `%%BoundingBox: 0x10 0 116 50` followed by `%%BoundingBox: 16 0 116 50`. This is the fixture that **disproved my own claim** that the strict DSC number grammar was ceremony: `0x10` is not a DSC real, but Ruby's `Float` reads it as `16.0`, which agrees with the delegate's value from the *second* declaration. A loosened grammar publishes a box built from a hex literal the file never legally declared |

### PostScript, fourth round — grammars, continuations and ordering

| Fixture | What it discriminates |
|---|---|
| `real_coarse_box.ps`, `exponent_coarse.ps` | `%%BoundingBox` takes four **integers**; only `%%HiResBoundingBox` takes reals. Applying real syntax to both published `0.5 0 100.5 50` and `1e2 0 2e2 50` as coarse boxes |
| `continued_title.ps` | a `%%Title` continued by `%%+`. 0.2.0 leaves the first fragment in the field and puts the rest in `custom`, so publishing the field reports a **truncated** value as a complete one |
| `continued_box.ps` | the same continuation on a `%%BoundingBox`. DSC allows `%%+` after ANY structuring comment, so a guard written for the scalar fields alone still publishes a truncated box |
| `reversed_box.ps` | `100 50 0 0`. DSC orders the box lower-left then upper-right, so this is malformed rather than merely flipped — unlike PDF, which permits either diagonal and is normalised with `abs`. It published `-100.0 x -50.0` |
| `padded_level.ps` | `%%LanguageLevel: 02`, a valid unsigned integer that 0.2.0 reads as `2`. A textual first-declaration comparison rejected it, because `"02" != "2"` |
| `underscored_level.ps` | `%%LanguageLevel: 2_0` followed by `20`. `Integer("2_0", 10)` is 20, so Ruby's own conversion agreed with the value the delegate read from the SECOND declaration. Its box comes through untouched, so the level alone is what the fixture pins |
| `nul_padded_box.ps` | a `%%BoundingBox` line ending in a NUL. `String#strip` also removes NUL, VT and FF, none of which DSC admits, so the anchored grammar saw a clean declaration |
| `parenthesized_title.ps` | `%%Title: (Draft)`, which 0.2.0 hands back with the parentheses. Pinned as a delegate gap: decoding DSC's text syntax here would report something the parser never saw |

Note that `overflow_endpoint.ps` and `overflow_width.ps` declare
**HiRes** boxes. They test finiteness, and a coarse box carrying
`1e9999` or `-1e308` is refused on grammar alone before finiteness is
ever reached.
