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
        # The precondition matters: without it the IO arms are never
        # actually exercised, since truncation and header mutation reach
        # the allowlist by different routes.
        expect { Emf.parse(File.binread(fixture(name))) }.to raise_error(raised)
        expect(inspect_emf(name).parse_status).to eq("failed")
      end
    end
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
    it "coerces every scalar to a primitive" do
      meta = inspect_emf("valid").meta

      expect(meta["n_records"]).to be_an(Integer)
      expect(meta["n_handles"]).to be_an(Integer)
      expect(meta["frame"].values).to all(be_an(Integer))
    end

    it "renders numbers as numbers through JSON" do
      expect(inspect_emf("valid").to_json).to include('"n_records":17')
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

    # The payload is packed binary. Carrying it, in any encoding, would
    # make to_json raise.
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
    # BOTH parse calls are pinned. Pass one necessarily receives the
    # declared-size prefix, so asserting only "parse received the
    # content" would be satisfied by pass one and prove nothing about
    # pass two.
    it "gives the full stream the exact content, from a path" do
      image = Claricle::Image.from_path(fixture("valid"))
      content = image.content

      expect(image).not_to receive(:with_path)
      expect(Emf).to receive(:parse).with(satisfy { |a| a.bytesize < content.bytesize })
                                    .and_call_original
      expect(Emf).to receive(:parse).with(content).and_call_original

      handler.inspection(image)
    end

    it "gives the full stream the exact content, from content" do
      image = Claricle::Image.from_content(File.binread(fixture("valid")), format: :emf)

      expect(image).not_to receive(:with_path)
      allow(Emf).to receive(:parse).and_call_original
      handler.inspection(image)

      expect(Emf).to have_received(:parse).with(image.content)
    end
  end

  describe "errors it must not swallow" do
    it "propagates an off-allowlist error" do
      allow(Emf).to receive(:parse).and_raise(NoMethodError, "delegate defect")

      expect { inspect_emf("valid") }.to raise_error(NoMethodError)
    end

    # The rescue wraps the delegate read only, as PNG's does. A
    # method-wide rescue would also swallow this.
    it "propagates an IOError raised after the parse" do
      header = Emf.parse(File.binread(fixture("valid"))).header
      allow(header).to receive(:n_records).and_raise(IOError, "not input")
      allow(Emf).to receive(:parse).and_return(instance_double(Emf::Model::Metafile,
                                                               header: header, emf_plus: nil))

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
    lib = File.expand_path("../../lib", __dir__)
    command = [RbConfig.ruby, "-I#{lib}", "-e", script]
    output = IO.popen(command, err: %i[child out], &:read)

    expect($CHILD_STATUS).to be_success, "handler could not load alone: #{output}"
    expect(output).to eq("100.0")
  end
end
