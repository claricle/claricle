# frozen_string_literal: true

# Handed a PATH-BORN image, no handler calls `Image#content`, and none
# leaves bytes in that image's `@content`.
#
# `#content` is `@content ||= File.binread(path).freeze`. It reads the
# whole file and keeps it for the life of the image. `with_source` hands
# over the open File and retains nothing. This regressed once:
# `Handlers::Metafile#inspection` used to send the whole stream through
# `image.content`, which defeated the limit it exists to bound.
#
# PATH-BORN is the whole scope. A content-born image legitimately reaches
# `#content`, because `with_path` writes those bytes to a temporary file.
# Only a path-born image can reach the unbounded read this file forbids.
#
# The samples are driven off the registry, so a new inspect-capable format
# cannot arrive without one. Where a format has a file the detector accepts
# and the handler then fails on, it brings that file too: a handler that
# slurps only on the failure path would pass on good input alone. eps, ps
# and svg bring none, because their handlers answer "ok" for every byte
# string the detector accepts as that format.
registry = Claricle.const_get(:Registry)

# Only the formats whose handler implements inspect. A convert-only
# handler would otherwise fail here for the wrong reason.
inspectable = registry.formats.select do |format|
  registry.capabilities_for(format).include?(:inspect)
end

# format => fixture file => the parse status that file must produce.
samples = {
  png: { "valid.png" => "ok", "short_ihdr.png" => "failed" },
  emf: { "valid.emf" => "ok", "truncated_44.emf" => "failed" },
  eps: { "basic.eps" => "ok" },
  ps: { "bare.ps" => "ok" },
  svg: { "valid.svg" => "ok" }
}.freeze

RSpec.describe "Handlers inspect path-born samples without calling Image#content" do
  def fixture(name)
    File.join(__dir__, "..", "fixtures", "inspect", name)
  end

  # Both directions: a format added to the registry with no sample here
  # fails, and a sample that outlives its format fails too.
  it "keeps samples for exactly the formats the registry can inspect" do
    expect(samples.keys).to match_array(inspectable)
  end

  samples.each do |format, files|
    files.each do |name, parse_status|
      it "inspects path-born #{name} without calling Image#content" do
        image = Claricle::Image.from_path(fixture(name))
        # Every Image, not only this one: a handler that dups the image
        # and slurps the copy would leave this receiver untouched.
        expect_any_instance_of(Claricle::Image).not_to receive(:content)

        inspection = image.inspection

        # Detected from the BYTES by `Detector.detect_path`, never the
        # extension, so a sample cannot quietly be the wrong format.
        expect(inspection.format).to eq(format.to_s)
        expect(inspection.parse_status).to eq(parse_status)
        # Independent of the expectation above, which a direct `@content`
        # assignment would slip past. The `include` guards the guard:
        # `instance_variable_get` answers nil for an ivar that does not
        # exist, so renaming `@content` would leave the line below passing
        # forever while pinning nothing.
        expect(image.instance_variables).to include(:@content)
        expect(image.instance_variable_get(:@content)).to be_nil
      end
    end
  end
end
