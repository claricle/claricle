# frozen_string_literal: true

RSpec.describe Claricle::Models::FormatCapability do
  let(:attributes) do
    { format: "pdf", inspectable: true, conform: true, convert: false,
      convert_to: [] }
  end

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

  it "refuses a row missing any scalar field at both doors" do
    { format: "format", inspectable: "inspect", conform: "conform", convert: "convert" }.each do |name, key|
      direct = attributes.dup.tap { |values| values.delete(name) }
      document = JSON.parse(json).tap { |values| values.delete(key) }

      expect { described_class.new(direct) }
        .to raise_error(Lutaml::Model::ValidationError, /#{name}/),
            "expected direct construction without #{name} to fail"
      expect { described_class.from_json(JSON.generate(document)) }
        .to raise_error(Lutaml::Model::ValidationError, /#{name}/),
            "expected deserialization without #{key} to fail"
    end
  end

  it "refuses non-boolean capability values at both doors" do
    { inspectable: "inspect", conform: "conform", convert: "convert" }.each do |name, key|
      direct = attributes.merge(name => "false")
      document = JSON.parse(json).merge(key => "false")

      expect { described_class.new(direct) }
        .to raise_error(Lutaml::Model::ValidationError),
            "expected direct #{name}: \"false\" to fail"
      expect { described_class.from_json(JSON.generate(document)) }
        .to raise_error(Lutaml::Model::ValidationError),
            "expected JSON #{key}: \"false\" to fail"
    end
  end
end
