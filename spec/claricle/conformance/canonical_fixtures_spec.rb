# frozen_string_literal: true

# Conformance over third-party corpora (issue #1: "canonical conformance
# fixtures"). PNG is exercised against PngSuite in png_spec.rb. Provenance and
# licenses: spec/fixtures/canonical/README.
#
# Not covered: a W3C SVG 1.1 suite (not shipped by svg_conform; the IETF
# svgcheck corpus stands in), a Microsoft EMF reference corpus (none is
# freely redistributable), and PDF/A-failing files (claricle checks structure
# and Arlington, not PDF/A).
RSpec.describe "Claricle conformance over canonical fixtures" do
  root = File.expand_path("../../fixtures/canonical", __dir__)

  rows = [
    { file: "svg/svgcheck-good.svg", conforms: true, codes: [] },
    { file: "svg/svgcheck-viewBox-none.svg", conforms: false, codes: %w[viewbox_required] },
    { file: "svg/svgcheck-malformed.svg", conforms: false, codes: %w[namespace] },
    { file: "svg/svgcheck-DrawBerry-sample-2.svg", conforms: false, codes: %w[namespace_attributes] },
    { file: "pdf/verapdf-6-8-2-2-t01-pass-a.pdf", conforms: true, codes: [] },
    { file: "pdf/verapdf-6-2-3-2-t01-pass-a.pdf", conforms: true, codes: [] },
    { file: "pdf/qpdf-bad-xref.pdf", conforms: false, codes: %w[PDF_STRUCTURE_UNREADABLE] },
    { file: "pdf/qpdf-bad10.pdf", conforms: false, codes: %w[PDF_STRUCTURE_UNREADABLE] },
    { file: "emf/poi-vector_image.emf", conforms: true, codes: [] },
    { file: "emf/poi-wrench.emf", conforms: true, codes: [] },
    { file: "emf/poi-63327.emf", conforms: true, codes: [] },
    { file: "emf/poi-61294.emf", conforms: false,
      codes: %w[emf.parse_error emf.record_count_mismatch emf.record_framing] },
    { file: "emf/poi-crash-7b60e9fe.emf", conforms: false,
      codes: %w[emf.byte_count_mismatch emf.parse_error emf.record_count_mismatch emf.record_framing] }
  ]

  rows.each do |row|
    it "#{row[:file]} #{row[:conforms] ? "conforms" : "is rejected"}" do
      path = File.join(root, row[:file])
      codes = Claricle.conformance_report(path).issues.map(&:code).uniq.sort

      expect(codes).to eq(row[:codes])
      expect(Claricle.conform?(path)).to be(row[:conforms])
    end
  end
end
