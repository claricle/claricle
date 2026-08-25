# frozen_string_literal: true

require "stringio"
require "timeout"

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

  # `shows` is for a code line, which the README never wraps. Prose is
  # hard wrapped, so a sentence is matched with its wrap points left
  # free. Each word is escaped, so backticks and punctuation inside the
  # claim stay literal.
  def claims(sentence)
    pattern = /#{sentence.split.map { |word| Regexp.escape(word) }.join('\s+')}/
    expect(readme).to match(pattern), "README no longer claims: #{sentence}"
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
      # Anchored to the affirmative wording, not just the class name: a
      # negated sentence ("does not raise `Claricle::UnknownFormat`")
      # would still satisfy an unanchored version of these regexes.
      expect(readme).to match(/no known signature raise `Claricle::UnknownFormat`/)
      expect(readme).to match(/recognised but unhandled raises\s+`Claricle::UnsupportedFormat`/)
      expect { Claricle.detect("not an image") }.to raise_error(Claricle::UnknownFormat)
      expect { Claricle::Image.from_content(png).inspection }
        .to raise_error(Claricle::UnsupportedFormat)
    end
  end

  describe "what the README claims" do
    # The verdict alone pins nothing here. A 70-byte PNG settles after
    # its 8-byte signature, so a spec that only checked the returned
    # format would stay green whether detection drained the IO, stopped
    # on the byte that settled it, or stopped on the allowance. Where
    # the IO is left afterward is the part the README makes a claim
    # about, so that is what these assert.
    describe "how far detection reads an IO" do
      let(:bound) { Claricle.const_get(:Detector)::MAX_PROBE_BYTES }

      it "reads to the allowance even once the format has settled" do
        claims("A file or a `StringIO` hands over the whole allowance at once")
        io = StringIO.new(png + ("x" * (bound + 1_000)).b)
        expect(Claricle.detect(io)).to eq(:png)
        expect(io.pos).to eq(bound)
        expect(io.eof?).to be(false)
      end

      it "stops on the allowance when nothing ever settles it" do
        claims("the IO sits mid-stream and `eof?` is false")
        io = StringIO.new(("\x00" * (bound + 1_000)).b)
        expect { Claricle.detect(io) }.to raise_error(Claricle::UnknownFormat)
        expect(io.pos).to eq(bound)
        expect(io.eof?).to be(false)
      end

      # A real pipe rather than a StringIO with `readpartial` stubbed:
      # the claim is about an IO that hands over only what has arrived,
      # and a stub would restate the assumption instead of testing it.
      # The writer stays open, so a read that waited for the full
      # allowance would block forever -- Timeout turns that regression
      # into a failure rather than a hung suite.
      it "settles a short complete image without waiting for a pipe to close" do
        claims("A pipe or a socket hands over what has arrived")
        reader, writer = IO.pipe
        reader.binmode
        writer.binmode
        writer.write(png)
        expect(Timeout.timeout(5) { Claricle.detect(reader) }).to eq(:png)
      ensure
        writer&.close
        reader&.close
      end
    end

    # detector_spec already pins the behaviour, so the `claims` line is
    # what makes this more than a replica of it: deleting the README
    # sentence has to go red, not just changing the detector.
    it "admits that an SVG is only detected with its namespace" do
      claims("An SVG is recognised only when its root carries the SVG namespace")
      expect { Claricle.detect(%(<svg width="10" height="10"/>)) }
        .to raise_error(Claricle::UnknownFormat)
    end

    # Exact, not inclusion-only: an inclusion check misses a command the
    # CLI has that the README doesn't -- Thor 1.5 adds `tree` to every
    # subclass, and that slipped past an inclusion-only version of this
    # check.
    it "lists exactly the commands the CLI has, no more and no fewer" do
      documented = readme.scan(/^\s+claricle (\w+)/).flatten.uniq
      expect(documented).not_to be_empty
      expect(Claricle::Cli.all_commands.keys.sort).to eq(documented.sort)
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

    # The list above stops at `Models` and says nothing about what is
    # inside it, which is how `FreeFormHash` reached the public surface
    # without the README ever naming it. Assert the nested list too, and
    # that the README accounts for every constant on it.
    it "accounts for every constant Models exposes" do
      expect(Claricle::Models.constants.sort)
        .to eq(%i[FreeFormHash Inspection Issue Location Marshalling
                  Report Validation])
      %w[FreeFormHash Inspection Issue Location Report].each do |name|
        expect(readme).to include("Models::#{name}")
      end
      claims("`Models::Marshalling` and `Models::Validation` are reachable too")
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
      tokens = prose.scan(/\b[A-Z]{2,5}\b/).uniq - %w[XMP]
      expect(tokens.sort).to eq(allowed.sort)
    end
  end
end
