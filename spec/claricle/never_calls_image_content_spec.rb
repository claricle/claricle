# frozen_string_literal: true

require_relative "../support/inspect_fixture"

# Handed a PATH-BORN image, no handler may call `Image#content` or leave
# bytes in its `@content`: `#content` slurps the whole file into memory,
# defeating the bound `with_source` exists to keep. A content-born image
# legitimately reaches `#content` (`with_path` writes it to a temp file);
# only path-born is in scope here.
#
# Samples are driven off the registry, so a new inspect-capable format
# cannot skip this file. Where the detector accepts a file the handler then
# fails on, add that failing file too -- a handler that slurps only on the
# failure path would otherwise pass on good input alone. eps's failing
# sample is the DOS EPS wrapper signature (C5 D0 D3 C6): detected as eps by
# magic bytes, but its PostScript range is invalid, so the header scan
# refuses it before ever reaching the PostScript delegate.
RSpec.describe "Handlers inspect path-born samples without calling Image#content" do
  # Local variables, not `let`: `samples.each` below builds the example
  # tree once, when this file loads, before any example runs. `let` is
  # lazy per-example and cannot generate examples at that time -- only
  # values used INSIDE an `it` block could safely be `let` instead.
  registry = Claricle.const_get(:Registry)

  # Only the formats whose handler implements inspect. A convert-only
  # handler would otherwise fail here for the wrong reason.
  inspectable = registry.formats.select do |format|
    registry.capabilities_for(format).include?(:inspect)
  end

  # format => fixture file => the parse status that file must produce.
  samples = {
    # The pdf pair was BUILT, not found: the PDF handler builds its own
    # inputs at runtime and left no fixture behind. Reproduce with #12's
    # own builder:
    #
    #   require_relative "spec/support/pdf_builder"
    #   FileUtils.cp(PdfBuilder.path, "spec/fixtures/inspect/valid.pdf")
    #   File.binwrite("spec/fixtures/inspect/no_trailer.pdf",
    #                 File.binread(PdfBuilder.path)[0, 60])
    #
    # 60 bytes lands well inside the object list, before the xref (162) or
    # trailer (251) -- every cut from byte 9 through 297 reports the same
    # "no trailer"/"failed" result, so this point is not fragile.
    pdf: { "valid.pdf" => "ok", "no_trailer.pdf" => "failed" },
    png: { "valid.png" => "ok", "short_ihdr.png" => "failed" },
    emf: { "valid.emf" => "ok", "truncated_44.emf" => "failed" },
    eps: { "basic.eps" => "ok", "zeroed_wrapper.eps" => "failed" },
    ps: { "bare.ps" => "ok" },
    svg: { "valid.svg" => "ok" }
  }.freeze

  # Both directions: a format added to the registry with no sample here
  # fails, and a sample that outlives its format fails too.
  it "keeps samples for exactly the formats the registry can inspect" do
    expect(samples.keys).to match_array(inspectable)
  end

  samples.each do |format, files|
    files.each do |name, parse_status|
      it "inspects path-born #{name} without calling Image#content" do
        image = Claricle::Image.from_path(InspectFixture.path(name))
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
