# frozen_string_literal: true

require "English"
# The DOM parser, required only by the specs: it is what "malformed"
# means in the root-prefix examples, and the library never loads it.
require "rexml/document"
require "rexml/security"
# FileUtils for the XXE example, which keeps its canary file alive across
# the whole example rather than letting a block form delete it early.
require "fileutils"
require "tempfile"

RSpec.describe "Claricle SVG handler" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Svg).new }
  let(:svg_ns) { "http://www.w3.org/2000/svg" }

  let(:with_svg_file) do
    lambda do |source, &block|
      Tempfile.create(["svg", ".svg"]) do |file|
        file.binmode
        file.write(source)
        file.flush
        block.call(file.path)
      end
    end
  end

  def svg(attributes, body = "")
    %(<svg xmlns="#{svg_ns}" #{attributes}>#{body}</svg>)
  end

  def inspect_svg(source)
    handler.inspection(Claricle::Image.from_content(source, format: :svg))
  end

  def canonical_prefix
    boundaries = [
      0xC0, 0xD6, 0xD8, 0xF6, 0xF8, 0x2FF, 0x370, 0x37D,
      0x37F, 0x1FFF, 0x200C, 0x200D, 0x2070, 0x218F, 0x2C00, 0x2FEF,
      0x3001, 0xD7FF, 0xF900, 0xFDCF, 0xFDF0, 0xFFFD, 0x10000, 0xEFFFF
    ]
    "a#{boundaries.pack("U*")}-.0\u{B7}\u{300}\u{36F}\u{203F}\u{2040}"
  end

  # `read` is the only call the reader is allowed to make, so it is the
  # only one counted in bytes. Everything else is counted as an event
  # that must never happen -- and the list is INVERTED for that: naming
  # the readers to watch was tried and lost three times, to readpartial,
  # to `pos = 0` and to pread. So every method a File has is watched,
  # minus the handful the plumbing itself needs.
  def allowed_calls
    %i[read close closed? path to_path to_io fileno]
  end

  # Subtracting Object's methods is what makes the list manageable, and
  # it is also a hole: copying the file is how you get an unwatched
  # handle on it, and `dup` and `clone` both come from Object, so the
  # subtraction removed them. A mutant duped the file and read the whole
  # body through the copy -- neither the copy nor its reads were ever
  # seen. They go back in by name.
  def watched_calls
    (File.instance_methods - Object.instance_methods - allowed_calls) | %i[dup clone]
  end

  def read_recorder(taken)
    recorder = Module.new
    recorder.define_method(:read) do |*args, **kwargs, &block|
      super(*args, **kwargs, &block).tap { |bytes| taken[:read] += bytes.to_s.bytesize }
    end
    count_calls(recorder, taken, watched_calls)
    recorder
  end

  def count_calls(recorder, taken, names)
    names.each do |name|
      recorder.define_method(name) do |*args, **kwargs, &block|
        super(*args, **kwargs, &block).tap { taken[:other] += 1 }
      end
    end
  end

  # Installs the recorder on every file opened from here on. Whatever
  # has already been opened is untouched, which is what keeps
  # detection's own reads out of the count.
  def watch_reads(taken)
    recorder = read_recorder(taken)
    allow(File).to receive(:open).and_wrap_original do |open, *args, &block|
      next open.call(*args, &block) unless block

      open.call(*args) do |file|
        file.singleton_class.prepend(recorder)
        block.call(file)
      end
    end
  end

  describe "dimensions" do
    it "reads a plain number as user units" do
      expect(inspect_svg(svg(%(width="100" height="50"))))
        .to have_attributes(width: 100.0, height: 50.0)
    end

    # vectory rounds this to 11; reading the attribute keeps it.
    it "keeps decimal precision" do
      expect(inspect_svg(svg(%(width="10.5" height="20.25"))).width).to eq(10.5)
    end

    # Computed from 1in = 96px, not copied. 72pt, 6pc and 1in are all 96.
    {
      "px" => 1.0, "in" => 96.0, "pc" => 16.0, "pt" => 96.0 / 72,
      "cm" => 96.0 / 2.54, "mm" => 96.0 / 25.4, "Q" => 96.0 / 101.6
    }.each do |unit, factor|
      it "converts #{unit} to CSS px" do
        expect(inspect_svg(svg(%(width="1#{unit}"))).width).to be_within(1e-9).of(factor)
      end
    end

    it "agrees with the identities the table rests on" do
      %w[72pt 6pc 1in].each do |declared|
        expect(inspect_svg(svg(%(width="#{declared}"))).width).to be_within(1e-9).of(96.0)
      end
    end

    # A relative unit has no absolute value without a viewport or font
    # metrics, so the numeric prefix would be a fiction.
    %w[% em ex rem ch vw vh vmin vmax].each do |unit|
      it "leaves a #{unit} dimension nil" do
        expect(inspect_svg(svg(%(width="100#{unit}"))).width).to be_nil
      end
    end

    it "keeps the declaration in meta whatever the unit" do
      inspection = inspect_svg(svg(%(width="100%" height="10mm")))

      expect(inspection.meta).to include("width" => "100%", "height" => "10mm")
    end

    # A viewBox defines an aspect ratio, not an intrinsic size (D15).
    # vectory answers 100x50 here.
    it "does not take dimensions from the viewBox" do
      inspection = inspect_svg(svg(%(viewBox="0 0 100 50")))

      expect(inspection).to have_attributes(width: nil, height: nil)
      expect(inspection.meta).to include("viewBox" => "0 0 100 50")
    end

    it "reports a width with no height" do
      expect(inspect_svg(svg(%(width="7"))))
        .to have_attributes(width: 7.0, height: nil)
    end

    it "reports a height with no width" do
      expect(inspect_svg(svg(%(height="7"))))
        .to have_attributes(width: nil, height: 7.0)
    end

    it "leaves both nil for a dimensionless SVG" do
      expect(inspect_svg(svg("")))
        .to have_attributes(width: nil, height: nil, parse_status: "ok")
    end

    # These fail at three different points, which is why all four are
    # here. `auto` and `abc` never reach Float() at all -- the number
    # grammar rejects them. `1e9999` parses, to Infinity. `1e308` parses
    # to a finite Float and only overflows once it is multiplied by 96.
    {
      "auto" => "auto", "an unknown token" => "abc",
      "an overflowing literal" => "1e9999",
      "a value that overflows only after conversion" => "1e308in"
    }.each do |label, declared|
      it "leaves the dimension nil for #{label}" do
        expect(inspect_svg(svg(%(width="#{declared}"))).width).to be_nil
      end
    end

    # The overflow reaches to_json as "Infinity not allowed in JSON",
    # so this is the difference between exit 0 and exit 4.
    it "serializes an overflowing dimension without raising" do
      expect { inspect_svg(svg(%(width="1e308in"))).to_json }.not_to raise_error
    end
  end

  describe "whitespace around a dimension" do
    # XML attribute-value normalization keeps surrounding whitespace for
    # a CDATA attribute, so these arrive with it and it is not part of
    # the value the document means.
    { "a leading space" => " 100", "a trailing space" => "100 ",
      "a tab" => "&#x9;100", "a newline" => "&#xA;100",
      "a carriage return" => "&#xD;100" }.each do |label, declared|
      it "ignores #{label}" do
        expect(inspect_svg(svg(%(width="#{declared}"))).width).to eq(100.0)
      end
    end

    # `\s` would accept these; XML's whitespace set does not, so they
    # are not whitespace and the value is not a dimension.
    #
    # XML 1.0 goes further and forbids the characters altogether, so a
    # complete parse rejects the document -- measured, REXML's DOM
    # raises on both. Inspection does not judge that: its scope is the
    # root prefix, and the dimension is nil either way.
    { "a vertical tab" => "&#xB;100", "a form feed" => "&#xC;100" }.each do |label, declared|
      it "does not treat #{label} as whitespace" do
        expect(inspect_svg(svg(%(width="#{declared}"))).width).to be_nil
      end
    end
  end

  # XML 1.0 3.3.3. Both halves are pinned, because normalizing
  # everything erases the difference just as surely as normalizing
  # nothing, and the two would then report the same metadata for two
  # documents that say different things.
  describe "attribute-value normalization" do
    { "a literal newline" => "a\nb", "a literal tab" => "a\tb",
      "a literal carriage return" => "a\rb",
      # One line ending, so ONE space: XML's line-end rule runs first.
      "a literal CRLF" => "a\r\nb" }.each do |label, declared|
      it "replaces #{label} with a space" do
        expect(inspect_svg(svg(%(id="#{declared}"))).meta["id"]).to eq("a b")
      end
    end

    { "a newline" => ["&#xA;", "\n"], "a tab" => ["&#x9;", "\t"],
      "a carriage return" => ["&#xD;", "\r"] }.each do |label, (reference, kept)|
      it "keeps #{label} written as a reference" do
        expect(inspect_svg(svg(%(id="a#{reference}b"))).meta["id"]).to eq("a#{kept}b")
      end
    end
  end

  describe "the complete inspection" do
    it "is pinned exactly for a readable root" do
      inspection = inspect_svg(svg(%(width="100" height="50" viewBox="0 0 100 50")))

      expect(inspection).to have_attributes(
        format: "svg", width: 100.0, height: 50.0, dpi: nil, color_space: nil,
        parse_status: "ok"
      )
      expect(inspection.issues).to be_empty
      expect(inspection.meta).to eq(
        "xmlns" => "http://www.w3.org/2000/svg",
        "width" => "100", "height" => "50", "viewBox" => "0 0 100 50"
      )
    end

    # Readable and unreadable are separate constructors, so the failed
    # branch could otherwise omit format or leak metadata.
    {
      "a malformed root tag" => %(<svg xmlns="x" width=),
      "no root element at all" => "",
      "an unusable encoding name" => %(<?xml version="1.0" encoding="not-a-charset"?><svg/>)
    }.each do |label, source|
      it "is pinned exactly for #{label}" do
        inspection = inspect_svg(source)

        expect(inspection).to have_attributes(
          format: "svg", width: nil, height: nil, dpi: nil,
          color_space: nil, parse_status: "failed"
        )
        expect(inspection.meta).to be_nil
        expect(inspection.issues.map { |i| [i.severity, i.code, i.message] })
          .to eq([["error", "svg.root_unreadable", "SVG root element could not be read"]])
      end
    end
  end

  describe "qualified root names" do
    it "inspects the canonical XML QName grammar through an ordinary prolog" do
      prefix = canonical_prefix
      source = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <?#{prefix} probe?>
        <!DOCTYPE #{prefix}:svg>
        <#{prefix}:svg xmlns:#{prefix}="#{svg_ns}" width="7"/>
      XML

      expect(inspect_svg(source))
        .to have_attributes(parse_status: "ok", width: 7.0,
                            meta: include("xmlns:#{prefix}" => svg_ns))
    end

    it "inspects a canonical prefix defaulted by an internal DTD" do
      prefix = canonical_prefix
      source = <<~XML
        <!DOCTYPE #{prefix}:svg [
          <!ATTLIST #{prefix}:svg xmlns:#{prefix} CDATA "#{svg_ns}"
            width CDATA "7" kind (#{prefix}|plain) "#{prefix}">
        ]>
        <#{prefix}:svg/>
      XML

      expect(inspect_svg(source))
        .to have_attributes(parse_status: "ok", width: 7.0,
                            meta: include("xmlns:#{prefix}" => svg_ns, "kind" => prefix))
    end

    it "inspects declaration-less UTF-8 QNames from content and a path" do
      source = %(<é:svg xmlns:é="#{svg_ns}" width="7"/>)
      inspections = [inspect_svg(source)]
      with_svg_file.call(source) do |path|
        inspections << Claricle::Image.from_path(path).inspection
      end

      expect(inspections)
        .to all(have_attributes(parse_status: "ok", width: 7.0,
                                meta: include("xmlns:é" => svg_ns)))
    end

    it "inspects a declared legacy encoding from content and a path" do
      source = <<~XML.encode("ISO-8859-1").b
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <a·:svg xmlns:a·="#{svg_ns}" width="7" label="é"/>
      XML
      inspections = [inspect_svg(source)]
      with_svg_file.call(source) do |path|
        inspections << Claricle::Image.from_path(path).inspection
      end

      expect(inspections)
        .to all(have_attributes(parse_status: "ok", width: 7.0,
                                meta: include("xmlns:a·" => svg_ns, "label" => "é")))
    end
  end

  describe "what it does not judge" do
    # Root name, namespace and viewBox are conformance (item 03). Only
    # the detector decides whether a file is an SVG at all.
    it "inspects a well-formed non-SVG root as ok" do
      expect(inspect_svg(%(<html width="7"></html>)))
        .to have_attributes(parse_status: "ok", width: 7.0)
    end

    # The documented scope of parse_status: the root prefix, nothing
    # more. Five shapes, not one, because "malformed after the root" is
    # a family and a single example would leave the contract guessed at.
    #
    # Two assertions each, and both are needed. REXML's DOM rejecting
    # the source is what makes it malformed; without that an example
    # could quietly pass on a document that is simply well-formed.
    {
      "damage after the root" => %(<svg xmlns="%<ns>s" width="7"/><g></svg>),
      "a second root element" => %(<svg xmlns="%<ns>s" width="7"/><g/>),
      "an unclosed root" => %(<svg xmlns="%<ns>s" width="7">),
      "a mismatched end tag" => %(<svg xmlns="%<ns>s" width="7"><g></rect></svg>),
      "a truncation mid-body" => %(<svg xmlns="%<ns>s" width="7"><rect )
    }.each do |label, template|
      it "reports ok for #{label}" do
        source = format(template, ns: svg_ns)

        expect { REXML::Document.new(source) }.to raise_error(REXML::ParseException)
        expect(inspect_svg(source))
          .to have_attributes(parse_status: "ok", width: 7.0)
      end
    end
  end

  describe "the shared reader" do
    # Behavioural agreement proves nothing here: a duplicated reader
    # inside the handler passes every other example in this file. These
    # pin which reader each caller reaches -- `read_root` for the
    # handler, `root_event` for detection.
    it "is a public singleton method on Detector" do
      expect(Claricle.const_get(:Detector).singleton_class)
        .to be_public_method_defined(:read_root)
    end

    it "is what the handler consumes" do
      source = svg(%(width="7"))
      allow(Claricle.const_get(:Detector)).to receive(:read_root)
        .with(source).and_return(["svg", { "width" => "42" }])

      expect(inspect_svg(source).width).to eq(42.0)
    end

    # Detection shares the parsing `read_root` itself wraps -- the
    # bound and the ATTLIST precedence -- through `root_event`, not
    # `read_root`. It resolves its own xmlns-bearing attributes bare,
    # deliberately without `read_root`'s raw-on-failure fallback: a
    # fallback is the right answer for something about to be reported
    # as metadata, and the wrong one for deciding whether the document
    # IS an SVG in the first place.
    it "is what detection consumes" do
      detector = Claricle.const_get(:Detector)
      allow(detector).to receive(:root_event).and_return(nil)
      # The stub alone proves only that SOMETHING downstream of
      # `root_event` ran, and `read_root` is downstream of it too -- so a
      # `read_root` + `svg_root?` mutant sat on the same stub and stayed
      # green. What separates the two paths is that detection must not
      # reach `read_root`, whose raw-on-failure fallback would hide an
      # unresolvable reference instead of failing closed on it.
      expect(detector).not_to receive(:read_root)

      expect { Claricle.detect(svg("")) }.to raise_error(Claricle::UnknownFormat)
    end

    # The handler must not round-trip through a temporary file: the
    # reader takes a String, and comparing a path-born inspection to a
    # content-born one would pass a handler that quietly writes one.
    it "reads content directly, never through a temporary path" do
      image = Claricle::Image.from_content(svg(%(width="7")), format: :svg)
      received = nil
      expect(image).not_to receive(:with_path)
      # Forbidding `with_path` is not enough on its own: a mutant that
      # wrote the bytes to a Tempfile itself never touches it.
      expect(Tempfile).not_to receive(:create)
      expect(Tempfile).not_to receive(:new)
      allow(Claricle.const_get(:Detector)).to receive(:read_root)
        .and_wrap_original do |reader, source|
          received = source
          reader.call(source)
        end

      expect(handler.inspection(image).width).to eq(7.0)
      # `equal?`, not `==`. A round trip through a temporary file hands
      # back a String holding the same bytes, so the old `.with(
      # image.content)` matched it by value and stayed green through an
      # actual Tempfile. Only object identity says the reader was given
      # the image's own bytes.
      expect(received).to be(image.content)
    end

    # The reader asks for 8192 bytes. Passing `image.content` handed it
    # the whole file instead: measured on a 64.0 MiB SVG, +64.5 MiB RSS,
    # retained in @content for the lifetime of the image.
    #
    # Four weaker versions of this example were each defeated by a
    # mutation that still slurped, so it now watches the file itself:
    #
    #   * refusing File.binread -- `file.read` inside the block costs
    #     the same and never touches File.binread;
    #   * the reader's final `pos` -- `StringIO.open(File.read(path))`
    #     slurps and then answers every read and every pos identically;
    #   * that plus the yielded object's class -- reading the real File
    #     to the end, rewinding, and yielding it lands on the same pos;
    #   * counting `read`, `rewind` and `seek` -- `readpartial` and
    #     `pos = 0` take the same bytes through methods nobody watched,
    #     and so does `pread`, which needs no cursor at all.
    #
    # What survives all four: `read` is counted in bytes, and every
    # other method the file has is counted as an event that must not
    # happen at all. Naming the ones to watch is what kept losing.
    it "reads a path-born SVG without slurping the file" do
      source = svg(%(width="7"), "<rect/>" * 2048)
      taken = { read: 0, other: 0 }
      received = nil
      allow(Claricle.const_get(:Detector)).to receive(:read_root)
        .and_wrap_original do |reader, io|
          received = io
          reader.call(io)
        end

      with_svg_file.call(source) do |path|
        # After detection, which opens the file itself: its reads are
        # not the handler's and must not be counted here.
        image = Claricle::Image.from_path(path)
        watch_reads(taken)
        expect(File).not_to receive(:binread)
        expect(File).not_to receive(:read)

        expect(source.bytesize).to be > 8192
        expect(handler.inspection(image).width).to eq(7.0)
        expect(received).to be_a(File)
        expect(taken).to eq(read: 8192, other: 0)
      end
    end
  end

  describe "attribute defaults declared in a DTD" do
    # One fixture pins the ORDER of two operations: if defaults were
    # merged in raw after the explicit attributes were normalized, the
    # dimension would be nil and meta would hold the raw reference.
    it "normalizes a defaulted attribute, not just an explicit one" do
      source = %(<?xml version="1.0"?>\n) +
               %(<!DOCTYPE svg [<!ATTLIST svg width CDATA "&#49;&#48;">]>\n) +
               %(<svg xmlns="#{svg_ns}"/>)
      inspection = inspect_svg(source)

      expect(inspection.width).to eq(10.0)
      expect(inspection.meta["width"]).to eq("10")
    end
  end

  describe "errors it must not swallow" do
    # Only the parser's own encoding ArgumentError may become "failed".
    it "propagates a RuntimeError from resolution" do
      allow(REXML::Text).to receive(:unnormalize).and_raise(RuntimeError, "boom")

      expect { inspect_svg(svg(%(width="7"))) }.to raise_error(RuntimeError)
    end

    it "propagates an ArgumentError from resolution" do
      allow(REXML::Text).to receive(:unnormalize).and_raise(ArgumentError, "boom")

      expect { inspect_svg(svg(%(width="7"))) }.to raise_error(ArgumentError)
    end

    it "propagates a RuntimeError through detection too" do
      allow(REXML::Text).to receive(:unnormalize).and_raise(RuntimeError, "boom")

      expect { Claricle.detect(svg(%(width="7"))) }.to raise_error(RuntimeError)
    end

    it "propagates an ArgumentError through detection too" do
      allow(REXML::Text).to receive(:unnormalize).and_raise(ArgumentError, "boom")

      expect { Claricle.detect(svg(%(width="7"))) }.to raise_error(ArgumentError, "boom")
    end

    it "propagates an ArgumentError from the name adapter through detection" do
      root_source = Claricle.const_get(:Detector).const_get(:RootSource, false)
      allow_any_instance_of(root_source).to receive(:rewritten).and_raise(ArgumentError, "boom")
      source = %(<a·:svg xmlns:a·="#{svg_ns}"/>).encode("ISO-8859-1").b

      expect { Claricle.detect(source) }.to raise_error(ArgumentError, "boom")
    end

    it "propagates a RuntimeError from the name adapter through inspection" do
      root_source = Claricle.const_get(:Detector).const_get(:RootSource, false)
      allow_any_instance_of(root_source).to receive(:rewritten).and_raise(RuntimeError, "boom")

      expect { inspect_svg(%(<a·:svg xmlns:a·="#{svg_ns}"/>)) }
        .to raise_error(RuntimeError, "boom")
    end

    # The reader's ArgumentError rescue is for REXML's unusable encoding
    # name and nothing else. One raised while assembling attribute
    # defaults comes from the detector's own code, and reporting it as
    # "this file has no root" would hide a bug behind a tidy "failed".
    it "propagates an ArgumentError from reading the root's attributes" do
      allow(Claricle.const_get(:AttributeDefaults)).to receive(:for_root)
        .and_raise(ArgumentError, "boom")

      expect { inspect_svg(svg(%(width="7"))) }.to raise_error(ArgumentError)
    end

    # Needs a DTD: without an attlistdecl event, `collect` is never
    # called and the example would pass on any implementation.
    it "propagates one from collecting declared defaults" do
      source = %(<!DOCTYPE svg [<!ATTLIST svg width CDATA "10">]><svg xmlns="#{svg_ns}"/>)
      allow(Claricle.const_get(:AttributeDefaults)).to receive(:collect)
        .and_raise(ArgumentError, "boom")

      expect { inspect_svg(source) }.to raise_error(ArgumentError)
    end

    it "propagates one from registering declared namespaces" do
      source = %(<!DOCTYPE svg [<!ATTLIST svg width CDATA "10">]><svg xmlns="#{svg_ns}"/>)
      root_parser = Claricle.const_get(:Detector).const_get(:RootParser, false)
      allow_any_instance_of(root_parser).to receive(:register_declared_namespaces)
        .and_raise(ArgumentError, "boom")

      expect { inspect_svg(source) }.to raise_error(ArgumentError)
    end
  end

  describe "REXML global limits" do
    # Asserted on the setters, not before/after: an implementation could
    # lower a process-wide limit, call unnormalize bare, and restore it.
    it "are never written" do
      expect(REXML::Security).not_to receive(:entity_expansion_limit=)
      expect(REXML::Security).not_to receive(:entity_expansion_text_limit=)

      inspect_svg(svg(%(width="7" id="&#65;")))
    end
  end

  # lib/claricle.rb loads the registry before the detector, so relying on
  # that ordering would pass through the ordinary entry point and only
  # fail when the handler is required alone. Requires the handler file
  # and NOTHING else -- requiring `claricle` or the registry would let
  # the detector require hide in the registry and still pass.
  it "requires the detector itself" do
    script = <<~RUBY
      require "claricle/handlers/svg"
      handler = Claricle.const_get(:Handlers).const_get(:Svg).new
      # The handler asks its image for a source, not for bytes. A real
      # Claricle::Image is out of reach here: requiring it would pull in
      # the registry, which is the very thing this example refuses.
      double = Struct.new(:format, :content) do
        def with_source
          yield(content)
        end
      end
      image = double.new(:svg, %(<svg xmlns="#{svg_ns}" width="7"/>))
      print handler.inspection(image).width
    RUBY
    lib = File.expand_path("../../../lib", __dir__)
    output = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", script], err: %i[child out], &:read)
    status = $CHILD_STATUS

    # Bundler's inherited RUBYOPT puts lib on the child's path too, so a
    # wrong -I passes here unnoticed -- and did, one directory short at
    # spec/lib. This is what makes the -I mean anything.
    expect(File).to exist(File.join(lib, "claricle", "handlers", "svg.rb"))
    expect(status).to be_success, "handler could not load alone: #{output}"
    expect(output).to eq("7.0")
  end

  describe "meta" do
    # read_root hands back its own hash. Handing a reference to it out of
    # an inspection lets a caller mutate what the reader produced, and
    # the model's freeze does not reach inside a Hash.
    # The handler passes the reader's hash straight through, relying on
    # lutaml to copy a `:hash` attribute on assignment. That is measured
    # behaviour of a dependency, not a guarantee, so it is pinned here --
    # if lutaml ever starts aliasing, an inspection would hand callers a
    # reference to the reader's own hash and this goes red.
    it "does not share the reader's hash" do
      readers_hash = { "xmlns" => svg_ns, "width" => "7" }
      allow(Claricle.const_get(:Detector)).to receive(:read_root)
        .and_return(["svg", readers_hash])

      meta = inspect_svg(svg(%(width="7"))).meta

      # Identity and frozenness, not mutation: meta is frozen now, a
      # stronger guarantee than "a write to it does not reach the
      # reader", and the old probe raised FrozenError before it could
      # demonstrate anything.
      expect(meta).to eq(readers_hash)
      expect(meta).not_to be(readers_hash)
      expect(readers_hash).not_to be_frozen
    end
  end

  describe "references that cannot be resolved" do
    # A surrogate resolves to invalid UTF-8. It does not raise where it
    # is produced -- it detonates later, in the dimension parse or in
    # to_json -- so the raw declaration is kept instead.
    it "keeps the raw declaration for a surrogate reference" do
      inspection = inspect_svg(svg(%(width="&#xD800;")))

      expect(inspection.width).to be_nil
      expect(inspection.meta["width"]).to eq("&#xD800;")
    end

    # The attribute has to still be in meta. Dropping it would serialize
    # just as cleanly and prove nothing about the raw declaration being
    # safe to carry -- measured: filtering meta down to xmlns, width,
    # height and viewBox left this example green.
    it "serializes an attribute holding a surrogate reference" do
      inspection = inspect_svg(svg(%(id="&#xD800;")))

      expect(inspection.meta["id"]).to eq("&#xD800;")
      expect { inspection.to_json }.not_to raise_error
    end

    it "keeps the raw declaration for an out-of-range reference" do
      inspection = inspect_svg(svg(%(width="&#99999999999999999999;")))

      expect(inspection.meta["width"]).to eq("&#99999999999999999999;")
    end

    # An escaped reference means the literal text. Resolving twice would
    # turn "&amp;#x67;" into "g" and change what the document says.
    # Both halves: an escaped reference must survive as literal text,
    # and a plain one must still be resolved. Asserting only the first
    # would pass an implementation that never resolves anything.
    it "resolves a reference once and only once" do
      escaped = %(<svg xmlns="http://www.w3.org/2000/sv&amp;#x67;"/>)
      expect { Claricle.detect(escaped) }.to raise_error(Claricle::UnknownFormat)

      resolved = %(<svg xmlns="http://www.w3.org/2000/sv&#x67;"/>)
      expect(Claricle.detect(resolved)).to eq(:svg)
    end
  end

  describe "SVG's number grammar" do
    # Ruby's Float is broader: Float("1.") is 1.0 and Float("1.e2") is
    # 100.0, but SVG requires a digit after the decimal point.
    { "1." => nil, "1.e2" => nil, ".5" => 0.5, "1.5" => 1.5,
      "+2" => 2.0, "-2" => -2.0, "1e2" => 100.0 }.each do |declared, expected|
      it "reads #{declared.inspect} as #{expected.inspect}" do
        expect(inspect_svg(svg(%(width="#{declared}"))).width).to eq(expected)
      end
    end
  end

  describe "the bound is measured in bytes" do
    # source[0, n] counts CHARACTERS, so a multibyte prolog would let the
    # handler read past where detection stopped and the two would
    # disagree about the same file.
    it "agrees with detection on a multibyte prolog straddling it" do
      prolog = "<!--#{"é" * 4100}-->"
      source = prolog + svg(%(width="7"))

      expect(prolog.bytesize).to be > 8192
      expect(prolog.length).to be < 8192
      expect(Claricle.const_get(:Detector).read_root(source)).to be_nil
      expect { Claricle.detect(source) }.to raise_error(Claricle::UnknownFormat)
    end
  end

  describe "an encoding tag on content-born bytes" do
    # Detection normalises with `bytes.b`, so these ASCII bytes detect as
    # :svg whatever the tag says. Reading them back honoured the tag
    # instead: REXML decoded ASCII as UTF-16, the pull loop saw no events,
    # and inspection reported "failed" without raising -- the two halves
    # disagreeing silently about one string.
    %w[UTF-16LE UTF-16BE].each do |encoding|
      it "reads #{encoding}-tagged ASCII the way detection did" do
        tagged = svg(%(width="7")).dup.force_encoding(encoding)

        expect(Claricle.detect(tagged)).to eq(:svg)
        expect(inspect_svg(tagged))
          .to have_attributes(parse_status: "ok", width: 7.0)
      end
    end
  end

  # Claricle's own structural pre-pass (D23). Whole-document, unlike
  # `inspection` above, which is scoped to the root prefix.
  describe "the structural scan" do
    let(:scanner) do
      Claricle.const_get(:Handlers).const_get(:Svg).const_get(:Structure, false)
    end

    def scan(source)
      scanner.scan(source)
    end

    def scan_file(source)
      Tempfile.create(["scan", ".svg"]) do |file|
        file.binmode
        file.write(source)
        file.flush
        File.open(file.path, "rb") { |io| scanner.scan(io) }
      end
    end

    # One declaration, one reference, so a resolving parser inlines the
    # target's markup and the verdict changes.
    def system_entity_document(target)
      %(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "#{target}">]>) +
        %(<svg xmlns="#{svg_ns}">&x;</svg>)
    end

    # Drains the pull parser the way the scan does, so an example can say
    # "REXML itself raises nothing here" without duplicating the loop.
    def drain(source)
      parser = REXML::Parsers::BaseParser.new(source.dup.force_encoding(Encoding::UTF_8))
      loop { break if parser.pull[0] == :end_document }
    end

    # GC is DISABLED across the measurement, not run after it. Measured:
    # with a trailing `GC.start` a mutant that built a whole DOM inside the
    # scan and dropped it scored zero, because the tree was collected
    # before it was counted. Disabling GC counts every Element the work
    # created, retained or not.
    def elements_created
      GC.start
      GC.disable
      before = ObjectSpace.each_object(REXML::Element).count
      yield
      ObjectSpace.each_object(REXML::Element).count - before
    ensure
      GC.enable
    end

    # The final entity expands to MARKUP, so a parser that expanded the
    # chain would produce a document this scan judges differently. Without
    # that the bomb is indistinguishable from ordinary text.
    def billion_laughs
      entities = ("a".."f").each_cons(2).map do |from, to|
        %(<!ENTITY #{to} "#{"&#{from};" * 10}">)
      end.join
      %(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "</svg><g/>">#{entities}]>) +
        %(<svg xmlns="#{svg_ns}">&f;</svg>)
    end

    def triples(issues)
      issues.map { |issue| [issue.severity, issue.code, issue.message] }
    end

    def pairs(issues)
      issues.map { |issue| [issue.severity, issue.code] }
    end

    # Built here rather than as fixtures: each is one line and the point
    # of each is its shape, which a binary file would hide.
    def utf16_document
      ("\xFF\xFE".b + %(<?xml version="1.0" encoding="UTF-16"?><svg xmlns="#{svg_ns}"/>)
        .encode("UTF-16LE").b)
    end

    def latin1_document
      %(<?xml version="1.0" encoding="ISO-8859-1"?><svg xmlns="#{svg_ns}" id="café"/>)
        .encode("ISO-8859-1").b
    end

    def sound_documents
      {
        "a minimal root" => %(<svg xmlns="#{svg_ns}" width="7"/>),
        "a prolog, a body and a trailing comment" =>
          %(<?xml version="1.0"?><!DOCTYPE svg><svg xmlns="#{svg_ns}"><g><rect/></g></svg><!--t-->),
        "a multibyte root name" => %(<漢 xmlns="#{svg_ns}"/>),
        "UTF-16 with a BOM" => utf16_document,
        "a UTF-8 BOM" => ("\xEF\xBB\xBF".b + %(<svg xmlns="#{svg_ns}"/>).b),
        "a declared ISO-8859-1 encoding" => latin1_document,
        "an undeclared entity reference" => %(<svg xmlns="#{svg_ns}">&nope;</svg>)
      }
    end

    # `code` and the DOM co-assertion, not the exact prose: the gemspec
    # pins rexml at `~> 3.4.4`, which admits 3.4.5+, and a consumer
    # resolves fresh rather than from our lock. The anchor is what the
    # message must keep saying; the wording is REXML's to change.
    def malformed_documents
      {
        "damage after the root" => [%(<svg xmlns="#{svg_ns}"/><g></svg>), /extra tag/i, true],
        "a mismatched end tag" => [%(<svg xmlns="#{svg_ns}"><g></rect></svg>), /end tag/i, true],
        "an unclosed root" => [%(<svg xmlns="#{svg_ns}">), /end tag/i, true],
        "a truncation mid-body" => [%(<svg xmlns="#{svg_ns}"><rect ), /attribute/i, true],
        "an unbound namespace prefix" => [%(<z:svg xmlns="#{svg_ns}"/>), /prefix/i, true],
        "a stray end tag" => [%(</svg>), /end tag/i, true],
        "whitespace alone" => ["   \n ", /no root element/i, true],
        # No DOM co-assertion: measured, `REXML::Document.new("")`
        # ACCEPTS an empty document where `("   ")` raises. The row is
        # otherwise identical to the whitespace one above.
        "no document at all" => ["", /no root element/i, false]
      }
    end

    it "reports no issue for a structurally sound document" do
      sound_documents.each do |label, source|
        expect(scan(source.b)).to eq([]), "expected #{label} to be sound"
      end
    end

    it "reports exactly one error issue naming a malformed document's failure" do
      malformed_documents.each do |label, (source, anchor, dom_rejects)|
        expect { REXML::Document.new(source) }.to raise_error(REXML::ParseException) if dom_rejects

        issues = scan(source.b)
        expect(pairs(issues)).to eq([["error", "svg.not_well_formed"]]), "for #{label}"
        expect(issues.first.message).to match(anchor), "for #{label}"
      end
    end

    # Four of the five shapes are invisible to the pull parser, so this
    # verdict is Claricle's own arithmetic rather than a forwarded REXML
    # error -- which is why each row asserts the parser stays quiet.
    it "reports a second root element the pull parser accepts" do
      [%(<svg xmlns="#{svg_ns}"/><g/>), %(<svg xmlns="#{svg_ns}"></svg><g/>),
       %(<svg xmlns="#{svg_ns}"/><svg xmlns="#{svg_ns}"/>),
       %(<svg xmlns="#{svg_ns}"/> <g/>)].each do |source|
        expect { drain(source) }.not_to raise_error
        expect(triples(scan(source.b)))
          .to eq([["error", "svg.multiple_root_elements", "document has 2 root elements"]])
      end
    end

    # The count itself, not merely the fact of a second root: with only
    # the two-root rows above, hardcoding "2" in the message leaves
    # every example green.
    it "counts the roots it found rather than reporting a fixed number" do
      expect(triples(scan(%(<svg xmlns="#{svg_ns}"/><g/><g/>).b)))
        .to eq([["error", "svg.multiple_root_elements", "document has 3 root elements"]])
    end

    # The one second-root shape REXML does catch, so the counter above
    # cannot be the only thing keeping that example green.
    it "reports the second-root shape REXML rejects as malformed instead" do
      source = %(<svg xmlns="#{svg_ns}"/><g></g>)

      expect { drain(source) }.to raise_error(REXML::ParseException)
      expect(pairs(scan(source.b))).to eq([["error", "svg.not_well_formed"]])
    end

    # The D23 hole: svg_conform's `base` profile returns zero errors for
    # raw binary, and UTF-32 was measured passing every profile silently.
    # Refusal only -- the code differs by byte order, measured, so an
    # exact-triple table here would be a one-shape generalisation.
    it "refuses UTF-32 and raw binary while accepting the encodings SVG allows" do
      body = %(<svg xmlns="#{svg_ns}"/>)
      refused = {
        "UTF-32BE with a BOM" => ("\x00\x00\xFE\xFF".b + body.encode("UTF-32BE").b),
        "UTF-32LE with a BOM" => ("\xFF\xFE\x00\x00".b + body.encode("UTF-32LE").b),
        "UTF-32BE with no BOM" => body.encode("UTF-32BE").b,
        "UTF-32LE with no BOM" => body.encode("UTF-32LE").b,
        "a real PNG" => File.binread(File.join(__dir__, "..", "..", "fixtures", "detector", "valid.png")),
        "random bytes" => Random.new(7).bytes(512)
      }
      refused.each do |label, source|
        # Either code is a refusal; which one a given file gets is
        # REXML's decision, pinned per shape in the examples below.
        expect(pairs(scan(source))).to eq([["error", "svg.encoding_unusable"]])
          .or(eq([["error", "svg.not_well_formed"]])), "expected #{label} refused"
      end
      sound_documents.each_value { |source| expect(scan(source.b)).to eq([]) }
    end

    # Binary REXML cannot decode is an ENCODING failure, not a
    # well-formedness one, and it arrives as an ArgumentError wrapped in
    # a ParseException. Not every binary file takes this route -- across
    # nine shapes, seven do and two decode far enough to fail as markup
    # instead -- so these two fixtures are pinned by name rather than
    # "raw binary" as a class.
    #
    # Three wrong implementations fail this: `.lines.first` yields
    # "#<ArgumentError: ...>", the bare `to_s` yields "Exception
    # parsing", and routing on the exception class alone yields
    # svg.not_well_formed.
    it "calls raw binary an encoding failure, in Claricle's own words" do
      png = File.binread(File.join(__dir__, "..", "..", "fixtures", "detector", "valid.png"))

      [png, Random.new(7).bytes(512)].each do |source|
        expect(triples(scan(source)))
          .to eq([["error", "svg.encoding_unusable", "SVG source is not decodable text"]])
      end
    end

    # A regex anchor, not REXML's exact prose: the gemspec pins rexml at
    # `~> 3.4.4`, which admits 3.4.5+, and a consumer resolves fresh.
    # Thirteen bytes: a UTF-16LE BOM then an odd-length processing
    # instruction, so the last character is truncated mid-unit. REXML
    # transcodes lazily inside the pull loop, so this raises
    # Encoding::InvalidByteSequenceError -- which is neither an
    # ArgumentError nor a ParseException, and escaped `scan` entirely on
    # both arms before the EncodingError clause existed. Exactly the
    # input class this unit exists to catch.
    it "returns an issue for bytes truncated mid-character rather than raising" do
      source = "\xFF\xFE<\x00?\x00x\x00 \x00>\x00\x00".b

      expect(source.bytesize).to eq(13)
      expect(pairs(scan(source))).to eq([["error", "svg.encoding_unusable"]])
      expect(pairs(scan_file(source))).to eq([["error", "svg.encoding_unusable"]])
    end

    it "names an unusable declared encoding separately from a malformed document" do
      source = %(<?xml version="1.0" encoding="not-a-charset"?><svg/>)

      issues = scan(source.b)
      expect(pairs(issues)).to eq([["error", "svg.encoding_unusable"]])
      expect(issues.first.message).to match(/not-a-charset/)
    end

    # The declared encoding NAME is document content, so it is
    # attacker-controlled, and it reaches `issue` by a different route
    # than a parse failure does. Without the bound at the funnel this
    # message measured 100,018 characters.
    it "bounds the message on the encoding route too, not just the parse route" do
      source = %(<?xml version="1.0" encoding="#{"x" * 100_000}"?><svg/>)

      issues = scan(source.b)
      expect(pairs(issues)).to eq([["error", "svg.encoding_unusable"]])
      expect(issues.first.message.length).to eq(200)
    end

    # REXML's "first line" bounds LINES, not bytes -- measured at 100,027
    # bytes for one long token. The cap counts CHARACTERS, so the byte
    # ceiling is script-dependent: a fixed multiplier would be wrong.
    # byteslice is deliberately not used; it split a CJK codepoint and
    # Models::Issue then refused the value outright.
    it "bounds the message in characters, keeping it valid in every script" do
      { "ASCII" => "a", "CJK" => "漢", "astral" => "\u{1F600}" }.each do |script, char|
        source = %(<svg xmlns="#{svg_ns}"><rect #{char * 50_000})

        message = scan(source.b).first.message
        expect(message.length).to eq(200), "for #{script}"
        expect(message).to be_valid_encoding, "for #{script}"
        expect(message.bytesize).to be <= 800, "for #{script}"
      end
    end

    # The message quotes operator-supplied document text, so it must not
    # carry control bytes into a terminal or a CI log, and it must
    # actually be one line -- a length bound alone does not make it one.
    it "keeps the message on one line and free of control characters" do
      escape = 27.chr
      newline = 10.chr

      # Collapsed to a space, not deleted: the surrounding text stays
      # legible, which is the whole reason the message quotes it.
      { "a#{escape}[2Jb" => "a [2Jb", "a#{newline}b" => "a b", "a#{7.chr}b" => "a b" }
        .each do |name, visible|
          message = scan(%(<?xml version="1.0" encoding="#{name}"?><svg/>).b).first.message

          expect(message.lines.size).to eq(1), "for #{name.inspect}"
          expect(message).not_to match(/[[:cntrl:]]/), "for #{name.inspect}"
          expect(message).to include(visible)
        end
    end

    # Both directions, and asserted as a PROPERTY rather than as a list
    # of forbidden routes. Naming the calls to watch is a losing shape --
    # `svg_spec.rb` already records it losing three times above, and a
    # fetch through Net::HTTP, Socket, IO.popen or any helper nobody
    # thought to name would sail past an enumerated hook list.
    #
    # So every hostile document here declares an entity whose
    # replacement text is MARKUP that would break well-formedness. A
    # scan that resolved it -- by any route, from a file, over a socket,
    # or from the internal subset -- reports a different verdict. A scan
    # that never parsed at all fails the ordinary rows below. Only a
    # parser that reads the document and resolves nothing returns [] for
    # every row. The hooks stay as a supplement, not as the assertion.
    it "never fetches an external entity and never expands one" do
      canary = "#{Dir.tmpdir}/claricle-canary-#{Process.pid}.txt"
      # Markup, so inlining it is observable, plus a canary string so a
      # leak into the message is observable too.
      File.write(canary, %(</svg><g/>TOP-SECRET-CANARY))
      hits = []
      [[File, :open], [File, :read], [File, :binread], [IO, :read]].each do |mod, name|
        allow(mod).to receive(name).and_wrap_original do |original, *args, &block|
          hits << "#{mod}.#{name}"
          original.call(*args, &block)
        end
      end
      expect(REXML::Security).not_to receive(:entity_expansion_limit=)
      expect(REXML::Security).not_to receive(:entity_expansion_text_limit=)

      hostile = {
        "a SYSTEM file entity" => system_entity_document("file://#{canary}"),
        "a SYSTEM http entity" => system_entity_document("http://127.0.0.1:1/a"),
        "an external DTD subset" =>
          %(<?xml version="1.0"?><!DOCTYPE svg SYSTEM "file://#{canary}"><svg xmlns="#{svg_ns}">&x;</svg>),
        "a parameter entity" =>
          %(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY % p SYSTEM "file://#{canary}"> %p;]><svg xmlns="#{svg_ns}"/>),
        "an internal entity holding markup" =>
          %(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x "</svg><g/>">]><svg xmlns="#{svg_ns}">&x;</svg>),
        "a billion-laughs bomb ending in markup" => billion_laughs
      }
      begin
        hostile.each do |label, source|
          issues = scan(source.b)
          # Resolving the entity by ANY route inlines `</svg><g/>` and
          # the verdict changes. This is the assertion.
          # Canary first: with the emptiness assertion ahead of it the
          # example aborts on failure and this line never runs, so it
          # would only ever test the string "[]", which cannot contain
          # the canary. Proven by a mutant that leaks the fetched file
          # into the message -- reordered, this line names the leak.
          expect(triples(issues).to_s).not_to include("TOP-SECRET-CANARY")
          expect(issues).to eq([]), "expected #{label} left unresolved, got #{triples(issues).inspect}"
        end
        # The other direction: a scan that simply never parses would also
        # return [] above, so ordinary content must still be judged.
        expect(scan(%(<svg xmlns="#{svg_ns}">a &amp; b &#65;</svg>).b)).to eq([])
        expect(pairs(scan(%(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x "y">]><svg xmlns="#{svg_ns}">&x;</g>).b)))
          .to eq([["error", "svg.not_well_formed"]])
        expect(hits).to eq([])
        expect(File.read(canary)).to eq(%(</svg><g/>TOP-SECRET-CANARY))
      ensure
        FileUtils.rm_f(canary)
      end
    end

    # The property that separates this from the rejected DOM route, and
    # the only one that survives the ruling permitting a whole-file read.
    # Not a mock, so verify_partial_doubles cannot hollow it out; not a
    # named-class refusal; not bytes-consumed.
    it "never builds a document tree, where the DOM builds one per element" do
      source = %(<svg xmlns="#{svg_ns}">#{"<rect/>" * 1000}</svg>).b

      scanned = elements_created { scan(source) }
      built = elements_created { REXML::Document.new(source.dup.force_encoding(Encoding::UTF_8)) }

      expect(scanned).to eq(0)
      expect(built).to be > 1000
      expect(elements_created { scan(%(<svg xmlns="#{svg_ns}"><g></rect></svg>).b) }).to eq(0)
    end
    # A String and a real File must not disagree. The multibyte-root row
    # is what pins the encoding retag: both arms arrive binary-tagged --
    # `Image#initialize` normalises content to ASCII-8BIT and a path is
    # opened "rb" -- and without the retag that row alone goes red.
    it "reaches the same verdict from a String and from a file" do
      documents = sound_documents.values +
                  malformed_documents.values.map(&:first) +
                  [%(<svg xmlns="#{svg_ns}"/><g/>), %(<漢 xmlns="#{svg_ns}"/>)]

      documents.each do |source|
        expect(triples(scan_file(source.b))).to eq(triples(scan(source.b))), "for #{source[0, 40].inspect}"
      end
    end

    it "leaves inspect and the advertised capabilities untouched" do
      malformed = %(<svg xmlns="#{svg_ns}" width="7"/><g/>)

      expect(scan(malformed.b)).not_to be_empty
      expect(Claricle.const_get(:Handlers).const_get(:Svg).capabilities).to eq([:inspect])
      expect(inspect_svg(malformed)).to have_attributes(parse_status: "ok", width: 7.0)
    end

    # `const_get` walks straight past `private_constant` -- so the Module
    # clause is what stops this passing with the feature deleted, and the
    # `::` form is what actually asserts the privacy.
    it "stays off the public surface" do
      svg = Claricle.const_get(:Handlers).const_get(:Svg)

      expect(svg.const_get(:Structure, false)).to be_a(Module)
      expect(svg.constants(false)).not_to include(:Structure)
      expect { svg::Structure }.to raise_error(NameError, /private constant/)
    end

    # A false failure, pinned in both directions so it cannot change
    # silently: the detector widens REXML's live name grammar to XML's
    # canonical one, and this scan does not. Fixing it needs
    # `detector.rb`, which this branch does not own.
    it "refuses a canonical name the detector accepts" do
      source = %(<a·:svg xmlns:a·="#{svg_ns}"/>).b

      expect(Claricle.detect(source)).to eq(:svg)
      expect(pairs(scan(source))).to eq([["error", "svg.not_well_formed"]])
    end
  end
end
