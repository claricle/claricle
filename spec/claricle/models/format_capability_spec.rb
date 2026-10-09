# frozen_string_literal: true

RSpec.describe Claricle::Models::FormatCapability do
  let(:json) do
    %({"format":"pdf","inspect":true,"conform":true,"convert":false,"convert_to":[]})
  end

  it "is a lutaml model" do
    expect(described_class.ancestors).to include(Lutaml::Model::Serializable)
  end

  it "round-trips its row through JSON, keeping an empty convert_to" do
    row = described_class.from_json(json)

    expect(row.to_json).to eq(json)
  end

  it "reads every field back" do
    row = described_class.from_json(
      %({"format":"svg","inspect":true,"conform":false,"convert":true,"convert_to":["eps","ps"]})
    )

    expect([row.format, row.inspectable, row.conform, row.convert, row.convert_to])
      .to eq(["svg", true, false, true, %w[eps ps]])
  end

  it "keeps Object#inspect, so the JSON key does not replace it" do
    expect(described_class.from_json(json).inspect)
      .to start_with("#<Claricle::Models::FormatCapability")
  end
end
