# frozen_string_literal: true

require "png_conform"
require "zlib"

# `AncillaryBoundsGuard` (a private nested class inside `Handlers::Png`)
# runs before png_conform's own iCCP/zTXt/iTXt validators ever see the
# file -- each calls `Zlib::Inflate.inflate` on attacker-controlled bytes
# with no output bound (measured against the installed 0.1.4 gem). A
# 1,043,730-byte PNG built the same way as `iccp_chunk` below, carrying a
# payload that inflates to 1 GiB, measured driving `conformance_report` to
# a 2.19 GB peak RSS before this guard existed.
#
# Kept apart from `png_spec.rb` -- a different concern (a resource-safety
# boundary, not metadata reading or conformance mapping) with its own
# fixture-building helpers, and `png_spec.rb` was already substantial
# before this existed.
RSpec.describe "Claricle PNG handler's decompression bound" do
  # A complete signature and IHDR, then whatever bytes the caller wants the
  # file to carry. Copied from `png_spec.rb` rather than shared: this repo
  # has no `spec/support/` convention yet, and these two small builders are
  # the only thing the two files have in common.
  def png_with_trailing(tail)
    signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
    header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")

    signature + chunk("IHDR", header) + tail
  end

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  # Reached rather than duplicated as a literal, so these examples stay
  # correct if the ceiling ever changes.
  def max_decompressed_bytes
    Claricle.const_get(:Handlers).const_get(:Png).const_get(:MAX_DECOMPRESSED_BYTES)
  end

  # A small, deterministic compressed payload for any decompressed size --
  # the same construction the real bomb used, just parameterised.
  def deflated(decompressed_bytes)
    Zlib::Deflate.deflate("\x00" * decompressed_bytes, Zlib::BEST_COMPRESSION)
  end

  def iccp_chunk(compressed, name: "profile")
    chunk("iCCP", "#{name}\x00\x00#{compressed}")
  end

  def ztxt_chunk(compressed, keyword: "key")
    chunk("zTXt", "#{keyword}\x00\x00#{compressed}")
  end

  # `compressed: false` yields the PNG spec's uncompressed-iTXt shape --
  # `text` is carried verbatim, not run through `deflated` by this helper.
  def itxt_chunk(text, keyword: "key", compressed: true)
    chunk("iTXt", "#{keyword}\x00#{(compressed ? 1 : 0).chr}\x00\x00\x00#{text}")
  end

  # A chunk header that LIES about its own length -- more than the bytes
  # that actually follow it in the file, simulating a file truncated
  # mid-chunk. `chunk` above always keeps the two consistent, so this is
  # its own builder.
  def chunk_with_declared_length(type, declared_length, actual_payload)
    [declared_length].pack("N") + type + actual_payload
  end

  def conform_image(bytes)
    Claricle::Image.from_content(bytes, format: :png)
  end

  it "flags an iCCP chunk whose payload decompresses past the ceiling, without ever calling the delegate" do
    expect(PngConform::Services::ValidationService).not_to receive(:new)
    bomb = iccp_chunk(deflated(max_decompressed_bytes + 1))
    report = conform_image(png_with_trailing(bomb + chunk("IEND", ""))).conformance_report

    expect(report.valid).to eq(:no)
    expect(report.issues).to contain_exactly(
      have_attributes(
        severity: "error", code: "png.decompression_bound_exceeded",
        message: a_string_including("iCCP"),
        location: have_attributes(chunk: "iCCP", byte_offset: 33)
      )
    )
  end

  # Same shape, a different chunk type and field layout -- each of the
  # three watched types gets its own example because each has a different
  # byte layout to get right, not because the assertion differs.
  it "flags a zTXt chunk the same way" do
    expect(PngConform::Services::ValidationService).not_to receive(:new)
    bomb = ztxt_chunk(deflated(max_decompressed_bytes + 1))
    report = conform_image(png_with_trailing(bomb + chunk("IEND", ""))).conformance_report

    expect(report.issues).to contain_exactly(
      have_attributes(code: "png.decompression_bound_exceeded", location: have_attributes(chunk: "zTXt"))
    )
  end

  it "flags a compressed iTXt chunk the same way" do
    expect(PngConform::Services::ValidationService).not_to receive(:new)
    bomb = itxt_chunk(deflated(max_decompressed_bytes + 1))
    report = conform_image(png_with_trailing(bomb + chunk("IEND", ""))).conformance_report

    expect(report.issues).to contain_exactly(
      have_attributes(code: "png.decompression_bound_exceeded", location: have_attributes(chunk: "iTXt"))
    )
  end

  # Not "a large uncompressed field goes unflagged" -- that would pass even
  # if the guard ignored the compression flag entirely and simply failed to
  # decompress plain text. The payload here is the bomb's own bytes, a
  # valid oversized deflate stream, carried with the compression flag set
  # to 0. Only checking that flag before attempting decompression --
  # exactly like png_conform's own `compressed?` gate -- keeps this from
  # being flagged.
  it "does not decompress an uncompressed iTXt chunk, even one whose raw bytes are an oversized deflate stream" do
    bomb_shaped_bytes = deflated(max_decompressed_bytes + 1)
    chunk_bytes = itxt_chunk(bomb_shaped_bytes, compressed: false)
    report = conform_image(png_with_trailing(chunk_bytes + chunk("IEND", ""))).conformance_report

    expect(report.issues).not_to include(have_attributes(code: "png.decompression_bound_exceeded"))
  end

  # The exact boundary, not just "small" vs "huge": examples built only
  # from 40 MiB/~67 MiB fixtures cannot tell a `>` ceiling comparison from
  # a `>=` one -- both classify 40 MiB as safe and ~67 MiB as a bomb. These
  # two are what a boundary mutation on `MAX_DECOMPRESSED_BYTES` actually
  # goes red on.
  it "passes a payload that decompresses to exactly the ceiling" do
    bytes = png_with_trailing(iccp_chunk(deflated(max_decompressed_bytes)) + chunk("IEND", ""))

    expect(conform_image(bytes).conformance_report.issues)
      .not_to include(have_attributes(code: "png.decompression_bound_exceeded"))
  end

  it "flags a payload that decompresses to one byte past the ceiling" do
    bytes = png_with_trailing(iccp_chunk(deflated(max_decompressed_bytes + 1)) + chunk("IEND", ""))

    expect(conform_image(bytes).conformance_report.issues)
      .to include(have_attributes(code: "png.decompression_bound_exceeded"))
  end

  # The ceiling must apply across the whole file, not reset per chunk:
  # several chunks that are each individually safe can still sum past it
  # -- measured against the real delegate,
  # eight 32 MiB zTXt chunks (each well under the ceiling alone) drove a
  # 654 MB peak RSS from a 261,196-byte file, because png_conform's own
  # `zTXt`/`iTXt` validators retain every chunk's decompressed text in one
  # growing array across the whole file, not one at a time.
  #
  # Two chunks, each just over HALF the ceiling: the earlier per-chunk-only
  # check would have passed both (`half < MAX_DECOMPRESSED_BYTES` is true
  # for each on its own), and only a running total catches their sum. The
  # single-chunk boundary examples above already cover one chunk alone
  # crossing the ceiling; this is what only a cumulative total can catch.
  it "flags a file whose watched chunks individually stay under the ceiling but sum past it" do
    half = (max_decompressed_bytes / 2) + 1
    first_chunk = ztxt_chunk(deflated(half), keyword: "a")
    second_chunk = ztxt_chunk(deflated(half), keyword: "b")
    bytes = png_with_trailing(first_chunk + second_chunk + chunk("IEND", ""))

    report = conform_image(bytes).conformance_report

    expect(report.valid).to eq(:no)
    # `byte_offset`, not just the chunk type: both chunks are zTXt, so
    # only pinning the offset proves the SECOND chunk (where the running
    # total actually crosses the ceiling) was flagged, rather than the
    # first -- 33 is the same fixed offset every single-chunk example
    # above pins (signature + IHDR chunk), and `first_chunk.bytesize`
    # is how far past it the second chunk's own header starts.
    expect(report.issues).to contain_exactly(
      have_attributes(
        code: "png.decompression_bound_exceeded",
        location: have_attributes(chunk: "zTXt", byte_offset: 33 + first_chunk.bytesize)
      )
    )
  end

  # A zlib stream missing only its trailing checksum decompresses fully
  # and raises nothing under the incremental block form this guard uses
  # (measured: a 40 MiB payload with its last checksum byte cut off still
  # yields the full 40 MiB and `Zlib::Inflate::finished?` reports false) --
  # where `Zlib::Inflate.inflate`, the MODULE method the real validators
  # call, raises `Zlib::BufError` on the identical bytes. Left unguarded,
  # that chunk's bytes would join the running total for a chunk the
  # delegate itself rejects and never retains, wrongly flagging a
  # perfectly safe second chunk. Two chunks: the first is 40 MiB short its
  # last checksum byte (must contribute nothing), the second a legitimate,
  # untouched 32 MiB chunk that alone is nowhere near the ceiling.
  it "does not let a chunk missing its trailing checksum contribute to the running total" do
    truncated = ztxt_chunk(deflated(40 * 1024 * 1024)[0...-1], keyword: "broken")
    safe = ztxt_chunk(deflated(32 * 1024 * 1024), keyword: "safe")
    bytes = png_with_trailing(truncated + safe + chunk("IEND", ""))

    report = conform_image(bytes).conformance_report

    expect(report.issues.map(&:code)).not_to include("png.decompression_bound_exceeded")
  end

  # A chunk that DECOMPRESSES cleanly but that the real validator still
  # rejects (bad CRC, a compression method other than 0, or -- iTXt only
  # -- non-UTF-8 decompressed text) must not contribute either, for the
  # same reason a checksum-truncated one must not: png_conform's own
  # validators check these FIRST (`check_crc` before anything else in all
  # three, `check_compression_method`/`check_compression_flags` before
  # decompressing, iTXt's `check_decompression` rejecting invalid UTF-8
  # before `store_text_info` ever runs) and never retain a rejected
  # chunk's bytes. Concrete reproduction: 40 MiB of `"\xFF"` behind a
  # compressed iTXt chunk (invalid UTF-8 once decompressed) wrongly
  # flagged an entirely unrelated, legitimate 32 MiB zTXt chunk alongside it.
  #
  # Three causes, one shared shape (a large "rejected" chunk paired with a
  # small, untouched, legitimate one) -- each its own example because each
  # exercises a different one of the three new checks.
  def chunk_with_bad_crc(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data) ^ 1].pack("N")
  end

  it "does not let a chunk with a bad CRC contribute to the running total" do
    bad_crc = chunk_with_bad_crc("zTXt", "broken\x00\x00#{deflated(40 * 1024 * 1024)}")
    safe = ztxt_chunk(deflated(32 * 1024 * 1024), keyword: "safe")
    bytes = png_with_trailing(bad_crc + safe + chunk("IEND", ""))

    report = conform_image(bytes).conformance_report

    expect(report.issues.map(&:code)).not_to include("png.decompression_bound_exceeded")
  end

  it "does not let a chunk declaring a non-deflate compression method contribute to the running total" do
    bad_method = chunk("zTXt", "broken\x00\x01#{deflated(40 * 1024 * 1024)}")
    safe = ztxt_chunk(deflated(32 * 1024 * 1024), keyword: "safe")
    bytes = png_with_trailing(bad_method + safe + chunk("IEND", ""))

    report = conform_image(bytes).conformance_report

    expect(report.issues.map(&:code)).not_to include("png.decompression_bound_exceeded")
  end

  it "does not let an iTXt chunk with invalid UTF-8 once decompressed contribute to the running total" do
    not_utf8 = Zlib::Deflate.deflate("\xFF" * (40 * 1024 * 1024), Zlib::BEST_COMPRESSION)
    invalid_utf8 = itxt_chunk(not_utf8, keyword: "broken")
    safe = ztxt_chunk(deflated(32 * 1024 * 1024), keyword: "safe")
    bytes = png_with_trailing(invalid_utf8 + safe + chunk("IEND", ""))

    report = conform_image(bytes).conformance_report

    expect(report.issues.map(&:code)).not_to include("png.decompression_bound_exceeded")
  end

  # The proof this bound does not refuse a legitimate large profile:
  # structurally valid (128-byte header, "acsp" at the ICC signature
  # offset png_conform itself checks), decompresses to 40 MiB -- 24 MiB
  # under the ceiling -- and is highly compressible so the PNG carrying it
  # stays small. Reaches the REAL delegate (no stub), and its own report
  # is what is asserted, not merely "the guard let it through".
  it "does not refuse a large but legitimate ICC profile, and still reports through the real delegate" do
    profile = ("\x00" * (40 * 1024 * 1024)).b
    profile[36, 4] = "acsp"
    compressed = Zlib::Deflate.deflate(profile, Zlib::BEST_COMPRESSION)
    idat = chunk("IDAT", Zlib::Deflate.deflate("\x00" * 3))
    bytes = png_with_trailing(iccp_chunk(compressed, name: "Large Profile") + idat + chunk("IEND", ""))

    report = conform_image(bytes).conformance_report

    expect(report.issues).not_to include(have_attributes(code: "png.decompression_bound_exceeded"))
    expect(report.issues).to include(have_attributes(severity: "info", message: a_string_including("iCCP:")))
  end

  # Genuinely corrupt zlib data answers "not a bomb" and is left for the
  # delegate's own "decompression failed" error -- the guard must not take
  # over reporting a different problem for input that was never actually a
  # bomb.
  it "leaves undecodable garbage for the delegate's own decompression-failed error" do
    bytes = png_with_trailing(iccp_chunk("not valid zlib data at all") + chunk("IEND", ""))
    report = conform_image(bytes).conformance_report

    expect(report.issues.map(&:code)).not_to include("png.decompression_bound_exceeded")
    expect(report.issues).to include(
      have_attributes(severity: "error", message: a_string_including("decompression failed"))
    )
  end

  # A declared length past what the file actually backs is truncation, not
  # a bomb -- `bomb_at?` requires the full declared length to have been
  # read before it will even look for a compressed segment. The payload
  # here is the COMPLETE bomb-shaped compressed stream, not a short prefix
  # of it -- a truly truncated fragment decompresses to far less than the
  # ceiling on its own (measured: the first 100 bytes of this exact stream
  # yield only 81,920 bytes), so a fixture built that way would pass this
  # example whether or not the length check is doing anything. Declaring
  # one byte more than the file actually supplies is what makes the
  # example distinguish "the check caught a short read" from "the payload
  # was never going to be a bomb regardless".
  it "does not flag a chunk whose declared length exceeds the file's real bytes" do
    compressed = deflated(max_decompressed_bytes + 1)
    payload = "profile\x00\x00#{compressed}"
    bomb = chunk_with_declared_length("iCCP", payload.bytesize + 1, payload)
    report = conform_image(png_with_trailing(bomb)).conformance_report

    expect(report.issues.map(&:code)).not_to include("png.decompression_bound_exceeded")
  end

  # Pins the fix for a bypass found while designing this guard: png_conform
  # does not stop at IEND (measured directly -- a zTXt chunk appended
  # after a complete PNG's IEND is still inflated and reported), so a
  # guard that stopped scanning there would miss a bomb chunk placed after
  # it while the real delegate still reached it. This is built by hand
  # rather than through `png_with_trailing`, which always appends its tail
  # immediately after IHDR: an IDAT and a real IEND come first here, and
  # the bomb chunk after both.
  #
  # `include`, not `contain_exactly`: the structural scanner this handler
  # also runs (private_constant `StructureScanner`) independently flags the
  # same trailing bytes as `png.trailing_data` -- a true, separate finding
  # about the same chunk. This example is only about the bound-exceeded
  # issue still firing past IEND, not about it being the sole issue.
  it "still flags a bomb-shaped zTXt chunk placed after IEND" do
    expect(PngConform::Services::ValidationService).not_to receive(:new)
    idat = chunk("IDAT", Zlib::Deflate.deflate("\x00" * 3))
    bomb = ztxt_chunk(deflated(max_decompressed_bytes + 1))
    bytes = png_with_trailing(idat + chunk("IEND", "") + bomb)

    report = conform_image(bytes).conformance_report

    expect(report.issues).to include(
      have_attributes(code: "png.decompression_bound_exceeded", location: have_attributes(chunk: "zTXt"))
    )
  end

  # A pre-existing, out-of-scope png_conform defect, found while designing
  # this guard (not introduced by it): this exact payload shape raises
  # `NoMethodError` deep inside the real delegate's own
  # `check_compression_method` (`nil.ord`, off this repo's
  # `MALFORMED_INPUT` allowlist), independently reproduced against the
  # installed 0.1.4 gem directly. The guard cannot find a compressed
  # segment in "ab\0" -- no byte survives past where one would start -- and
  # correctly defers entirely to the delegate, which is what still raises.
  # The point of this example is that the guard leaves this alone rather
  # than papering over it.
  it "does not intercept a structurally malformed iCCP chunk that a pre-existing delegate defect raises on" do
    bytes = png_with_trailing(chunk("iCCP", "ab\x00") + chunk("IEND", ""))

    # `/ord/`, not a bare class match: the delegate's own bug is
    # `nil.ord` inside `check_compression_method`, and a class-only
    # match cannot tell that from the guard itself crashing on this
    # input -- a mutated guard that drops its own nil-safety raises the
    # same NoMethodError class one frame earlier, on `nil.zero?`, and a
    # bare `raise_error(NoMethodError)` cannot tell the two apart.
    expect { conform_image(bytes).conformance_report }.to raise_error(NoMethodError, /ord/)
  end
end
