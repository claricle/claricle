# frozen_string_literal: true

RSpec.describe "the documentation" do
  root = File.expand_path("../..", __dir__)

  # `let`, not describe-scope locals: a local here is shared by closure
  # across every example, so assigning one inside an example silently
  # rebinds it for the rest of the file -- that happened in models_spec
  # and broke fifteen unrelated examples. They are also eager I/O at load
  # time, where a missing fixture fails while the file loads rather than
  # in the example that names it.
  let(:readme) { File.read(File.join(root, "README.adoc")) }
  let(:png) { File.binread(File.join(root, "spec/fixtures/detector/valid.png")) }
  let(:wmf) { File.binread(File.join(root, "spec/fixtures/detector/std.wmf")) }

  # Each example asserts the expression it runs is still IN the README.
  # Without that these are replicas: renaming image.format to image.formatt
  # in the docs would leave them green.
  # A helper method, not a lambda: `expect` is unavailable at describe
  # scope and only works inside the example.
  # Whole lines, not substrings: asserting "image.format" would still pass
  # if the doc said "image.formatt".
  def shows(snippet)
    lines = readme.lines.map(&:strip)
    expect(lines).to include(snippet), "README no longer shows the line: #{snippet}"
  end

  describe "the examples in Usage" do
    it "detects from bytes and from an IO" do
      shows('Claricle.detect(File.binread("logo.png"))   # => :png')
      shows('File.open("logo.png", "rb") { |io| Claricle.detect(io) } # => :png')
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
        shows('image = Claricle::Image.from_path("logo.png")')
        shows("image.format    # => :png")
        shows("image.content   # read lazily, once")
        image = Claricle::Image.from_path(file.path)
        expect(image.format).to eq(:png)
        expect(image.content).to eq(png)
      end
    end

    it "yields a real path for a content-born image" do
      shows("Claricle::Image.from_content(bytes, format: :png).with_path do |path|")
      seen = nil
      Claricle::Image.from_content(png, format: :png).with_path do |path|
        seen = path
        expect(File.exist?(path)).to be(true)
      end
      expect(File.exist?(seen)).to be(false)
    end

    it "distinguishes UnknownFormat from UnsupportedFormat, as documented" do
      expect(readme).to match(/raise `Claricle::UnknownFormat`/)
      expect(readme).to match(/raises\s+`Claricle::UnsupportedFormat`/)
      expect { Claricle.detect("not an image") }.to raise_error(Claricle::UnknownFormat)
      # A format with no handler -- png has one now, so it would prove
      # the opposite.
      expect { Claricle::Image.from_content(wmf).inspection }
        .to raise_error(Claricle::UnsupportedFormat)
    end
  end

  describe "what the README claims" do
    # A mapped command is documented under the name users type, not the
    # method behind it. Flag aliases (-h, --tree) are Thor's, not commands.
    # The registry keys ARE the command names now. This used to invert
    # `Cli.map` to translate `inspect_file` back to `inspect`; the
    # command is re-keyed at the source, so there is no alias left to
    # resolve and that branch would be dead code.
    def self.cli_command_names
      Claricle::Cli.all_commands.keys
    end

    it "lists no command the CLI does not have" do
      documented = readme.scan(/`claricle (\w+)/).flatten.uniq
      expect(documented).not_to be_empty
      expect(self.class.cli_command_names).to include(*documented)
    end

    # The other direction, which the check above cannot make: a command we
    # ship and never documented. Thor's own built-ins are excluded because
    # they are Thor's to name -- the README used to reproduce `help`
    # verbatim, and that block silently went stale when Thor 1.5 added
    # `tree` to output we do not control.
    it "documents every command Claricle itself defines" do
      ours = self.class.cli_command_names - Thor.all_commands.keys
      documented = readme.scan(/`claricle (\w+)/).flatten.uniq

      expect(ours - documented).to be_empty
    end

    # Assert what the note SAYS before exempting it: stripping it first
    # would let it be reversed to "compression now works" and still pass.
    # Tied to compression specifically: an unrelated negative sentence
    # elsewhere plus "compression now works" would otherwise pass.
    # The wording is deliberately "not in v1's scope" rather than "no
    # longer planned": 0.1.0's published metadata advertised compression,
    # and retiring a public commitment is the maintainer's call, not a
    # documentation PR's. "Never implemented" is the factual half and
    # stays.
    it "states plainly that compression is not in v1" do
      note = readme[/^\[NOTE\]\n====.*?^====$/m]
      expect(note).to be_a(String), "the 0.1.0 correction note is gone"
      expect(note).to match(/compression/i)
      expect(note).to match(/never implemented/)
      expect(note).to match(/not in\s+v1's scope/)
      expect(readme).not_to match(/compression (now |is |will be )?(works|supported|available)/i)
    end

    it "names no capability that was dropped, outside that note" do
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
      # Nested privacy is not implied by the outer check.
      expect(Claricle.const_get(:Handlers).constants).not_to include(:Base)
      expect(Claricle::Models.constants).not_to include(:Base)
    end

    it "leaves exactly the documented public surface" do
      expect(Claricle.constants.sort)
        .to eq(%i[Cli ConversionError Error Image InvocationError Models
                  UnknownFormat UnsupportedFormat VERSION])
      expect(Claricle.methods(false)).to eq([:detect])
    end
  end

  # The built spec, not the raw file: a comment mentioning compression is
  # harmless and should not fail this.
  describe "what the gemspec claims" do
    spec = Gem::Specification.load(File.join(root, "claricle.gemspec"))
    prose = "#{spec.summary} #{spec.description}"

    it "promises no capability the code lacks" do
      expect(prose).not_to match(/compress/i)
      expect(prose).not_to match(/comprehensive/i)
    end

    # Any bare uppercase token, so an added BMP or AVIF fails rather than
    # going unnoticed by a fixed alternation.
    it "names every format detection supports, and no others" do
      allowed = %w[EMF EPS PDF PNG PS SVG WMF]
      tokens = prose.scan(/\b[A-Z]{2,5}\b/).uniq
      expect(tokens.sort).to eq(allowed.sort)
    end
  end
end
