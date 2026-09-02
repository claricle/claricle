# frozen_string_literal: true

require "stringio"
require "tempfile"

# Two subjects, one file: the model that carries a conversion result, and the
# classifier that decides its `lossiness`. They ship together because the
# vocabulary is shared -- `Conversion::LOSSINESS_LEVELS` is `Lossiness::LEVELS`.
RSpec.describe "conversion lossiness" do
  root = File.expand_path("../../..", __dir__)
  # `const_get`, because Lossiness is a private constant -- the same door
  # spec/claricle/registry_spec.rb:6 uses for Registry.
  lossiness = Claricle.const_get(:Lossiness)
  model = Claricle::Models::Conversion

  let(:fixtures) { File.join(root, "spec/fixtures/convert") }
  let(:emf_bytes) { File.binread(File.join(root, "spec/fixtures/detector/valid.emf")) }
  let(:eps_bytes) { File.binread(File.join(root, "spec/fixtures/inspect/basic.eps")) }

  # A `def`, not a `let`: it takes arguments, and `let` has no arity -- a block
  # parameter there receives the RSpec Example, not the argument.
  def path_for(name)
    File.join(File.expand_path("../../..", __dir__), "spec/fixtures/convert", "#{name}.svg")
  end

  def classify(name, to: :eps, from: :svg)
    Claricle.const_get(:Lossiness).classify(source_format: from, target_format: to,
                                            source: File.binread(path_for(name)))
  end

  def classify_io(name, to: :eps, from: :svg)
    File.open(path_for(name), "rb") do |io|
      Claricle.const_get(:Lossiness).classify(source_format: from, target_format: to, source: io)
    end
  end

  def classify_source(source, to: :eps, from: :svg)
    Claricle.const_get(:Lossiness).classify(source_format: from, target_format: to,
                                            source: source)
  end

  # `rect_and_line.svg` rebuilt, with `body` spliced between the two shapes and
  # `root_attrs` appended to the root. An inline document then differs from the
  # fixture control by exactly the one thing its example names -- the same
  # discipline spec/fixtures/convert/README.md states for the fixtures
  # themselves. Two examples below assert it reproduces that file byte for
  # byte, so the two controls cannot drift apart.
  def control_document(body = "", root_attrs: "", rect_attrs: "", line_attrs: "")
    root = %(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"#{root_attrs}>)
    rect = %(<rect width="10" height="10" fill="#ff0000"#{rect_attrs}/>)
    line = %(<line x1="0" y1="0" x2="10" y2="10" stroke="#000000"#{line_attrs}/>)
    "#{root}#{rect}#{body}#{line}</svg>"
  end

  # `Claricle::Models::Conversion` spelled out, not the `model` local above: a
  # `def` body cannot see a describe-scope local, which is the same arity/scope
  # reason a helper taking arguments cannot be a `let`.
  def conversion(**attrs)
    defaults = { source_format: "svg", target_format: "eps", lossiness: "lossless" }
    Claricle::Models::Conversion.new(defaults.merge(attrs))
  end

  describe "the model" do
    it "keeps the output bytes out of every serialized representation" do
      subject = conversion(source_path: "a.svg", output_path: "a.eps", content: emf_bytes)
      keys = %w[source_path source_format target_format lossiness output_path]

      expect(JSON.parse(subject.to_json).keys).to match_array(keys)
      expect(YAML.safe_load(subject.to_yaml).keys).to match_array(keys)
      expect(subject.to_hash.keys).to match_array(keys)
    end

    it "carries binary target bytes back out unchanged" do
      subject = conversion(content: emf_bytes)

      expect(subject.content).to eq(emf_bytes)
      expect(subject.content.encoding).to eq(Encoding::BINARY)
      expect(subject.content.bytesize).to eq(364)
    end

    it "neither forces BINARY nor corrupts UTF-8 text content" do
      subject = conversion(content: "<svg/>")

      expect(subject.content).to eq("<svg/>")
      expect(subject.content.encoding).to eq(Encoding::UTF_8)
    end

    it "hands back frozen content and does not freeze or alias the caller's String" do
      caller_bytes = +"<svg/>"
      subject = conversion(content: caller_bytes)

      expect(subject.content).to be_frozen
      expect(caller_bytes).not_to be_frozen
      expect(subject.content).not_to equal(caller_bytes)
      caller_bytes << "mutated"
      expect(subject.content).to eq("<svg/>")
    end

    it "reads back the document it writes, and cannot be handed content through one" do
      subject = conversion(source_path: "a.svg", output_path: "a.eps", content: emf_bytes)
      reloaded = model.from_json(subject.to_json)

      expect(reloaded.source_path).to eq("a.svg")
      expect(reloaded.output_path).to eq("a.eps")
      expect(reloaded.lossiness).to eq("lossless")
      expect(reloaded.content).to be_nil

      injected = model.from_json(%({"source_format":"svg","target_format":"eps",
                                    "lossiness":"lossy","content":"zz"}))
      expect(injected.content).to be_nil
      expect(injected.target_format).to eq("eps")
    end

    # Every non-String shape refuses through `BinaryContent.cast`, EXCEPT an
    # Array: lutaml's collection path never calls `cast` on the Array itself,
    # stores it raw, and `#content` then calls `value` on it. Measured before
    # the fix: `["a"]` and `[]` died as `NoMethodError: undefined method
    # 'value' for an instance of Array` rather than refusing.
    #
    # `[1, 2]` is listed with the scalars deliberately -- it DID refuse, but
    # only because an Integer ELEMENT tripped `cast`. A guard that holds for
    # the wrong reason, and an Array of Strings walks straight past it, which
    # is why the string arrays below are the rows that matter.
    it "refuses a non-String content at the door, an Array of Strings included" do
      [42, :sym, {}, 1.5, true, [1, 2], [], ["a"], %w[a b]].each do |bad|
        expect { conversion(content: bad) }
          .to raise_error(Lutaml::Model::ValidationError, /content/),
              "#{bad.inspect} should refuse rather than construct"
      end

      # The other direction: a String still constructs and reads back.
      expect(conversion(content: "<svg/>").content).to eq("<svg/>")
    end

    it "refuses a lossiness outside the vocabulary at both doors" do
      expect { conversion(lossiness: "maybe") }
        .to raise_error(Lutaml::Model::ValidationError, /maybe/)
      expect { model.from_json(%({"source_format":"svg","target_format":"eps","lossiness":"maybe"})) }
        .to raise_error(Lutaml::Model::ValidationError, /maybe/)
    end

    it "represents a content-born, stdout-bound conversion" do
      subject = conversion(source_path: nil, output_path: nil)

      expect(JSON.parse(subject.to_json).keys)
        .to match_array(%w[source_format target_format lossiness])
    end

    it "refuses to omit what makes a conversion traceable" do
      %i[source_format target_format lossiness].each do |name|
        attrs = { source_format: "svg", target_format: "eps", lossiness: "lossless" }
        attrs.delete(name)

        expect { model.new(attrs) }
          .to raise_error(Lutaml::Model::ValidationError, /#{name}/),
              "expected a missing #{name} to be refused by name"
      end
    end

    it "publishes exactly the documented vocabulary, frozen" do
      expect(model::LOSSINESS_LEVELS).to eq(%w[lossless lossy unknown])
      expect(model::LOSSINESS_LEVELS).to be_frozen
    end
  end

  describe "the classifier" do
    it "never calls a target with no measured rule set lossless" do
      expect(classify("rect_and_line", to: :ps)).to eq("unknown")
    end

    it "never calls a source format it cannot inspect lossless" do
      # SVG bytes under a non-SVG declared format: the only shape that reaches
      # the source guard, since :svg is absent from RULES and the target branch
      # would otherwise answer first.
      svg = File.binread(path_for("rect_and_line"))
      %i[emf png].each do |declared|
        verdict = lossiness.classify(source_format: declared, target_format: :eps, source: svg)
        expect(verdict).to eq("unknown"), "expected #{declared} source to be unknown"
      end
    end

    it "reads an IO exactly as it reads a String" do
      %w[rect_and_line gradient_linear large_trailing_gradient].each do |name|
        expect(classify_io(name)).to eq(classify(name)), "String and IO disagreed on #{name}"
      end
    end

    it "calls a document lossless only when every feature present is proven kept" do
      expect(classify("rect_and_line")).to eq("lossless")
      expect(classify("rect_and_line", to: :emf)).to eq("lossless")
    end

    it "classifies each measured loss against its measured target" do
      table = {
        %w[gradient_linear] => { eps: "lossy", emf: "lossy" },
        %w[gradient_radial] => { eps: "lossy", emf: "lossy" },
        %w[clip_path_element] => { eps: "lossy", emf: "lossy" },
        %w[clip_path_attribute] => { eps: "lossy", emf: "lossy" },
        %w[embedded_raster] => { eps: "lossy", emf: "unknown" }
      }
      table.each do |(name), targets|
        targets.each do |target, want|
          expect(classify(name, to: target)).to eq(want), "#{name} -> #{target}"
        end
      end
    end

    # Both fixtures carry an unmeasured element BESIDE proven ones, so the
    # empty-feature step cannot answer first and the element catch-all is the
    # guard under test. `path_and_rect` uses a bare `<path/>`: a `d=` attribute
    # would trip the attribute rule instead.
    #
    # Renamed from "cannot have its ignored-element list grow silently", which
    # this cannot show -- adding "path" to IGNORED reddens the constant pin
    # below, not this example.
    it "never waves through an element nobody has measured" do
      %w[text_rect_line path_and_rect].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} -> eps"
        expect(classify(name, to: :emf)).to eq("unknown"), "#{name} -> emf"
      end
    end

    it "pins the two elements that are deliberately ignored" do
      expect(classify("defs_container")).to eq("lossless")
    end

    # These three shipped with a README entry and no example. Measured: making
    # `content_feature` return nil for "style" -- the exact wrong behaviour the
    # README names -- left the whole suite green at 991/0 while
    # style_element_rect classified `lossless`.
    it "treats a style element as unmeasured, and comments and CDATA as marks-free" do
      expect(classify("style_element_rect")).to eq("unknown")
      expect(classify("comment_rect")).to eq("lossless")
      expect(classify("cdata_rect")).to eq("lossless")
    end

    it "returns a verdict for an unreadable document rather than raising" do
      expect(classify("malformed")).to eq("unknown")
    end

    it "returns a verdict for an unusable declared encoding rather than raising" do
      expect(classify("bad_encoding")).to eq("unknown")
    end

    # REXML defends itself against entity bombs with two BARE `raise "..."`
    # sites reachable from the pull loop -- baseparser.rb:642 "number of entity
    # expansions exceeded, processing aborted." and :600 "entity expansion has
    # grown too large". Both are RuntimeError, and both escaped `classify`,
    # which is documented to return one of three levels: measured, a 426-byte
    # document raised rather than answering.
    #
    # The VALUE is asserted, not the absence of a raise. `not_to raise_error`
    # would pass just as well on `nil`, which is not one of the three levels.
    #
    # Both limits, because a guard proven against one of a pair is proven in
    # one direction only. They need genuinely different documents: the count
    # guard never fires for the size bomb, and nesting one to four levels
    # returns `unknown` cleanly all the way -- only level 4 and beyond reaches
    # the count limit, so a shallow fixture passes while testing nothing.
    #
    # The size bomb is inline and needs no recursion at all: two flat entities,
    # one 1000 bytes and one repeating it twenty times. As a fixture its bulk
    # would read as noise on disk.
    it "returns a verdict for either entity-expansion limit rather than raising" do
      grown = %(<!DOCTYPE svg [<!ENTITY b "#{"Z" * 1000}"><!ENTITY c "#{"&b;" * 20}">]>) +
              control_document("&c;")

      expect(classify("entity_bomb")).to eq("unknown")
      expect(classify_source(grown)).to eq("unknown")

      # That the two are DIFFERENT raise sites is asserted, not assumed --
      # otherwise the pair could quietly collapse into one guard tested twice.
      # Compared to each other, never to literals: REXML's wording is not a
      # public contract and both strings have changed across versions.
      messages = [File.binread(path_for("entity_bomb")), grown].map do |document|
        parser = REXML::Parsers::PullParser.new(document)
        begin
          parser.pull while parser.has_next?
          nil
        rescue RuntimeError => e
          e.message
        end
      end
      expect(messages.compact.uniq.size).to eq(2), "expected two distinct REXML limits, got #{messages.inspect}"
    end

    # A source that is neither a String nor readable is a CALLER error, and it
    # reaches the caller as `InvocationError` -- the class this module already
    # converts a closed stream and an unpositionable one into. It used to leak
    # REXML's bare `RuntimeError: NilClass is not a valid input stream.`
    #
    # This example asserted that RuntimeError for one round, which was worse
    # than having no example: it turned a gap into a guarantee, so fixing the
    # inconsistency would have read as a regression. It now pins the contract
    # the module's own comments claim.
    #
    # The second half is the part that must not be lost: whatever the class,
    # a caller error must never come back as one of the three levels.
    # REXML invokes the supplied reader INSIDE the parse rescue, so a fault in
    # the CALLER's own IO came back as a verdict about their document --
    # measured, an IO whose `readline` raised returned "unknown".
    #
    # This refutes the reasoning that let it through for two rounds: that a
    # caller error is safe because `PullParser.new` sits OUTSIDE the rescue.
    # True of construction only. Location does not preserve origin, so the
    # fault is tagged where it is raised instead of inferred from where the
    # rescue sits.
    it "does not report a fault in the caller's own IO as a verdict" do
      clean = File.binread(path_for("rect_and_line"))

      %i[read readline eof?].each do |method|
        faulty = Class.new(StringIO) do
          define_method(method) { |*| raise("caller fault via #{method}") }
        end
        expect { classify_source(faulty.new(clean)) }
          .to raise_error(RuntimeError, /caller fault/),
              "a fault in ##{method} must reach the caller, not become a level"
      end

      # The other direction: an IO that behaves still gets a verdict, so the
      # tagging cannot be turning every IO read into an escape.
      expect(classify_source(StringIO.new(clean))).to eq("lossless")
    end

    it "refuses a source of the wrong type instead of answering about it" do
      [nil, 42, [], {}, :sym, 1.5].each do |bad|
        expect { classify_source(bad) }
          .to raise_error(Claricle::InvocationError, /String or a readable IO/),
              "expected a #{bad.class} source to be refused as a caller error"
      end
    end

    # REXML's PullParser does not enforce the XML 1.0 `Char` production, so
    # characters no conformant parser will read reached `lossless` -- the one
    # verdict that tells a caller not to look -- about a file a real converter
    # refuses outright. `REXML::Document` rejects the first two of these.
    #
    # Four landing sites rather than one, and `id` is the reason. The obvious
    # fix is to check the character-data events; `id` is exactly the route such
    # a list misses, because ATTR_HARMLESS waves it through by NAME and its
    # value never reaches a value rule. The guard sweeps every field of every
    # event, and -- since the round that added the example below -- the
    # characters each field DENOTES rather than the bytes it spells.
    # Sweeping every FIELD is not the same as sweeping every CHARACTER:
    # for one round this was still a route list, and an encoded reference
    # in `id` was the route it missed.
    it "never calls a document carrying a character illegal in XML lossless" do
      expect(classify("control_char_text")).to eq("unknown")
      expect(classify("control_char_id")).to eq("unknown")
      expect(classify_source(control_document("<!-- a\u001Cb -->"))).to eq("unknown")
      expect(classify_source(control_document("<![CDATA[a\u001Cb]]>"))).to eq("unknown")
      # Not a C0 control: U+FFFF is excluded by the same production, and a
      # guard written as "below 0x20" would miss it.
      expect(classify_source(control_document("\uFFFF"))).to eq("unknown")
    end

    # The ENCODED route. A value REXML hands back is RAW for attributes:
    # `id="a&#28;b"` denotes five characters, not the eight it spells. Only
    # character data gets a decoded second field, so the literal-character
    # guard caught text by accident of the event shape while every
    # name-admitted attribute leaked. Measured before the fix: a literal
    # U+001C in `id` gave unknown and `&#28;` in the same place gave lossless,
    # while REXML::Document refuses both.
    it "reads what an attribute value denotes, not what it spells" do
      %w[&#28; &#x1c; &#0;].each do |reference|
        expect(classify_source(control_document(rect_attrs: %( id="a#{reference}b"))))
          .to eq("unknown"), "#{reference} in id should be unknown"
      end

      # Every name-admitted route, because each reaches `lossless` down its own
      # branch of `feature_for` and closing one does not close the rest.
      { %( version="&#28;") => "ATTR_HARMLESS",
        %( xml:space="&#28;") => "the xml: allowance",
        %( xml:lang="&#28;") => "the xml: allowance",
        %( xmlns:foo="&#28;") => "the prefix == xmlns early return" }.each do |attribute, route|
        expect(classify_source(control_document(rect_attrs: attribute)))
          .to eq("unknown"), "#{route} should not admit an encoded illegal character"
      end

      # The other direction, so the fix is not "any value containing & is
      # unknown": `&#65;` denotes "A" and `&amp;` denotes "&", both legal.
      # A reference can also denote NOTHING establishable, and these are the
      # rows that make the totality guard fail when it is removed. `&#xD800;`
      # is a lone surrogate and `&#x110000;` is past the last codepoint: both
      # RESOLVE, without raising, to invalid UTF-8. `&#999999999999;` raises
      # RangeError and resolves to nil. Asking `match?` about any of the three
      # raises rather than answers, so a guard that let them through would be
      # relying on `Scanner#run` rescue to reach the same verdict by accident.
      ["&#xD800;", "&#x110000;", "&#999999999999;"].each do |reference|
        expect(classify_source(control_document(rect_attrs: %( id="a#{reference}b"))))
          .to eq("unknown"), "#{reference} denotes nothing establishable"
      end
      expect(classify_source(control_document("a&#xD800;b"))).to eq("unknown")

      expect(classify_source(control_document(rect_attrs: %( id="a&#65;b")))).to eq("lossless")
      expect(classify_source(control_document(rect_attrs: %( id="a&amp;b")))).to eq("lossless")
    end

    # An UNDECLARED reference resolves to nothing, so the document denotes
    # characters this scanner cannot establish -- strictly LESS evidence than a
    # DECLARED entity, which already answers `unknown` through
    # SUBSET_DECLARATIONS. Before the fix the undeclared case was the more
    # permissive of the two, inverting the rule at the top of lossiness.rb.
    #
    # The oracles genuinely disagree here and the choice is deliberate:
    # REXML::Document ACCEPTS an undeclared reference, xmllint refuses it.
    # `unknown` is right under this file own rule whichever oracle is right,
    # because a reference Claricle never resolves is evidence running out
    # either way.
    # A reference that is not merely unresolvable but MALFORMED, and a raw `<`,
    # which is never legal in parsed character data. Three misses stacked on
    # one input let these through: `&amp` and `&#xZZ;` are INCOMPLETE, so they
    # never match a reference and slipped past the unresolved test; the
    # characters themselves are legal, so ILLEGAL_CHAR passed them; and `id`
    # is admitted by NAME, which then supplied positive evidence for
    # `lossless`. REXML::Document refuses every one of these documents.
    it "never calls a document with malformed markup in a value lossless" do
      ["&amp", "&#xZZ;", "&#;", "a<b", "a & b"].each do |value|
        expect(classify_source(control_document(rect_attrs: %( id="#{value}"))))
          .to eq("unknown"), "attribute value #{value.inspect} is not well formed"
      end

      # The same rule in character data, which had the same hole.
      ["a&amp b", "a&#xZZ;b"].each do |text|
        expect(classify_source(control_document(text)))
          .to eq("unknown"), "text #{text.inspect} is not well formed"
      end

      # The other direction, and CDATA and comments are the reason it matters:
      # both legally carry a raw `<` and a bare `&`, so a rule applied to every
      # field rather than to PARSED character data would condemn them. These
      # rows fail if that happens.
      expect(classify_source(control_document("<![CDATA[a<b]]>"))).to eq("lossless")
      expect(classify_source(control_document("<![CDATA[a&b]]>"))).to eq("lossless")
      expect(classify_source(control_document("<!-- a<b -->"))).to eq("lossless")
      expect(classify_source(control_document(rect_attrs: %( id="R&amp;D")))).to eq("lossless")
      expect(classify_source(control_document("R&amp;D"))).to eq("lossless")
    end

    # `width` and `height` are EXTENTS and cannot be negative; `x`, `y` and the
    # line endpoints are signed coordinates and can. One pattern served both,
    # so `width="-1"` -- not a valid SVG extent -- got a positive `lossless`
    # claim. `viewBox` had the matching problem: `[\d.]+` is not a number
    # grammar, so `. . . .` and `1.2.3 0 10 10` both passed.
    it "proves an extent is non-negative and a viewBox is four numbers" do
      %w[width height].each do |name|
        negative = control_document.sub(%(#{name}="100"), %(#{name}="-1"))
                                   .sub(%(#{name}="50"), %(#{name}="-1"))
        expect(negative).not_to eq(control_document), "#{name} substitution did not apply"
        expect(classify_source(negative)).to eq("unknown"), "a negative #{name} should be unknown"
      end
      expect(classify_source(control_document.sub(%(<rect width="10"), %(<rect width="-1"))))
        .to eq("unknown")

      ["ChangeMe . . . .", "1.2.3 0 10 10", "0 0 10", "0 0 10 10 10"].each do |box|
        value = box.sub("ChangeMe ", "")
        expect(classify_source(control_document(root_attrs: %( viewBox="#{value}"))))
          .to eq("unknown"), "viewBox #{value.inspect} is not four numbers"
      end

      # The other direction: a signed COORDINATE may be negative, and a real
      # viewBox still passes. Without these a rule that refused every minus
      # sign, or every viewBox, would look correct.
      expect(classify_source(control_document(rect_attrs: %( x="-1" y="-2")))).to eq("lossless")
      expect(classify_source(control_document.sub(%(x1="0"), %(x1="-5")))).to eq("lossless")
      expect(classify_source(control_document(root_attrs: %( viewBox="-1 -1 10 10"))))
        .to eq("lossless")
      expect(classify_source(control_document(root_attrs: %( viewBox="0,0,10,10"))))
        .to eq("lossless")
    end

    it "treats an unresolvable reference as evidence running out" do
      subset = %(<!DOCTYPE svg [<!ENTITY e "x">]>)
      declared = "#{subset}#{control_document(%(&e;))}"
      expect(classify_source(declared)).to eq("unknown")

      expect(classify_source(control_document("a&nope;b"))).to eq("unknown")
      expect(classify_source(control_document(rect_attrs: %( id="a&nope;b")))).to eq("unknown")

      # `&amp;nope;` denotes the literal text "&nope;", which is legal and
      # fully accounted for. In an ATTRIBUTE the distinction survives and the
      # verdict is `lossless`, because REXML hands attribute values back raw
      # and the reference test runs there -- detector.rb states the same rule
      # for the same reason.
      expect(classify_source(control_document(rect_attrs: %( id="a&amp;nope;b"))))
        .to eq("lossless")

      # And it survives in TEXT too, which this suite got wrong for one round.
      # REXML supplies character data as TWO fields, raw and pre-decoded --
      # ["a&amp;nope;b", "a&nope;b"] -- and the DECODED copies of an escaped
      # and a genuine reference are byte-identical. The RAW copies are not, so
      # the event does distinguish them; sweeping the derived field is what
      # destroyed the distinction. The scanner now reads the raw alone, which
      # is what the attribute path always did.
      #
      # These two rows are the ones that go red if the reference test is ever
      # pointed back at the decoded copy.
      expect(classify_source(control_document("a&amp;nope;b"))).to eq("lossless")
      expect(classify_source(control_document("a&nope;b"))).to eq("unknown")
      expect(classify_source(control_document("a&amp;b"))).to eq("lossless")
    end

    # The other direction, which is the one a character guard gets wrong. It
    # runs on DECODED characters, never on source bytes: utf16_gradient.svg
    # holds 193 bytes below 0x20 that are ordinary UTF-16 code units, so a
    # byte-level guard condemns a legal document. The two clean UTF-16
    # documents here are what discriminate -- both would answer `unknown` under
    # a byte guard and `lossless` under a character one.
    it "admits every character XML 1.0 allows, including outside the BMP" do
      expect(control_document).to eq(File.binread(path_for("rect_and_line")))
      expect(classify_source(control_document)).to eq("lossless")
      expect(classify_source(control_document("\t\n\r"))).to eq("lossless")
      expect(classify_source(control_document("\u{1F600}"))).to eq("lossless")

      clean = control_document
      expect(classify_source("\xFF\xFE".b + clean.encode("UTF-16LE").b)).to eq("lossless")
      expect(classify_source("\xFE\xFF".b + clean.encode("UTF-16BE").b)).to eq("lossless")

      # And the fixture that made the distinction matter still answers for its
      # own reason. That reason is the ROOT guard, not its gradient: a
      # gradient is a MEASURED loss and would give `lossy`. See the
      # utf16_gradient row in spec/fixtures/convert/README.md.
      expect(classify("utf16_gradient")).to eq("unknown")
    end

    # `foo:xmlns` is not a namespace declaration. A declaration is `xmlns=`
    # with no prefix, or `xmlns:foo=`; `foo:xmlns` is an ordinary attribute in
    # the foo namespace that merely has that local name. The local-name test
    # used to run BEFORE the prefix guards, so any prefixed attribute named
    # `xmlns` skipped `prefixed` entirely and, at the SVG namespace value, came
    # back harmless -- breaking the "No other prefix is allowed" contract the
    # constant states about itself.
    #
    # No example caught it because the corpus tests the two halves apart and
    # never together: foreign_prefixed_attr is prefixed but not named `xmlns`,
    # redundant_svg_ns_rect is named `xmlns` but not prefixed.
    it "does not let the local name xmlns exempt an attribute from the prefix guard" do
      expect(classify("prefixed_xmlns_attr")).to eq("unknown")

      # Three controls, so the cheap wrong fixes are visible. Ignoring every
      # prefixed attribute passes the line above and fails the first; treating
      # anything named `xmlns` as unmeasured fails the second and third.
      expect(classify("foreign_prefixed_attr")).to eq("unknown")
      expect(classify("redundant_svg_ns_rect")).to eq("lossless")
      expect(control_document).to eq(File.binread(path_for("rect_and_line")))
      declared = control_document(root_attrs: %( xmlns:foo="http://example.com/f"))
      expect(classify_source(declared)).to eq("lossless")
    end

    it "does not let a namespace prefix hide a loss" do
      expect(classify("prefixed_gradient")).to eq("lossy")
    end

    # text.svg is the one fixture shaped "an unmeasured element and NO proven
    # shape at all" -- text_rect_line carries a rect and a line -- so it is
    # exactly the document that must never come back lossless. It used to be
    # covered only by an `include` matcher over the vocabulary, which
    # "lossless" satisfies.
    it "never calls a document of only unmeasured elements lossless" do
      expect(classify("text")).to eq("unknown")
      expect(classify("text", to: :emf)).to eq("unknown")
    end

    it "pins every rule table against silent growth" do
      expect(lossiness::RULES).to eq(
        eps: { lost: %i[gradient clip_path embedded_raster], kept: %i[basic_shape] },
        emf: { lost: %i[gradient clip_path], kept: %i[basic_shape] }
      )
      expect(lossiness::ELEMENTS).to eq(
        "linearGradient" => :gradient, "radialGradient" => :gradient,
        "clipPath" => :clip_path, "image" => :embedded_raster,
        "rect" => :basic_shape, "line" => :basic_shape
      )
      expect(lossiness::IGNORED).to eq(%w[svg defs])
      expect(lossiness::ATTR_FEATURES).to eq("clip-path" => :clip_path)
      expect(lossiness::KEPT_FEATURES).to eq(lossiness::RULES.values.flat_map { _1[:kept] }.uniq)

      # "EVERY rule table" named five and left four unpinned, which is the
      # expensive kind of miss: the next reader checks the name and stops
      # looking. Adding `transform` to ATTR_HARMLESS kept the whole suite green
      # while `<rect transform="scale(99)"/>` went `unknown` -> `lossless`.
      expect(lossiness::ATTR_HARMLESS).to eq(%w[version id])
      expect(lossiness::ATTR_ALLOWED_PREFIXED).to eq("xml" => %w[space lang])
      expect(lossiness::SUBSET_DECLARATIONS)
        .to eq(%i[entitydecl attlistdecl elementdecl notationdecl])
      expect(lossiness::VALUE_RULES.keys)
        .to eq(%w[fill stroke width height x y x1 y1 x2 y2 viewBox])

      # Derived, not spelled twice. Listed separately the two could drift, and
      # that drift fails OPEN -- a declaration type in KNOWN_EVENTS but not in
      # SUBSET_DECLARATIONS is a recognised event nobody notes.
      expect(lossiness::KNOWN_EVENTS).to include(*lossiness::SUBSET_DECLARATIONS)
    end

    it "reads the whole document rather than a bounded prefix" do
      expect(File.size(path_for("large_trailing_gradient"))).to be > 8192
      expect(classify("large_trailing_gradient")).to eq("lossy")
    end

    it "never calls a document with nothing in it lossless" do
      %w[empty_svg empty_defs].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end
      ["", "   \n  ", "<!-- hi -->"].each do |raw|
        verdict = lossiness.classify(source_format: :svg, target_format: :eps, source: raw)
        expect(verdict).to eq("unknown"), "#{raw.inspect} should be unknown"
      end
    end

    it "never calls a non-SVG root lossless, even carrying real shapes" do
      expect(classify("defs_root_svg_ns")).to eq("unknown")
    end

    it "never waves through an attribute nobody has proven harmless" do
      expect(classify("opacity_rect")).to eq("unknown")
      expect(classify("opacity_rect", to: :emf)).to eq("unknown")
    end

    # ATTR_HARMLESS was exercised in NEITHER direction, and the reason is not
    # visible by reading: `id=` appears in six fixtures and every one of them
    # is a gradient or a clipPath, whose verdict is already settled by the
    # lossy step before the harmless table is ever consulted. So no `lossless`
    # document in the corpus reached the table at all -- a property the whole
    # corpus shared that nobody chose.
    #
    # Both directions here. Adding `transform` to the table keeps the suite
    # green without the last row.
    it "admits the harmless attribute names and only those" do
      %w[id version].each do |name|
        expect(classify_source(control_document(rect_attrs: %( #{name}="a"))))
          .to eq("lossless"), "#{name} is on the harmless list and should be admitted"
      end
      expect(classify_source(control_document(rect_attrs: %( transform="scale(99)"))))
        .to eq("unknown")
    end

    # IGNORED is two elements and this covered only the root `<svg>`. All six
    # `<defs>` fixtures carry a bare `<defs>`, and the one with attributes has
    # `<defs>` AS the root, so it takes `visit_root` instead -- the whole
    # corpus agreed on a property nobody chose. Measured: skip attributes on a
    # non-root ignored element and `<defs opacity="0.5">` returns `lossless`
    # with the rest of this file green.
    it "reads attributes on elements whose own contribution is ignored" do
      expect(classify("root_style_rect")).to eq("unknown")

      nested = lambda do |attributes|
        root = %(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">)
        body = %(<defs#{attributes}><rect width="10" height="10" fill="#ff0000"/></defs>)
        "#{root}#{body}</svg>"
      end
      %w[opacity="0.5" style="fill:red" transform="scale(2)"].each do |attribute|
        expect(classify_source(nested.call(" #{attribute}")))
          .to eq("unknown"), "<defs #{attribute}> should be unknown"
      end

      # The other direction, so the rule cannot become "a defs with any
      # attribute is unknown": a proven-harmless name on the same element is
      # still admitted, and so is a bare one.
      expect(classify_source(nested.call(%( id="a")))).to eq("lossless")
      expect(classify_source(nested.call(""))).to eq("lossless")
    end

    it "never mistakes a foreign-namespace element for a proven-kept shape" do
      expect(classify("foreign_namespace_rect")).to eq("unknown")
      expect(classify("foreign_default_ns_rect")).to eq("unknown")
      expect(classify("no_namespace_rect")).to eq("unknown")
      expect(classify("nested_foreign_ns_rect")).to eq("unknown")
      expect(classify("redundant_svg_ns_rect")).to eq("lossless")
    end

    it "runs the prefix test before the ignored-element skip" do
      expect(classify("foreign_prefixed_defs")).to eq("unknown")
    end

    it "never calls a document whose DTD can hide markup lossless" do
      %w[entity_gradient attlist_default_opacity public_doctype_attlist
         public_doctype_rect system_dtd_rect external_entity_ref].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end
      expect(classify("bare_doctype_rect")).to eq("lossless")

      # SUBSET_DECLARATIONS names four types and the fixtures reached two of
      # them. Dropping `elementdecl` or `notationdecl` from the table left the
      # suite green while these two documents went `unknown` -> `lossless`,
      # and both are reachable input.
      { "<!ELEMENT rect EMPTY>" => :elementdecl,
        %(<!NOTATION gif SYSTEM "g">) => :notationdecl }.each do |declaration, type|
        document = "<!DOCTYPE svg [#{declaration}]>#{control_document}"
        expect(classify_source(document)).to eq("unknown"), "#{type} should be unknown"
      end
    end

    it "never waves through a processing instruction" do
      expect(classify("stylesheet_pi_rect")).to eq("unknown")
      expect(classify("other_pi_rect")).to eq("unknown")
      expect(classify("xmldecl_rect")).to eq("lossless")
    end

    it "allows xml:space only because a text-bearing element is separately unclassified" do
      expect(classify("xml_space_rect")).to eq("lossless")
      expect(classify("xml_space_text")).to eq("unknown")

      # `xml:lang` is the other half of the allowance and had nothing
      # exercising it; `xml:base` is the control, so adding a name to the
      # allowlist cannot stay green.
      expect(classify_source(control_document(rect_attrs: %( xml:lang="en")))).to eq("lossless")
      expect(classify_source(control_document(rect_attrs: %( xml:base="http://e/"))))
        .to eq("unknown")
    end

    it "does not let a non-xml prefixed attribute through the xml: allowance" do
      expect(classify("foreign_prefixed_attr")).to eq("unknown")
    end

    it "never calls a source it cannot decode lossless" do
      expect(classify("utf16_gradient")).to eq("unknown")
    end

    it "permits an absent paint attribute and refuses an unproven one" do
      expect(classify("no_paint_rect")).to eq("lossless")
      expect(classify("paint_none_rect")).to eq("unknown")
    end

    it "proves paint by value, on both paint attributes" do
      expect(classify("paint_rgb_rect")).to eq("lossless")
      %w[paint_url_rect paint_transparent_rect paint_named_rect
         paint_stroke_url_rect].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end

      # HEX_COLOUR's three-digit branch had nothing exercising it, and the
      # over-long form is its control: widened to `/\A#\h+\z/`, both of these
      # stay green without the second line.
      expect(classify_source(control_document.sub(%(fill="#ff0000"), %(fill="#f00"))))
        .to eq("lossless")
      expect(classify_source(control_document.sub(%(fill="#ff0000"), %(fill="#ff00000000"))))
        .to eq("unknown")
    end

    # "the whole geometry-name set" is nine names, and the fixtures reach three
    # of them -- `width`, `height`, `y1`. Making the pattern permissive one name
    # at a time left the other six green, each with a wrong-`lossless`
    # counterexample, so the name promised more than the example delivered.
    #
    # The six are inline rather than six more near-duplicate fixtures: they
    # differ from `rect_and_line.svg` by exactly one attribute, which is the
    # discipline the fixture corpus exists to keep, and `control_document`
    # above is asserted equal to that file.
    it "proves geometry by value, across the whole geometry-name set" do
      expect(classify("geom_px_rect")).to eq("lossless")
      expect(classify("geom_viewbox_rect")).to eq("lossless")
      %w[geom_percent_rect geom_em_rect geom_mm_rect geom_calc_rect
         geom_height_percent geom_y1_percent].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end

      expect(control_document).to eq(File.binread(path_for("rect_and_line")))

      # `x1`, `x2` and `y2` are SUBSTITUTED into the line, never appended.
      # Appending them a second time made all three examples pass for the
      # wrong reason: REXML rejects a duplicate attribute outright, so the
      # verdict was `unknown` before any value rule was consulted, and the
      # rows would have stayed green with the geometry pattern deleted.
      #
      # Exactly ONE of the two `sub` calls can match per name -- the control
      # carries `x1="0"` but `x2="10"` and `y2="10"` -- so each pair is one
      # hit and one no-op, and asserting the COMBINED result differs is
      # equivalent to asserting the applicable one did. A row where both
      # could match would break that equivalence and let a no-op hide.
      #
      # Keep the guard below even though the example currently goes red
      # without it. It is redundant only while the control verdict
      # (`lossless`) DIFFERS from the row expectation (`unknown`): a no-op
      # leaves the document identical and the next line catches it. Add a row
      # whose control already classifies `unknown` and the no-op becomes
      # invisible, at which point this is the only thing left. Measured:
      # break the substitution and this fires naming the real cause; remove
      # it and the failure points at the geometry rule instead, which is the
      # wrong place to send the next reader.
      %w[x1 x2 y2].each do |name|
        document = control_document.sub(%(#{name}="0"), %(#{name}="50%"))
                                   .sub(%(#{name}="10"), %(#{name}="50%"))
        expect(document).not_to eq(control_document), "#{name} substitution did not apply"
        expect(classify_source(document)).to eq("unknown"), "a relative #{name} should be unknown"
      end

      # `x`, `y` and `viewBox` are absent from the control, so these add rather
      # than replace.
      expect(classify_source(control_document(rect_attrs: %( x="50%")))).to eq("unknown")
      expect(classify_source(control_document(rect_attrs: %( y="50%")))).to eq("unknown")
      expect(classify_source(control_document(root_attrs: %( viewBox="a b c d"))))
        .to eq("unknown")

      # The other direction, so a rule that simply refuses these names cannot
      # pass the rows above. `x1`/`y1`/`x2`/`y2` carry absolute values in the
      # control document itself, which is asserted `lossless` throughout.
      expect(classify_source(control_document(rect_attrs: %( x="1" y="2")))).to eq("lossless")
      expect(classify_source(control_document(root_attrs: %( viewBox="0 0 10 10"))))
        .to eq("lossless")
    end

    it "never waves through an event type it does not recognise" do
      expect(classify("external_entity_ref")).to eq("unknown")

      # The SETS, never their sizes: both happen to hold 14 and they overlap in
      # only 10, so `eq(14)` on each pins a coincidence -- swapping one member
      # of KNOWN_EVENTS for a non-event keeps the size and silently flips
      # comment_rect. Asserted against REXML's own predicate list so a grammar
      # change in the dependency reddens here.
      predicates = REXML::Parsers::PullEvent.instance_methods(false)
                                            .grep(/\?\z/)
                                            .map { |m| m.to_s.chomp("?").to_sym }
      expect(predicates - lossiness::KNOWN_EVENTS)
        .to contain_exactly(:doctype, :entity, :error, :instruction)
      expect(lossiness::KNOWN_EVENTS - predicates)
        .to contain_exactly(:start_doctype, :end_doctype,
                            :processing_instruction, :end_document)

      # `:end_document` looks dead and is not. No fixture delivers it, because
      # all 66 are written with no trailing newline -- a property the whole
      # corpus shares that nobody chose. Any trailing whitespace produces it,
      # which is every SVG file an editor has ever saved, so dropping it from
      # KNOWN_EVENTS would send every real-world document to `unknown`.
      expect(classify_source("#{control_document}\n")).to eq("lossless")
      expect(classify_source("#{control_document}\r\n  ")).to eq("lossless")
    end

    # PullParser does not report an unclosed stack at EOF, so "REXML raised"
    # was not the whole of malformedness. Measured before the depth guard:
    # cutting 30 bytes off large_trailing_gradient.svg turned `lossy` into
    # `lossless` -- losing evidence made the verdict more confident.
    it "never grows more confident when the document is truncated" do
      expect(classify("large_trailing_gradient")).to eq("lossy")
      expect(classify("truncated_gradient")).to eq("unknown")
    end

    it "treats a nested svg viewport as a new, unmeasured context" do
      expect(classify("nested_svg_rect")).to eq("unknown")
    end

    # Named for the guard that actually answers. `second_root` trips the epilog
    # check before `visit_root` ever reaches its `@roots > 1` branch, so this
    # cannot isolate the second-root count -- that branch is deliberate
    # redundancy in the safe direction, not something this example pins.
    it "never calls content after the root closes lossless" do
      expect(classify("second_root")).to eq("unknown")
      expect(classify("epilog_content")).to eq("unknown")
    end

    # `no_root_dimensions.svg` omits BOTH, so it cannot tell an `&&` from
    # either half on its own: dropping the `height` test keeps the suite green
    # while `<svg width="100">` goes from `unknown` to `lossless`. The two
    # single-dimension roots below are what discriminate.
    it "treats absent root dimensions as it treats a relative one" do
      expect(classify("no_root_dimensions")).to eq("unknown")
      expect(classify("rect_and_line")).to eq("lossless")

      shape = %(<rect width="10" height="10" fill="#ff0000"/></svg>)
      %w[width="100" height="50"].each do |only|
        document = %(<svg xmlns="http://www.w3.org/2000/svg" #{only}>#{shape})
        expect(classify_source(document)).to eq("unknown"),
                                             "a root carrying only #{only} should be unknown"
      end
    end

    it "refuses a source whose position cannot be observed" do
      reader, writer = IO.pipe
      writer.write(File.binread(path_for("rect_and_line")))
      writer.close
      expect { lossiness.classify(source_format: :svg, target_format: :eps, source: reader) }
        .to raise_error(Claricle::InvocationError, /position/)
    ensure
      reader&.close
    end

    # BOTH IO classes the seam accepts, because that is the axis that produced
    # the gap: measured, a closed File raises IOError from `pos` while a closed
    # StringIO returns 0 from `pos` and used to reach the scan, where the read
    # raised a bare IOError outside the seam's own error type.
    it "refuses a closed source the same way it refuses an unpositionable one" do
      # The block form closes the file and hands back the closed IO.
      closed_file = File.open(path_for("rect_and_line"), "rb") { |io| io }
      closed_string_io = StringIO.new(File.binread(path_for("rect_and_line")))
      closed_string_io.close

      [closed_file, closed_string_io].each do |source|
        expect { lossiness.classify(source_format: :svg, target_format: :eps, source: source) }
          .to raise_error(Claricle::InvocationError, /not readable/),
              "expected a closed #{source.class} to be refused by the seam"
      end
    end

    it "refuses a source that has already been partly consumed" do
      File.open(path_for("attlist_default_opacity"), "rb") do |io|
        io.seek(io.read.index("<svg"))
        expect { lossiness.classify(source_format: :svg, target_format: :eps, source: io) }
          .to raise_error(Claricle::InvocationError, /byte 0/)
      end
    end

    # Interface restriction, not a mutation: a mutant explores the neighbourhood
    # of the code we wrote and cannot express "reads the whole thing by another
    # route", because that is a different implementation rather than a mutation
    # of ours. So the seam is handed an object that answers ONLY what the design
    # is permitted to call, and anything else raises.
    #
    # The permitted set is measured, not guessed. REXML::SourceFactory.create_from
    # (rexml-3.4.4/lib/rexml/source.rb:42-53) dispatches on read, readline, nil?
    # and eof?, and IOSource then uses external_encoding; `pos` is ours, for the
    # byte-0 guard. Reproduce the parser's own calls with:
    #   ruby -rrexml/parsers/pullparser -e 'wrap an IO in a method_missing spy,
    #     parse, print the calls'  # => eof?, external_encoding, read(Integer),
    #                              #    readline(String)
    #
    # `to_str` is deliberately ABSENT: SourceFactory would use it to slurp the
    # whole source into a StringIO, which is exactly the access pattern the
    # `source:` seam exists to avoid.
    #
    # BasicObject, not Object, and that is the difference between watching a
    # route and closing it. Measured: an Object-based double still answers 52
    # methods without ever reaching method_missing, and
    # `instance_variable_get(:@io).read` hands back the real IO and reads all
    # 17,986 bytes. BasicObject removes 43 of those, so the permitted list
    # below is what the object answers rather than only what it intercepts.
    it "never repositions the IO it is given, and never reads it in one call" do
      permitted = %i[eof? external_encoding read readline nil? pos]
      restricted = Class.new(BasicObject) do
        attr_reader :largest_read

        define_method(:initialize) do |io|
          @io = io
          @largest_read = 0
        end
        define_method(:respond_to?) { |m, p = false| permitted.include?(m) && @io.respond_to?(m, p) }
        define_method(:method_missing) do |name, *args, &blk|
          # Bare `Kernel`/`String`, no `::` prefix: a `Class.new(BasicObject)
          # do ... end` body and its `define_method` blocks capture the
          # ENCLOSING lexical scope, so top-level constants resolve normally.
          # The `::` form is only needed under `class Foo < BasicObject`, which
          # opens a fresh constant scope. Measured both ways before deciding.
          Kernel.raise "forbidden IO call: #{name}" unless permitted.include?(name)
          Kernel.raise "unbounded read" if name == :read && args.empty?

          result = @io.public_send(name, *args, &blk)
          @largest_read = [@largest_read, result.bytesize].max if result.is_a?(String)
          result
        end
        define_method(:respond_to_missing?) { |*| false }
      end

      File.open(path_for("large_trailing_gradient"), "rb") do |io|
        wrapper = restricted.new(io)
        verdict = lossiness.classify(source_format: :svg, target_format: :eps,
                                     source: wrapper)
        expect(verdict).to eq("lossy")
        # The repositioning half is pinned by `permitted` above (seek, rewind
        # and pos= all raise, and to_str is absent so SourceFactory cannot
        # wrap the source in a StringIO). This pins the realistic slurp shape
        # -- one call returning the whole document -- rather than cumulative
        # bytes, which a streaming parse legitimately reads in full.
        #
        # The bound is DERIVED, not a constant. `< File.size` left 17,925
        # bytes of slack: measured, the largest single read is 61 bytes, so a
        # reader slurping 17,985 of the 17,986 would have passed. What the
        # property actually says is that the largest read does not grow with
        # the file, and that is what is asserted -- against a document 106
        # times smaller, whose own largest read is the same 61. A slurp cannot
        # satisfy it at any file size, and REXML's buffer size stays REXML's
        # to change.
        small = restricted.new(File.open(path_for("rect_and_line"), "rb"))
        expect(lossiness.classify(source_format: :svg, target_format: :eps, source: small))
          .to eq("lossless")
        expect(wrapper.largest_read).to eq(small.largest_read)
        expect(wrapper.largest_read).to be < File.size(path_for("rect_and_line"))
      end
    end
  end
end
