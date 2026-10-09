# frozen_string_literal: true

require_relative "../../support/convert_semantics"

RSpec.describe "svg -> eps/ps fidelity repairs" do
  def svg(body, root: 'width="100" height="50"')
    %(<svg xmlns="http://www.w3.org/2000/svg" #{root}>#{body}</svg>)
  end

  def postscript(source, target = :eps)
    Claricle::Image.from_content(source, format: :svg).convert(to: target).content
  end

  def shapes(source) = ConvertSemantics.painted_shapes(postscript(source))

  let(:repair) { Claricle.const_get(:PostscriptFidelity).method(:repair) }

  describe "lengths postsvg reads as 0" do
    {
      "10px" => 10.0, ".5" => 0.5, "+5" => 5.0, " 7px " => 7.0, "2.50px" => 2.5
    }.each do |written, extent|
      it "paints width=#{written.inspect} at #{extent}" do
        fill = shapes(svg(%(<rect width="#{written}" height="1"/>))).first

        expect(ConvertSemantics.extent(fill.points).values_at(0, 2)).to eq([0.0, extent])
      end
    end

    it "leaves a unit it cannot convert for the classifier to disclose" do
      source = svg(%(<rect width="5mm" height="1"/>))

      expect(repair.call(source)).to equal(source)
    end
  end

  describe "a document it should not rewrite" do
    {
      "a non-UTF-8 declaration" =>
        %(<?xml version="1.0" encoding="ISO-8859-1"?><svg xmlns="http://www.w3.org/2000/svg"><rect width="1px"/></svg>),
      "elements outside the SVG namespace" =>
        %(<svg xmlns="http://www.w3.org/2000/svg"><x:rect xmlns:x="urn:x" width="10px"/></svg>)
    }.each do |reason, source|
      it "is passed through byte for byte for #{reason}" do
        expect(repair.call(source)).to equal(source)
      end
    end
  end

  describe "rgb() paint" do
    { "rgb(255,0,0)" => [255, 0, 0], "rgb( 0 , 128 , 255 )" => [0, 128, 255], "rgb(300,0,0)" => [255, 0, 0] }
      .each do |written, rgb|
      it "paints #{written} as #{rgb.inspect}" do
        expect(shapes(svg(%(<rect width="1" height="1" fill="#{written}"/>))).first.color).to eq(rgb)
      end
    end
  end

  describe "a line without a stroke" do
    def kinds(body) = shapes(svg(body)).map(&:kind)

    it "paints nothing when its stroke is absent or none" do
      expect(kinds(%(<line x2="9"/><line x2="9" stroke="none"/>))).to be_empty
    end

    [
      ["its own stroke", %(<line x2="9" stroke="#000"/>)],
      ["a stroke on an ancestor", %(<g stroke="#000"><line x2="9"/></g>)],
      ["an ancestor style", %(<g style="stroke:#000"><line x2="9"/></g>)],
      ["its own style", %(<line x2="9" style="stroke:#000"/>)],
      ["a stylesheet", %(<style>line{stroke:#000}</style><line x2="9"/>)]
    ].each do |reason, body|
      it "keeps the line when #{reason} may stroke it" do
        expect(repair.call(svg(body))).to include("<line")
      end
    end
  end

  describe "the y-down origin" do
    def top_of(source) = ConvertSemantics.extent(shapes(source).first.points).values_at(1, 3)

    it "flips about the root height" do
      expect(top_of(svg(%(<rect width="10" height="10"/>)))).to eq([40.0, 50.0])
    end

    it "flips about a viewBox that starts at the origin" do
      source = svg(%(<rect width="10" height="10"/>), root: 'viewBox="0 0 100 20"')

      expect(top_of(source)).to eq([10.0, 20.0])
    end

    it "flips about the viewBox, not the content, when content overflows it" do
      source = svg(%(<rect y="-5" width="10" height="10"/>), root: 'viewBox="0 0 100 20"')

      expect(top_of(source)).to eq([15.0, 25.0])
    end

    it "keeps the bounding box around content that overflows the root" do
      header = postscript(svg(%(<rect y="-20" width="10" height="10"/>))).lines.grep(/BoundingBox/)

      expect(header).to eq(["%%BoundingBox: 0 0 100 70\n"])
    end

    it "survives eps -> svg: the rect stays at the top" do
      eps = postscript(svg(%(<rect width="10" height="10"/>)))
      round = Claricle::Image.from_content(eps, format: :eps).convert(to: :svg).content

      expect(round.scan("translate(0 50) scale(1 -1)").length).to eq(2)
    end
  end

  describe "a viewBox whose origin is not 0 0" do
    def box_of(source) = ConvertSemantics.extent(shapes(source).first.points)

    {
      "50 50 100 100" => [10.0, 80.0, 20.0, 90.0],
      "50,50,100,100" => [10.0, 80.0, 20.0, 90.0],
      "40 50 100 100" => [20.0, 80.0, 30.0, 90.0],
      "50 40 100 100" => [10.0, 70.0, 20.0, 80.0]
    }.each do |view_box, expected|
      it "paints the rect where #{view_box.inspect} puts it" do
        source = svg(%(<rect x="60" y="60" width="10" height="10"/>), root: %(viewBox="#{view_box}"))

        expect(box_of(source)).to eq(expected)
      end
    end

    it "keeps the bounding box at the viewBox size" do
      source = svg(%(<rect x="60" y="60" width="10" height="10"/>), root: 'viewBox="50 50 100 80"')

      expect(postscript(source).lines.grep(/BoundingBox/)).to eq(["%%BoundingBox: 0 0 100 80\n"])
    end

    it "leaves a nested svg's viewBox alone" do
      source = svg(%(<svg viewBox="5 5 10 10"><rect width="1" height="1"/></svg>), root: 'viewBox="0 0 100 100"')

      expect(repair.call(source)).to equal(source)
    end
  end

  describe "text" do
    let(:text) { svg(%(<text x="10" y="20" font-size="14">Hi (a)</text>)) }

    it "is drawn upright inside the flipped page" do
      lines = postscript(text).lines.map(&:strip)
      at = lines.index("(Hi \\(a\\)) show")

      expect(lines[(at - 4)..(at + 1)])
        .to eq(["gsave", "10 20 translate", "1 -1 scale", "0 0 moveto", "(Hi \\(a\\)) show", "grestore"])
    end
  end
end
