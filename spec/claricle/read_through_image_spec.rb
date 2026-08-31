# frozen_string_literal: true

require "tempfile"

# Handlers reach their bytes THROUGH `Image`, not around it: every one
# of them goes via `Image#with_source` or `Image#with_path`, and none
# calls `Image#content`.
#
# That distinction is the whole point. `#content` is
# `@content ||= File.binread(path).freeze` -- it reads the entire file
# and then retains it for the life of the image. `with_source` hands
# over the open File and retains nothing.
#
# This regressed once. `Handlers::Metafile#inspection` records the cost:
# a stat reading low "used to send the whole stream through
# `image.content` -- an unbounded `File.binread` -- so a file that grew
# after the stat was materialised whole, defeating the limit for exactly
# the streams it exists to bound." It was fixed there, and afterwards no
# example held any format to it.
#
# WHAT THIS DELIBERATELY DOES NOT CLAIM: that inspection reads only a
# bounded prefix. How much a handler reads depends on the format AND on
# the shape of the input -- PS and EPS follow the DSC header as far as
# it runs, PNG reads a header per chunk, EMF changes strategy at
# `Handlers::Metafile::SCAN_LIMIT`. Four successive attempts to
# summarise that per format were each wrong in a different way, which is
# the point: "bounded" means something different for every format, and
# this file asserts it for none of them. What they DO all share is the
# property below, and it is the one that regressed.
RSpec.describe "Handlers read through Image" do
  def fixture(name)
    File.join(__dir__, "..", "fixtures", "inspect", name)
  end

  # A readable sample per format. SVG has no on-disk fixture -- its own
  # specs build sources inline -- so it is written to a temporary file,
  # because only a PATH-born image can reach the unbounded read at all.
  let(:on_disk) do
    { png: "valid.png", emf: "valid.emf", eps: "basic.eps", ps: "bare.ps" }
  end

  let(:inline) do
    { svg: %(<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>) }
  end

  let(:formats) { on_disk.keys + inline.keys }

  let(:with_sample) do
    lambda do |format, &block|
      name = on_disk[format]
      next block.call(fixture(name)) if name

      source = inline.fetch(format) do
        raise "no sample for #{format.inspect}: add one, so this file keeps covering every format"
      end

      Tempfile.create(["sample", ".#{format}"]) do |file|
        file.binmode
        file.write(source)
        file.flush
        block.call(file.path)
      end
    end
  end

  # Both directions: a format added to the registry with no sample here
  # fails, and a sample that outlives its format fails too.
  it "keeps a sample for exactly the formats the registry handles" do
    expect(formats).to match_array(Claricle.const_get(:Registry).formats)
  end

  Claricle.const_get(:Registry).formats.each do |format|
    it "inspects a path-born #{format} image without calling Image#content" do
      with_sample.call(format) do |path|
        image = Claricle::Image.from_path(path)
        # Forbids the unbounded reader specifically. It does NOT prove
        # which route the handler took instead: a handler reading the
        # path itself would satisfy this too.
        expect(image).not_to receive(:content)

        inspection = image.inspection

        # Detected from the BYTES by `Detector.detect_path`, never the
        # extension -- so a sample cannot quietly be the wrong format.
        expect(inspection.format).to eq(format.to_s)
        # Names a real outcome, so the example cannot pass against a
        # handler that returned something inert.
        expect(inspection.parse_status).to eq("ok")
        # Independent of the expectation above, which a direct
        # `@content` assignment would slip past. Scoped to that one
        # ivar: bytes parked under some other name are not covered.
        expect(image.instance_variable_get(:@content)).to be_nil
      end
    end
  end
end
