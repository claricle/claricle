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
fails — which is why the handler reads the declared header prefix
before attempting the full stream.
