# frozen_string_literal: true

# Partial-double verification is a suite-wide safety net, and a net that is
# off looks exactly like a net that is on: every example still passes. So it
# gets its own pin rather than being trusted to stay configured.
#
# Measured before it was turned on: `allow(image).to receive(:no_such_method)`
# passed green against a real `Claricle::Image`. Any spec that stubbed a
# method it had misremembered or that had since been renamed was asserting
# nothing at all, while reading as a precise assertion.
RSpec.describe "partial double verification" do
  # A real object, not a double -- the setting governs PARTIAL doubles, and
  # a plain `double` would bypass it entirely. A `double` is not interface
  # verified at all: it accepts any method, whatever this flag says. Only
  # `instance_double`, `class_double` and `object_double` verify an API,
  # and they are governed by `verify_doubled_constant_names`, not by this.
  let(:image) { Claricle::Image.new(format: :png, path: "/nonexistent.png") }

  it "refuses to stub a method the object does not have" do
    expect { allow(image).to receive(:definitely_not_a_real_method) }
      .to raise_error(RSpec::Mocks::MockExpectationError, /does not implement/)
  end

  it "refuses to expect a method the object does not have" do
    expect { expect(image).to receive(:also_not_a_real_method) }
      .to raise_error(RSpec::Mocks::MockExpectationError, /does not implement/)
  end

  # The other half of the guard, and the reason the two examples above are
  # not enough on their own: a setting that rejected EVERY stub would satisfy
  # them while making the suite unusable. This proves it still allows the
  # legitimate case.
  it "still allows stubbing a method the object does have" do
    allow(image).to receive(:format).and_return(:svg)

    expect(image.format).to eq(:svg)
  end
end
