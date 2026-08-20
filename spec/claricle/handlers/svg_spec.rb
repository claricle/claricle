# frozen_string_literal: true

require "rexml/security"

RSpec.describe "Claricle SVG handler" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Svg).new }
  let(:svg_ns) { "http://www.w3.org/2000/svg" }

  def svg(attributes, body = "")
    %(<svg xmlns="#{svg_ns}" #{attributes}>#{body}</svg>)
  end

  def inspect_svg(source)
    handler.inspection(Claricle::Image.from_content(source, format: :svg))
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

    # These fail in three different ways: Float() returns nil for the
    # first two, Infinity for 1e9999, and 1e308 is finite until it is
    # multiplied by 96.
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
        expect(inspection.meta).to be_nil.or be_empty
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

    # Nothing past the root is parsed, so damage after it is invisible.
    it "ignores damage after a complete root" do
      expect(inspect_svg(%(<svg xmlns="#{svg_ns}" width="7"/><g></svg>)))
        .to have_attributes(parse_status: "ok", width: 7.0)
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
      allow(Claricle.const_get(:Detector)).to receive(:read_root)
        .and_return(["svg", { "width" => "42" }])

      expect(inspect_svg(svg(%(width="7"))).width).to eq(42.0)
    end

    it "is what detection consumes" do
      allow(Claricle.const_get(:Detector)).to receive(:read_root).and_return(nil)

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
      image = Struct.new(:format, :content).new(:svg, %(<svg xmlns="#{svg_ns}" width="7"/>))
      print handler.inspection(image).width
    RUBY
    lib = File.expand_path("../../lib", __dir__)
    output = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", script], err: %i[child out], &:read)

    expect(output).to eq("7.0"), "handler could not load alone: #{output}"
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

    it "serializes an attribute holding a surrogate reference" do
      expect { inspect_svg(svg(%(id="&#xD800;"))).to_json }.not_to raise_error
    end

    it "keeps the raw declaration for an out-of-range reference" do
      inspection = inspect_svg(svg(%(width="&#99999999999999999999;")))

      expect(inspection.meta["width"]).to eq("&#99999999999999999999;")
    end

    # An escaped reference means the literal text. Resolving twice would
    # turn "&amp;#x67;" into "g" and change what the document says.
    it "does not resolve an escaped reference twice" do
      escaped = %(<svg xmlns="http://www.w3.org/2000/sv&amp;#x67;"/>)

      expect { Claricle.detect(escaped) }.to raise_error(Claricle::UnknownFormat)
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
end
