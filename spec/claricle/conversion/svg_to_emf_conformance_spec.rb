# frozen_string_literal: true

require "tmpdir"

# Claricle's own svg -> emf output must pass Claricle's own conformance check.
RSpec.describe "svg -> emf conversion output" do
  fixtures = File.expand_path("../../fixtures", __dir__)
  sources = %w[
    conform/valid.svg convert/bare_doctype_rect.svg convert/cdata_rect.svg
    convert/geom_px_rect.svg convert/gradient_linear.svg convert/no_paint_rect.svg
    convert/clip_path_element.svg
  ].map { |name| File.join(fixtures, name) }

  sources.each do |source|
    it "conforms for #{File.basename(source)}" do
      Dir.mktmpdir do |dir|
        output = File.join(dir, "out.emf")
        Claricle.convert(source, output: output)
        report = Claricle.conformance_report(output)

        expect(report.issues.map(&:code)).not_to include("emf.byte_count_mismatch")
        expect(Claricle.conform?(output)).to be(true)
      end
    end
  end

  it "declares the byte count of the file it wrote" do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.emf")
      Claricle.convert(sources.first, output: output)
      bytes = File.binread(output)

      expect(bytes.byteslice(48, 4).unpack1("V")).to eq(bytes.bytesize)
    end
  end
end
