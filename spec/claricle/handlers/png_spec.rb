# frozen_string_literal: true

require "png_conform"
require "stringio"
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

  # A real pipe, torn down in an ensure -- a spec that stops reading
  # early would otherwise leave the feeder blocked on a full buffer.
  def with_fed_pipe(bytes)
    reader, writer = IO.pipe
    feeder = feed(writer, bytes)

    yield(reader)
  ensure
    feeder&.kill
    reader&.close
  end

  # From a thread, so bytes past the pipe buffer do not deadlock.
  def feed(writer, bytes)
    Thread.new do
      writer.write(bytes)
    rescue Errno::EPIPE
      nil # the reader went away first; there is nothing left to feed
    ensure
      writer.close
    end
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
    # 1..3 gave [nil, nil, 1] -- unit passed, then nil was multiplied --
    # and 5..7 gave [value, nil, 1], a dpi the chunk never carried. Both
    # sat between the lengths an obvious sample would have picked.
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
    # gemspec admits any 0.1.x, so this pins what happens the day a patch
    # release starts raising it -- "failed", not exit 4.
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

  # An allowlist, so IDAT and IEND both stay out. `gather` skips both
  # over rather than reading them, so a PNG carrying a huge ancillary
  # chunk never costs more than that chunk's own 8-byte header.
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
