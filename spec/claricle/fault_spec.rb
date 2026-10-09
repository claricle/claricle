# frozen_string_literal: true

RSpec.describe "Claricle::Fault" do
  fault = Claricle.const_get(:Fault)

  # UnsupportedProfile is an InvocationError: a wrong argument, so exit 2.
  it "exits 2 for UnsupportedProfile" do
    error = Claricle::UnsupportedProfile.new(:png, "nope", %i[base])

    expect(fault.exit_code(error)).to eq(2)
  end

  it "falls back to the exception class when message is not text" do
    stub_const("NonTextMessageError", Class.new(StandardError) do
      def message = nil
    end)

    expect(fault.message(NonTextMessageError.new)).to eq("NonTextMessageError")
  end

  it "falls back to the exception class when reading message fails" do
    stub_const("BrokenMessageError", Class.new(StandardError) do
      def message = raise("broken message")
    end)

    expect(fault.message(BrokenMessageError.new)).to eq("BrokenMessageError")
  end

  it "still replaces invalid bytes in a normal exception message" do
    expect(fault.message(StandardError.new("bad \xFF".b))).to eq("bad \uFFFD")
  end
end
