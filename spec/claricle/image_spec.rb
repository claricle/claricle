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
    registry.send(:private_constant, :HANDLERS)
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

    # `false` clears the exactly-one check and is still falsy, so it used
    # to build an image whose `content` went reading the nil path. Without
    # a format too, because detection reads the bytes first and would
    # otherwise answer with its own NoMethodError.
    it "refuses content that is not a String" do
      expect { described_class.from_content(false) }
        .to raise_error(ArgumentError, /content must be a String, got FalseClass/)
      expect { described_class.from_content(false, format: :png) }
        .to raise_error(ArgumentError, /content must be a String, got FalseClass/)
      expect { described_class.new(format: :png, content: 123) }
        .to raise_error(ArgumentError, /content must be a String, got Integer/)
    end

    # `path: false` used to clear the exactly-one check and then read as
    # "no path" in with_path, so the image took the temporary-file branch
    # and died on File.binread(false).
    it "refuses a path that is not a String" do
      expect { described_class.new(format: :png, path: false) }
        .to raise_error(ArgumentError, /path must be a String, got FalseClass/)
      expect { described_class.new(format: :png, path: 123) }
        .to raise_error(ArgumentError, /path must be a String, got Integer/)
    end

    # `File.open` takes a descriptor as happily as a name, so detecting
    # before the type check opened and closed the caller's IO. The
    # ArgumentError alone would pass either way -- it is the surviving
    # descriptor that pins the ordering.
    it "refuses a non-String path before anything opens it" do
      with_file.call(png) do |path|
        File.open(path, "rb") do |io|
          expect { described_class.from_path(io.fileno) }
            .to raise_error(ArgumentError, /path must be a String, got Integer/)
          expect(io.read(1)).to eq("\x89".b)
        end
      end
    end

    # The path is the other half of owning the bytes. Sharing the
    # caller's String let them repoint a detected image at another file:
    # format stayed :png while content came from somewhere else.
    it "keeps its own copy of the path it was given" do
      with_file.call(png) do |path|
        supplied = path.dup
        image = described_class.from_path(supplied)
        supplied.replace("/nonexistent")

        expect(image.path).to eq(path)
        expect(image.content).to eq(png)
      end
    end

    it "hands back a path nobody can rewrite in place" do
      with_file.call(png) do |path|
        image = described_class.from_path(path.dup)

        expect(image.path).to be_frozen
        expect { image.path << "-tampered" }.to raise_error(FrozenError)
      end
    end

    # Ruby's default Marshal reads the ivars straight back in without
    # running any of the guards, and it does not carry a String's freeze.
    # Measured on a copy made that way: `content.replace("NOT A PNG AT
    # ALL")` left it reporting :png over sixteen bytes of text, and
    # `path.replace("/etc/passwd")` pointed a path-born image at another
    # file. Nothing in this gem crosses a process boundary, so the dump is
    # refused rather than reimplemented.
    it "refuses to dump a content-born image" do
      expect { Marshal.dump(described_class.from_content(png)) }
        .to raise_error(TypeError, /cannot marshal Claricle::Image/)
    end

    it "refuses to dump a path-born image" do
      with_file.call(png) do |path|
        expect { Marshal.dump(described_class.from_path(path)) }
          .to raise_error(TypeError, /not marshalable/)
      end
    end

    it "refuses an image nested inside a plain container" do
      expect { Marshal.dump({ "a" => [described_class.from_content(png)] }) }
        .to raise_error(TypeError, /not marshalable/)
    end

    # Ruby prefers `marshal_dump` over `_dump` where both exist, so one
    # added later would silently displace the refusal. `marshal_load` was
    # a second constructor with none of the arity checks: handed another
    # image's state it took the new format and kept the old bytes.
    it "defines neither marshal hook that would displace the refusal" do
      %i[marshal_dump marshal_load].each do |hook|
        expect(described_class.method_defined?(hook)).to be(false)
        expect(described_class.private_method_defined?(hook)).to be(false)
      end
    end

    # Marshal reaches a private `_dump` -- measured -- so publishing it
    # would add surface and buy nothing.
    it "keeps _dump off its public surface" do
      expect(described_class.from_content(png)).not_to respond_to(:_dump)
      expect(described_class.private_method_defined?(:_dump)).to be(true)
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

    # `File.read` instead of `File.binread` is all it takes: the same 70
    # PNG bytes then report a `length` of 69 and `valid_encoding?` false.
    # Detection normalizes its own copy and not the one Image keeps, so
    # without this the two constructors hand a handler different objects
    # for identical bytes.
    it "hands back binary bytes however the image was built" do
      tagged = png.dup.force_encoding(Encoding::UTF_8)

      expect(described_class.from_content(tagged).content.encoding)
        .to eq(Encoding::BINARY)
      expect(described_class.from_content(tagged).content).to eq(png)
      with_file.call(png) do |path|
        expect(described_class.from_path(path).content.encoding)
          .to eq(Encoding::BINARY)
      end
    end

    # Re-tagging happens on our copy. The caller's String is theirs.
    it "leaves the caller's string tagged as they had it" do
      tagged = png.dup.force_encoding(Encoding::UTF_8)
      described_class.from_content(tagged)

      expect(tagged.encoding).to eq(Encoding::UTF_8)
    end

    # An Image is a value. Sharing the caller's buffer let them rewrite
    # the bytes out from under the format we had already detected: the
    # image kept saying :png over nine bytes of text. Binary input used to
    # be handed straight through, so only a binary String catches this --
    # the UTF-8 case above was already copied on the way in.
    it "keeps its own copy of the bytes it was given" do
      bytes = png.dup
      image = described_class.from_content(bytes)
      bytes.replace("not a PNG")

      expect(image.content).to eq(png)
      expect(image.format).to eq(:png)
    end

    it "hands back bytes nobody can rewrite in place" do
      expect(described_class.from_content(png.dup).content).to be_frozen
      with_file.call(png) do |path|
        expect(described_class.from_path(path).content).to be_frozen
      end
    end

    # A String that is already frozen and already binary cannot be
    # rewritten, so it is kept rather than costing a second copy of the
    # whole image.
    it "keeps a frozen binary string rather than copying it again" do
      frozen = png.b.freeze

      expect(described_class.from_content(frozen).content).to equal(frozen)
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
end
