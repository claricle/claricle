# frozen_string_literal: true

require "English"
# The DOM parser, required only by the specs: it is what "malformed"
# means in the root-prefix examples, and the library never loads it.
require "rexml/document"
require "rexml/security"
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

  # `read` is the only call the reader is allowed to make, so it is the
  # only one counted in bytes. Everything else is counted as an event
  # that must never happen -- and the list is INVERTED for that: naming
  # the readers to watch was tried and lost three times, to readpartial,
  # to `pos = 0` and to pread. So every method a File has is watched,
  # minus the handful the plumbing itself needs.
  def allowed_calls
    %i[read close closed? path to_path to_io fileno]
  end

  def watched_calls
    File.instance_methods - Object.instance_methods - allowed_calls
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
    # assert the handler actually goes through Detector.read_root.
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
      allow(Claricle.const_get(:Detector)).to receive(:root_event).and_return(nil)

      expect { Claricle.detect(svg("")) }.to raise_error(Claricle::UnknownFormat)
    end

    # The handler must not round-trip through a temporary file: the
    # reader takes a String, and comparing a path-born inspection to a
    # content-born one would pass a handler that quietly writes one.
    it "reads content directly, never through a temporary path" do
      image = Claricle::Image.from_content(svg(%(width="7")), format: :svg)
      expect(image).not_to receive(:with_path)
      expect(Claricle.const_get(:Detector)).to receive(:read_root)
        .with(image.content).and_call_original

      handler.inspection(image)
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
end
