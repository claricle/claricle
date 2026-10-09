# frozen_string_literal: true

require "emf"
require_relative "../../support/convert_semantics"

# 00-overview.md D11: "same-format parse->serialize identity for EMF". There
# is no emf -> emf conversion (`Claricle.convert_one` refuses a same-format
# target), so the identity lives in the `emf` gem itself: `Emf.parse` and
# `Emf.serialize`, which the metafile handler delegates its parsing to.
# emf 0.1.0's README claims byte-identical round-trips; this pins that claim on
# the fixtures this gem ships, so a gem bump that loses it goes red here.
RSpec.describe "EMF same-format identity" do
  inspect_dir = File.expand_path("../../fixtures/inspect", __dir__)

  # Every fixture the parser accepts with no parse error. Written out, not
  # globbed: the corpus is the claim, and a fixture dropped from disk should
  # redden the spec instead of shrinking it.
  round_trippable = %w[
    after_eof comment_shaped_record distinct_device emf_plus header_100
    misaligned_record overrun_comment overrun_then_carrier padded_comment
    second_device unequal_device valid zero_device_both zero_device_x
    zero_device_y record_size_10 short_comment short_eof short_eof_16
  ].map { |name| File.join(inspect_dir, "#{name}.emf") }
  round_trippable << ConvertSemantics.fixture_path("rect_and_line", "emf")

  # Measured: parse reports an error AND serialize differs. Outside the
  # guarantee, but only because the parser says so -- the second example pins that.
  reported_malformed = %w[broken_suffix record_size_4 truncated_99 zero_record]
                       .map { |name| File.join(inspect_dir, "#{name}.emf") }

  round_trippable.each do |path|
    it "serializes #{File.basename(path)} back to the bytes it was parsed from" do
      bytes = File.binread(path)
      metafile = Emf.parse(bytes)

      expect(Emf.serialize(metafile)).to eq(bytes)
    end
  end

  it "has a non-empty corpus including the convert fixture" do
    expect(round_trippable.length).to eq(20)
    expect(round_trippable).to all(satisfy { |path| File.size(path).positive? })
  end

  reported_malformed.each do |path|
    it "reports a parse error for #{File.basename(path)}, the reason it is outside the identity claim" do
      metafile = Emf.parse(File.binread(path))

      expect(metafile.errors).not_to be_empty
    end
  end

  # The same identity on bytes this gem PRODUCES: an svg -> emf conversion
  # must itself be a well-formed metafile the parser reads back exactly.
  it "round-trips the emf bytes svg -> emf produces" do
    image = Claricle::Image.from_path(ConvertSemantics.fixture_path("rect_and_line", "svg"))
    bytes = image.convert(to: :emf).content
    metafile = Emf.parse(bytes)

    expect(metafile.errors).to be_empty
    expect(Emf.serialize(metafile)).to eq(bytes)
  end

  %i[eps ps].each do |source|
    it "round-trips the emf bytes #{source} -> emf produces" do
      image = Claricle::Image.from_path(ConvertSemantics.fixture_path("rect_and_line", source.to_s))
      bytes = image.convert(to: :emf).content
      metafile = Emf.parse(bytes)

      expect(metafile.errors).to be_empty
      expect(Emf.serialize(metafile)).to eq(bytes)
    end
  end
end
