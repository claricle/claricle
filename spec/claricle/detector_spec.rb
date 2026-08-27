# frozen_string_literal: true

require "English"
require "stringio"
require "tempfile"
require "timeout"
# Required explicitly because these specs compare Claricle's name handling
# with REXML's canonical XML grammar rather than its narrower live parser.
require "rexml/xmltokens"

RSpec.describe "Claricle format detection" do
  svg_ns = "http://www.w3.org/2000/svg"

  fixture = lambda do |name|
    File.binread(File.join(__dir__, "..", "fixtures", "detector", name))
  end

  # Writes bytes to a real file so detect_path exercises the streaming path.
  with_file = lambda do |bytes, &block|
    Tempfile.create(["detector", ".bin"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      block.call(file.path)
    end
  end

  # Both ends of every non-ASCII NameStartChar range, followed by every
  # NameChar-only production. One prefix exercises the whole canonical
  # grammar without turning each codepoint into another parser example.
  canonical_prefix = lambda do
    boundaries = [
      0xC0, 0xD6, 0xD8, 0xF6, 0xF8, 0x2FF, 0x370, 0x37D,
      0x37F, 0x1FFF, 0x200C, 0x200D, 0x2070, 0x218F, 0x2C00, 0x2FEF,
      0x3001, 0xD7FF, 0xF900, 0xFDCF, 0xFDF0, 0xFFFD, 0x10000, 0xEFFFF
    ]
    "a#{boundaries.pack("U*")}-.0\u{B7}\u{300}\u{36F}\u{203F}\u{2040}"
  end

  describe "formats" do
    {
      "valid.png" => :png,
      "valid.emf" => :emf,
      "std.wmf" => :wmf,
      "place.wmf" => :wmf
    }.each do |name, format|
      it "detects #{name} as #{format} from content and from a path" do
        expect(Claricle.detect(fixture.call(name))).to eq(format)
        with_file.call(fixture.call(name)) do |path|
          expect(Claricle::Image.from_path(path).format).to eq(format)
        end
      end
    end

    {
      pdf: "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n",
      eps: "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\n",
      ps: "%!PS-Adobe-3.0\n%%BoundingBox: 0 0 10 10\n",
      svg: %(<svg xmlns="#{svg_ns}" width="10" height="10"/>)
    }.each do |format, content|
      it "detects #{format} from content and from a path" do
        expect(Claricle.detect(content)).to eq(format)
        with_file.call(content) do |path|
          expect(Claricle::Image.from_path(path).format).to eq(format)
        end
      end
    end
  end

  describe "header bounds" do
    it "detects an EMF truncated to 44 bytes, the shortest header emf can read" do
      expect(Claricle.detect(fixture.call("valid.emf")[0, 44])).to eq(:emf)
    end

    it "gives up on an EMF truncated to 43 bytes" do
      expect { Claricle.detect(fixture.call("valid.emf")[0, 43]) }
        .to raise_error(Claricle::UnknownFormat)
    end
  end

  describe "the EPS/PS split reads the whole first line" do
    # 4096 is the scanner's chunk size. A token starting at 4093 leaves
    # three bytes in the first chunk, at 4094 two, at 4095 one -- so these
    # are what actually require the carry to be five bytes wide (one byte
    # of left context plus the four-byte token) rather than one. Starting
    # at 4096 or later needs no carry at all.
    [508, 4089, 4090, 4091, 4092, 4093, 8185, 8186, 8187].each do |padding|
      it "finds EPSF starting at byte #{padding + 4}, from content and from a path" do
        content = "%!PS#{" " * padding}EPSF\n"
        expect(Claricle.detect(content)).to eq(:eps)
        with_file.call(content) { |path| expect(Claricle::Image.from_path(path).format).to eq(:eps) }
      end
    end

    it "stops at the line end rather than running on to a later EPSF" do
      content = "%!PS-Adobe-3.0\n#{" " * 8000}EPSF\n"
      expect(Claricle.detect(content)).to eq(:ps)
      with_file.call(content) { |path| expect(Claricle::Image.from_path(path).format).to eq(:ps) }
    end

    # PostScript ends a line with CR, LF or CRLF. Scanning only for LF runs
    # a CR-terminated file's second line into its first.
    {
      "CR" => "%!PS-Adobe-3.0\r%%Title: EPSF\r",
      "CRLF" => "%!PS-Adobe-3.0\r\n%%Title: EPSF\r\n",
      "LF" => "%!PS-Adobe-3.0\n%%Title: EPSF\n"
    }.each do |terminator, content|
      it "treats EPSF on the second line of a #{terminator}-terminated file as :ps" do
        expect(Claricle.detect(content)).to eq(:ps)
        with_file.call(content) { |path| expect(Claricle::Image.from_path(path).format).to eq(:ps) }
      end
    end

    it "finds EPSF on a first line that never ends" do
      content = "%!PS#{" " * 508}EPSF"
      expect(Claricle.detect(content)).to eq(:eps)
      with_file.call(content) { |path| expect(Claricle.const_get(:Detector).detect_path(path)).to eq(:eps) }
    end

    it "finds EPSF comfortably inside the scan ceiling" do
      content = "%!PS#{" " * 12_000}EPSF\n"
      expect(Claricle.detect(content)).to eq(:eps)
      with_file.call(content) { |path| expect(Claricle::Image.from_path(path).format).to eq(:eps) }
    end

    # The literal case this ceiling exists for: an unterminated first line
    # long enough that scanning it fully would be unbounded. Reusing the
    # old 99_996 padding this spec used to (wrongly) expect :eps for.
    it "gives up on a first line that never ends past the scan ceiling" do
      content = "%!PS#{" " * 99_996}EPSF"
      expect(Claricle.detect(content)).to eq(:ps)
      with_file.call(content) { |path| expect(Claricle.const_get(:Detector).detect_path(path)).to eq(:ps) }
    end

    # A file that ends inside the third window, past HEADER_BYTES and
    # SVG_PROLOG_BYTES but short of the scan ceiling, has no line
    # terminator -- so only a genuine end of stream backs the match.
    # `read` returns fewer than CHUNK_BYTES only at real EOF, and that
    # has to count the same as a nil read or a line ending does.
    [8193, 9000, 12_287].each do |size|
      it "finds EPSF ending exactly at EOF, #{size} bytes in" do
        content = "%!PS#{" " * (size - 8)}EPSF"
        expect(content.bytesize).to eq(size)
        expect(Claricle.detect(content)).to eq(:eps)
        with_file.call(content) { |path| expect(Claricle.const_get(:Detector).detect_path(path)).to eq(:eps) }
      end
    end

    # EPSF landing exactly at the ceiling's edge must not be trusted the
    # way a token at a genuine line end or EOF is: the byte right after
    # it was never read, so a disqualifying byte sitting just past the
    # ceiling has to still win. Padded so EPSF occupies the last four
    # bytes this scan reads (byte indices 12284-12287) and the
    # disqualifying X sits at byte 12288 -- one past the 12,288-byte
    # ceiling.
    it "does not trust a token landing exactly on the ceiling's edge" do
      content = "%!PS#{" " * 12_280}EPSFX\n"
      expect(Claricle.detect(content)).to eq(:ps)
      with_file.call(content) { |path| expect(Claricle.const_get(:Detector).detect_path(path)).to eq(:ps) }
    end

    # EPSF is a whitespace-delimited field in the header, so a substring
    # match called these EPS files. Measured against the PostScript
    # parser, which calls both plain PostScript.
    {
      "%!PS-Adobe-3.0 XEPSFY" => "a token it is glued to on the left",
      "%!PS-Adobe-3.0 NOT-EPSFILE" => "a hyphenated word containing it",
      "%!PS-Adobe-3.0 EPSFILE" => "a longer word starting with it",
      "%!PS-Adobe-3.0 .EPSF" => "punctuation on the left",
      "%!PS-Adobe-3.0 EPSF.foo" => "punctuation on the right",
      "%!PS-Adobe-3.0 (EPSF)" => "brackets around it"
    }.each do |header, why|
      it "is plain PostScript for #{why}" do
        expect(Claricle.detect("#{header}\n")).to eq(:ps)
      end
    end

    it "accepts the bare EPSF field as well as a versioned one" do
      expect(Claricle.detect("%!PS-Adobe-3.0 EPSF\n")).to eq(:eps)
      expect(Claricle.detect("%!PS-Adobe-2.0 EPSF-1.2\n")).to eq(:eps)
    end

    # The field match reads one byte either side of the token, so a token
    # straddling a chunk boundary needs its neighbours carried with it.
    # Both a real field and a decoy are swept across the boundary.
    # The carry must not let the buffer edge stand in for a token's real
    # left-hand neighbour: a window made entirely of carried bytes once
    # matched "EPSF " at position 0, turning "%!PS XEPSF " into an EPS.
    it "decides the same way wherever the token falls across a chunk edge" do
      wrong = []
      (4080..4105).each do |offset|
        padding = " " * (offset - 4)
        { "EPSF-3.0" => :eps, "EPSF" => :eps, "XEPSF" => :ps, ".EPSF" => :ps }
          .each do |token, want|
            ["\n", "", " "].each do |tail|
              source = "%!PS#{padding}#{token}#{tail}"
              got = Claricle.detect(source)
              wrong << "#{offset}/#{token}/#{tail.inspect}=#{got}" unless got == want
            end
          end
      end

      expect(wrong).to be_empty
    end

    # Rejecting a boundary decoy must not end the search of its window.
    # Examining only the FIRST match meant a decoy straddling the chunk
    # edge hid a real `EPSF` later on the same line, and the file read
    # as :ps -- through both entry points.
    it "keeps looking after rejecting a decoy at the chunk boundary" do
      source = "%!PS#{" " * 4086}XEPSF EPSF\n"

      expect(Claricle.detect(source)).to eq(:eps)

      # Detector.detect_path, not the public wrapper: #7 removes
      # Claricle.detect_path, and this spec has to survive that.
      Tempfile.create(["decoy", ".eps"]) do |file|
        file.binmode
        file.write(source)
        file.flush
        expect(Claricle.const_get(:Detector).detect_path(file.path)).to eq(:eps)
      end
    end

    # The decoy alone still decides :ps -- the fix must not turn every
    # rejected match into an accepted one.
    it "still refuses a window whose only field is a decoy" do
      expect(Claricle.detect("%!PS#{" " * 4086}XEPSF\n")).to eq(:ps)
      expect(Claricle.detect("%!PS#{" " * 4086}XEPSFY\n")).to eq(:ps)
    end

    # No line ending at all, so the decision is made at end of file.
    it "decides a token flush against the end of the file" do
      expect(Claricle.detect("%!PS EPSF")).to eq(:eps)
      expect(Claricle.detect("%!PS XEPSF")).to eq(:ps)
    end

    it "treats a bare %!PS as plain PostScript" do
      expect(Claricle.detect("%!PS")).to eq(:ps)
    end

    it "treats a long first line without EPSF as plain PostScript" do
      expect(Claricle.detect("%!PS#{"x" * 50_000}")).to eq(:ps)
    end
  end

  describe "SVG forms a regex misses" do
    {
      "a prefixed root" => %(<s:svg xmlns:s="#{svg_ns}"/>),
      "an internal DTD subset" => %(<!DOCTYPE svg [<!ENTITY a "b">]><svg xmlns="#{svg_ns}"/>),
      "an XML declaration" => %(<?xml version="1.0"?><svg xmlns="#{svg_ns}"/>)
    }.each do |description, content|
      it "detects SVG with #{description}" do
        expect(Claricle.detect(content)).to eq(:svg)
      end
    end

    it "accepts the canonical XML QName grammar through an ordinary prolog" do
      prefix = canonical_prefix.call
      source = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <?#{prefix} probe?>
        <!DOCTYPE #{prefix}:svg>
        <#{prefix}:svg xmlns:#{prefix}="#{svg_ns}" width="7"/>
      XML
      ncname = /\A#{REXML::XMLTokens::NCNAME_STR}\z/u

      expect(prefix).to match(ncname)
      expect(Claricle.detect(source)).to eq(:svg)
      expect(Claricle.const_get(:Detector).read_root(source))
        .to eq(["#{prefix}:svg", { "xmlns:#{prefix}" => svg_ns, "width" => "7" }])
    end

    it "accepts canonical XML names in an entity declaration" do
      name = canonical_prefix.call
      source = <<~XML
        <!DOCTYPE svg [
          <!ENTITY #{name} "unused">
        ]>
        <svg xmlns="#{svg_ns}"/>
      XML

      expect(Claricle.detect(source)).to eq(:svg)
    end

    it "applies a namespace default declared with canonical XML names" do
      prefix = canonical_prefix.call
      source = <<~XML
        <!DOCTYPE #{prefix}:svg [
          <!ATTLIST #{prefix}:svg xmlns:#{prefix} CDATA "#{svg_ns}"
            width CDATA "7" kind (#{prefix}|plain) "#{prefix}">
        ]>
        <#{prefix}:svg/>
      XML

      expect(Claricle.detect(source)).to eq(:svg)
      expect(Claricle.const_get(:Detector).read_root(source))
        .to eq(["#{prefix}:svg", { "xmlns:#{prefix}" => svg_ns, "width" => "7",
                                   "kind" => prefix }])
    end

    it "treats declaration-less XML QNames as UTF-8 through both entry points" do
      source = %(<é:svg xmlns:é="#{svg_ns}" width="7"/>)

      expect(Claricle.detect(source)).to eq(:svg)
      with_file.call(source) do |path|
        expect(Claricle::Image.from_path(path).format).to eq(:svg)
      end
    end

    it "preserves a declared legacy encoding while adapting XML names" do
      source = <<~XML.encode("ISO-8859-1").b
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <a·:svg xmlns:a·="#{svg_ns}" width="7"/>
      XML

      expect(Claricle.detect(source)).to eq(:svg)
      with_file.call(source) do |path|
        expect(Claricle::Image.from_path(path).format).to eq(:svg)
      end
    end

    it "detects SVG encoded UTF-16LE with a BOM" do
      content = "\xFF\xFE".b + %(<svg xmlns="#{svg_ns}"/>).encode("UTF-16LE").b
      expect(Claricle.detect(content)).to eq(:svg)
    end

    # Through both entry points: testing only the path would let the String
    # path quietly parse nothing but the header and still pass.
    it "detects a root sitting behind a 5000-byte comment" do
      content = "<!--#{"x" * 5000}--><svg xmlns=\"#{svg_ns}\"/>"
      expect(Claricle.detect(content)).to eq(:svg)
      with_file.call(content) { |path| expect(Claricle::Image.from_path(path).format).to eq(:svg) }
    end
  end

  describe "rejections" do
    {
      "a root in a foreign namespace" => %(<svg xmlns="urn:not-svg"/>),
      "an svg with no namespace at all" => "<svg/>",
      "an undeclared root prefix" => "<s:svg/>",
      "a root prefix bound to a foreign namespace" => %(<s:svg xmlns:s="urn:not-svg"/>),
      "a prefixed root with only the SVG default namespace" => %(<s:svg xmlns="#{svg_ns}"/>),
      "a decoy inside a comment" => "<!-- <svg --><html/>",
      "the right namespace on the wrong root" => %(<rect xmlns="#{svg_ns}"/>)
    }.each do |description, content|
      it "refuses #{description}" do
        expect { Claricle.detect(content) }.to raise_error(Claricle::UnknownFormat)
      end
    end
  end

  describe "unknown input" do
    it "refuses plain text" do
      expect { Claricle.detect("hello world") }.to raise_error(Claricle::UnknownFormat)
    end

    it "refuses a partial PNG signature" do
      expect { Claricle.detect("\x89P".b) }.to raise_error(Claricle::UnknownFormat)
    end

    it "refuses empty content and an empty file" do
      expect { Claricle.detect("") }.to raise_error(Claricle::UnknownFormat)
      with_file.call("") do |path|
        expect { Claricle::Image.from_path(path) }.to raise_error(Claricle::UnknownFormat)
      end
    end

    it "raises something callers can rescue as Claricle::Error" do
      expect { Claricle.detect("hello world") }.to raise_error(Claricle::Error)
    end
  end

  # Emf.detect_format raises for every non-metafile input. Both of these
  # reach that probe, so an unrescued call would surface Emf::FormatError
  # instead. PNG proves nothing here -- it returns at the first probe.
  describe "the metafile probe's error never escapes" do
    it "passes plain text through to UnknownFormat" do
      expect { Claricle.detect("hello world") }.to raise_error(Claricle::UnknownFormat)
    end

    it "passes SVG through to the XML probe" do
      expect(Claricle.detect(%(<svg xmlns="#{svg_ns}"/>))).to eq(:svg)
    end
  end

  describe "encoding" do
    it "detects binary signature bytes handed over tagged as UTF-8" do
      content = "\x89PNG\r\n\x1A\n".dup.force_encoding("UTF-8")
      expect(Claricle.detect(content)).to eq(:png)
    end

    it "detects an exact String's bytes instead of its singleton b view" do
      content = fixture.call("valid.png")
      content.define_singleton_method(:b) { "not a PNG".b }
      content.freeze

      expect(Claricle.detect(content)).to eq(:png)
    end
  end

  # Character references and XML's predefined entities are resolved (see
  # the namespace group below); general entities declared in a DTD are not.
  # Putting one in the root's xmlns makes that observable through the return
  # value -- an implementation that resolved it would answer :svg, so
  # refusing is the proof.
  describe "general entities are never resolved" do
    # Titled for what it asserts. The file is real and holds the SVG
    # namespace, so resolving the entity would answer :svg -- refusing is
    # the proof it stayed unresolved. It says nothing about whether the
    # file was opened; the nonexistent-path example below is what shows
    # nothing is fetched.
    it "does not resolve a SYSTEM entity, even one naming the SVG namespace" do
      Tempfile.create("ns") do |secret|
        secret.write(svg_ns)
        secret.flush
        doctype = %(<!DOCTYPE svg [<!ENTITY ns SYSTEM "file://#{secret.path}">]>)
        expect { Claricle.detect(%(#{doctype}<svg xmlns="&ns;"/>)) }
          .to raise_error(Claricle::UnknownFormat)
      end
    end

    it "does not resolve an internal entity in the namespace either" do
      doctype = %(<!DOCTYPE svg [<!ENTITY ns "#{svg_ns}">]>)
      expect { Claricle.detect(%(#{doctype}<svg xmlns="&ns;"/>)) }
        .to raise_error(Claricle::UnknownFormat)
    end

    it "still detects a document that references an entity outside the root tag" do
      doctype = %(<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///nonexistent/nope">]>)
      expect(Claricle.detect(%(#{doctype}<svg xmlns="#{svg_ns}">&xxe;</svg>))).to eq(:svg)
    end

    # In xmlns, not in an unread attribute: this has to reach
    # resolve_references to prove anything -- REXML's pull parser never
    # substitutes a general entity into an attribute value, so the value
    # handed to resolve_references is the literal "&d;", however deeply
    # the declarations that reference it are nested. This proves refusal
    # and proves no time is lost walking those declarations; it is not
    # evidence that entity_expansion_text_limit ever fires.
    it "does not amplify deeply nested internal entities" do
      nested = [
        %(<!ENTITY a "#{"a" * 100}">),
        %(<!ENTITY b "#{"&a;" * 100}">),
        %(<!ENTITY c "#{"&b;" * 100}">),
        %(<!ENTITY d "#{"&c;" * 100}">)
      ].join
      content = %(<!DOCTYPE svg [#{nested}]><svg xmlns="&d;"/>)
      expect { Timeout.timeout(5) { Claricle.detect(content) } }
        .to raise_error(Claricle::UnknownFormat)
    end
  end

  describe "malformed XML" do
    it "reports an unusable encoding name as an unknown format" do
      content = %(<?xml version="1.0" encoding="no-such-encoding"?><svg xmlns="#{svg_ns}"/>)
      expect { Claricle.detect(content) }.to raise_error(Claricle::UnknownFormat)
    end

    # Namespaced, so this still fails if the invalid bytes are ignored and
    # the root parses anyway.
    it "reports undecodable bytes as an unknown format" do
      content = "<?xml version=\"1.0\"?>\xC3\x28<svg xmlns=\"#{svg_ns}\"/>"
      expect { Claricle.detect(content) }.to raise_error(Claricle::UnknownFormat)
    end
  end

  describe "namespace normalization" do
    # XML replaces character references when normalizing an attribute, so a
    # conformant parser sees the SVG namespace here. REXML's own DOM does.
    it "resolves a character reference inside the namespace" do
      expect(Claricle.detect(%(<svg xmlns="http://www.w3.org/2000/sv&#x67;"/>))).to eq(:svg)
    end

    it "still refuses a foreign namespace written with character references" do
      expect { Claricle.detect(%(<svg xmlns="urn:not-sv&#x67;"/>)) }
        .to raise_error(Claricle::UnknownFormat)
    end

    # An escaped ampersand is ordinary in a URL query string, and the
    # reserved-prefix guard must not mistake the resolved text for a
    # still-unresolved reference: it reads the RAW value for that.
    #
    # The fixture resolves to "&foo;", not to "&amp;", on purpose.
    # "&amp;" is one of the five the lookahead already excludes, so a
    # mutant reading the resolved value stayed green through it --
    # measured, the whole file did. "&foo;" is the shape only the
    # raw-versus-resolved choice gets right.
    it "still accepts an unrelated prefix whose resolved value reads as a reference" do
      source = %(<svg xmlns="#{svg_ns}" xmlns:p="https://example.test/?a=1&amp;foo;b=2"/>)

      expect(Claricle.detect(source)).to eq(:svg)
    end

    # Sized to sit inside the 8192-byte prolog bound. An earlier version
    # used 10_241 references, which pushed the root tag past the bound --
    # REXML then gave up on a truncated tag and resolve_references never
    # ran, so the example passed without resolving anything.
    #
    # A reference is never longer expanded than it is in the source, so
    # this is not a runaway waiting to be capped. What it pins is that
    # entity_expansion_text_limit does not misfire on many legitimate
    # references -- it does not pin that resolution ran: the raw and the
    # resolved string are both != the SVG namespace here, so this example
    # passes either way. The character-reference example above is what
    # pins resolution itself.
    it "refuses a namespace dense with references" do
      expect { Claricle.detect(%(<svg xmlns="#{"&amp;" * 1000}"/>)) }
        .to raise_error(Claricle::UnknownFormat)
    end

    # Rescued as RangeError inside resolve_references. Unrescued it would
    # reach the caller instead of UnknownFormat.
    it "refuses a namespace with an out-of-range numeric reference" do
      expect { Claricle.detect(%(<svg xmlns="&#99999999999999999999;"/>)) }
        .to raise_error(Claricle::UnknownFormat)
    end
  end

  describe "accepted sources" do
    it "accepts a String" do
      expect(Claricle.detect(fixture.call("valid.png"))).to eq(:png)
    end

    it "accepts a seekable IO" do
      with_file.call(fixture.call("valid.emf")) do |path|
        File.open(path, "rb") { |io| expect(Claricle.detect(io)).to eq(:emf) }
      end
    end

    # Nothing here rewinds a caller's IO, so a pipe must work too.
    it "accepts a non-seekable IO" do
      reader, writer = IO.pipe
      writer.write(fixture.call("valid.emf"))
      writer.close
      expect(Claricle.detect(reader)).to eq(:emf)
    ensure
      reader&.close
      writer&.close
    end

    # Documented behaviour: the IO is read from wherever it sits, never
    # rewound. Without this, nothing stops a future rewind creeping in.
    it "reads a seekable IO from its current position, not from byte zero" do
      io = StringIO.new("JUNKJUNK#{fixture.call("valid.png")}")
      io.read(8)
      expect(Claricle.detect(io)).to eq(:png)
    end

    it "sees the junk when that same IO is not advanced" do
      io = StringIO.new("JUNKJUNK#{fixture.call("valid.png")}")
      expect { Claricle.detect(io) }.to raise_error(Claricle::UnknownFormat)
    end

    # Every fixture above is smaller than HEADER_BYTES, so an implementation
    # that read only a header from an IO would pass them all. This one needs
    # the root at byte 5007.
    context "with content larger than the probe header" do
      let(:long_svg) { "<!--#{"x" * 5000}--><svg xmlns=\"#{svg_ns}\"/>" }

      it "reads past the header from a seekable IO" do
        with_file.call(long_svg) do |path|
          File.open(path, "rb") { |io| expect(Claricle.detect(io)).to eq(:svg) }
        end
      end

      it "reads past the header from a non-seekable IO" do
        reader, writer = IO.pipe
        feeder = Thread.new do
          writer.write(long_svg)
        ensure
          writer.close
        end
        expect(Claricle.detect(reader)).to eq(:svg)
        feeder.join
      ensure
        reader&.close
        writer&.close
      end
    end

    it "reads a bounded amount from a large IO instead of draining it" do
      io = StringIO.new(fixture.call("valid.png") + ("x" * 1_000_000))
      expect(Claricle.detect(io)).to eq(:png)
      expect(io.pos).to be < 1_000_000
    end

    # read(length) returns nil at EOF, unlike no-arg read which returns
    # "". Switching to a bounded read means an already-exhausted IO must
    # not crash trying to detect nil.
    it "refuses an IO that is already at EOF" do
      io = StringIO.new("")
      expect { Claricle.detect(io) }.to raise_error(Claricle::UnknownFormat)
    end

    # Simulates a source that never reaches EOF -- a read with no length
    # would wait for a close that never comes. detect must return once it
    # has read its own bound instead of waiting on the writer.
    it "returns from a pipe that stays open past its bound" do
      reader, writer = IO.pipe
      writer_thread = Thread.new do
        writer.write(fixture.call("valid.png") + ("x" * 50_000))
      rescue IOError, Errno::EPIPE
        # Expected once the ensure block below closes the pipe out from
        # under this thread; nothing here depends on the write finishing.
      end

      expect(Timeout.timeout(2) { Claricle.detect(reader) }).to eq(:png)
    ensure
      reader&.close
      writer&.close
      writer_thread&.kill
    end

    # A complete, conclusive image sitting on a pipe the writer never
    # closes -- no more bytes are coming, but nothing tells detect that.
    # `read(bound)` blocks until either the bound or EOF, so a full PNG
    # far short of the bound hung forever. Only readpartial's "whatever
    # is already there" semantics let a short image settle without
    # waiting on a writer that has nothing left to say.
    it "does not block on a short, complete image over a pipe that stays open" do
      reader, writer = IO.pipe
      writer.write(fixture.call("valid.png"))

      expect(Timeout.timeout(2) { Claricle.detect(reader) }).to eq(:png)
    ensure
      reader&.close
      writer&.close
    end

    # A byte that has not arrived yet can still turn EPSF from a trusted
    # match into a disqualified one, so an :eps read from a still-growing
    # buffer must not be trusted the way a PNG signature match is --
    # detect has to keep waiting on the pipe rather than settle early.
    it "does not settle a PostScript verdict before a disqualifying byte can arrive" do
      reader, writer = IO.pipe
      writer.write("%!PS EPSF")
      verdict = Thread.new { Claricle.detect(reader) }

      expect(verdict.join(0.2)).to be_nil

      writer.write("X\n")
      writer.close
      expect(Timeout.timeout(2) { verdict.value }).to eq(:ps)
    ensure
      reader&.close
      writer&.close
    end
  end

  # A file beginning "<" with no ">" made REXML hold one live string for
  # the construct it was reading: +52MB of RSS for 1MB of input, +217MB
  # for 16MB. The probe now reads a bounded prolog, so the worst case is
  # fixed rather than proportional to the file.
  # XML 1.0 requires attribute defaults from the internal subset to be
  # applied, and REXML's own DOM applies them -- so reading only the
  # explicit root attributes rejected a valid SVG.
  describe "attribute defaults declared in an internal DTD" do
    def doc(attlist, root)
      %(<?xml version="1.0"?>\n<!DOCTYPE svg [\n  #{attlist}\n]>\n#{root})
    end

    svg_ns = "http://www.w3.org/2000/svg"

    it "takes xmlns from a #FIXED default when the root omits it" do
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">), "<svg width='10'/>")

      expect(Claricle.detect(source)).to eq(:svg)
    end

    it "prefers an explicit xmlns over the declared default" do
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "http://example.com/other">),
                   %(<svg xmlns="#{svg_ns}"/>))

      expect(Claricle.detect(source)).to eq(:svg)
    end

    it "still rejects a default naming some other namespace" do
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "http://example.com/other">),
                   "<svg width='10'/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    # XML accumulates declarations, and the first declaration of an
    # attribute binds -- so a later ATTLIST neither wipes the earlier
    # one nor overrides a duplicate.
    it "accumulates defaults across separate ATTLIST declarations" do
      width_decl = %(<!ATTLIST svg width CDATA "10">)
      ns_decl = %(  <!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">)
      source = doc("#{width_decl}\n#{ns_decl}", "<svg/>")

      expect(Claricle.detect(source)).to eq(:svg)
    end

    it "binds the first of two declarations for the same attribute" do
      ours = %(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">)
      theirs = %(  <!ATTLIST svg xmlns CDATA #FIXED "http://example.com/other">)
      first_wins = doc("#{ours}\n#{theirs}", "<svg/>")
      other_first = doc("#{theirs.strip}\n  #{ours}", "<svg/>")

      expect(Claricle.detect(first_wins)).to eq(:svg)
      expect { Claricle.detect(other_first) }.to raise_error(Claricle::UnknownFormat)
    end

    # REXML collapses duplicates inside ONE declaration last-wins before
    # handing over the parsed hash, so the raw source is re-read for the
    # order XML actually specifies.
    it "binds the first of two declarations inside a single ATTLIST" do
      ours = %(xmlns CDATA #FIXED "#{svg_ns}")
      theirs = %(xmlns CDATA #FIXED "http://example.com/other")

      expect(Claricle.detect(doc("<!ATTLIST svg #{ours} #{theirs}>", "<svg/>"))).to eq(:svg)
      expect { Claricle.detect(doc("<!ATTLIST svg #{theirs} #{ours}>", "<svg/>")) }
        .to raise_error(Claricle::UnknownFormat)
    end

    it "reads an xmlns declared after an enumerated attribute" do
      source = doc(%(<!ATTLIST svg kind (a|b) "a" xmlns CDATA #FIXED "#{svg_ns}">), "<svg/>")

      expect(Claricle.detect(source)).to eq(:svg)
    end

    # Separate #FIXED from its value by anything but a plain space and
    # REXML hands over the separator instead of the value -- "#FIXED\t"
    # for a tab. Only the raw scan recovers the namespace, so without it
    # both of these are unknown formats rather than SVG.
    {
      "a tab" => %(<!ATTLIST svg xmlns CDATA #FIXED\t"#{svg_ns}">),
      "a newline" => %(<!ATTLIST svg xmlns\n  CDATA\n  #FIXED\n  "#{svg_ns}">)
    }.each do |separator, attlist|
      it "reads a default that #{separator} separates from #FIXED" do
        expect(Claricle.detect(doc(attlist, "<svg/>"))).to eq(:svg)
      end
    end

    # Pinned as a known limitation, not an endorsement: REXML raises
    # "Bad ATTLIST declaration!" for a single-quoted default before any
    # event reaches us, so a document XML permits is reported unknown.
    # If REXML ever fixes this, the example fails and we revisit.
    it "cannot read a single-quoted default, and fails closed" do
      # The SVG namespace deliberately: with a foreign one the example
      # would pass whether or not REXML is fixed, pinning nothing. This
      # document is a valid SVG, so the day REXML parses it, detection
      # succeeds and this example goes red.
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED '#{svg_ns}'>), "<svg/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    # `#IMPLIED` means "declared, no default", so it is a real answer and
    # not an absence. XML binds the first declaration, so a later one
    # carrying a value must not fill in what the first left undeclared --
    # a first-wins rule keyed on truthiness rather than presence got this
    # backwards and reported a plain XML document as an SVG.
    describe "an attribute declared without a default" do
      it "is not resurrected by a later declaration in the same ATTLIST" do
        source = doc(%(<!ATTLIST svg xmlns CDATA #IMPLIED xmlns CDATA #FIXED "#{svg_ns}">),
                     "<svg/>")

        expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
      end

      it "is not resurrected by a later ATTLIST either" do
        implied = %(<!ATTLIST svg xmlns CDATA #IMPLIED>)
        fixed = %(  <!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">)

        expect { Claricle.detect(doc("#{implied}\n#{fixed}", "<svg/>")) }
          .to raise_error(Claricle::UnknownFormat)
      end

      it "does not disturb a different attribute declared after it" do
        source = doc(%(<!ATTLIST svg id ID #IMPLIED xmlns CDATA #FIXED "#{svg_ns}">),
                     "<svg/>")

        expect(Claricle.detect(source)).to eq(:svg)
      end

      it "is still overridden by an explicit attribute on the root" do
        source = doc(%(<!ATTLIST svg xmlns CDATA #IMPLIED>),
                     %(<svg xmlns="#{svg_ns}"/>))

        expect(Claricle.detect(source)).to eq(:svg)
      end
    end

    it "does not apply another element's defaults to the root" do
      source = doc(%(<!ATTLIST other xmlns CDATA #FIXED "#{svg_ns}">), "<svg width='10'/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    # `xml` is permanently bound to the XML namespace and `xmlns` cannot
    # be used as a prefix at all -- REXML enforces that for an explicit
    # declaration, but the raw ATTLIST scan bypasses REXML's own
    # namespace validation, so a DTD default binding either reserved
    # prefix to the SVG namespace must be rejected here instead.
    it "rejects a DTD default that rebinds the reserved xml prefix" do
      source = %(<!DOCTYPE xml:svg [
  <!ATTLIST xml:svg xmlns:xml CDATA #FIXED "#{svg_ns}">
]>
<xml:svg/>)

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    it "rejects a DTD default that uses xmlns itself as a prefix" do
      source = %(<!DOCTYPE xmlns:svg [
  <!ATTLIST xmlns:svg xmlns:xmlns CDATA #FIXED "#{svg_ns}">
]>
<xmlns:svg/>)

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    # The reserved-prefix constraint is on the declaration, not on
    # whether the root happens to use that prefix for itself -- a plain,
    # unprefixed root carrying an unrelated xmlns:xml default is just as
    # invalid as one where xml: prefixes the root.
    it "rejects a plain root that DTD-defaults an unrelated xmlns:xml" do
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">\n  ) +
                   %(<!ATTLIST svg xmlns:xml CDATA #FIXED "#{svg_ns}">),
                   "<svg/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    it "still accepts xml redeclared to its own canonical namespace" do
      xml_ns = "http://www.w3.org/XML/1998/namespace"
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">\n  ) +
                   %(<!ATTLIST svg xmlns:xml CDATA #FIXED "#{xml_ns}">),
                   "<svg/>")

      expect(Claricle.detect(source)).to eq(:svg)
    end

    it "still accepts xml redeclared via a single legitimate reference" do
      xml_attlist = %(<!ATTLIST svg xmlns:xml CDATA #FIXED "http&#x3a;//www.w3.org/XML/1998/namespace">)
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">\n  #{xml_attlist}), "<svg/>")

      expect(Claricle.detect(source)).to eq(:svg)
    end

    # A value that only reads as the XML namespace after TWO rounds of
    # reference resolution must still be refused: XML resolves a
    # reference exactly once, so this declaration's true value is the
    # literal text "http://www.w3.org/XML/1998/n&#x61;mespace", which is
    # not the XML namespace. Regression guard for a bug where the guard
    # resolved an already-resolved value a second time and accepted it.
    it "rejects xml redeclared via a reference that only resolves after two passes" do
      xml_attlist = %(<!ATTLIST svg xmlns:xml CDATA #FIXED "http://www.w3.org/XML/1998/n&amp;#x61;mespace">)
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">\n  #{xml_attlist}), "<svg/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    # A lone UTF-16 surrogate half is not a valid Unicode scalar value,
    # so resolving it answers with invalid UTF-8 rather than raising.
    # The guard has to fail closed on that, not crash: regression guard
    # for a bug where re-resolving it fed invalid bytes into a regex
    # match and raised ArgumentError instead of refusing the document.
    it "rejects an unrelated prefix bound to a lone surrogate reference" do
      p_attlist = %(<!ATTLIST svg xmlns:p CDATA #FIXED "&#xD800;">)
      source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">\n  #{p_attlist}), "<svg/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    # The XML and XMLNS namespace names are just as reserved as the
    # prefixes that normally carry them -- binding either to some other
    # prefix is invalid even though neither reserved prefix is declared.
    {
      "the XML namespace name" => "http://www.w3.org/XML/1998/namespace",
      "the XMLNS namespace name" => "http://www.w3.org/2000/xmlns/"
    }.each do |label, reserved_ns|
      it "rejects #{label} bound to an unrelated prefix" do
        source = doc(%(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">\n  ) +
                     %(<!ATTLIST svg xmlns:p CDATA #FIXED "#{reserved_ns}">),
                     "<svg/>")

        expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
      end
    end

    # The root classifies through its own prefix (p:svg), so only the
    # reserved-namespace check -- not a mismatched root namespace --
    # can be what rejects the unrelated default-namespace declaration.
    it "rejects the XML namespace name bound as the default namespace" do
      xml_ns = "http://www.w3.org/XML/1998/namespace"
      source = doc(%(<!ATTLIST p:svg xmlns:p CDATA #FIXED "#{svg_ns}">\n  ) +
                   %(<!ATTLIST p:svg xmlns CDATA #FIXED "#{xml_ns}">),
                   "<p:svg/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end

    # resolve_references deliberately leaves a general entity reference
    # unexpanded, so a reserved namespace name smuggled in through one
    # doesn't literally equal XML_NAMESPACE or XMLNS_NAMESPACE -- the
    # reserved check has to fail closed on the unresolved reference
    # itself rather than read that as proof the binding is safe.
    {
      "the XML namespace name" => "http://www.w3.org/XML/1998/namespace",
      "the XMLNS namespace name" => "http://www.w3.org/2000/xmlns/"
    }.each do |label, reserved_ns|
      it "rejects #{label} smuggled through an unresolved general entity" do
        source = %(<!DOCTYPE svg [
  <!ENTITY r "#{reserved_ns}">
  <!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">
  <!ATTLIST svg xmlns:p CDATA #FIXED "&r;">
]>
<svg/>)

        expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
      end
    end
  end

  # An entity NAME is an XML Name, and XML Names are Unicode. The guard
  # once matched `[A-Za-z_:][\w.:-]*`, and Ruby's `\w` is ASCII-only, so
  # every one of these sailed past it and the document read as :svg --
  # while the same document with an ASCII entity name was correctly
  # refused.
  #
  # No DTD here, deliberately: the reference should reach the reserved-name
  # guard without making declaration parsing another precondition. It is also
  # the raw shape an external DTD produces, which is how this was reported.
  describe "entity names outside ASCII" do
    # One case per NameStartChar range a reviewer might expect the ASCII
    # class to have covered by accident. `é` is the reported case; the
    # other two are here because widening a regex until the reported
    # case passes is exactly how these two would have been left behind.
    {
      "a Latin-1 name (U+00E9)" => "\u{E9}",
      "a CJK name (U+3042)" => "\u{3042}",
      "an astral-plane name (U+10400)" => "\u{10400}"
    }.each do |label, entity_name|
      it "rejects a reserved namespace smuggled through #{label}" do
        source = %(<svg xmlns="#{svg_ns}" xmlns:p="&#{entity_name};"/>)

        expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
      end
    end

    # The guard's own subject, not the detector's verdict: the examples
    # above would stay green if detection refused these documents for
    # some unrelated reason, and this one cannot.
    it "sees a non-ASCII entity name as an unresolved reference" do
      references = Claricle.const_get(:AttributeReferences)

      expect(references).to be_unresolved("&\u{E9};")
      expect(references).to be_unresolved("&\u{3042};")
    end

    {
      "binary text with a high byte" => "\xFF".b,
      "invalid UTF-8" => "\xFF".dup.force_encoding(Encoding::UTF_8)
    }.each do |label, raw|
      it "treats #{label} as unresolved rather than raising" do
        references = Claricle.const_get(:AttributeReferences)

        expect(references).to be_unresolved(raw)
      end
    end

    # All five, not just `amp`. Each one is a reference the resolver
    # DOES have a table for, so reading it as unresolved would refuse a
    # namespace value holding an ordinary escaped `<` or `"`. Measured:
    # cutting `lt`, `gt`, `apos` and `quot` out of the lookahead left
    # the whole suite green when only `amp` was asserted here.
    it "sees none of the five predefined entities as unresolved" do
      references = Claricle.const_get(:AttributeReferences)

      %w[amp lt gt apos quot].each do |predefined|
        expect(references).not_to be_unresolved("&#{predefined};")
      end
    end

    # The other direction, which none of the examples above prove: a
    # guard that refused every non-ASCII value would pass all of them.
    # This value carries no reference at all and has to come through.
    it "still accepts a non-ASCII namespace value carrying no reference" do
      source = %(<svg xmlns="#{svg_ns}" xmlns:p="https://\u{4F8B}.test/\u{3042}"/>)

      expect(Claricle.detect(source)).to eq(:svg)
    end

    # The name class in the detector is hand-transcribed from XML 1.0
    # 5th ed., and a hand transcription drifts from the production it
    # claims to copy without anything going red. REXML ships its OWN
    # transcription of that same production, so the two are checked
    # against each other instead of against a reviewer's memory.
    #
    # Exhaustive rather than sampled: an off-by-one at a range edge is
    # exactly the error this is looking for, and sampling is how you
    # miss one. Every BMP codepoint plus the astral boundaries, ~120ms.
    #
    # REXML's constants are its own -- XMLTokens says "not for general
    # consumption" -- which is why the detector does not simply use
    # them. Depending on them HERE puts the risk in the right place: if
    # REXML ever drops them, this spec fails loudly and the library
    # keeps working.
    it "matches REXML's own transcription of the XML Name grammar" do
      canonical = /&(?!amp;|lt;|gt;|apos;|quot;)#{REXML::XMLTokens::NAME_START_CHAR}#{REXML::XMLTokens::NAME_CHAR}*;/
      mine = Claricle.const_get(:AttributeReferences).const_get(:UNRESOLVED_REFERENCE)
      # Surrogate halves are excluded because they are not codepoints a
      # String can hold on their own, not because the grammar skips them.
      codepoints = (0..0xFFFF).grep_v(0xD800..0xDFFF) +
                   [0x10000, 0x10001, 0x10400, 0xEFFFF, 0xF0000, 0x10FFFF]

      disagreements = codepoints.reject do |cp|
        char = cp.chr("UTF-8")
        mine.match?("&#{char};") == canonical.match?("&#{char};") &&
          mine.match?("&x#{char};") == canonical.match?("&x#{char};")
      end

      expect(disagreements.map { |cp| format("U+%04X", cp) }).to be_empty
    end
  end

  describe "the SVG prolog bound" do
    svg_tag = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'

    it "still detects an ordinary SVG" do
      expect(Claricle.detect(svg_tag)).to eq(:svg)
    end

    it "still detects one behind a declaration and a full DOCTYPE" do
      declaration = %(<?xml version="1.0" encoding="UTF-8"?>\n)
      doctype = %(<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" ) +
                %("http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n)

      expect(Claricle.detect("#{declaration}#{doctype}#{svg_tag}")).to eq(:svg)
    end

    it "accepts a root that ends on the last byte of the bound" do
      padding = "<!--#{"x" * (8192 - svg_tag.bytesize - 7)}-->"
      expect(Claricle.detect(padding + svg_tag)).to eq(:svg)
    end

    # One byte further and the root tag loses its closing ">". The XML
    # comment still completes at byte 8131 -- what falls outside the bound
    # is the tag itself, so there is no root to read. Pinned both sides,
    # or "a big prolog fails" would pass for any cap.
    it "rejects the same root one byte beyond the bound" do
      padding = "<!--#{"x" * (8192 - svg_tag.bytesize - 6)}-->"
      expect { Claricle.detect(padding + svg_tag) }
        .to raise_error(Claricle::UnknownFormat)
    end

    # The title used to say "without reading it all", which nothing here
    # asserts -- slurping the file and slicing to 8192 afterwards would
    # leave this green. The two examples above are what pin the bound, on
    # both sides. This one only covers the shape that provoked the memory
    # blow-up: a file with no ">" anywhere.
    it "refuses a delimiter-free file" do
      hostile = "<#{"a" * 1_000_000}"

      expect { Claricle.detect(hostile) }.to raise_error(Claricle::UnknownFormat)
    end
  end

  describe "public surface" do
    # All three constants, not just Detector: dropping one from the
    # private_constant call used to leave the whole suite green. Written
    # out rather than looped because const_get walks straight past
    # private_constant, so only the literal reference raises.
    it "keeps Detector private" do
      expect { Claricle::Detector }.to raise_error(NameError, /private constant/)
    end

    it "keeps EpsHeader private" do
      expect { Claricle::EpsHeader }.to raise_error(NameError, /private constant/)
    end

    it "keeps ReservedNamespace private" do
      expect { Claricle::ReservedNamespace }.to raise_error(NameError, /private constant/)
    end

    it "lists none of them among its constants" do
      expect(Claricle.constants & %i[Detector EpsHeader ReservedNamespace]).to be_empty
    end

    it "loads REXML for itself in a fresh process" do
      lib = File.expand_path("../../lib", __dir__)
      script = %(require "claricle"; print Claricle.detect(%q(<svg xmlns="#{svg_ns}"/>)))
      output = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", script], err: %i[child out], &:read)
      expect($CHILD_STATUS).to be_success, "subprocess failed: #{output}"
      expect(output).to eq("svg")
    end
  end
end
