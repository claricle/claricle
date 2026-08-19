# frozen_string_literal: true

require "English"
require "stringio"
require "tempfile"
require "timeout"

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
          expect(Claricle.detect_path(path)).to eq(format)
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
          expect(Claricle.detect_path(path)).to eq(format)
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
    # are what actually require the carry to be three bytes wide rather
    # than one. Starting at 4096 or later needs no carry at all.
    [508, 4089, 4090, 4091, 4092, 4093, 8185, 8186, 8187, 99_996].each do |padding|
      it "finds EPSF starting at byte #{padding + 4}, from content and from a path" do
        content = "%!PS#{" " * padding}EPSF\n"
        expect(Claricle.detect(content)).to eq(:eps)
        with_file.call(content) { |path| expect(Claricle.detect_path(path)).to eq(:eps) }
      end
    end

    it "stops at the line end rather than running on to a later EPSF" do
      content = "%!PS-Adobe-3.0\n#{" " * 8000}EPSF\n"
      expect(Claricle.detect(content)).to eq(:ps)
      with_file.call(content) { |path| expect(Claricle.detect_path(path)).to eq(:ps) }
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
        with_file.call(content) { |path| expect(Claricle.detect_path(path)).to eq(:ps) }
      end
    end

    it "finds EPSF on a first line that never ends" do
      content = "%!PS#{" " * 99_996}EPSF"
      expect(Claricle.detect(content)).to eq(:eps)
      with_file.call(content) { |path| expect(Claricle.detect_path(path)).to eq(:eps) }
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

    it "detects SVG encoded UTF-16LE with a BOM" do
      content = "\xFF\xFE".b + %(<svg xmlns="#{svg_ns}"/>).encode("UTF-16LE").b
      expect(Claricle.detect(content)).to eq(:svg)
    end

    # Through both entry points: testing only the path would let the String
    # path quietly parse nothing but the header and still pass.
    it "detects a root sitting behind a 5000-byte comment" do
      content = "<!--#{"x" * 5000}--><svg xmlns=\"#{svg_ns}\"/>"
      expect(Claricle.detect(content)).to eq(:svg)
      with_file.call(content) { |path| expect(Claricle.detect_path(path)).to eq(:svg) }
    end
  end

  describe "rejections" do
    {
      "a root in a foreign namespace" => %(<svg xmlns="urn:not-svg"/>),
      "an svg with no namespace at all" => "<svg/>",
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
        expect { Claricle.detect_path(path) }.to raise_error(Claricle::UnknownFormat)
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
  end

  # Character references and XML's predefined entities are resolved (see
  # the namespace group below); general entities declared in a DTD are not.
  # Putting one in the root's xmlns makes that observable through the return
  # value -- an implementation that resolved it would answer :svg, so
  # refusing is the proof.
  describe "general entities are never resolved" do
    it "does not fetch a file whose contents would make the root an SVG" do
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
    # resolve_references and its expansion limit to prove anything.
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

    # Unbounded expansion is prevented by the limit passed to unnormalize
    # rather than rescued; the out-of-range reference is rescued as
    # RangeError. Either escaping would exit 4 rather than 3.
    it "refuses a namespace that tries to expand without bound" do
      expect { Claricle.detect(%(<svg xmlns="#{"&amp;" * 10_241}"/>)) }
        .to raise_error(Claricle::UnknownFormat)
    end

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
      ns_decl = %(<!ATTLIST svg xmlns CDATA #FIXED "#{svg_ns}">)
      width_decl = %(  <!ATTLIST svg width CDATA "10">)
      source = doc("#{ns_decl}\n#{width_decl}", "<svg/>")

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

    it "does not apply another element's defaults to the root" do
      source = doc(%(<!ATTLIST other xmlns CDATA #FIXED "#{svg_ns}">), "<svg width='10'/>")

      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
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

    # One byte further and the comment is truncated, so there is no root
    # inside the bound. Pinned both sides, or "a big prolog fails" would
    # pass for any cap.
    it "rejects the same root one byte beyond the bound" do
      padding = "<!--#{"x" * (8192 - svg_tag.bytesize - 6)}-->"
      expect { Claricle.detect(padding + svg_tag) }
        .to raise_error(Claricle::UnknownFormat)
    end

    it "refuses a delimiter-free file without reading it all" do
      hostile = "<#{"a" * 1_000_000}"

      expect { Claricle.detect(hostile) }.to raise_error(Claricle::UnknownFormat)
    end
  end

  describe "public surface" do
    it "keeps Detector private" do
      expect { Claricle::Detector }.to raise_error(NameError, /private constant/)
    end

    it "does not list Detector among its constants" do
      expect(Claricle.constants).not_to include(:Detector)
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
