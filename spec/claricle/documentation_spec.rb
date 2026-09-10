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

    # Both halves of the claim: the yielded source is the open file, and
    # the file is not slurped to produce it. The class is asserted, not
    # just the bytes -- a StringIO over the whole file reads the same
    # and costs the whole file, which is the opposite of the claim.
    it "yields the open file for a path-born image, reading nothing else" do
      shows('Claricle::Image.from_path("logo.svg").with_source do |source|')
      Tempfile.create(["logo", ".png"]) do |file|
        file.binmode
        file.write(png)
        file.flush
        expect(File).not_to receive(:binread)

        # The read comes back out of the block: expectations inside one
        # that is never called assert nothing at all.
        prefix = Claricle::Image.from_path(file.path).with_source do |source|
          expect(source).to be_a(File)
          source.read(8)
        end

        expect(prefix).to eq(png[0, 8])
      end
    end

    it "distinguishes UnknownFormat from UnsupportedFormat, as documented" do
      # Anchored to the affirmative wording, not just the class name: a
      # negated sentence ("does not raise `Claricle::UnknownFormat`")
      # would still satisfy an unanchored version of these regexes.
      expect(readme).to match(/no known signature raise `Claricle::UnknownFormat`/)
      expect(readme).to match(/recognised but unhandled raises\s+`Claricle::UnsupportedFormat`/)
      expect { Claricle.detect("not an image") }.to raise_error(Claricle::UnknownFormat)
      # A format with no handler -- png has one now, so it would prove
      # the opposite.
      expect { Claricle::Image.from_content(wmf).inspection }
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

    # A mapped command is documented under the name users type, not the
    # method behind it. Flag aliases (-h, --tree) are Thor's, not commands.
    # The registry keys ARE the command names now. This used to invert
    # `Cli.map` to translate `inspect_file` back to `inspect`; the
    # command is re-keyed at the source, so there is no alias left to
    # resolve and that branch would be dead code.
    #
    # `[\w-]+`, not `\w+`: a dash ends `\w`, so documenting the rejected
    # `claricle inspect-file` would have been captured as `inspect` and
    # passed both checks below.
    def self.cli_command_names
      Claricle::Cli.all_commands.keys
    end

    it "lists no command the CLI does not have" do
      documented = readme.scan(/`claricle ([\w-]+)/).flatten.uniq
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
      documented = readme.scan(/`claricle ([\w-]+)/).flatten.uniq

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

    # The org moved from `ribose` to `claricle` and these links did not,
    # so every one of them 404'd. Scanned rather than counted, because the
    # wrong org is only visible next to the right one.
    #
    # Both link shapes, not just `github.com`: the License badge reads
    # `img.shields.io/github/license/OWNER/claricle`, so a version keyed
    # to the host missed it entirely -- measured, reverting that one badge
    # to `ribose` left this example green. Matching the owner loosely
    # instead was worse: `lib/claricle/` in the architecture tree and the
    # ownerless `shields.io/gem/v/claricle` badge both scanned as owners.
    it "links to a repository that exists" do
      owners = readme.scan(%r{(?:github\.com|shields\.io/github/\w+)/([\w.-]+)/claricle})
      expect(owners.flatten.uniq).to eq(["claricle"])
    end

    it "names only constants that exist" do
      readme.scan(/Claricle::[A-Z][\w:]*/).uniq.each do |const|
        expect { Object.const_get(const) }.not_to raise_error, "README names #{const}"
      end
    end
  end

  # Grouped by what they are about -- the surface -- rather than by
  # where the claim lives. The first of these reads no README at all.
  describe "the public surface" do
    # Only what the surface tree below cannot reach. That tree is exact on
    # every public namespace, so it already proves `Detector`, `Registry`
    # and `Handlers` are not public constants, and that `Models` exposes
    # no `Base` -- measured, `Claricle.constants` equals
    # `Claricle.constants(false)` and the same holds for `Models`.
    # `Handlers::Base` is the one case left: the walk stops at `Handlers`
    # because it is private, so nothing else looks inside it.
    it "keeps the internals of a private namespace private too" do
      expect(Claricle.const_get(:Handlers).constants).not_to include(:Base)
    end

    # A list of one namespace's constants says nothing about what is
    # nested below it. That is how `FreeFormHash` once reached the public
    # surface without the README naming it, and how `PARSE_STATUSES`,
    # `SEVERITIES` and `POSITIONS` sat public and undocumented after it:
    # privatising all three left every other example in this suite green,
    # so nothing was watching them. Walking the tree closes it for good --
    # a constant added anywhere under `Claricle`, at any depth, has to be
    # accounted for here.
    #
    # `constants(false)`, both halves deliberate. `constants` omits a private
    # constant, which is the question being asked, where `const_get` walks
    # straight past `private_constant` and hands the value back. And
    # `false`, because these are mostly classes: inherited would drag in
    # every constant on `StandardError` and `Thor` and answer a different
    # question.
    #
    # A constant pointing back up would recurse to `SystemStackError`,
    # which fails this example rather than hiding in it. Nothing under
    # `Claricle` does today.
    def surface_of(namespace)
      namespace.constants(false).sort.each_with_object({}) do |name, tree|
        value = namespace.const_get(name)
        tree[name] = value.is_a?(Module) ? surface_of(value) : nil
      end
    end

    it "leaves exactly the documented public surface, at every depth" do
      expect(surface_of(Claricle)).to eq(
        Cli: { Runner: { Status: {} } },
        ConversionError: {},
        Error: {},
        Image: {},
        InvocationError: {},
        Models: {
          Conversion: { LOSSINESS_LEVELS: nil },
          Inspection: { PARSE_STATUSES: nil },
          Issue: { SEVERITIES: nil },
          Location: {},
          Report: {}
        },
        UnknownFormat: {},
        UnsupportedFormat: {},
        VERSION: nil
      )
      expect(Claricle.methods(false)).to eq([:detect])
    end

    # The tree above is what the code exposes; this is what the README
    # says about it. Both halves are needed -- the tree alone lets the
    # README fall silent on a constant, and the README alone lets one
    # appear that it never mentions.
    #
    # `FreeFormHash` and `Validation` are private: the first is a
    # documented workaround for one lutaml-model version, the second a
    # mixin only the already-private `Base` uses. `POSITIONS` joins them
    # because only the private `validate_types` reads it, where the two
    # enums above are vocabulary a caller builds a model from. Publishing
    # any of the three would bind the gem until a major bump.
    it "documents every constant on that surface, and calls the rest private" do
      # Both sentences whole, not the names in them. Naming alone pinned
      # nothing in either direction -- measured twice: with only `include`
      # calls, rewriting "The public surface is" to "Nothing here is
      # public, least of all" stayed green, and before the private
      # sentence was pinned, reversing it to "are public constants" did
      # the same.
      claims("The public surface is `Claricle.detect`, `Claricle::Image`, " \
             "`Claricle::Cli` (including `Cli::Runner` and " \
             "`Runner::Status`), `Claricle::VERSION`, the error classes, " \
             "the model classes `Models::Inspection`, `Models::Issue`, " \
             "`Models::Location` and `Models::Report`, and the two " \
             "vocabularies those models validate against, " \
             "`Inspection::PARSE_STATUSES` and `Issue::SEVERITIES`.")
      claims("`Detector`, `Registry`, `Handlers::Base`, `Models::Base`, " \
             "`Models::FreeFormHash`, `Models::Validation`, " \
             "`Models::Location::POSITIONS`, `Cli::Runner::Status::RANGE` " \
             "and `UnsupportedFormat::ABSENT` are private constants.")
      # `::`, not `const_get` -- measured: `Module#const_get` walks
      # straight past `private_constant` and hands the class back, so an
      # assertion written that way passes whatever the visibility is.
      claims("The model class `Models::Conversion` and its vocabulary " \
             "`Conversion::LOSSINESS_LEVELS` are public.")
      claims("`Lossiness` and `Models::BinaryContent` are private constants.")
      expect { Claricle::Lossiness }
        .to raise_error(NameError, /private constant/)
      expect { Claricle::Models::BinaryContent }
        .to raise_error(NameError, /private constant/)
      expect { Claricle::Models::FreeFormHash }
        .to raise_error(NameError, /private constant/)
      expect { Claricle::Models::Validation }
        .to raise_error(NameError, /private constant/)
      expect { Claricle::Models::Location::POSITIONS }
        .to raise_error(NameError, /private constant/)
      expect { Claricle::Cli::Runner::Status::RANGE }
        .to raise_error(NameError, /private constant/)
      expect { Claricle::UnsupportedFormat::ABSENT }
        .to raise_error(NameError, /private constant/)
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

    # Thor 1.0 and 1.1 reference DidYouMean::SPELL_CHECKERS, which is
    # absent on supported Ruby 3.4. Thor 1.2.0 is the first tested
    # compatible line there; the upper bound keeps unreviewed 2.x out.
    it "requires the supported Thor line" do
      dependency = spec.runtime_dependencies.find { |item| item.name == "thor" }

      expect(dependency.requirement).not_to be_satisfied_by(Gem::Version.new("1.1.0"))
      expect(dependency.requirement).to be_satisfied_by(Gem::Version.new("1.2.0"))
      expect(dependency.requirement).not_to be_satisfied_by(Gem::Version.new("2.0.0"))
    end

    # Published metadata, so a wrong URL here is what a user lands on from
    # the gem page rather than something they can correct in a checkout.
    #
    # Every value, not three named keys: a `bug_tracker_uri` added later
    # would have escaped a list that had to be remembered. Measured
    # against the built spec -- `metadata` is a plain Hash of Strings, and
    # the grep drops the one non-URL value (`rubygems_mfa_required`).
    # `start_with`, so a deeper path like `/issues` stays legal while a
    # wrong owner still fails.
    it "points every public URL at a repository that exists" do
      urls = [spec.homepage, *spec.metadata.values].grep(/github\.com/)
      expect(urls).not_to be_empty
      expect(urls).to all(start_with("https://github.com/claricle/claricle"))
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
