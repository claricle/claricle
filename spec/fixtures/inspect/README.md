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
