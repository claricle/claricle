# frozen_string_literal: true

RSpec.describe Claricle do
  it "has a version number" do
    expect(Claricle::VERSION).not_to be_nil
  end

  it "defines the Error class" do
    expect(Claricle::Error).to be < StandardError
  end

  it "loads the CLI module" do
    expect(defined?(Claricle::Cli)).to eq("constant")
  end
end
