# frozen_string_literal: true

RSpec.describe "Claricle::Fault" do
  fault = Claricle.const_get(:Fault)

  # UnsupportedProfile is an InvocationError: a wrong argument, so exit 2.
  it "exits 2 for UnsupportedProfile" do
    error = Claricle::UnsupportedProfile.new(:png, "nope", %i[base])

    expect(fault.exit_code(error)).to eq(2)
  end
end
