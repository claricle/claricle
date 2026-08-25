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
