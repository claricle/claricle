# frozen_string_literal: true

require "png_conform"
require "zlib"

RSpec.describe "Claricle PNG handler" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Png).new }

  def fixture(name)
    File.join(__dir__, "..", "..", "fixtures", "inspect", name)
  end

  def inspect_file(name)
    handler.inspection(Claricle::Image.from_path(fixture(name)))
  end

  # Built in memory rather than as a fixture: the point is the chunk's
  # length, which is easier to read here than in a binary blob.
  def png_with_phys(payload)
    signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")
    header = [4, 3, 8, 6, 0, 0, 0].pack("NNC5")

    signature + chunk("IHDR", header) + chunk("pHYs", payload) + chunk("IEND", "")
  end

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  # `validate` returns the FileAnalysis itself, not a result wrapping one.
  def image_info(name)
    path = fixture(name)
    reader = PngConform::Readers::FullLoadReader.new(path)
    PngConform::Services::ValidationService.new(reader, path).validate.image_info
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
  end

  describe "error handling" do
    it "absorbs an allowlisted parse error into a failed status" do
      allow(PngConform::Readers::FullLoadReader).to receive(:new)
        .and_raise(Errno::ENOENT, "vanished")

      expect(inspect_file("valid.png").parse_status).to eq("failed")
    end

    # Measured: the reader raises EOFError here, which is not part of
    # png_conform's own hierarchy. Detection rejects empty bytes, so this
    # only reaches the handler through from_content -- where the caller
    # asserts the format. An empty file is unreadable, not a defect.
    it "reports an empty file as failed rather than raising" do
      image = Claricle::Image.from_content("", format: :png)

      expect(handler.inspection(image).parse_status).to eq("failed")
    end

    # A delegate defect is a defect. Absorbing it would report "this file
    # does not parse" for a file that parses fine.
    it "lets an off-allowlist error propagate" do
      allow(PngConform::Readers::FullLoadReader).to receive(:new)
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
end
