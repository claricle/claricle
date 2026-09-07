# frozen_string_literal: true

# Partial-double verification is a suite-wide safety net, and a net that is
# off looks exactly like a net that is on: every example still passes. So it
# gets its own pin rather than being trusted to stay configured.
#
# The object is a local class, not a library class: the setting is about
# RSpec, so nothing here should break when Claricle changes. It is a real
# object and not a `double`, because the setting governs PARTIAL doubles
# only; a plain `double` accepts any method whatever this flag says.
RSpec.describe "partial double verification" do
  let(:object) { Struct.new(:format).new(:png) }

  it "refuses to stub a method the object does not have" do
    expect { allow(object).to receive(:definitely_not_a_real_method) }
      .to raise_error(RSpec::Mocks::MockExpectationError, /does not implement/)
  end

  # A setting that rejected EVERY stub would satisfy the example above while
  # making the suite unusable, so the allowed case is pinned too.
  it "still allows stubbing a method the object does have" do
    allow(object).to receive(:format).and_return(:svg)

    expect(object.format).to eq(:svg)
  end
end
