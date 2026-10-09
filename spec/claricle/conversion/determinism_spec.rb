# frozen_string_literal: true

require_relative "../../support/convert_semantics"

# 00-overview.md D11: byte identity and idempotence are unreachable, so what
# a conversion can promise is determinism -- the same input gives the same
# bytes. A conversion that stamped a time, a counter or a random id would break
# every consumer that diffs or caches output.
RSpec.describe "Conversion determinism" do
  def convert_bytes(name, ext, target)
    Claricle::Image.from_path(ConvertSemantics.fixture_path(name, ext)).convert(to: target)
  end

  # rect_and_line exists in all four source formats; this is every edge the
  # registry offers, written out rather than derived from the registry so a
  # dropped edge reddens the spec instead of shrinking it.
  edges = {
    svg: %i[eps ps emf],
    emf: %i[svg eps ps],
    eps: %i[svg emf ps],
    ps: %i[svg emf eps]
  }

  edges.each do |source, targets|
    targets.each do |target|
      it "converts rect_and_line #{source} -> #{target} to identical bytes twice" do
        first = convert_bytes("rect_and_line", source, target)
        second = convert_bytes("rect_and_line", source, target)

        expect(first.content).not_to be_empty
        expect(second.content).to eq(first.content)
        expect(second.lossiness).to eq(first.lossiness)
      end
    end
  end

  it "covers all twelve edges" do
    expect(edges.values.sum(&:length)).to eq(12)
  end

  # The in-process pairs above run within the same second. A clock stamp with
  # one-second resolution only shows when the second conversion is later.
  it "gives the same bytes across a clock tick, on every edge" do
    first = edges.flat_map do |source, targets|
      targets.map { |target| [[source, target], convert_bytes("rect_and_line", source, target).content] }
    end
    sleep 1.1
    second = first.map do |(source, target), _|
      [[source, target], convert_bytes("rect_and_line", source, target).content]
    end

    expect(second).to eq(first)
  end

  # A feature fixture goes through a different branch of each writer than the
  # control does, so determinism of the control proves nothing about it.
  %w[gradient_linear clip_path_element embedded_raster text_rect_line].each do |fixture|
    %i[eps ps emf].each do |target|
      it "converts #{fixture} svg -> #{target} to identical bytes twice" do
        first = convert_bytes(fixture, "svg", target)
        second = convert_bytes(fixture, "svg", target)

        expect(first.content).not_to be_empty
        expect(second.content).to eq(first.content)
      end
    end
  end

  it "gives a different result for a different target, so equality above is not a constant" do
    eps = convert_bytes("rect_and_line", "svg", :eps).content
    ps = convert_bytes("rect_and_line", "svg", :ps).content

    expect(ps).not_to eq(eps)
  end
end
