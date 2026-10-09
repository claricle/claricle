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

  describe "a width/height that differs from the viewBox" do
    let(:rect) { %(<rect x="20" y="10" width="40" height="20"/>) }

    def box_of(source) = ConvertSemantics.extent(shapes(source).first.points)

    {
      'width="100" height="100" viewBox="0 0 200 100"' => [10.0, 60.0, 30.0, 70.0],
      'width="100px" height="100px" viewBox="0 0 200 100"' => [10.0, 60.0, 30.0, 70.0],
      'width="50" height="50" viewBox="0 0 100 100"' => [10.0, 35.0, 30.0, 45.0],
      'width="100" viewBox="0 0 200 100"' => [10.0, 35.0, 30.0, 45.0],
      'width="200" height="50" viewBox="0 0 100 100"' => [85.0, 35.0, 105.0, 45.0],
      'width="100" height="100" viewBox="50 0 200 100"' => [-15.0, 60.0, 5.0, 70.0]
    }.each do |root, expected|
      it "paints the rect where #{root} puts it" do
        expect(box_of(svg(rect, root: root))).to eq(expected)
      end
    end

    it "sizes the page to width and height" do
      source = svg(rect, root: 'width="100" height="100" viewBox="0 0 200 100"')

      expect(postscript(source).lines.grep(/BoundingBox/)).to eq(["%%BoundingBox: 0 0 100 100\n"])
    end

    it "leaves a viewBox that already is the viewport unscaled" do
      source = svg(rect, root: 'width="200" height="100" viewBox="0 0 200 100"')

      expect(box_of(source)).to eq([20.0, 70.0, 60.0, 90.0])
    end
  end

  # The root svg's overflow is `visible` (SVG's UA stylesheet only hides it on
  # `svg:not(:root)`), so the output keeps content past the viewport and sizes
  # the page around it. Pinned: a clip here would contradict that rule.
  describe "content outside the root viewport" do
    def box_of(source) = ConvertSemantics.extent(shapes(source).first.points)

    [
      ['width="100" height="50"', [80, 10, 60, 20], [80.0, 20.0, 140.0, 40.0]],
      ['width="100" height="50"', [-30, 10, 60, 20], [-30.0, 20.0, 30.0, 40.0]],
      ['width="100" height="100" viewBox="0 0 200 100"', [150, 10, 100, 20], [75.0, 60.0, 125.0, 70.0]]
    ].each do |root, rect, expected|
      it "paints #{rect.inspect} unclipped inside #{root}" do
        x, y, width, height = rect
        source = svg(%(<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}"/>), root: root)

        expect(box_of(source)).to eq(expected)
      end
    end
  end

  describe "the lossiness verdict" do
    let(:shifted) { svg(%(<rect width="5" height="5"/>), root: 'width="100" height="100" viewBox="10 10 100 100"') }

    def verdict(source, target = :eps)
      Claricle::Image.from_content(source, format: :svg).convert(to: target).lossiness
    end

    it "is not lossless for an SVG the repair could not read" do
      declared = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n#{shifted}"

      expect(%i[eps ps].map { |target| verdict(declared, target) }).to eq(%w[unknown unknown])
    end

    it "stays lossless for the same SVG once it is readable" do
      expect(verdict(shifted)).to eq("lossless")
    end

    {
      "zero viewBox width" => 'viewBox="0 0 0 100"',
      "negative viewBox width" => 'viewBox="0 0 -200 100"',
      "zero viewBox height" => 'viewBox="0 0 200 0"',
      "negative viewBox height" => 'viewBox="0 0 200 -100"'
    }.each do |name, root|
      it "is not lossless for a #{name}, which disables rendering" do
        source = svg(%(<rect width="5" height="5"/>), root: %(width="100" height="50" #{root}))

        expect(verdict(source)).not_to eq("lossless")
      end
    end

    {
      "preserveAspectRatio none" => 'viewBox="0 0 200 100" preserveAspectRatio="none"',
      "preserveAspectRatio slice" => 'viewBox="0 0 200 100" preserveAspectRatio="xMinYMin slice"',
      "preserveAspectRatio meet" => 'viewBox="0 0 200 100" preserveAspectRatio="xMinYMin meet"',
      "a percentage size" => 'width="50%" height="50%" viewBox="0 0 200 100"',
      "a mm size" => 'width="100mm" height="50mm" viewBox="0 0 200 100"',
      "an em size" => 'width="10em" height="5em" viewBox="0 0 200 100"'
    }.each do |name, root|
      it "is not lossless for #{name}, which the scaling does not model" do
        expect(verdict(svg(%(<rect width="5" height="5"/>), root: root))).not_to eq("lossless")
      end
    end

    it "is not lossless for a nested svg, which postsvg does not place" do
      nested = svg(%(<svg x="50" width="100" height="50" viewBox="0 0 200 100"><rect width="5" height="5"/></svg>))

      expect(verdict(nested)).not_to eq("lossless")
    end

    {
      "text-anchor" => %(<text x="50" y="20" text-anchor="middle">Hi</text>),
      "tspan x/y" => %(<text x="5" y="20">A<tspan x="50" y="40">B</tspan></text>)
    }.each do |name, body|
      it "is not lossless for #{name}, which postsvg drops" do
        expect(verdict(svg(body))).not_to eq("lossless")
      end
    end
  end
end
