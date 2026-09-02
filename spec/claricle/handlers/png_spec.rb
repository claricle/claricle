# frozen_string_literal: true

require "png_conform"
require "stringio"
require "tmpdir"
require "zlib"

# A StringIO that logs every #read and #seek call (method, argument,
# position before the call), so a spec can assert not just "no request
# was ever large" but "this exact byte range was never touched". Built
# from bytes starting at what `gather` actually receives as `reader.io`
# -- already positioned past the signature -- rather than a whole file.
class RecordingIO < StringIO
  attr_reader :calls

  def initialize(bytes)
    super
    @calls = []
  end

  def read(length = nil)
    @calls << [:read, length, pos]
    super
  end

  def seek(length, whence = IO::SEEK_SET)
    @calls << [:seek, length, pos]
    super
  end
end

# The same log, but wrapped around a REAL pipe reader rather than a
# StringIO. The `Errno::ESPIPE` that sends `skip` down its drain comes
# out of the kernel here -- a double told to raise it would prove only
# that the rescue clause is spelled correctly. No `pos`: a pipe has no
# position to record, which is the whole point of it.
class RecordingPipe
  attr_reader :calls

  def initialize(io)
    @io = io
    @calls = []
  end

  def read(length = nil)
    @calls << [:read, length]
    @io.read(length)
  end

  def seek(length, whence = IO::SEEK_SET)
    @calls << [:seek, length]
    @io.seek(length, whence)
  end
end

RSpec.describe "Claricle PNG handler" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Png).new }

  def fixture(name)
    File.join(__dir__, "..", "..", "fixtures", "inspect", name)
  end

  def inspect_file(name)
    handler.inspection(Claricle::Image.from_path(fixture(name)))
  end

  # A complete signature and IHDR, then whatever bytes the caller wants
  # the file to carry -- including bytes it deliberately stops in the
  # middle of.
  def png_with_trailing(tail)
    signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
    header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")

    signature + chunk("IHDR", header) + tail
  end

  # Built in memory rather than as a fixture: the point is the chunk's
  # length, which is easier to read here than in a binary blob.
  def png_with_phys(payload)
    png_with_trailing(chunk("pHYs", payload) + chunk("IEND", ""))
  end

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  # Like `chunk`, but truncates the CRC to `crc_bytes` instead of the
  # full 4 -- for pinning that a wanted chunk whose CRC didn't fully
  # arrive is truncation, not something to keep.
  def chunk_with_short_crc(type, data, crc_bytes)
    crc = [Zlib.crc32(type + data)].pack("N")
    [data.bytesize].pack("N") + type + data + crc[0, crc_bytes]
  end

  # `ChunkReader` is a private nested constant on the handler class --
  # reached with `const_get`, the same way `handler` above reaches the
  # handler itself, since `private_constant` doesn't block that.
  def chunk_reader_for(bytes)
    io = RecordingIO.new(bytes)

    [chunk_reader_class.new(io), io]
  end

  def chunk_reader_class
    Claricle.const_get(:Handlers).const_get(:Png).const_get(:ChunkReader)
  end

  # Fed from a thread, so bytes past the pipe buffer do not deadlock the
  # writer, and killed in an ensure -- a spec that stops reading early
  # would otherwise leave the feeder blocked on a full buffer forever.
  # Same shape as detector_spec.rb:617-631, "returns from a pipe that stays
  # open past its bound" -- named as well as numbered so it survives a move.
  # EPIPE rescue included: there
  # isn't one, because the kill lands before the writer can ever resume
  # into a closed reader. Measured over 800 runs, both teardown
  # orderings, EPIPE never fired.
  def with_fed_pipe(bytes)
    reader, writer = IO.pipe
    feeder = Thread.new do
      writer.write(bytes)
    ensure
      writer.close
    end

    yield(reader)
  ensure
    feeder&.kill
    reader&.close
  end

  # `gather` driven straight off a pipe, with its calls recorded.
  def with_piped_chunk_reader(bytes)
    with_fed_pipe(bytes) do |reader|
      # Binary, like the reader library opens its own file: without it a
      # trailing `read` with no length comes back tagged UTF-8 and stops
      # comparing equal to the packed bytes it actually holds.
      reader.binmode
      io = RecordingPipe.new(reader)

      yield(chunk_reader_class.new(io), io)
    end
  end

  # A PNG carrying a large unwanted chunk before its pHYs, so anything
  # reading it off a pipe has to drain that chunk and land exactly on
  # the next header.
  def png_with_fat_text_before_phys
    png_with_trailing(fat_text + chunk("pHYs", square_phys) + chunk("IEND", ""))
  end

  # 2835 pixels per metre on both axes -- 72.01 dpi, the same value the
  # phys.png fixture carries.
  def square_phys
    [2835, 2835, 1].pack("NNC")
  end

  # 100,002 bytes of payload: far past any read this handler is allowed
  # to make, and past the pipe buffer too, so draining it is real work.
  def fat_text
    chunk("tEXt", "k\x00#{"x" * 100_000}")
  end

  # Served over a real pipe through `/dev/fd/<n>`, which is the only
  # shape that reaches `skip`'s ESPIPE fallback end to end.
  def with_piped_path(bytes)
    with_fed_pipe(bytes) { |reader| yield("/dev/fd/#{reader.fileno}") }
  end

  # `validate` returns the FileAnalysis itself, not a result wrapping one.
  #
  # Closed in an ensure: given a String the full reader opens the file
  # itself and holds it until #close, which is the leak this handler
  # switched readers to avoid. A spec that documents that must not be the
  # one place still doing it.
  def image_info(name)
    path = fixture(name)
    reader = PngConform::Readers::FullLoadReader.new(path)
    PngConform::Services::ValidationService.new(reader, path).validate.image_info
  ensure
    reader&.close
  end

  describe "metadata" do
    subject(:inspection) { inspect_file("valid.png") }

    it "reads the IHDR fields" do
      expect(inspection).to have_attributes(
        format: "png",
        width: 4.0,
        height: 3.0,
        color_space: "truecolor+alpha",
        parse_status: "ok"
      )
    end

    it "returns dimensions as Floats, per the one-numeric-type rule" do
      expect([inspection.width, inspection.height]).to all(be_a(Float))
    end

    it "carries the remaining IHDR fields in meta as Integers" do
      expect(inspection.meta).to eq(
        "bit_depth" => 8, "compression" => 0, "filter" => 0, "interlace" => 0
      )
    end

    it "reports no issues for a clean file" do
      expect(inspection.issues).to be_empty
    end

    # The handler unpacks IHDR by hand rather than running the validator,
    # so this is what stops the two drifting apart.
    it "agrees with png_conform's own ImageInfo" do
      info = image_info("valid.png")

      expect([inspection.width.to_i, inspection.height.to_i, inspection.meta["bit_depth"]])
        .to eq([info.width, info.height, info.bit_depth])
    end
  end

  # One fixture only exercises one colour type, so the other four could
  # drift from png_conform's vocabulary unnoticed. Comparing the table
  # against itself would not catch that, so each type is checked against
  # ImageInfo -- which is how the "indexed" / "palette" mismatch surfaced.
  describe "the colour-type table" do
    %w[grayscale.png truecolor.png indexed.png gray_alpha.png valid.png].each do |name|
      it "agrees with png_conform's vocabulary for #{name}" do
        expect(inspect_file(name).color_space).to eq(image_info(name).color_type)
      end
    end
  end

  describe "dpi" do
    it "reads pHYs in pixels per metre" do
      expect(inspect_file("phys.png").dpi).to be_within(0.01).of(72.01)
    end

    it "is nil when pHYs records an aspect ratio only" do
      expect(inspect_file("phys_unit0.png").dpi).to be_nil
    end

    it "is nil when pHYs is absent" do
      expect(inspect_file("valid.png").dpi).to be_nil
    end

    # 2835x5669 is roughly 72x144: reporting the x axis alone would call
    # it a 72 dpi image, which is half the truth.
    it "is nil when the axes disagree" do
      bytes = png_with_phys([2835, 5669, 1].pack("NNC"))
      inspection = handler.inspection(Claricle::Image.from_content(bytes, format: :png))

      expect(inspection).to have_attributes(dpi: nil, parse_status: "ok")
    end

    # A short pHYs is a malformed chunk, but inspection reports metadata
    # readability, not conformance -- so it degrades to nil rather than
    # raising, and the header it did read still stands.
    #
    # Every length below 9 is covered, not a sample: unpack skips a
    # directive it lacks bytes for but keeps reading the rest from where
    # it started, so the lengths behave in three groups rather than one.
    # 1..3 gave [nil, nil, 1] -- unit passed, then nil was multiplied,
    # which is the crash this gate stops. 5..7 gave [value, nil, 1],
    # which the axis check rejects on its own. Both sat between the
    # lengths an obvious sample would have picked.
    (0...9).each do |length|
      it "is nil when pHYs carries only #{length} bytes" do
        bytes = png_with_phys("\x01" * length)
        inspection = handler.inspection(Claricle::Image.from_content(bytes, format: :png))

        expect(inspection).to have_attributes(dpi: nil, parse_status: "ok", width: 4.0)
      end
    end

    it "reads pHYs once it is long enough to carry a unit" do
      bytes = png_with_phys([2835, 2835, 1].pack("NNC"))
      inspection = handler.inspection(Claricle::Image.from_content(bytes, format: :png))

      expect(inspection.dpi).to be_within(0.01).of(72.01)
    end
  end

  # Two distinct failure shapes. Measured: truncating mid-IHDR yields
  # zero chunks, so it reaches the absent branch, never the length one.
  describe "the metadata-readability gate" do
    it "fails a signature-only file, which the reader accepts silently" do
      expect(inspect_file("signature_only.png").parse_status).to eq("failed")
    end

    it "fails a file truncated mid-IHDR" do
      expect(inspect_file("truncated_ihdr.png").parse_status).to eq("failed")
    end

    it "fails a well-formed IHDR carrying fewer than 13 bytes" do
      expect(inspect_file("short_ihdr.png").parse_status).to eq("failed")
    end

    # The fixture above only pins one length (9). 10, 11 and 12 are the
    # rest of "fewer than 13" -- a regression that rejected only 9 bytes
    # but accepted 10-12 would still pass without these.
    (10..12).each do |length|
      it "fails a well-formed IHDR carrying exactly #{length} bytes" do
        signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
        bytes = signature + chunk("IHDR", "\x01" * length)

        expect(handler.inspection(Claricle::Image.from_content(bytes, format: :png)).parse_status)
          .to eq("failed")
      end
    end

    it "reports one error-severity issue when the header is unreadable" do
      issues = inspect_file("signature_only.png").issues

      expect(issues.map(&:severity)).to eq(["error"])
    end

    # The gate's limit, stated so nobody mistakes it for a conformance check.
    it "passes a file truncated after a complete IHDR" do
      expect(inspect_file("truncated_after_ihdr.png")).to have_attributes(
        parse_status: "ok", width: 4.0
      )
    end

    # The example above only reaches clean EOF. Cut a file two bytes into
    # the NEXT chunk and `gather` stops the loop instead, which used to
    # throw away the IHDR it had already read and report "PNG header
    # (IHDR) could not be read" about a header this had just parsed.
    #
    # Both tails take the same route: a short/absent header (or, for the
    # second, a header for an unwanted type whose declared length reaches
    # past EOF) ends the loop with whatever was already in `into`. They
    # are kept as two cases because they are differently shaped inputs,
    # not because they exercise two different mechanisms.
    {
      "a chunk header cut in half" => "\x00\x00",
      "a chunk promising data the file lacks" => "\x00\x00\x00\x40IDAT\x01\x02"
    }.each do |label, tail|
      it "keeps a complete IHDR when the file ends in #{label}" do
        bytes = png_with_trailing(tail)
        inspection = handler.inspection(Claricle::Image.from_content(bytes, format: :png))

        expect(inspection).to have_attributes(parse_status: "ok", width: 4.0, height: 3.0)
      end
    end

    # A wanted chunk longer than MAX_CHUNK_READ still has to leave the
    # stream aligned for whatever comes after it -- the unread remainder
    # of its declared length must be skipped, not left for the next
    # header read to misinterpret.
    it "still finds IHDR after an oversized wanted chunk ahead of it" do
      signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
      header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")
      oversized_phys = chunk("pHYs", "x" * 40) # declared and actual length both exceed 32
      bytes = signature + oversized_phys + chunk("IHDR", header) + chunk("IEND", "")

      inspection = handler.inspection(Claricle::Image.from_content(bytes, format: :png))

      expect(inspection).to have_attributes(parse_status: "ok", width: 4.0, height: 3.0)
    end

    # A wanted chunk is only kept once its CRC is confirmed present --
    # png_conform's own atomic chunk read never hands `gather` a chunk
    # whose CRC didn't fully arrive either, and the new hand-rolled read
    # has to keep that guarantee now that it reads the CRC itself.
    describe "a truncated CRC on a wanted chunk" do
      (0...4).each do |crc_bytes|
        it "does not keep an IHDR whose CRC carries only #{crc_bytes} bytes" do
          signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
          header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")
          bytes = signature + chunk_with_short_crc("IHDR", header, crc_bytes)

          expect(handler.inspection(Claricle::Image.from_content(bytes, format: :png)).parse_status)
            .to eq("failed")
        end
      end

      it "does not let a pHYs with a truncated CRC report a dpi" do
        payload = [2835, 2835, 1].pack("NNC")
        bytes = png_with_trailing(chunk_with_short_crc("pHYs", payload, 2))
        inspection = handler.inspection(Claricle::Image.from_content(bytes, format: :png))

        expect(inspection).to have_attributes(parse_status: "ok", dpi: nil)
      end
    end
  end

  describe "error handling" do
    # A file that vanished between detection and this read is not
    # malformed input. Absorbing it said "PNG header (IHDR) could not be
    # read" about a file that was no longer there, and exited 0; the
    # runner maps the propagated error to 2, which is the code the README
    # gives for a missing file.
    it "lets a vanished file surface as the missing-file error" do
      allow(PngConform::Readers::StreamingReader).to receive(:open)
        .and_raise(Errno::ENOENT, "vanished")

      expect { inspect_file("valid.png") }.to raise_error(Errno::ENOENT)
    end

    it "exits 2, not 0, when the file vanishes mid-inspection" do
      allow(PngConform::Readers::StreamingReader).to receive(:open)
        .and_raise(Errno::ENOENT, "vanished")

      code = Claricle::Cli::Runner.run(["inspect", fixture("valid.png")], output: StringIO.new)

      expect(code).to eq(2)
    end

    # Measured against 0.1.4: the streaming reader raises nothing here.
    # It reads a nil signature, reports EOF, and the file yields zero
    # chunks, so the IHDR gate is what fails it. Detection rejects empty
    # bytes, so this only reaches the handler through from_content --
    # where the caller asserts the format. An empty file is unreadable,
    # not a defect.
    it "reports an empty file as failed rather than raising" do
      image = Claricle::Image.from_content("", format: :png)

      expect(handler.inspection(image).parse_status).to eq("failed")
    end

    # Four shapes of unusable input, each pinned to "failed" rather than
    # an exception reaching the caller. Measured: under this reader all
    # four take the same route -- zero chunks, nothing raised, and the
    # IHDR gate is what fails them. They are still driven one by one
    # because that shared route is the delegate's choice, not ours, and
    # nothing here would notice it splitting apart again.
    {
      "a 1-byte signature" => "\x89",
      "a 7-byte signature" => [137, 80, 78, 71, 13, 10, 26].pack("C*"),
      "an empty file" => "",
      "a full signature and nothing else" => [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
    }.each do |label, bytes|
      it "reports #{label} as failed rather than raising" do
        image = Claricle::Image.from_content(bytes, format: :png)

        expect(handler.inspection(image).parse_status).to eq("failed")
      end
    end

    # A chunk declaring 0x8000000d bytes now only ever gets read up to
    # MAX_CHUNK_READ -- with 17 real bytes left in this fixture, that
    # request comes back short, which is truncation, not an EINVAL from
    # asking the OS for the whole declared length.
    it "reports an absurd chunk length as failed" do
      header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")
      signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
      absurd = [0x8000000d].pack("N")
      crc = [0].pack("N")
      bytes = "#{signature}#{absurd}IHDR#{header}#{crc}"
      image = Claricle::Image.from_content(bytes, format: :png)

      expect(handler.inspection(image).parse_status).to eq("failed")
    end

    # Stubbed, and deliberately so: no code path in png_conform 0.1.4
    # raises this. It is the delegate's declared parse failure and the
    # gemspec admits every later 0.1.x, so this pins what happens the day
    # a patch release starts raising it -- "failed", not exit 4.
    #
    # Raises the BASE `PngConform::Error`, not `ParseError`: `ParseError`
    # is a subclass, so a regression that narrowed the rescue clause to
    # `ParseError` only would still pass a spec that raised `ParseError`.
    # Raising the base is what a narrowed rescue clause would miss.
    it "absorbs the delegate's own error class" do
      allow(PngConform::Readers::StreamingReader).to receive(:open)
        .and_raise(PngConform::Error, "bad chunk")

      expect(inspect_file("valid.png").parse_status).to eq("failed")
    end

    # A delegate defect is a defect. Absorbing it would report "this file
    # does not parse" for a file that parses fine.
    it "lets an off-allowlist error propagate" do
      allow(PngConform::Readers::StreamingReader).to receive(:open)
        .and_raise(NoMethodError, "undefined method")

      expect { inspect_file("valid.png") }.to raise_error(NoMethodError)
    end
  end

  describe "a content-born image" do
    it "inspects identically, via the temporary path" do
      content = File.binread(fixture("valid.png"))
      from_content = handler.inspection(Claricle::Image.from_content(content))

      # The whole model, not two fields -- "identically" is the claim.
      expect(from_content.to_json).to eq(inspect_file("valid.png").to_json)
    end
  end

  # The delegate's full reader is `read_until: :eof`, so it walks past
  # IEND into whatever follows. A PNG's metadata ends at IEND, and
  # anything after it belongs to some other file.
  describe "the IEND boundary" do
    it "ignores a pHYs chunk appended after IEND" do
      expect(inspect_file("phys_after_iend.png").dpi).to be_nil
    end

    # Two concatenated PNGs. The full reader read the second signature as
    # a chunk length of 0x89504E47, the OS returned EINVAL, and a file
    # whose first image is perfectly readable reported "failed".
    it "reads the first image of a doubled PNG" do
      expect(inspect_file("doubled.png")).to have_attributes(
        parse_status: "ok", width: 4.0, height: 3.0
      )
    end
  end

  # An allowlist, so IDAT and IEND both stay out. `gather` steps over
  # both rather than reading them, so on a seekable IO a PNG carrying a
  # huge ancillary chunk never costs more than that chunk's own 8-byte
  # header. The pipe examples at the end of this file are the other
  # case, where those bytes are read and thrown away.
  describe "what it keeps" do
    it "retains only the wanted chunks" do
      chunks = handler.send(:read_chunks,
                            Claricle::Image.from_path(fixture("phys.png")))

      expect(chunks.map { |chunk| chunk.type.to_s }).to eq(%w[IHDR pHYs])
    end

    # "never retains", not "never reads": this is the collection-only
    # half of the claim. The bounded-reads examples below are the other
    # half -- that the chunk's bytes were never pulled off disk either.
    it "drops a large ancillary chunk it never retains" do
      bytes = png_with_trailing(chunk("tEXt", "k\x00#{"x" * 100_000}") + chunk("IEND", ""))
      chunks = handler.send(:read_chunks, Claricle::Image.from_content(bytes, format: :png))

      expect(chunks.sum { |chunk| chunk.data.bytesize }).to eq(13)
    end
  end

  # `read_chunks` collects a large unwanted chunk's own bytes today by
  # driving `gather` end to end -- these instead drive `gather` directly
  # against a recording double, so the assertion is on what the IO was
  # actually asked to read, not only on what `into` ends up holding.
  describe "bounded reads" do
    it "never asks the IO to read anywhere near a huge declared length" do
      header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")
      # A declared length of 500,000,000 backed by only 4 real trailing
      # bytes -- the point is what gets REQUESTED, not what exists.
      huge = "#{[500_000_000].pack("N")}tEXtxxxx"
      chunk_reader, io = chunk_reader_for(chunk("IHDR", header) + huge)
      into = []

      chunk_reader.gather(into: into)

      expect(into.map(&:type)).to eq(["IHDR"])
      reads = io.calls.select { |method, _n, _pos| method == :read }
      expect(reads.map { |_method, n, _pos| n }.max).to be <= 32
      # The unwanted chunk's declared length is what moved the IO past
      # it -- a seek, not a read, is where the huge number appears.
      expect(io.calls).to include([:seek, 500_000_004, 33])
    end

    it "keeps only the first of two chunks sharing a wanted type" do
      kept = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")
      dropped = [8, 6, 8, 6, 0, 0, 0].pack("NNC5")
      chunk_reader, io = chunk_reader_for(chunk("IHDR", kept) + chunk("IHDR", dropped))
      into = []

      chunk_reader.gather(into: into)

      expect(into.map(&:data)).to eq([kept])
      # The second IHDR's 13-byte payload is skipped, not read: only one
      # 13-byte read exists in the log, for the first chunk.
      payload_reads = io.calls.count { |method, n, _pos| method == :read && n == 13 }
      expect(payload_reads).to eq(1)
    end

    # The two above bound an UNWANTED chunk, where the allowlist would
    # stop the read even if the cap did not. This one is a wanted type
    # on its first occurrence, fully backed by real bytes: the cap is
    # the only thing between it and a 100 KB read, so it is the only
    # example that goes red if `read_chunk_data` starts trusting a
    # declared length.
    it "caps a wanted chunk's own payload and steps over the rest" do
      header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")
      fat_phys = chunk("pHYs", "p" * 100_000)
      chunk_reader, io = chunk_reader_for(chunk("IHDR", header) + fat_phys + chunk("IEND", ""))
      into = []

      chunk_reader.gather(into: into)

      # 13 bytes of IHDR kept whole, 32 of pHYs kept out of 100,000.
      expect(into.map { |kept| kept.data.bytesize }).to eq([13, 32])
      reads = io.calls.select { |method, _n, _pos| method == :read }
      expect(reads.map { |_method, n, _pos| n }.max).to eq(32)
      # The remaining 99,968 bytes are seeked, not read, from just past
      # the capped payload at offset 65.
      expect(io.calls).to include([:seek, 99_968, 65])
      # And the stream is still aligned afterwards: all that is left is
      # the CRC of the IEND whose header ended the loop.
      expect(io.read).to eq([Zlib.crc32("IEND")].pack("N"))
    end
  end

  # The full reader owned the file it opened and closed it only on an
  # explicit #close, which this handler never called -- so every
  # inspection held a descriptor until GC happened to run.
  it "closes the file it opens" do
    path = fixture("valid.png")
    GC.disable
    before = Dir["/dev/fd/*"].size
    100.times { Claricle::Image.from_path(path).inspection }
    delta = Dir["/dev/fd/*"].size - before

    expect(delta).to eq(0)
  ensure
    GC.enable
  end

  # The delegate accepts only a String path. Detection, #content and
  # #with_path all take a Pathname, so inspection raising NoMethodError
  # on `rewind` made PNG the odd handler out -- and NoMethodError is off
  # the allowlist, so it surfaced as exit 4, the defect code.
  it "inspects a Pathname the same as a String path" do
    require "pathname"
    image = Claricle::Image.from_path(Pathname(fixture("valid.png")))

    expect(image.inspection).to have_attributes(
      parse_status: "ok", width: 4.0, height: 3.0
    )
    # `Image#checked_path` owns what it stores: a frozen String, not the
    # Pathname itself. Storing the Pathname directly would still pass
    # every assertion above -- `StreamingReader.open` accepts one just
    # as happily as a String -- so this is what would actually catch it.
    expect(image.path).to be_a(String).and be_frozen
  end

  # A path that cannot be sought, which is what `skip`'s `Errno::ESPIPE`
  # rescue exists for. The supported shape is narrow and these pin both
  # sides of it.
  describe "a non-seekable path" do
    # The public entry point, not `handler.inspection`: what a caller
    # holds is an Image. The format has to be given, because detection
    # reads the path and a pipe hands its bytes out exactly once.
    #
    # A fat tEXt sits BEFORE the pHYs on purpose. Reaching the dpi at
    # all means the drain consumed 100,006 bytes and stopped on the
    # next header, so the assertion below is about alignment, not just
    # about not raising.
    it "inspects a PNG whose format it is given" do
      with_piped_path(png_with_fat_text_before_phys) do |path|
        inspection = Claricle::Image.new(format: :png, path: path).inspection

        expect(inspection).to have_attributes(parse_status: "ok", width: 4.0, height: 3.0)
        expect(inspection.dpi).to be_within(0.01).of(72.01)
      end
    end

    # The other side of the same boundary, and the reason the paragraph
    # on `skip` says "not `Image.from_path`". Detection opens the path
    # and consumes the signature, so inspection reopens `/dev/fd/<n>`
    # onto a stream that has already moved. If the detector ever stops
    # doing that, this goes red -- which is the signal to widen the
    # claim rather than a reason to loosen the example.
    it "reports an unreadable header when the format is detected instead" do
      with_piped_path(png_with_fat_text_before_phys) do |path|
        image = Claricle::Image.from_path(path)

        expect(image.format).to eq(:png)
        expect(image.inspection).to have_attributes(
          parse_status: "failed",
          issues: [have_attributes(code: "png.ihdr_unreadable")]
        )
      end
    end

    # Driven against a real pipe reader rather than the whole handler,
    # so the drain's own reads are visible. Both of the mutations that
    # the earlier version of this example survived now fail it: one
    # unbounded read blows the size assertion, and a drain that does
    # nothing loses the pHYs and the tail.
    it "drains what it cannot seek in bounded reads" do
      tail = "#{chunk("IEND", "")}TAIL"
      into = []

      with_piped_chunk_reader(fat_text + chunk("pHYs", square_phys) + tail) do |chunk_reader, io|
        chunk_reader.gather(into: into)

        reads = io.calls.filter_map { |method, n| n if method == :read }
        # 100,006 bytes of payload and CRC over a 16 KiB buffer: six
        # full reads and a remainder, never one big one and never none.
        expect(reads.max).to eq(16_384)
        expect(reads.count(16_384)).to eq(6)
        # Alignment, twice over: the pHYs behind the drained chunk came
        # back whole, and what is left on the pipe is exactly the CRC of
        # the IEND that ended the loop plus the sentinel after it.
        expect(into.map { |kept| [kept.type, kept.data] }).to eq([["pHYs", square_phys]])
        expect(io.read).to eq("#{[Zlib.crc32("IEND")].pack("N")}TAIL")
      end
    end
  end
end

# Byte-stream builders for the structural scanner's table. At file scope
# because the table is enumerated when the example group is DEFINED, and
# an instance method is not available there.
#
# Every stream is built from `.b` literals: a `"\xFF"` literal in this
# UTF-8 source is a UTF-8 string carrying invalid bytes, and joining one
# to packed binary raises `Encoding::CompatibilityError`.
# Not an IO, deliberately. `each_byte`, `readpartial`, `gets` and the
# rest raise NoMethodError here rather than consuming the file
# unrecorded -- measured: a StringIO subclass intercepting only `read`
# watched an `each_byte` consumer swallow a whole file and logged zero
# calls, so the assertion was about the recorder, not the code.
class CapabilityIO
  attr_reader :reads

  def initialize(file)
    @file = file
    @reads = []
  end

  def read(length = nil)
    @file.read(length).tap { |bytes| @reads << bytes.to_s.bytesize }
  end

  def seek(*) = @file.seek(*)
  def size = @file.size
  def close = @file.close
end

module PngStreams
  module_function

  SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
  IHDR_13 = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data.b + [Zlib.crc32(type + data)].pack("N")
  end

  # A chunk header alone: a declared length and a type with no record
  # behind them. How MOST truncation rows are built -- not all: the residue
  # rows append raw bytes with no header, and the duplicate-IEND rows slice
  # one, so do not read this as covering every truncation case.
  def header(length, type)
    [length].pack("N") + type.b
  end

  def png(*parts) = SIGNATURE + parts.join.b
  def ihdr(payload = IHDR_13) = chunk("IHDR", payload)
  def ihdr_chunk = ihdr
  def iend = chunk("IEND", "")
  def idat(payload) = chunk("IDAT", payload)
  def payload_10_mib = "x" * 10_485_760
end

# The scanner's row tables, kept apart from the byte builders above so
# neither module has to grow past what one concern needs.
module PngRows
  extend PngStreams

  module_function

  def built
    trailing_rows.merge(duplicate_rows).merge(repeat_placement_rows).merge(truncation_rows)
                 .merge(type_code_rows).merge(short_file_rows)
  end

  # Everything past IEND is outside the datastream and gets exactly one
  # issue over the whole remainder. Which issue turns on whether that
  # remainder opens with a COMPLETE IEND record, not merely the type.
  # Every remainder starts at 45, so the rows differ only in what sits
  # there and in how much of it there is.
  def after_iend(tail, code, length, chunk_name)
    [png(ihdr, iend) + tail.b, [["png.#{code}", "error", 45, length, chunk_name]]]
  end

  def trailing_rows = plain_trailing_rows.merge(second_iend_rows)

  def plain_trailing_rows
    {
      "IEND first, no IHDR" => [png(iend), []],
      "trailing IHDR after IEND" => after_iend(ihdr_chunk, "trailing_data", 25, nil),
      "one trailing byte" => after_iend("x", "trailing_data", 1, nil)
    }
  end

  # Which issue the remainder gets turns on whether it opens with a
  # COMPLETE IEND record, not merely on the type bytes.
  def second_iend_rows
    {
      # The SAME 20-byte remainder either way: only the declared span
      # differs, so neither a `declared.zero?` nor a `remaining >= 12`
      # shortcut can tell these two apart.
      "complete second IEND, 20 declaring 8" =>
        after_iend(header(8, "IEND") + ("z" * 12), "duplicate_iend", 20, "IEND"),
      "incomplete second IEND, 20 declaring 13" =>
        after_iend(header(13, "IEND") + ("z" * 12), "trailing_data", 20, nil),
      # 42 bytes of remainder behind a 20-byte IEND record, so the range
      # cannot be the record's span -- the two coincide at exactly 20 in
      # the row above, which is the shape that hid this twice before.
      "complete second IEND with 22 bytes behind it" =>
        after_iend(header(8, "IEND") + ("z" * 12) + ("t" * 22), "duplicate_iend", 42, "IEND")
    }
  end

  # Declared lengths 0, 6, 13 and 20 so no row's header-derived span can
  # coincide with the ubiquitous 13 or with what is left in the file.
  def repeat_row(payload, span)
    [png(ihdr, ihdr(payload), iend), [["png.duplicate_ihdr", "error", 33, span, "IHDR"]]]
  end

  def duplicate_rows
    {
      "duplicate IHDR, 13" => repeat_row(PngStreams::IHDR_13, 25),
      "duplicate IHDR, 20" => repeat_row("x" * 20, 32),
      "duplicate IHDR, 0" => repeat_row("", 12),
      "duplicate IHDR, 6" => repeat_row("x" * 6, 18)
    }
  end

  # One issue per repeat, and a repeat is recognised wherever it sits --
  # not only immediately after the first, which an adjacency-only
  # detector would satisfy.
  def repeat_placement_rows
    {
      "third IHDR emits a second issue" =>
        [png(ihdr, ihdr, ihdr, iend),
         [["png.duplicate_ihdr", "error", 33, 25, "IHDR"],
          ["png.duplicate_ihdr", "error", 58, 25, "IHDR"]]],
      "repeat separated by a complete chunk" =>
        [png(ihdr, chunk("pHYs", [1, 1, 1].pack("NNC")), ihdr, iend),
         [["png.duplicate_ihdr", "error", 54, 25, "IHDR"]]]
    }
  end

  # The range is always the bytes really present, never the declared span.
  def truncation_rows
    {
      "duplicate IHDR then truncated IDAT" =>
        [png(ihdr, ihdr, header(13, "IDAT"), "z"),
         [["png.duplicate_ihdr", "error", 33, 25, "IHDR"],
          ["png.chunk_truncated", "error", 58, 9, "IDAT"]]],
      "IEND one byte short" =>
        [png(ihdr, iend)[0..-2], [["png.chunk_truncated", "error", 33, 11, "IEND"]]],
      "seven stray bytes" =>
        [png(ihdr, "1234567"), [["png.chunk_truncated", "error", 33, 7, nil]]]
    }
  end

  # `chunk` is set only for four ASCII LETTERS, and only on the one code
  # that derives it from bytes read off the file. "pHYs" is mixed case,
  # so an uppercase-only predicate drops it; "1HDR" is ASCII but not
  # letters, which an `ascii_only?` predicate would wrongly accept.
  def type_code_rows
    {
      "exactly eight bytes remain" =>
        [png(ihdr, header(0, "pHYs")), [["png.chunk_truncated", "error", 33, 8, "pHYs"]]],
      "ASCII non-letter type" =>
        [png(ihdr, header(65_535, "1HDR"), "z" * 8), [["png.chunk_truncated", "error", 33, 16, nil]]],
      "high-byte type" =>
        [png(ihdr, header(65_535, "\xFF\xFEab".b), "z" * 8),
         [["png.chunk_truncated", "error", 33, 16, nil]]]
    }
  end

  # Shorter than the signature, so there is no chunk stream at all and no
  # range that could name one.
  def short_file_rows
    {
      "seven-byte file" => ["abcdefg", [["png.chunk_truncated", "error", nil, nil, nil]]],
      "empty file" => ["", [["png.chunk_truncated", "error", nil, nil, nil]]]
    }
  end

  def fixtures
    {
      "doubled.png" => [["png.trailing_data", "error", 75, 75, nil]],
      "phys_after_iend.png" => [["png.trailing_data", "error", 75, 21, nil]],
      "truncated_ihdr.png" => [["png.chunk_truncated", "error", 8, 17, "IHDR"]],
      "truncated_after_ihdr.png" => [["png.missing_iend", "error", nil, nil, "IEND"]],
      "signature_only.png" => [["png.missing_iend", "error", nil, nil, "IEND"]]
    }
  end
end

# Inputs for the read-volume property, kept apart from the fault rows:
# these vary by SIZE, and every one of them is well-formed enough that
# what is being measured is the reading, not the reporting.
module PngBounded
  extend PngStreams

  module_function

  # Bytes read = 8 x headers examined. Rows 2 to 4 are what make that
  # non-trivial: one CARRIES 10 MiB it never reads, one DECLARES 10 MiB
  # it never reads, and one has a 10 MiB tail past IEND. Row 5 is the
  # only one reaching the clean-end exit.
  def bounded = bounded_clean.merge(bounded_edge)

  def bounded_clean
    {
      "clean, small" => [png(ihdr, idat("x" * 18), iend), 24],
      "clean, 10 MiB payload" => [png(ihdr, idat(payload_10_mib), iend), 24]
    }
  end

  def bounded_edge
    {
      "truncated, declares 10 MiB" => [png(ihdr, header(10_485_760, "IDAT"), "zzzz"), 16],
      "clean plus a 10 MiB tail" => [png(ihdr, idat("x" * 18), iend) + payload_10_mib, 32],
      "ends cleanly with no IEND" => [png(ihdr, idat("x" * 18)), 16]
    }
  end
end

# The structural pre-pass (D23). Nothing calls `structural_issues` yet --
# the conform wiring is item 03 -- so these drive it directly, the same
# way the `read_chunks` examples above do.
RSpec.describe "Claricle PNG structural scanner" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Png).new }

  def fixture(name)
    File.join(__dir__, "..", "..", "fixtures", "inspect", name)
  end

  def scanner_class
    Claricle.const_get(:Handlers).const_get(:Png).const_get(:StructureScanner)
  end

  # Short names for the file-scope builders, so an example reads as the
  # stream it builds rather than as a chain of module calls.
  def ihdr = PngStreams::IHDR_13
  def png(*parts) = PngStreams.png(*parts)
  def chunk(type, data) = PngStreams.chunk(type, data)
  def header(length, type) = PngStreams.header(length, type)

  def scan(bytes)
    scanner_class.new(StringIO.new(bytes.b)).issues
  end

  def tuples(bytes)
    scan(bytes).map do |issue|
      location = issue.location
      [issue.code, issue.severity, location&.byte_offset, location&.byte_length, location&.chunk]
    end
  end

  def scan_path(name)
    handler.send(:structural_issues, Claricle::Image.from_path(fixture(name)))
  end

  # --- the boundedness harness ------------------------------------------
  #
  # Three layers, because two were not enough twice over. THREE DIFFERENT
  # LISTS live here and an earlier comment ran them together, so they are
  # named apart: `CapabilityIO`'s INSTANCE surface is [read, seek, size,
  # close] -- it is that one which adds size and seek, because this walk
  # needs both and without them the harness fails a CORRECT implementation,
  # the worst way for a gate to be wrong. `svg_spec.rb:49` is a different
  # list again ([read, close, closed?, path, to_path, to_io, fileno]), and
  # `permitted_class_calls` below is a CLASS-method list sharing only `path`.
  # The scanner is measured to reach the filesystem through exactly ONE
  # class method: File.open. So this is an ALLOWLIST -- refused by names
  # derived from the class, not by a list someone has to remember to extend.
  # NOT total, and the gap is named rather than implied: `:open` is
  # subtracted BY NAME from a set built from BOTH receivers, so `IO.open`
  # is permitted too, and neither `Kernel.open` nor a subprocess is on
  # either receiver at all. Those routes are known-open follow-ups.
  #
  # A denylist was tried and leaked three times: first `each_byte` past a
  # read-only recorder, then `IO.binread` and the non-block `File.open`
  # past a four-name list, then `File.new`, `File.foreach` and
  # `File.readlines` past a six-name one. Each leak read the whole file
  # while the example stayed green.
  # MEASURED, not guessed: these are every File class method the example
  # actually uses -- `open` for the scanner, the rest for the temporary file
  # and its cleanup. None of the others returns file CONTENT.
  # NOT all of them are load-bearing, and that is stated rather than implied:
  # removing `binwrite`, `expand_path` or `writable?` one at a time leaves
  # all five bounded examples GREEN, because those fire BEFORE the guards are
  # armed. They stay because the plumbing really does call them, not because
  # a spec would catch their absence.
  def permitted_class_calls
    %i[open join binwrite dirname expand_path lstat stat path unlink writable?]
  end

  def refused_class_calls
    (File.singleton_methods | IO.singleton_methods).uniq - permitted_class_calls
  end

  # Wraps File.open in BOTH forms -- the non-block form was measured
  # handing back an unwrapped handle, which is a hole svg_spec.rb:82 has.
  # EVERY handle is kept, not just the latest. Keeping one let a mutant
  # slurp through a first File.open and then run the real scan through a
  # second, overwriting the record and passing clean -- the record was
  # single-valued where the behaviour is plural.
  def watch_reads(events)
    events[:wrappers] = []
    allow(File).to receive(:open).and_wrap_original do |original, *args, &block|
      next track(events, original.call(*args)) unless block

      original.call(*args) { |file| block.call(track(events, file)) }
    end
  end

  def track(events, file)
    CapabilityIO.new(file).tap { |wrapper| events[:wrappers] << wrapper }
  end

  def bytes_read(events) = events[:wrappers].sum { |wrapper| wrapper.reads.sum }
  def largest_read(events) = events[:wrappers].flat_map(&:reads).max

  # `IO.binread` is NOT `File.binread` -- measured, the two Method objects
  # are unequal -- so an expectation on File alone lets it through, and it
  # never touches the instrumented handle either way.
  # Refuse every class-level reader that is not File.open, on BOTH
  # receivers: `IO.binread` is not `File.binread` -- measured, the two
  # Method objects are unequal -- so guarding File alone lets it through.
  def forbid_slurps
    refused_class_calls.each do |name|
      expect(File).not_to receive(name)
      expect(IO).not_to receive(name) if IO.respond_to?(name)
    end
  end

  def with_png_file(bytes)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "probe.png")
      File.binwrite(path, bytes.b)
      yield path
    end
  end

  describe "a well-formed datastream" do
    # short_ihdr.png is the one that keeps this from drifting into content
    # validation: its ihdr declares 9 bytes, which frames correctly.
    %w[valid.png phys.png grayscale.png short_ihdr.png].each do |name|
      it "reports nothing for #{name}" do
        expect(scan_path(name)).to eq([])
      end
    end
  end

  describe "each fault's code, severity, range and chunk" do
    it "reports nothing for a stream that ends at IEND with nothing after it" do
      expect(tuples(PngRows.built.fetch("IEND first, no IHDR").first)).to eq([])
    end

    PngRows.built.except("IEND first, no IHDR").each do |label, (bytes, expected)|
      it "reports #{label}" do
        expect(tuples(bytes)).to eq(expected)
      end
    end

    PngRows.fixtures.each do |name, expected|
      it "reports #{name}" do
        issues = scan_path(name).map do |issue|
          location = issue.location
          [issue.code, issue.severity, location&.byte_offset, location&.byte_length, location&.chunk]
        end
        expect(issues).to eq(expected)
      end
    end
  end

  # A forward guard for codes added later, not proof of anything about
  # byte_length: a zero-length mutant satisfies it while failing many
  # other examples. No count is stated -- it read "ten", measured 23, and a
  # number in a comment rots exactly like a line range.
  it "never names bytes the file does not contain" do
    checked = 0

    PngRows.built.each_value do |bytes, _expected|
      scan(bytes).filter_map(&:location).each do |location|
        next if location.byte_offset.nil?

        checked += 1
        expect(location.byte_offset + location.byte_length).to be <= bytes.bytesize
      end
    end

    # Without this the example is vacuous: a scanner returning [] offers
    # no location to inspect and every assertion above is skipped.
    expect(checked).to eq(19)
  end

  # Documents the degeneracy directly: for each declared length the
  # header-derived span differs from what is left in the file. NOT
  # load-bearing on its own -- the `duplicate_rows` examples run on streams
  # three of whose four pairs are byte-identical (the length-13 pair shares
  # a header but differs in payload and CRC), and a remainder-derived mutant
  # fails all of them too, so this catches no mutant they miss.
  it "derives byte_length from the chunk header, not from the remainder" do
    {
      20 => [77, 32], 0 => [57, 12], 13 => [70, 25], 6 => [63, 18]
    }.each do |declared, (size, header_derived)|
      bytes = png(chunk("IHDR", ihdr), chunk("IHDR", "x" * declared), chunk("IEND", ""))
      expect(bytes.bytesize).to eq(size)
      expect(header_derived).not_to eq(size - 33)
      expect(tuples(bytes).first[3]).to eq(header_derived)
    end
  end

  # LOAD-BEARING. Bytes read = 8 x headers examined. NOT "independent of
  # file size" -- that overstates it, and png.rb states the rule the same
  # corrected way beside `structural_issues`. What is guaranteed is that no
  # PAYLOAD is ever read, whatever it declares. Rows 2 to 4 make that
  # non-trivial: one carries 10 MiB it never reads, one DECLARES 10 MiB
  # it never reads, and one has a 10 MiB tail past IEND.
  describe "bounded reads" do
    PngBounded.bounded.each do |label, (bytes, expected_volume)|
      it "reads #{expected_volume} bytes when the stream #{label}" do
        events = {}

        # The temporary file is written BEFORE the guards are armed, so the
        # recorded reads belong to the scanner alone.
        # NOT because arming first would REFUSE the plumbing -- it would not,
        # and the old comment here said otherwise. Instrumented across
        # `Dir.mktmpdir` + `File.binwrite` + cleanup: nine File class methods
        # fire (path, join, stat, lstat, expand_path, writable?, binwrite,
        # dirname, unlink) and ALL NINE are on the allowlist, because the
        # allowlist was derived by instrumenting this exact path.
        with_png_file(bytes) do |path|
          watch_reads(events)
          forbid_slurps

          handler.send(:structural_issues, Claricle::Image.new(format: :png, path: path))
        end

        expect(bytes_read(events)).to eq(expected_volume)
        expect(largest_read(events)).to eq(8)
      end
    end
  end

  # `io.size` is trusted for the guard, so a size that OVER-reports lets
  # the walk ask for a header that is not there. Measured: `read(8)` at
  # EOF returns nil and `nil.unpack` raised NoMethodError -- a crash on
  # exactly the malformed input this exists to report. A short read is a
  # fault, so it lands as truncation like every other short read here.
  #
  # BOTH HALVES of `header&.bytesize == HEADER_BYTES` need their own row,
  # because they are DIFFERENT reads. A size lying by 1000 puts the walk
  # past EOF and `read` hands back nil -- the ABSENT case. A size lying by
  # only 6 leaves a 6-byte tail, so `read(8)` hands back a SHORT string.
  # Only the second fails when the guard is weakened to `header.nil?`,
  # which is why one row was not enough.
  #
  # NEITHER row asserts byte_length, and neither asserts the message's
  # NUMBERS, deliberately: both are computed from the lying size, so the
  # absent case reports 1000 and "1000 bytes left, too few for a chunk
  # header" -- a message that contradicts itself, since 1000 is ample for an
  # 8-byte header. The SHORT row DOES assert the message's SUFFIX, which
  # carries no number and is the only thing separating "no header at all"
  # from "a chunk that overruns".
  #
  # ONE HAZARD, TWO SYMPTOMS, and the second is the worse one. That same
  # `io.size` read also misfires on the TRAILING path: a VALID 45-byte PNG
  # under a size over-reporting by 1000 returns ["png.trailing_data",
  # offset 45, byte_length 1000] -- a wrong issue about a file that is
  # FINE, naming 1000 bytes it does not have, which is exactly what the
  # rule above `truncated` says must never happen.
  #
  # Fixing both means not trusting `io.size`. That deferral is recorded in
  # this branch's own plan at section 3.6 -- which is LOCAL AND UNTRACKED,
  # so do not go looking for it in the repo.
  # The tracked home for the work is item 03 (TODO.plan/03-conform.md),
  # whose card does not yet name this hazard at all and should.
  # Item 03 must close BOTH paths: closing
  # only the truncation one it happens to reproduce still leaves a
  # perfectly good file reported as damaged. The ABSENT row pins only that
  # the scanner no longer CRASHES; the SHORT row additionally pins WHICH
  # fault it names, via the message suffix -- see its own comment below.
  it "treats an ABSENT header read as truncation when io.size over-reports" do
    lying = Class.new(StringIO) { def size = super + 1000 }
    bytes = png(chunk("IHDR", ihdr))

    issues = scanner_class.new(lying.new(bytes)).issues

    expect(issues.map(&:code)).to eq(["png.chunk_truncated"])
    expect(issues.first.location.byte_offset).to eq(33)
  end

  it "treats a SHORT header read as truncation when io.size over-reports" do
    lying = Class.new(StringIO) { def size = super + 6 }
    bytes = png(chunk("IHDR", ihdr)) + ("z" * 6)

    issues = scanner_class.new(lying.new(bytes)).issues

    expect(issues.map(&:code)).to eq(["png.chunk_truncated"])
    expect(issues.first.location.byte_offset).to eq(33)
    # THE SUFFIX IS WHAT MAKES THIS ROW LOAD-BEARING. The code and offset
    # alone are not: weaken the guard to `header.nil?` and this same input
    # still reports png.chunk_truncated at 33, so both of those assertions
    # stay green. What changes is WHICH fault it names -- the 6-byte tail
    # gets unpacked as a declared length, giving "chunk needs 2054847110
    # bytes but only 12 remain in the file". A short read is NO HEADER AT
    # ALL, not a chunk that overruns, and that is the distinction pinned
    # here. The byte count is left out of the assertion because it is
    # still derived from the lying size.
    expect(issues.first.message).to end_with("too few for a chunk header")
  end

  # Invisible without this: replacing `issues` with a bare `scan` left
  # every other scanner example green while a second call appended a false
  # duplicate-IHDR issue. No count is stated on purpose -- it was "45" and
  # is now 49, and a number in a comment rots exactly like a line range.
  it "scans once however often issues is asked for" do
    scanner = scanner_class.new(StringIO.new(png(chunk("IHDR", ihdr), chunk("IHDR", ihdr), chunk("IEND", ""))))

    expect(scanner.issues.map(&:code)).to eq(["png.duplicate_ihdr"])
    expect(scanner.issues.map(&:code)).to eq(["png.duplicate_ihdr"])
    expect(scanner.issues).to equal(scanner.issues)
  end

  it "returns issues in byte order, with the rangeless terminal issue last" do
    bytes = png(chunk("IHDR", ihdr), chunk("IHDR", ihdr))

    expect(tuples(bytes)).to eq([["png.duplicate_ihdr", "error", 33, 25, "IHDR"],
                                 ["png.missing_iend", "error", nil, nil, "IEND"]])
  end

  it "scans a content-born image identically, and to the expected value" do
    bytes = File.binread(fixture("doubled.png"))
    expected = [["png.trailing_data", "error", 75, 75, nil]]
    issues = handler.send(:structural_issues, Claricle::Image.from_content(bytes, format: :png))

    expect(issues.map { |i| [i.code, i.severity, i.location.byte_offset, i.location.byte_length, i.location.chunk] })
      .to eq(expected)
    expect(tuples(bytes)).to eq(expected)
  end

  # `message` is required, and apart from the SHORT over-reporting row --
  # which asserts only a suffix -- nothing else here reads it. Asserting the
  # text is what stops STRUCTURE_MESSAGES's seven strings being invented unreviewed.
  describe "messages" do
    it "states the record span against the bytes really left" do
      expect(scan_path("truncated_ihdr.png").first.message)
        .to eq("chunk needs 25 bytes but only 17 remain in the file")
    end

    # A residue runs 1 to 7 bytes, so both sides of the plural are
    # reachable and both are asserted -- the singular alone is what a
    # `"#{count} bytes"` shortcut gets wrong. Nothing else asserts the COUNT
    # word; the SHORT over-reporting row reads the message suffix only.
    { 1 => "1 byte left", 7 => "7 bytes left" }.each do |residue, phrase|
      it "names a #{residue}-byte shortfall when no header fits" do
        expect(scan(png(chunk("IHDR", ihdr), "z" * residue)).first.message)
          .to eq("#{phrase}, too few for a chunk header")
      end
    end

    it "says the file is shorter than the signature" do
      expect(scan("abc").first.message).to eq("file is shorter than the PNG signature")
    end

    it "names the missing terminator" do
      expect(scan_path("truncated_after_ihdr.png").first.message)
        .to eq("PNG datastream ends without an IEND chunk")
    end

    it "names a second IEND behind the end of the datastream" do
      bytes = png(chunk("IHDR", ihdr), chunk("IEND", "")) + header(8, "IEND") + ("z" * 12)

      expect(scan(bytes).first.message)
        .to eq("a second IEND chunk follows the end of the datastream")
    end

    it "names bytes past the end without claiming they are a chunk" do
      expect(scan_path("doubled.png").first.message).to eq("unexpected bytes after the IEND chunk")
    end

    # `.uniq` collapses the issues on purpose: what this pins is the
    # WORDING, which stays correct however many repeats emit. The COUNT is
    # pinned by the table row asserting two duplicate_ihdr issues, not here.
    it "says duplicate rather than second, so a third repeat needs no rewording" do
      bytes = png(chunk("IHDR", ihdr), chunk("IHDR", ihdr), chunk("IHDR", ihdr), chunk("IEND", ""))
      messages = scan(bytes).map(&:message).uniq

      expect(messages).to eq(["duplicate IHDR chunk; a PNG datastream carries exactly one"])
    end
  end
end
