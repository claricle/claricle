# Detector fixtures

Only the binary formats live here as files. PDF, EPS, PS and every SVG
case is an inline byte string in `spec/claricle/detector_spec.rb`, so
each case sits next to the assertion that explains it.

| File | Bytes | Signature | State |
|---|---|---|---|
| `valid.png` | 70 | `89504e47` | Complete 1×1 PNG. Every chunk CRC verifies and IDAT inflates |
| `valid.emf` | 364 | `01000000` + `" EMF"` at `0x28` | Header and 16 records parse. `nBytes` is 0 where it should be 364, and `nHandles` is 1 where it should be 4 |
| `std.wmf` | 46 | `0100 0900` | Header only. Declared size is 0 words against 46 actual bytes |
| `place.wmf` | 44 | `d7cdc69a` | Placeable header only. Checksum stored as `0x0000`, correct value `0x5711` |

## What is and is not wrong with these

`valid.png` is a genuinely valid file — nothing to qualify.

`valid.emf` is very nearly one. Measured 2026-08-20, it has **two**
defects:

- `nBytes` reports 0 rather than the file length of 364.
- `nHandles` reports 1, but object indexes 1-4 are used, and MS-EMF
  sizes the object table as `Handles + 1` because index zero is
  reserved — so the correct value is 4.

Its `nSize` of 88 and `nRecords` of 17 are both **correct**. `nSize`
measures the header record, not the file. `nRecords` counts 17 because
a raw walk finds 17 records ending exactly at byte 364;
`metafile.records` returns 16 only because `Emf.parse` stores the header
separately and excludes it.

The two WMF files are headers with no valid record data behind them.

The names are historical and describe the *signature*, not the file:
`valid.emf` is a valid EMF header, not a fully valid EMF.

That is sufficient here, because the metafile probe matches a signature
at a fixed offset and never parses a record. It is **not** sufficient for
`TODO.plan/02-inspect.md`, which reads real records — those metafiles
need repairing or replacing first, and verifying by parsing rather than
by sniffing. The `emf` gem ships no `.emf` or `.wmf` corpus of its own
and has no WMF parser at all, so that work cannot be done from this
gem's dependencies as they stand.

## Why both WMF variants

`Emf::Detector` reaches them through different branches: the placeable
header matches on the first uint32, the standard one only after the EMF
check fails. Dropping either leaves a branch uncovered.

## Provenance

These are the fixtures the delegate contracts in
`TODO.plan/00-overview.md` were measured against — the
`Emf.detect_format` truth table, and the 44-byte header floor that
`spec/claricle/detector_spec.rb` pins.
