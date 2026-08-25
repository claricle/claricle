# frozen_string_literal: true

require "English"
require "emf"
require "json"

RSpec.describe "Claricle metafile handler" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Metafile).new }

  def fixture(name)
    File.join(__dir__, "..", "..", "fixtures", "inspect", "#{name}.emf")
  end

  # Explicit format, because several fixtures deliberately cannot be
  # DETECTED as EMF -- garbage and an empty file have no signature -- and
  # detection would raise before the handler ever ran. Image.from_content
  # with a format bypasses detection by design.
  def inspect_emf(name)
    handler.inspection(
      Claricle::Image.from_content(File.binread(fixture(name)), format: :emf)
    )
  end

  # The baseline with one or both device pairs rewritten as SIGNED
  # 32-bit values. Built here rather than as fixtures: these are
  # one-field edits to `valid.emf` at the two offsets the zero_device
  # fixtures already pin, and a binary file per sign combination would
  # say less than the pair of numbers does.
  def inspect_with_devices(pairs)
    bytes = File.binread(fixture("valid")).dup
    pairs.each { |offset, values| bytes[offset, 8] = values.pack("l<l<") }

    handler.inspection(Claricle::Image.from_content(bytes, format: :emf))
  end

  # The baseline's fixed 88-byte header followed by the records given,
  # already packed. The boundary cases below turn on a SINGLE byte, and
  # a binary fixture per byte would bury the number that matters inside
  # a file. `valid.emf` declares nSize 88, so the walk starts where the
  # first of these records does.
  def stream_of(*records)
    File.binread(fixture("valid")).byteslice(0, 88) + records.join
  end

  def inspect_stream(*records)
    handler.inspection(Claricle::Image.from_content(stream_of(*records), format: :emf))
  end

  # An EMF+ carrier: a comment whose declared payload is the marker plus
  # `payload` bytes, with no alignment padding.
  def carrier(payload)
    data = "EMF+".b + ("\x00".b * payload)
    [70, 12 + data.bytesize, data.bytesize].pack("VVV") + data
  end

  describe "dimensions" do
    it "reads the picture bounds" do
      expect(inspect_emf("valid")).to have_attributes(width: 100.0, height: 50.0)
    end

    # The baseline has bounds == device_pixels, so it cannot prove which
    # was read. This fixture has 120x60 bounds against a 300x200 device.
    it "reads bounds, not the reference device" do
      expect(inspect_emf("distinct_device")).to have_attributes(width: 120.0, height: 60.0)
    end
  end

  describe "dpi" do
    it "derives it from the device pair" do
      expect(inspect_emf("valid").dpi).to eq(97.69)
    end

    # A single derived expectation still passes a hardcoded 97.69.
    it "is not a constant" do
      expect(inspect_emf("second_device").dpi).to eq(254.0)
    end

    # The baseline is 100x50 pixels over 26x13 millimetres: unequal on
    # both axes, and both ratios are 97.69. Comparing axes rather than
    # ratios would report no dpi for a perfectly square resolution.
    it "compares ratios, not axes" do
      expect(inspect_emf("valid").dpi).to eq(97.69)
      expect(inspect_emf("unequal_device").dpi).to be_nil
    end

    %w[zero_device_x zero_device_y].each do |name|
      it "is nil rather than raising for #{name.tr("_", " ")}" do
        expect { inspect_emf(name) }.not_to raise_error
        expect(inspect_emf(name).dpi).to be_nil
      end
    end

    # The zero check runs first, so the one-axis fixtures DO trigger it.
    # What they cannot do is detect it: take it away and the cross
    # product rejects them anyway, 100 x 13 against 50 x 0 for one and
    # 100 x 0 against 50 x 26 for the other. Both axes zero is the case
    # that detects it. There 0 == 0 reads as uniform, and the division
    # that follows gives Infinity, which `to_json` refuses outright
    # ("Infinity not allowed in JSON"). Measured: with only the one-axis
    # fixtures, dropping the zero check passed every example.
    it "is nil when both device_mm axes are zero" do
      bytes = File.binread(fixture("zero_device_both"))
      expect(bytes.byteslice(80, 8).unpack("VV")).to eq([0, 0])

      expect(inspect_emf("zero_device_both").dpi).to be_nil
    end

    # Without this the edits below rewrite whatever happens to sit at 72
    # and 80, and every example under them passes for the wrong reason.
    it "keeps the two device pairs where the edits below write" do
      bytes = File.binread(fixture("valid"))

      expect(bytes.byteslice(72, 8).unpack("l<l<")).to eq([100, 50])
      expect(bytes.byteslice(80, 8).unpack("l<l<")).to eq([26, 13])
    end

    # MS-EMF's SIZEL is signed and the delegate hands the fields back
    # signed, so a malformed file carries a negative dimension and the
    # division takes it. A non-zero check passes all three of these:
    # measured, they reported -97.69, -97.69 and 97.69 -- the last one
    # the baseline's own figure, out of four nonsense values whose signs
    # cancel in both the cross product and the division.
    {
      "device_mm is negative on both axes" => [[80, [-26, -13]]],
      "device_pixels is negative on both axes" => [[72, [-100, -50]]],
      "both pairs are negative, so the signs cancel" => [[72, [-100, -50]],
                                                         [80, [-26, -13]]]
    }.each do |label, pairs|
      it "is nil when #{label}" do
        expect(inspect_with_devices(pairs).dpi).to be_nil
      end
    end

    # Both axes, not just one. The three above negate width and height
    # together, so checking either axis alone passes all of them. These
    # two negate ONE axis on each pair, which keeps the cross product
    # balanced -- both reported 97.69 under a single-axis check, and the
    # height pair reports it out of a division that never touches the
    # negative numbers at all.
    {
      "only the widths are negative" => [[72, [-100, 50]], [80, [-26, 13]]],
      "only the heights are negative" => [[72, [100, -50]], [80, [26, -13]]]
    }.each do |label, pairs|
      it "is nil when #{label}" do
        expect(inspect_with_devices(pairs).dpi).to be_nil
      end
    end

    # Zero PIXELS is a separate case from zero millimetres: it divides
    # cleanly and reported a dpi of 0.0, a number that reads as a
    # measured resolution rather than a missing one. The zero_device
    # fixtures all zero the denominator, so none of them reaches it.
    it "is nil when both device_pixels axes are zero" do
      expect(inspect_with_devices([[72, [0, 0]]]).dpi).to be_nil
    end

    # Refusing to DERIVE a dpi is not refusing to REPORT the file. The
    # metadata still echoes what the header declares, so the fix cannot
    # be mistaken for scrubbing the fields.
    it "still reports the negative dimensions it refused to divide" do
      result = inspect_with_devices([[80, [-26, -13]]])

      expect(result.parse_status).to eq("ok")
      expect(result.meta).to include(
        "device_pixels" => { "width" => 100, "height" => 50 },
        "device_mm" => { "width" => -26, "height" => -13 }
      )
    end
  end

  # D17's line: the header parsed, whatever happened to the records.
  describe "a header that parses but a stream that does not" do
    %w[truncated_99 truncated_117].each do |name|
      it "reports ok for #{name}, identically to the intact file" do
        expect(inspect_emf(name).to_json).to eq(inspect_emf("valid").to_json)
      end
    end

    # truncated_117 and nsize_87 raise the SAME class with the SAME
    # message. Only a header-first pass can separate them.
    it "separates a bad stream from a bad header despite the same error" do
      %w[truncated_117 nsize_87].each do |name|
        expect { Emf.parse(File.binread(fixture(name))) }.to raise_error(IOError)
      end

      expect(inspect_emf("truncated_117").parse_status).to eq("ok")
      expect(inspect_emf("nsize_87").parse_status).to eq("failed")
    end
  end

  describe "inputs whose header cannot be read" do
    {
      "garbage" => Emf::FormatError, "empty" => Emf::FormatError,
      "truncated_44" => Emf::FormatError, "truncated_87" => Emf::FormatError,
      "nsize_44" => EOFError, "nsize_87" => IOError
    }.each do |name, raised|
      it "reports failed for #{name}, which raises #{raised}" do
        # The precondition is what proves each fixture is broken, and
        # broken in its OWN way: three different failures across six
        # files, rather than one defect copied six times.
        #
        # None of them reaches the delegate through the handler --
        # measured, `Emf.parse` is called zero times for all six,
        # because `declared_size` refuses them first. That is the
        # header-first pass working, and it is why `PARSE_FAILURES`
        # names only `Emf::Error`: the IO failures below belong to
        # parsing the whole stream, which the handler never does.
        expect { Emf.parse(File.binread(fixture(name))) }.to raise_error(raised)
        expect(inspect_emf(name).parse_status).to eq("failed")
      end
    end

    # Under eight bytes there is no size field to read at all, and the
    # length guard is what keeps `unpack1` safe. SEVEN, because it is
    # the longest such file: `byteslice(4, 4)` hands back three bytes,
    # `unpack1("V")` gives nil, and the comparison after it raises
    # NoMethodError. No fixture reaches the gap -- `empty.emf` is 0
    # bytes and `garbage.emf` is 17.
    #
    # Only the part below eight is load-bearing, and deliberately so:
    # weakening the guard to `< 8` changes nothing observable, because
    # `declared >= 88` and `declared <= bytesize` between them already
    # refuse every shorter file. Measured, that weakening passed every
    # example, and it is an equivalent mutant rather than a gap.
    it "reports failed for a file too short to hold a size field" do
      image = Claricle::Image.from_content("\x01\x00\x00\x00\x58\x00\x00".b,
                                           format: :emf)

      expect(handler.inspection(image).parse_status).to eq("failed")
    end
  end

  # EMF control-record sizes are multiples of four. Measured: with
  # nSize 109 the delegate parses the prefix, reports ok? true and the
  # full baseline metadata, while the record stream is framed from an
  # impossible offset.
  # 109 is odd and 110 is even, so the pair is what pins the modulus:
  # measured, a `% 2` guard accepts 110 and passes every other example.
  [109, 110].each do |declared|
    it "refuses a header declaring #{declared}, which is not four-byte aligned" do
      bytes = File.binread(fixture("valid")).dup
      bytes[4, 4] = [declared].pack("V")
      expect(Emf.parse(bytes.byteslice(0, declared)).ok?).to be(true)

      image = Claricle::Image.from_content(bytes, format: :emf)
      expect(handler.inspection(image).parse_status).to eq("failed")
    end
  end

  # MS-EMF puts an optional UTF-16LE description straight after the
  # fixed 88-byte header, so nSize legitimately lands on 92 or 96.
  # An nSize above 88 makes emf 0.1.0 read the Win95 optional header
  # fields -- twelve more bytes -- so it wants a full 100 and raises
  # EOFError on both of these: on the declared prefix AND on the full
  # stream, which is why re-slicing cannot fix it. The handler parses
  # the fixed 88 bytes with nSize normalised instead.
  [["described_92", 92], ["described_96", 96]].each do |name, declared|
    it "reads a standards-valid header declaring #{declared}" do
      bytes = File.binread(fixture(name))
      expect(bytes.byteslice(4, 4).unpack1("V")).to eq(declared)
      expect { Emf.parse(bytes) }.to raise_error(EOFError)
      expect { Emf.parse(bytes.byteslice(0, declared)) }.to raise_error(EOFError)

      expect(inspect_emf(name)).to have_attributes(
        parse_status: "ok", width: 100.0, height: 50.0, dpi: 97.69
      )
    end
  end

  # 84 is the nearest ALIGNED size below the fixed 88, so it is the one
  # value that isolates the minimum from the alignment rule next to it.
  # Measured: with the minimum weakened to 84 every other example still
  # passed, and this file reported ok -- for a header declaring four
  # fewer bytes than the 88 the delegate is then handed.
  it "refuses a header declaring 84, an aligned size below the fixed 88" do
    bytes = File.binread(fixture("valid")).dup
    bytes[4, 4] = [84].pack("V")

    image = Claricle::Image.from_content(bytes, format: :emf)
    expect(handler.inspection(image).parse_status).to eq("failed")
  end

  # The declared size must fit in what is actually there. An aligned
  # header claiming 100 bytes with 99 present isolates that guard from
  # the alignment and minimum checks beside it.
  it "refuses a header declaring more bytes than the file holds" do
    bytes = File.binread(fixture("declared_100_have_99"))
    expect(bytes.bytesize).to eq(99)
    expect(bytes.byteslice(4, 4).unpack1("V")).to eq(100)

    expect(inspect_emf("declared_100_have_99").parse_status).to eq("failed")
  end

  # The accepting edge of that same rule: the bound is `declared > what
  # is there`, never `>=`, because a header may be the whole file. The
  # baseline's first 88 bytes are exactly that, and with the comparison
  # weakened they report failed while every other example still passes.
  it "accepts a header that is the entire file" do
    bytes = File.binread(fixture("valid")).byteslice(0, 88)
    expect(bytes.byteslice(4, 4).unpack1("V")).to eq(bytes.bytesize)

    image = Claricle::Image.from_content(bytes, format: :emf)
    expect(handler.inspection(image)).to have_attributes(
      parse_status: "ok", width: 100.0, height: 50.0
    )
  end

  describe "the complete inspection" do
    it "is pinned exactly for a readable header" do
      inspection = inspect_emf("valid")

      expect(inspection).to have_attributes(
        format: "emf", width: 100.0, height: 50.0, dpi: 97.69,
        color_space: nil, parse_status: "ok"
      )
      expect(inspection.issues).to be_empty
      expect(inspection.meta).to eq(
        "frame" => { "width" => 2645, "height" => 1322 },
        "device_pixels" => { "width" => 100, "height" => 50 },
        "device_mm" => { "width" => 26, "height" => 13 },
        "n_records" => 17, "n_handles" => 4, "emf_plus_present" => false
      )
    end

    it "is pinned exactly for an unreadable one" do
      inspection = inspect_emf("garbage")

      expect(inspection).to have_attributes(
        format: "emf", width: nil, height: nil, dpi: nil,
        color_space: nil, meta: nil, parse_status: "failed"
      )
      expect(inspection.issues.map { |i| [i.severity, i.code, i.message] })
        .to eq([["error", "emf.header_unreadable", "EMF header could not be read"]])
    end
  end

  describe "metadata types" do
    # The delegate hands back BinData wrappers. They behave like Integers
    # in Ruby but render as JSON strings, so an uncoerced n_records
    # serializes as "17" rather than 17.
    # EVERY nested scalar. Measured: removing the coercion from only the
    # two device hashes passed every example when this checked frame,
    # n_records and n_handles alone, while JSON rendered "width":"100".
    it "coerces every scalar to a primitive" do
      meta = inspect_emf("valid").meta
      scalars = meta.values.flat_map { |v| v.is_a?(Hash) ? v.values : [v] }

      expect(scalars.grep_v(true.class).grep_v(false.class)).to all(be_an(Integer))
    end

    it "renders every number as a number through JSON" do
      json = inspect_emf("valid").to_json

      expect(json).to include('"n_records":17', '"n_handles":4')
      expect(json).to include('"width":100', '"width":26', '"width":2645')
      expect(json).not_to match(/"width":"/)
    end
  end

  describe "EMF+" do
    it "reports absence on a plain EMF" do
      expect(inspect_emf("valid").meta).to include("emf_plus_present" => false)
      expect(inspect_emf("valid").meta).not_to have_key("emf_plus_bytes")
    end

    # A standards-derived carrier: two comments, so the byte count proves
    # concatenated size rather than first-comment size.
    it "reports presence and the concatenated payload size" do
      meta = inspect_emf("emf_plus").meta

      expect(meta).to include("emf_plus_present" => true, "emf_plus_bytes" => 40)
    end

    it "still reports the outer format as emf" do
      expect(inspect_emf("emf_plus").format).to eq("emf")
    end

    # The plan requires an INDEPENDENT oracle, and this is it. Asking the
    # parser for presence and 40 bytes proves nothing about the stream:
    # measured, changing the nested header type from 0x4001 to 0xFFFF
    # left every other example in this file passing.
    it "carries a structurally valid EMF+ stream, checked without the parser" do
      bytes = File.binread(fixture("emf_plus"))
      comments = []
      offset = 0
      while offset + 8 <= bytes.bytesize
        type, size = bytes[offset, 8].unpack("VV")
        break if size.nil? || size.zero?

        if type == 70
          comments << [offset, size, bytes[offset + 8, 4].unpack1("V"),
                       bytes[offset + 12, size - 12]]
        end
        offset += size
      end

      # The outer framing goes first, so the nested reads below cannot
      # be taken from a stream that has drifted. It is the NESTED fields
      # that nothing else in this file constrains: measured, setting the
      # header record's type to 0xFFFF and its DataSize to 99 left every
      # other example passing, while moving one outer cbData by four
      # failed eleven of them.
      expect(comments.map { |off, size, cb, data| [off, size, cb, data.bytesize] })
        .to eq([[88, 44, 32, 32], [388, 28, 16, 16]])

      header, eof = comments.map(&:last)
      expect(header[0, 4]).to eq("EMF+")
      # Type, Flags, Size, DataSize -- the record's own lengths, which a
      # type-and-size assertion leaves free.
      expect(header[4, 12].unpack("vvVV")).to eq([0x4001, 0x0000, 28, 16])
      expect(header[16, 16].unpack("VVVV")).to eq([0xDBC01002, 0x00000001, 96, 96])
      expect(eof[0, 4]).to eq("EMF+")
      expect(eof[4, 12].unpack("vvVV")).to eq([0x4002, 0x0000, 12, 0])
    end

    # The payload is packed binary. Carrying it would make to_json raise
    # under the tag it actually has: measured, BINARY, UTF-8 and UTF-16LE
    # all raise JSON::GeneratorError. ISO-8859-1 is the exception and not
    # a reprieve -- every byte is a valid character there, so it
    # serialises, and what comes out is mojibake rather than the bytes.
    # A count avoids both outcomes.
    it "never carries the payload itself" do
      meta = inspect_emf("emf_plus").meta

      expect(meta.keys).to contain_exactly(
        "frame", "device_pixels", "device_mm", "n_records", "n_handles",
        "emf_plus_present", "emf_plus_bytes"
      )
      expect { inspect_emf("emf_plus").to_json }.not_to raise_error
    end
  end

  describe "what it reads from" do
    # Pass one always gets the fixed 88 bytes with nSize normalised to
    # 88, whatever the stream declares. Asserted on two fixtures whose
    # declared sizes differ, so an implementation that slices the
    # declared prefix fails on one of them.
    [["valid", 88], ["header_100", 100]].each do |name, declared|
      it "gives pass one the normalised fixed header, declared #{declared}" do
        image = Claricle::Image.from_content(File.binread(fixture(name)), format: :emf)
        seen = []

        allow(Emf).to receive(:parse).and_wrap_original do |original, arg|
          seen << arg
          original.call(arg)
        end
        handler.inspection(image)

        expect(image.content.byteslice(4, 4).unpack1("V")).to eq(declared)
        expect(seen.first.bytesize).to eq(88)
        expect(seen.first.byteslice(4, 4).unpack1("V")).to eq(88)
        expect(seen.first.byteslice(8, 80)).to eq(image.content.byteslice(8, 80))
      end
    end

    # The normalisation must not reach the caller's string, and pass two
    # must see the stream as it arrived.
    it "leaves the image's own content untouched" do
      bytes = File.binread(fixture("header_100"))
      image = Claricle::Image.from_content(bytes.dup, format: :emf)

      handler.inspection(image)

      expect(image.content).to eq(bytes)
    end

    # Both passes must read the SAME snapshot. Equality assertions allow a
    # handler to re-read the file for one pass and use the cache for the
    # other, which is an inconsistent pair if the file changes underneath.
    # Pinning the identity of pass two still leaves pass one free, so the
    # re-read itself is what gets prohibited.
    it "never re-reads the file once the content is cached" do
      image = Claricle::Image.from_path(fixture("valid"))
      image.content

      allow(File).to receive(:binread).and_call_original
      handler.inspection(image)

      expect(File).not_to have_received(:binread)
    end

    # The delegate is asked exactly once, for the header. There is no
    # second full-stream pass: emf 0.1.0 does not parse EMF+ (its EMF+
    # parser is unimplemented), it crashes on a comment whose cbData
    # overruns its record, and it cannot read the described headers at
    # all -- so the marker is found by walking the framing instead.
    %i[path content].each do |origin|
      it "calls the delegate exactly once, from #{origin}" do
        image = if origin == :path
                  Claricle::Image.from_path(fixture("emf_plus"))
                else
                  Claricle::Image.from_content(File.binread(fixture("emf_plus")),
                                               format: :emf)
                end
        seen = []

        allow(Emf).to receive(:parse).and_wrap_original do |original, arg|
          seen << arg
          original.call(arg)
        end
        expect(image).not_to receive(:with_path)

        result = handler.inspection(image)

        expect(seen.length).to eq(1)
        expect(seen.first.bytesize).to eq(88)
        expect(result.meta).to include("emf_plus_present" => true,
                                       "emf_plus_bytes" => 40)
      end
    end
  end

  describe "the EMF+ probe's framing rules" do
    # The crash this replaced: a comment declaring four bytes of payload
    # in a twelve-byte record. The outer framing is perfect -- aligned,
    # in bounds, EOF intact -- so an outer-framing check alone passes it.
    # emf 0.1.0 raises NoMethodError here, from an extraction step that
    # checks cbData >= 4 without checking four bytes are present.
    it "survives a comment whose cbData overruns its own record" do
      bytes = File.binread(fixture("bad_comment"))
      expect { Emf.parse(bytes) }.to raise_error(NoMethodError)

      expect(inspect_emf("bad_comment")).to have_attributes(
        parse_status: "ok", width: 100.0, height: 50.0
      )
      expect(inspect_emf("bad_comment").meta)
        .to include("emf_plus_present" => false)
    end

    # A record too short to hold a comment's own header, standing LAST
    # in the stream. The outer framing is fine -- 8 bytes is a whole
    # record header, aligned and in bounds -- so only the comment
    # minimum stops it. It has to be last: anywhere else the four bytes
    # after the record header belong to the next record and read as a
    # cbData that fails the bound anyway. Here there are no bytes at
    # all, so `unpack1` gives nil and the bound raises NoMethodError.
    # The two carriers before it are intact and must still be reported.
    it "reads no payload from a comment record too short to hold one" do
      bytes = File.binread(fixture("short_comment"))
      expect(bytes.byteslice(416, 8).unpack("VV")).to eq([70, 8])
      expect(bytes.bytesize).to eq(424)

      expect(inspect_emf("short_comment").meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 40)
    end

    # Each of these leaves a real carrier REACHABLE from where a
    # weakened guard advances to, so the fixture separates the guard
    # from its neighbours rather than merely ending in "no EMF+" like
    # everything else. Measured: with size 13 and size 0 alone,
    # weakening the alignment to `% 2` or the minimum to a zero-only
    # check still passed every example.
    it "refuses a record size that is even but not four-byte aligned" do
      bytes = File.binread(fixture("record_size_10"))
      expect(bytes.byteslice(88, 8).unpack("VV")).to eq([40, 10])
      expect(bytes.byteslice(98, 4).unpack1("V")).to eq(70)

      expect(inspect_emf("record_size_10").meta)
        .to include("emf_plus_present" => false)
    end

    # Size 4 cannot put a carrier where the weakened walk lands. 88 + 4
    # is the record's own size FIELD, so the type read there is 4, and
    # a comment would have to declare its size as 70. It takes two hops
    # instead: that field frames a 28-byte record, which lands on a
    # real carrier at 120. Measured: with the carrier at 96, weakening
    # the minimum to a zero-only check still passed every example.
    it "refuses a record too small to hold its own header" do
      bytes = File.binread(fixture("record_size_4"))
      expect(bytes.byteslice(88, 8).unpack("VV")).to eq([40, 4])
      expect(bytes.byteslice(92, 8).unpack("VV")).to eq([4, 28])
      expect(bytes.byteslice(120, 4).unpack1("V")).to eq(70)

      expect(inspect_emf("record_size_4").meta)
        .to include("emf_plus_present" => false)
    end

    it "reports no EMF+ for a record running past the end of the stream" do
      bytes = File.binread(fixture("emf_plus")).dup
      bytes[88, 8] = [70, 4096].pack("VV")

      image = Claricle::Image.from_content(bytes, format: :emf)
      result = handler.inspection(image)

      expect(result.parse_status).to eq("ok")
      expect(result.meta).to include("emf_plus_present" => false)
      expect(result.meta).not_to have_key("emf_plus_bytes")
    end

    # Each of these fixtures is built so the WRONG behaviour is
    # observable. Corrupting a byte is not enough: dropping a guard
    # usually still ends in "no EMF+", which is the same answer the
    # guard produces. Every one of these was measured to survive the
    # matching mutation before the fixture existed.
    #
    # cbData reaches past the record into the next one, and the bytes it
    # would read start with the EMF+ signature. Unbounded, the probe
    # reports 4 bytes of EMF+ that the file never declared.
    it "refuses a comment whose cbData overruns its own record" do
      result = inspect_emf("overrun_comment")

      expect(result.parse_status).to eq("ok")
      expect(result.meta).to include("emf_plus_present" => false)
    end

    # A misaligned record size, with a well-formed EMF+ carrier sitting
    # at the misaligned offset. Without the alignment rule the walk lands
    # on it and reports EMF+.
    it "refuses a record whose size is not four-byte aligned" do
      expect(inspect_emf("misaligned_record").meta)
        .to include("emf_plus_present" => false)
    end

    # A record declaring size zero. Without the minimum-size rule the
    # walk never advances, so this fails by hanging rather than by
    # returning something wrong.
    it "refuses a record declaring no size at all, without looping" do
      result = Timeout.timeout(5) { inspect_emf("zero_record") }

      expect(result.meta).to include("emf_plus_present" => false)
    end

    # The signature is checked, not assumed. Breaking only the FIRST
    # carrier proves it: the second still counts, so the total drops
    # from 40 to that carrier alone rather than to zero. Asserting
    # "present is false" here would have been wrong, and asserting the
    # remaining count is what pins per-comment checking.
    it "ignores a comment that is not an EMF+ carrier" do
      bytes = File.binread(fixture("emf_plus")).dup
      bytes[100, 4] = "XXXX".b

      image = Claricle::Image.from_content(bytes, format: :emf)

      expect(handler.inspection(image).meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 12)
    end

    it "reports no EMF+ when every carrier signature is broken" do
      bytes = File.binread(fixture("emf_plus")).dup
      bytes[100, 4] = "XXXX".b
      bytes[400, 4] = "XXXX".b

      image = Claricle::Image.from_content(bytes, format: :emf)

      expect(handler.inspection(image).meta)
        .to include("emf_plus_present" => false)
    end

    # MS-EMF excludes alignment padding from the declared payload. Both
    # carriers in emf_plus.emf are padding-free -- 44 = 12 + 32 and
    # 28 = 12 + 16 -- so `size - 16` gives the same 40 there and the
    # mutation survives. This record has 8 bytes of room and declares 5,
    # so only 1 byte is EMF+ payload after the signature.
    #
    # The delegate disagrees, and is wrong: it reports 4 for this file,
    # counting the padding. That is a third thing emf 0.1.0 gets wrong
    # about EMF+, after the unimplemented parser and the cbData crash.
    it "excludes alignment padding from the payload count" do
      expect(Emf.parse(File.binread(fixture("padded_comment"))).emf_plus.bytesize)
        .to eq(4)

      expect(inspect_emf("padded_comment").meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 1)
    end

    # The declared cbData is what counts, not the record's own size.
    # NEITHER carrier here is padded -- 44 = 12 + 32 and 28 = 12 + 16 --
    # so what this separates is the record and marker overhead: summing
    # sizes gives 72 where the declared payloads give 40. Padding is
    # `padded_comment.emf`'s job, above.
    it "counts declared payload rather than whole record size" do
      expect(inspect_emf("emf_plus").meta["emf_plus_bytes"]).to eq(40)
    end

    # EMR_EOF is Type, Size, nPalEntries, offPalEntries and SizeLast, so
    # 20 bytes is its minimum. A shorter type-14 record is not an end of
    # stream: the delegate records it as Raw and keeps going, and the
    # carrier after it is real. Treating any type-14 as EOF loses it.
    # 16 is the nearest aligned size below 20, so it is the value that
    # separates the correct minimum from a plausible wrong one: with a
    # 16-byte minimum the size-12 fixture still passes and this one does
    # not.
    [["short_eof", 12], ["short_eof_16", 16]].each do |name, declared|
      it "does not treat a type-14 record of #{declared} bytes as end of stream" do
        bytes = File.binread(fixture(name))
        expect(bytes.byteslice(88, 8).unpack("VV")).to eq([14, declared])
        expect(Emf.parse(bytes).emf_plus.bytesize).to eq(12)

        expect(inspect_emf(name).meta)
          .to include("emf_plus_present" => true, "emf_plus_bytes" => 12)
      end
    end

    # The size cap bounds the WALK, not the header. Applying it earlier
    # turned a fully framed 209 MB EMF with a readable header into
    # "failed", which is the header-first contract inverted.
    #
    # Driven through the PUBLIC handler with a stubbed bytesize rather
    # than a 200 MB fixture: a module-level test leaves the cap free to
    # come back inside declared_size, where it would fail the header
    # again. The dimensions are asserted on both sides of the boundary,
    # which is the half that actually pins the contract.
    it "reads the header for a stream at the scan limit" do
      content = File.binread(fixture("emf_plus"))
      content.define_singleton_method(:bytesize) { 209_715_200 }
      # Frozen AFTER the singleton is defined: Image hands back the
      # caller's own object only when it is already frozen and binary,
      # and a copy would drop the singleton and defeat this test.
      content.freeze
      image = Claricle::Image.from_content(content, format: :emf)

      result = handler.inspection(image)

      expect(result).to have_attributes(parse_status: "ok", width: 100.0,
                                        height: 50.0)
      expect(result.meta).to include("emf_plus_present" => true,
                                     "emf_plus_bytes" => 40)
    end

    # Over the limit the walk does not run, so the EMF+ keys are ABSENT
    # rather than false. Reporting false would claim something about
    # bytes nobody read: measured, a fully framed 200 MiB stream with
    # `EMF+` at byte 100 was reported as having none.
    it "reports no EMF+ verdict at all for a stream over the scan limit" do
      content = File.binread(fixture("emf_plus"))
      content.define_singleton_method(:bytesize) { 209_715_201 }
      # Frozen AFTER the singleton is defined: Image hands back the
      # caller's own object only when it is already frozen and binary,
      # and a copy would drop the singleton and defeat this test.
      content.freeze
      image = Claricle::Image.from_content(content, format: :emf)

      result = handler.inspection(image)

      expect(result).to have_attributes(parse_status: "ok", width: 100.0,
                                        height: 50.0)
      expect(result.meta).not_to have_key("emf_plus_present")
      expect(result.meta).not_to have_key("emf_plus_bytes")
    end

    # The absent keys alone do not prove the walk was SKIPPED: move the
    # limit check below `walk` and the answer is still nil, while the
    # CPU bound the limit exists for is gone. Measured, that rearranged
    # version passed both examples above.
    #
    # So the skipped work is made observable by making it fail. This
    # stream has no EMR_EOF and its real length is 116 bytes, while the
    # stubbed one is over the limit -- so a walk that ran would read
    # past the real end, `unpack("VV")` would give nil for the size, and
    # the comparison would raise NoMethodError. Returning quietly is the
    # assertion.
    it "does not walk a stream over the scan limit at all" do
      content = stream_of(carrier(12))
      expect(content.bytesize).to eq(116)
      content.define_singleton_method(:bytesize) { 209_715_201 }
      # Frozen AFTER the singleton is defined: Image hands back the
      # caller's own object only when it is already frozen and binary,
      # and a copy would drop the singleton and defeat this test.
      content.freeze
      image = Claricle::Image.from_content(content, format: :emf)

      result = nil
      expect { result = handler.inspection(image) }.not_to raise_error
      expect(result.meta).not_to have_key("emf_plus_present")
    end

    # EMF+ travels in EMR_COMMENT and nowhere else. This record is type
    # 38, well framed, and its bytes read as a comment look exactly like
    # a carrier -- cbData 16 at +8 and "EMF+" at +12 -- so a walk that
    # skips the type check counts 12 bytes the file never declared as
    # EMF+. Every other fixture's non-comment records fail the cbData
    # bound by accident, which is why this one has to be built.
    it "reads EMF+ only out of comment records" do
      bytes = File.binread(fixture("comment_shaped_record"))
      expect(bytes.byteslice(88, 8).unpack("VV")).to eq([38, 28])
      expect(bytes.byteslice(100, 4)).to eq("EMF+".b)

      expect(inspect_emf("comment_shaped_record").meta)
        .to include("emf_plus_present" => false)
    end

    # An overrun cbData is not broken FRAMING. MS-EMF keeps the
    # whole-record Size and the inner DataSize separate, and the outer
    # size was already validated as aligned and in bounds, so it still
    # proves where the next record begins. This stream's first carrier
    # overruns and has a broken marker while its SECOND is intact:
    # stopping there reported no EMF+ for a file the delegate reads as
    # carrying 12 bytes.
    it "keeps walking past a comment whose cbData overruns" do
      expect(Emf.parse(File.binread(fixture("overrun_then_carrier"))).emf_plus.bytesize)
        .to eq(12)

      expect(inspect_emf("overrun_then_carrier").meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 12)
    end

    # A break in the framing stops the walk; it does not erase what the
    # walk already validated. This stream's two carriers are intact and
    # its final EMR_EOF declares nSize 0. Discarding the total reported
    # no EMF+ for a file the delegate reads as carrying 40 bytes --
    # a false negative about a fact we had already established.
    it "keeps a validated total when the framing breaks after it" do
      expect(Emf.parse(File.binread(fixture("broken_suffix"))).emf_plus.bytesize)
        .to eq(40)

      expect(inspect_emf("broken_suffix").meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 40)
    end

    # The walk starts at the DECLARED header size. This fixture puts an
    # EMF+ carrier immediately after a 92-byte described header, so a
    # walk starting at a fixed 88 reads the description as a record and
    # loses the carrier entirely.
    it "starts the walk after a described header, not at byte 88" do
      expect(inspect_emf("described_emf_plus").meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 12)
    end

    # An EMF+ carrier placed after EMR_EOF is not part of the stream.
    it "stops at EMR_EOF rather than reading past it" do
      expect(inspect_emf("after_eof").meta)
        .to include("emf_plus_present" => false)
    end

    # The guards above are all pinned from the REFUSING side. These seven
    # pin the other edge -- the largest thing each rule must still
    # accept, and the smallest overrun it must still reject. Each was
    # mutation-checked on its own rule: the weakening was applied, this
    # example went red, and nothing outside this group did.

    # Eight bytes is a whole record: EMR_SAVEDC is a type and a size and
    # nothing else. The minimum has to ADMIT it. Weakened to
    # `size <= RECORD_HEADER_BYTES` the walk stops here and loses the
    # carrier behind it.
    it "walks past a record that is exactly a header long" do
      save_dc = [33, 8].pack("VV")

      expect(inspect_stream(save_dc, carrier(12)).meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 12)
    end

    # The in-bounds rule is `size > what is left`, never `>=`: a record
    # may end on the last byte of the file. This carrier does, with no
    # EMR_EOF behind it, so weakening the comparison drops it.
    it "accepts a record that ends exactly at the last byte" do
      expect(stream_of(carrier(12)).bytesize).to eq(116)

      expect(inspect_stream(carrier(12)).meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 12)
    end

    # A stream can stop part-way through a record HEADER, and eight
    # bytes is what the walk needs to read one. SEVEN is the value that
    # pins it -- the largest partial header there is, so every weaker
    # minimum admits it. `truncated_117` leaves exactly one trailing
    # byte, which any positive minimum already refuses, and two bytes
    # only reaches a `< 2`. At seven, `byteslice` hands back a short
    # string, `unpack("VV")` gives nil for the size, and the comparison
    # raises NoMethodError instead of keeping the 12 bytes already
    # validated.
    it "keeps its total when the stream ends mid record header" do
      bytes = stream_of(carrier(12)) + ("\x00".b * 7)
      image = Claricle::Image.from_content(bytes, format: :emf)

      expect(handler.inspection(image).meta)
        .to include("emf_plus_present" => true, "emf_plus_bytes" => 12)
    end

    # 20 bytes is EMR_EOF's MINIMUM, not its size: a writer may pad it,
    # and a bigger one still closes the stream. Weakened to
    # `size == EOF_RECORD_BYTES` the walk runs straight through this
    # 24-byte EOF into the carrier behind it and reports 12 bytes that
    # are not part of the stream. The delegate agrees: it reads that
    # carrier as trailing data and reports no EMF+ at all.
    it "treats an EMR_EOF larger than the minimum as end of stream" do
      eof = [14, 24, 0, 20, 24, 0].pack("V6")
      expect(Emf.parse(stream_of(eof, carrier(12))).emf_plus).to be_nil

      expect(inspect_stream(eof, carrier(12)).meta)
        .to include("emf_plus_present" => false)
    end

    # One byte over, not four. `overrun_comment.emf` and the 4096-byte
    # record above both overrun by enough that an off-by-one bound still
    # rejects them. This record declares 20 with 19 left, and with the
    # bound one byte loose it reported four payload bytes where three
    # are present.
    it "refuses a record that overruns the stream by a single byte" do
      comment = [70, 20, 8].pack("VVV") + "EMF+ABC".b
      expect(stream_of(comment).bytesize).to eq(107)

      expect(inspect_stream(comment).meta).to include("emf_plus_present" => false)
    end

    # The same edge one level down. `overrun_comment.emf` overruns its
    # record by four, so a `cbData` bound one byte loose still rejects
    # it. This comment has room for four and declares five, and with the
    # bound loosened it reported one byte the record does not hold.
    it "refuses a comment whose cbData overruns by a single byte" do
      comment = [70, 16, 5].pack("VVV") + "EMF+".b
      eof = [14, 20, 0, 0, 20].pack("VVVVV")

      expect(inspect_stream(comment, eof).meta)
        .to include("emf_plus_present" => false)
    end

    # The `cbData` minimum is a correctness guard, not a fast path: the
    # signature is sliced from the RECORD rather than from the declared
    # run, so a comment declaring fewer than four bytes still gets four
    # read out of it and matches, and the subtraction goes negative.
    # THREE, because it is the largest value the minimum has to refuse:
    # a `cbData` of 1 is also refused by a minimum weakened to 3, and
    # measured, that weakening passed every other example while
    # reporting `emf_plus_bytes` -1 for this stream.
    it "reads no payload from a comment declaring less than the marker" do
      comment = [70, 16, 3].pack("VVV") + "EMF+".b
      meta = inspect_stream(comment).meta

      expect(meta).to include("emf_plus_present" => false)
      expect(meta).not_to have_key("emf_plus_bytes")
    end
  end

  # Nothing guarantees the tag on a String of raw bytes, and the
  # delegate reads these bytes correctly whatever it says. `String#[]=`
  # indexes by CHARACTER, so normalising nSize on a UTF-16LE-tagged
  # string raised Encoding::CompatibilityError on a perfectly good EMF.
  # UTF-8 and ASCII-8BIT both passed, which is why a single-encoding
  # example missed it.
  describe "encoding tags on the same bytes" do
    %w[ASCII-8BIT UTF-8 UTF-16LE UTF-16BE ISO-8859-1].each do |encoding|
      it "reads an EMF tagged #{encoding}" do
        bytes = File.binread(fixture("emf_plus")).dup.force_encoding(encoding)
        image = Claricle::Image.from_content(bytes, format: :emf)

        expect(handler.inspection(image)).to have_attributes(
          parse_status: "ok", width: 100.0, height: 50.0
        )
        expect(handler.inspection(image).meta)
          .to include("emf_plus_present" => true, "emf_plus_bytes" => 40)
      end
    end
  end

  # The header rescue itself, driven directly. Every malformed fixture
  # fails the declared-size check before the delegate is called, so the
  # rescue arm had no coverage of its own -- it was reachable only in
  # principle.
  describe "the header parse rescue" do
    it "reports failed when the delegate raises Emf::Error" do
      allow(Emf).to receive(:parse).and_raise(Emf::FormatError, "from the header")

      expect(inspect_emf("valid").parse_status).to eq("failed")
    end

    it "reports failed for a bare Emf::Error too" do
      allow(Emf).to receive(:parse).and_raise(Emf::Error, "from the header")

      expect(inspect_emf("valid").parse_status).to eq("failed")
    end
  end

  describe "errors it must not swallow" do
    it "propagates an off-allowlist error" do
      allow(Emf).to receive(:parse).and_raise(NoMethodError, "delegate defect")

      expect { inspect_emf("valid") }.to raise_error(NoMethodError)
    end

    # The rescue wraps the delegate read only, as PNG's does. A
    # method-wide rescue would also swallow this.
    #
    # The delegate here is a real parsed metafile with one field
    # stubbed, not a stand-in built to shape. The plan requires that
    # ("Real specs, no `double()`"), and it is the stronger test: a
    # stand-in wired to return a fixed header would keep passing even
    # if `header` stopped handing back the same object twice.
    it "propagates an IOError raised after the parse" do
      metafile = Emf.parse(File.binread(fixture("valid")))
      allow(metafile.header).to receive(:n_records).and_raise(IOError, "not input")
      allow(Emf).to receive(:parse).and_return(metafile)

      expect { inspect_emf("valid") }.to raise_error(IOError)
    end
  end

  it "loads alone and runs an inspection" do
    script = <<~RUBY
      require "claricle/handlers/metafile"
      handler = Claricle.const_get(:Handlers).const_get(:Metafile).new
      image = Struct.new(:format, :content).new(:emf, File.binread(#{fixture("valid").inspect}))
      print handler.inspection(image).width
    RUBY
    lib = File.expand_path("../../../lib", __dir__)
    command = [RbConfig.ruby, "-I#{lib}", "-e", script]
    output = IO.popen(command, err: %i[child out], &:read)

    expect($CHILD_STATUS).to be_success, "handler could not load alone: #{output}"
    expect(output).to eq("100.0")
  end
end
