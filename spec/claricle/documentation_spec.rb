# frozen_string_literal: true

RSpec.describe "the documentation" do
  root = File.expand_path("../..", __dir__)
  readme = File.read(File.join(root, "README.adoc"))
  gemspec = File.read(File.join(root, "claricle.gemspec"))
  png = File.binread(File.join(__dir__, "..", "fixtures", "detector", "valid.png"))

  # The README's examples, run for real. A stale example should fail a
  # named test rather than a reader.
  describe "the examples in Usage" do
    it "detects from bytes and from an IO" do
      expect(Claricle.detect(png)).to eq(:png)
      Tempfile.create(["logo", ".png"]) do |file|
        file.binmode
        file.write(png)
        file.flush
        File.open(file.path, "rb") { |io| expect(Claricle.detect(io)).to eq(:png) }
      end
    end

    it "builds an Image from a path and reads its format and content" do
      Tempfile.create(["logo", ".png"]) do |file|
        file.binmode
        file.write(png)
        file.flush
        image = Claricle::Image.from_path(file.path)
        expect(image.format).to eq(:png)
        expect(image.content).to eq(png)
      end
    end

    it "yields a real path for a content-born image" do
      seen = nil
      Claricle::Image.from_content(png, format: :png).with_path do |path|
        seen = path
        expect(File.exist?(path)).to be(true)
      end
      expect(File.exist?(seen)).to be(false)
    end

    it "distinguishes UnknownFormat from UnsupportedFormat, as documented" do
      expect { Claricle.detect("not an image") }.to raise_error(Claricle::UnknownFormat)
      expect { Claricle::Image.from_content(png).inspection }
        .to raise_error(Claricle::UnsupportedFormat)
    end
  end

  describe "what the README claims" do
    it "lists no command the CLI does not have" do
      documented = readme.scan(/^\s+claricle (\w+)/).flatten.uniq
      expect(documented).not_to be_empty
      expect(Claricle::Cli.all_commands.keys).to include(*documented)
    end

    it "names no capability that was dropped" do
      # The only permitted mentions are the correction notice itself.
      body = readme.sub(/^\[NOTE\]\n====.*?^====$/m, "")
      expect(body).not_to match(/compress/i)
      expect(body).not_to match(/placeholder/i)
      expect(body).not_to match(/Claricle::Validator/)
    end

    it "names only constants that exist" do
      readme.scan(/Claricle::[A-Z][\w:]*/).uniq.each do |const|
        expect { Object.const_get(const) }.not_to raise_error, "README names #{const}"
      end
    end

    # const_get bypasses private_constant, so the public-constants list is
    # the honest question -- and it is the one the README answers.
    it "describes the internals as internal" do
      %w[Detector Registry Handlers].each do |name|
        expect(readme).to match(/#{name}/), "README should mention #{name}"
        expect(Claricle.constants).not_to include(name.to_sym), "#{name} is public"
      end
    end

    it "leaves exactly the documented public surface" do
      expect(Claricle.constants.sort)
        .to eq(%i[Cli ConversionError Error Image InvocationError Models
                  UnknownFormat UnsupportedFormat VERSION])
      expect(Claricle.methods(false)).to eq([:detect])
    end
  end

  describe "what the gemspec claims" do
    it "promises no capability the code lacks" do
      expect(gemspec).not_to match(/compression/i)
      expect(gemspec).not_to match(/comprehensive/i)
    end

    it "names the formats detection actually supports" do
      %w[PNG SVG EMF WMF EPS PDF].each { |fmt| expect(gemspec).to include(fmt) }
    end
  end
end
