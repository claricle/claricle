# frozen_string_literal: true

require "tempfile"

RSpec.describe Claricle::Image do
  registry = Claricle.const_get(:Registry)
  handler_base = Claricle.const_get(:Handlers).const_get(:Base)
  png = File.binread(File.join(__dir__, "..", "fixtures", "detector", "valid.png"))

  with_file = lambda do |bytes, &block|
    Tempfile.create(["image", ".bin"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      block.call(file.path)
    end
  end

  # stub_const restores constants publicly; see registry_spec for the same
  # repair. Without it the privacy examples elsewhere become order-dependent.
  around do |example|
    example.run
  ensure
    begin
      registry.send(:private_constant, :HANDLERS)
    rescue NameError
      nil
    end
  end

  describe "construction" do
    it "detects from a path and keeps it" do
      with_file.call(png) do |path|
        image = described_class.from_path(path)
        expect(image.format).to eq(:png)
        expect(image.path).to eq(path)
      end
    end

    it "detects from content" do
      expect(described_class.from_content(png).format).to eq(:png)
    end

    # The caller taking responsibility, so it is not re-detected.
    it "honours an explicit format even against the bytes" do
      expect(described_class.from_content(png, format: :wmf).format).to eq(:wmf)
    end

    # :wmf is detectable with no handler behind it (01-core.md:88), so an
    # unregistered symbol must reach the registry rather than be refused here.
    it "accepts an unregistered format symbol" do
      expect(described_class.from_content(png, format: :nothing_handles_this).format)
        .to eq(:nothing_handles_this)
    end

    # false is not "no format given" -- only nil means detect.
    [["png", "a String"], [false, "false"], [1, "an Integer"]].each do |value, label|
      it "refuses #{label} as a format" do
        expect { described_class.from_content(png, format: value) }
          .to raise_error(ArgumentError, /must be a Symbol/)
      end
    end

    it "refuses bytes it cannot recognise from content" do
      expect { described_class.from_content("not an image") }
        .to raise_error(Claricle::UnknownFormat)
    end

    it "refuses bytes it cannot recognise from a path" do
      with_file.call("not an image") do |path|
        expect { described_class.from_path(path) }.to raise_error(Claricle::UnknownFormat)
      end
    end

    it "requires exactly one of path or content" do
      expect { described_class.new(format: :png) }
        .to raise_error(ArgumentError, /exactly one/)
      expect { described_class.new(format: :png, path: "x", content: "y") }
        .to raise_error(ArgumentError, /exactly one/)
    end
  end

  describe "#content" do
    # Detection reads the file; what must not happen is caching it at
    # construction. Deleting only after the first read would pass for an
    # eager constructor, so both halves are here.
    it "does not load the file until asked" do
      path = nil
      image = with_file.call(png) do |p|
        path = p
        described_class.from_path(p)
      end
      expect(File.exist?(path)).to be(false)
      expect(image.format).to eq(:png)
      expect { image.content }.to raise_error(Errno::ENOENT)
    end

    it "reads once and remembers" do
      with_file.call(png) do |path|
        image = described_class.from_path(path)
        expect(image.content).to eq(png)
        File.delete(path)
        expect(image.content).to eq(png)
      end
    end

    it "returns exactly the bytes a content-born image was given" do
      expect(described_class.from_content(png).content).to eq(png)
    end
  end

  describe "#with_path" do
    it "yields the real path and leaves it alone" do
      with_file.call(png) do |path|
        image = described_class.from_path(path)
        image.with_path { |yielded| expect(yielded).to eq(path) }
        expect(File.exist?(path)).to be(true)
      end
    end

    # CRLF is what binmode protects; on POSIX this cannot distinguish text
    # mode, but it would catch a regression where it matters.
    it "writes a content-born image byte-identically" do
      bytes = "#{png}\r\n\r\n".b
      image = described_class.from_content(bytes, format: :png)
      image.with_path do |path|
        expect(File.binread(path)).to eq(bytes)
      end
    end

    it "removes the temporary file afterwards" do
      captured = nil
      described_class.from_content(png).with_path do |path|
        captured = path
        # Without this, yielding an already-missing path would pass.
        expect(File.exist?(path)).to be(true)
      end
      expect(File.exist?(captured)).to be(false)
    end

    it "requires a block" do
      expect { described_class.from_content(png).with_path }
        .to raise_error(ArgumentError, /requires a block/)
    end

    it "removes it even when the block raises" do
      captured = nil
      expect do
        described_class.from_content(png).with_path do |path|
          captured = path
          expect(File.exist?(path)).to be(true)
          raise "boom"
        end
      end.to raise_error("boom")
      expect(File.exist?(captured)).to be(false)
    end
  end

  # Two separate contracts: the registry raises before any handler exists,
  # so only the populated case can prove forwarding.
  describe "dispatch" do
    it "raises from the registry for an unregistered format, naming it" do
      image = described_class.from_content(png, format: :nothing_handles_this)
      expect { image.inspection }
        .to raise_error(Claricle::UnsupportedFormat,
                        "format :nothing_handles_this is not supported")
    end

    context "with a handler registered" do
      recorder = Class.new(handler_base) do
        formats :png
        class << self
          attr_accessor :instances, :last
        end
        self.instances = 0
        def self.new(...)
          self.instances += 1
          self.last = super
        end
        attr_reader :seen, :target

        def inspection(image) = (@seen = image) && :inspected
        def conformance_report(image) = (@seen = image) && :conformed

        def convert(image, to:)
          @seen = image
          @target = to
          :converted
        end
      end

      before do
        recorder.instances = 0
        recorder.last = nil
        stub_const("#{registry}::HANDLERS", registry.send(:build, [recorder]))
      end

      it "hands inspection this very image and returns its result" do
        image = described_class.from_content(png)
        expect(image.inspection).to eq(:inspected)
        expect(recorder.last.seen).to equal(image)
      end

      it "hands conformance_report this very image and returns its result" do
        image = described_class.from_content(png)
        expect(image.conformance_report).to eq(:conformed)
        expect(recorder.last.seen).to equal(image)
      end

      # A truthy sentinel cannot show that nil comes back unchanged.
      it "forwards a nil result unchanged" do
        quiet = Class.new(handler_base) do
          formats :png
          def inspection(_image) = nil
        end
        stub_const("#{registry}::HANDLERS", registry.send(:build, [quiet]))
        expect(described_class.from_content(png).inspection).to be_nil
      end

      # The handler's own record, not just the return value: hardcoding
      # `to: :svg` inside convert would pass a return-value-only check.
      it "passes the conversion target through unchanged" do
        image = described_class.from_content(png)
        expect(image.convert(to: :eps)).to eq(:converted)
        expect(recorder.last.target).to eq(:eps)
        expect(recorder.last.seen).to equal(image)
      end

      it "hands the handler this very image, not a copy" do
        image = described_class.from_content(png)
        image.inspection
        expect(recorder.last.seen).to equal(image)
      end

      it "builds a handler per call rather than caching one" do
        image = described_class.from_content(png)
        image.inspection
        image.inspection
        expect(recorder.instances).to eq(2)
      end
    end
  end

  # An image is bytes. The encoding tag on a String handed to
  # from_content is an artifact of how the caller built it, and Detector
  # already discards it at its own entry -- so this is the same decision
  # applied to the bytes a handler actually reads.
  #
  # It lives here rather than in each handler because every handler goes
  # through this one method, and left to them two of two handlers that
  # touch raw bytes shipped the same bug: the EMF header indexed by
  # character, and the PostScript delegate raised
  # Encoding::CompatibilityError, both on files that are perfectly good.
  describe "#content encoding" do
    let(:bytes) { File.binread(File.join(__dir__, "..", "fixtures", "inspect", "valid.emf")) }

    %w[UTF-8 UTF-16LE UTF-16BE ISO-8859-1].each do |encoding|
      it "returns BINARY for content tagged #{encoding}" do
        tagged = bytes.dup.force_encoding(encoding)
        image = described_class.from_content(tagged, format: :emf)

        expect(image.content.encoding).to eq(Encoding::BINARY)
        expect(image.content.bytes).to eq(bytes.bytes)
      end

      it "leaves the caller's own string tagged #{encoding}" do
        tagged = bytes.dup.force_encoding(encoding)
        described_class.from_content(tagged, format: :emf).content

        expect(tagged.encoding).to eq(Encoding.find(encoding))
      end
    end

    it "returns BINARY from a path" do
      path = File.join(__dir__, "..", "fixtures", "inspect", "valid.emf")

      expect(described_class.from_path(path).content.encoding).to eq(Encoding::BINARY)
    end

    # Normalising must not re-copy on every read, or a handler holding
    # the result across two calls would be holding two objects.
    it "is the same object across repeated calls" do
      image = described_class.from_content(bytes.dup.force_encoding("UTF-8"), format: :emf)

      expect(image.content).to be(image.content)
    end

    # Already-binary content is passed through, not copied. That is
    # deliberate: it keeps the common path allocation-free and it is what
    # the handler specs' identity assertions rest on.
    it "hands back the caller's own object when it is already BINARY" do
      image = described_class.from_content(bytes, format: :emf)

      expect(image.content).to be(bytes)
    end
  end
end
