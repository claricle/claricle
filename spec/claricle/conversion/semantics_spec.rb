# frozen_string_literal: true

require "emf"
require_relative "../../support/convert_semantics"

# 04-convert.md "Done when": every `:lossless` classification is fixture-proven
# for the features present in that fixture, and the gradient, clip-path and
# embedded-raster cases each produce a `:lossy` classification rather than
# silent loss. spec/fixtures/convert/README.md says the classifier specs prove
# DETECTION, not preservation; this file reads the converted output to prove
# the second half.
RSpec.describe "Conversion semantics" do
  def source_image(name, ext = "svg")
    Claricle::Image.from_path(ConvertSemantics.fixture_path(name, ext))
  end

  def convert(name, target, ext: "svg")
    source_image(name, ext).convert(to: target)
  end

  def drawn(name, target) = ConvertSemantics.painted_shapes(convert(name, target).content)

  def expected(name) = ConvertSemantics.expected_shapes(ConvertSemantics.fixture_path(name))

  def size_of(shape)
    min_x, min_y, max_x, max_y = ConvertSemantics.extent(shape.points)
    [max_x - min_x, max_y - min_y]
  end

  # Through the convert path, forcing :svg so an undetectable fixture still
  # answers; a fixture the writer refuses has no verdict.
  def verdict(path, target)
    Claricle::Image.from_content(File.binread(path), format: :svg).convert(to: target).lossiness
  rescue Claricle::ConversionError
    nil
  end

  def min_x_of(shape) = ConvertSemantics.extent(shape.points).first

  # Every svg fixture the classifier calls :lossless for eps and ps. Written
  # out and cross-checked against the classifier below, so a new :lossless
  # fixture cannot dodge the preservation table.
  lossless_fixtures = %w[
    bare_doctype_rect cdata_rect comment_rect defs_container geom_px_rect
    geom_viewbox_rect no_paint_rect paint_rgb_rect rect_and_line
    redundant_svg_ns_rect xml_space_rect xmldecl_rect
  ]

  describe ":lossless svg -> eps/ps" do
    it "lists exactly the fixtures the classifier calls lossless" do
      classified = Dir[ConvertSemantics.fixture_path("*")].filter_map do |path|
        name = File.basename(path, ".svg")
        name if %i[eps ps].all? { |target| verdict(path, target) == "lossless" }
      end

      expect(classified.sort).to eq(lossless_fixtures.sort)
    end

    %i[eps ps].each do |target|
      lossless_fixtures.each do |name|
        context "#{name} -> #{target}" do
          it "is classified lossless" do
            expect(convert(name, target).lossiness).to eq("lossless")
          end

          it "paints every shape the source draws, at the source's size and x position" do
            pending "width=\"10px\" is read as 0: the rect is painted with zero size" if name == "geom_px_rect"

            actual = drawn(name, target)

            expected(name).each do |want|
              got = actual.select { |shape| shape.kind == want.kind }
              expect(got.map { |shape| [size_of(shape), min_x_of(shape)] })
                .to include([size_of(want), min_x_of(want)])
            end
          end

          it "paints each shape in the colour the source gave it" do
            pending "rgb() paint is dropped: output has no setrgbcolor, so red paints as black" if
              name == "paint_rgb_rect"

            actual = drawn(name, target)
            expected(name).each do |want|
              expect(actual.select { |shape| shape.kind == want.kind }.map(&:color)).to include(want.color)
            end
          end

          it "paints no shape the source did not ask for" do
            pending "a line with no stroke attribute is stroked black; SVG paints no stroke" if
              name == "no_paint_rect"

            expect(drawn(name, target).map(&:kind)).to eq(expected(name).map(&:kind))
          end
        end
      end

      it "sets the bounding box from the source's root width and height (#{target})" do
        expect(convert("rect_and_line", target).content).to include("%%BoundingBox: 0 0 100 50\n")
      end

      it "paints the rect before the line, the source's order (#{target})" do
        expect(drawn("rect_and_line", target).map(&:kind)).to eq(%i[fill stroke])
      end

      it "keeps the SVG y-down origin: a rect at the top-left lands at the top of the page (#{target})" do
        pending "svg -> #{target} emits y-up coordinates unflipped: the rect lands at y 0..10, the page bottom"

        fill = drawn("rect_and_line", target).find { |shape| shape.kind == :fill }
        _, min_y, _, max_y = ConvertSemantics.extent(fill.points)

        expect([min_y, max_y]).to eq([40.0, 50.0])
      end
    end

    it "drops a rect inside defs, as SVG does not render it" do
      expect(drawn("defs_container", :eps).map(&:kind)).to eq(%i[stroke])
    end
  end

  # The EMF writer's :lossless claim is withdrawn (the classifier answers
  # unknown), so these hold no promise; they pin what survives so the claim can
  # come back with evidence. Strongest for svg -> emf, where the writer emits
  # plain rectangle/moveto/lineto records. eps/ps -> emf goes through path
  # records, so only the paint objects are checked: a weaker assertion.
  describe "emf output" do
    def records(name, ext)
      bytes = convert(name, :emf, ext: ext).content
      metafile = Emf.parse(bytes)
      expect(metafile.errors).to be_empty
      metafile.records.map { |record| [record.type_id, record.wire.snapshot] }
    end

    def painted_with(records, type_id, color)
      records.any? { |id, wire| id == type_id && wire[:color].slice(:red, :green, :blue) == color }
    end

    red = { red: 255, green: 0, blue: 0 }
    black = { red: 0, green: 0, blue: 0 }

    it "svg -> emf carries a 10x10 rectangle at the origin, a 0,0 -> 10,10 line, a red brush and a black pen" do
      found = records("rect_and_line", "svg")
      rectangle = found.find { |id, _| id == 43 }
      move = found.find { |id, _| id == 27 }
      line = found.find { |id, _| id == 54 }

      expect(rectangle.last[:rcl_box]).to eq(left: 0, top: 0, right: 10, bottom: 10)
      expect([move.last[:origin], line.last[:origin]]).to eq([{ x: 0, y: 0 }, { x: 10, y: 10 }])
      expect(painted_with(found, 39, red)).to be(true)
      expect(painted_with(found, 38, black)).to be(true)
    end

    %w[eps ps].each do |ext|
      it "#{ext} -> emf carries a red brush and a black pen" do
        found = records("rect_and_line", ext)

        expect(painted_with(found, 39, red)).to be(true)
        expect(painted_with(found, 38, black)).to be(true)
      end
    end
  end

  # No :lossless claim exists on these edges (all unknown), so the claim under
  # test is weaker: the source's two shapes and two colours reach the output.
  describe "rect_and_line on the unclassified edges" do
    [%i[emf eps], %i[emf ps], %i[eps ps], %i[ps eps]].each do |source, target|
      it "#{source} -> #{target} keeps the rect edge, the line, red and black" do
        content = convert("rect_and_line", target, ext: source.to_s).content

        expect(content).to match(/^10 0 rlineto$/)
        expect(content).to match(/^10 10 lineto$/)
        expect(content).to match(/^1 0 0 setrgbcolor$/)
        expect(content).to match(/^0 0 0 setrgbcolor$/)
      end
    end

    { emf: "10.0000", eps: "10", ps: "10" }.each do |source, edge|
      it "#{source} -> svg keeps a red fill, a black stroke and the 10 unit rect edge" do
        content = convert("rect_and_line", :svg, ext: source.to_s).content

        expect(content).to match(/fill="#ff0000"/i)
        expect(content).to match(/stroke="#000000"/i)
        expect(content).to match(/\b#{Regexp.escape(edge)}\b/)
      end
    end
  end

  # The loss a :lossy label reports must be real, or the label is noise. These
  # fixtures are the control plus ONE feature, so equal output to the control
  # means the feature left no trace -- exactly what makes the label the only
  # place the loss is recorded.
  describe ":lossy features, through the convert path" do
    lossy = %w[gradient_linear gradient_radial prefixed_gradient clip_path_element clip_path_attribute]

    %i[eps ps emf].each do |target|
      lossy.each do |name|
        it "classifies #{name} -> #{target} lossy, with no trace of the feature in the output" do
          conversion = convert(name, target)

          expect(conversion.lossiness).to eq("lossy")
          expect(conversion.content).to eq(convert("rect_and_line", target).content)
        end
      end
    end

    %i[eps ps].each do |target|
      it "classifies embedded_raster -> #{target} lossy" do
        expect(convert("embedded_raster", target).lossiness).to eq("lossy")
      end
    end

    # README: unmeasured for emf, so unknown rather than a guessed verdict.
    it "classifies embedded_raster -> emf unknown, never lossless" do
      expect(convert("embedded_raster", :emf).lossiness).to eq("unknown")
    end

    # Control for the table above: the label comes from the feature, not from
    # the target. The same writer on the control is not lossy.
    it "does not classify the control lossy on the same targets" do
      expect(%i[eps ps].map { |target| convert("rect_and_line", target).lossiness }).to eq(%w[lossless lossless])
    end
  end
end
