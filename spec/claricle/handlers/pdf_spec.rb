# frozen_string_literal: true

require "pdfrb"
require_relative "../../support/pdf_builder"

RSpec.describe "Claricle PDF handler" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Pdf).new }

  def image_for(path)
    Claricle::Image.from_path(path)
  end

  describe "conformance_report" do
    # A structurally valid document -- catalog, one page under it, a
    # MediaBox on the page -- so `Validator.validate` has nothing to say.
    #
    # `and_call_original` on top of the two value assertions: without it,
    # a handler that never calls `Validator.validate` at all (and simply
    # returns an empty issue list) would pass this example too -- the
    # empty-issues result is a symptom of "validate ran and found
    # nothing", not proof of it.
    it "reports a conformant PDF" do
      expect(Pdfrb::Validator).to receive(:validate).and_call_original
      path = PdfBuilder.path(name: "valid")
      report = image_for(path).conformance_report

      expect(report.valid).to eq(:yes)
      expect(report.issues).to eq([])
    end

    it "carries the image's own path and format" do
      path = PdfBuilder.path(name: "valid")
      report = image_for(path).conformance_report

      expect(report.source_path).to eq(path)
      expect(report.format).to eq("pdf")
    end

    # Measured against the installed pdfrb gem: a trailer with no /Root
    # makes `document.catalog` nil, and `Validator.check_pages` raises
    # `Pdfrb::Error` ("Document has no Catalog") reaching into
    # `Document::Pages#pages_root` before it ever returns an issue list.
    describe "a catalog-less document" do
      let(:report) do
        path = PdfBuilder.path(name: "catalog-less", trailer: "<< /Size 4 >>")
        image_for(path).conformance_report
      end

      it "is not conformant, rather than raising" do
        expect(report.valid).to eq(:no)
      end

      it "maps the raised Pdfrb::Error to a synthetic structure issue" do
        expect(report.issues).to contain_exactly(
          have_attributes(
            severity: "error", code: "PDF_STRUCTURE_UNREADABLE",
            message: "PDF structure could not be validated", location: nil
          )
        )
      end
    end

    # Found while dependency-contract-checking the allowlist against the
    # real gem: `Pdfrb::Error` has several subclasses (ParseError,
    # SyntaxError, MalformedPdfError, ...), and the allowlist rescues the
    # base class, so it catches all of them -- but only a real one proves
    # that generalisation is right rather than assumed. An xref entry
    # marked "in use" pointing at a byte offset with no object there, and
    # no "N G obj" anywhere else in the file either, sends
    # `ObjectReader#recover_parse` (reached from `check_catalog`'s own
    # `document.catalog` call, not `check_pages`) to raise
    # `Pdfrb::MalformedPdfError` -- a different class, and a different
    # call site, than the "no /Root at all" case above, and still an
    # ordinary `Pdfrb::Error` as far as this handler's rescue is
    # concerned.
    describe "a reference to an object the xref claims exists but cannot be found anywhere" do
      let(:report) do
        objects = [[1, 0, "<< /Type /Catalog /Pages 99 0 R >>"]]
        path = PdfBuilder.path(name: "unresolvable-anywhere", objects: objects,
                               trailer: "<< /Size 100 /Root 1 0 R >>", phantom_oids: [99])
        image_for(path).conformance_report
      end

      it "is not conformant, rather than raising" do
        expect(report.valid).to eq(:no)
      end

      it "maps the raised Pdfrb::MalformedPdfError to the same synthetic issue" do
        expect(report.issues).to contain_exactly(
          have_attributes(
            severity: "error", code: "PDF_STRUCTURE_UNREADABLE",
            message: "PDF structure could not be validated", location: nil
          )
        )
      end
    end

    # A /Pages reference to an object that does not exist. Measured:
    # `document.object(ref)` returns nil, `Document::Pages#walk` then
    # subscripts that nil directly, raising `NoMethodError: undefined
    # method '[]' for nil` -- not `Pdfrb::Error`. The allowlist has to
    # name this specific NoMethodError, scoped to the validate call, not
    # NoMethodError in general (03-conform.md).
    describe "a /Pages reference to a missing object" do
      let(:report) do
        objects = [[1, 0, "<< /Type /Catalog /Pages 99 0 R >>"],
                   [2, 0, PdfBuilder::PAGES], [3, 0, PdfBuilder::PAGE]]
        path = PdfBuilder.path(name: "missing-pages", objects: objects)
        image_for(path).conformance_report
      end

      it "is not conformant, rather than raising" do
        expect(report.valid).to eq(:no)
      end

      it "maps the raised NoMethodError to the same synthetic issue" do
        expect(report.issues).to contain_exactly(
          have_attributes(
            severity: "error", code: "PDF_STRUCTURE_UNREADABLE",
            message: "PDF structure could not be validated", location: nil
          )
        )
      end
    end

    # A dangling reference unrelated to the catalog/pages walk: pdfrb
    # does not raise for this, it returns an ordinary error string in
    # the array `Validator.validate` gives back.
    describe "a dangling unrelated reference" do
      let(:report) do
        page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources 42 0 R >>"
        objects = [[1, 0, PdfBuilder::CATALOG], [2, 0, PdfBuilder::PAGES], [3, 0, page]]
        path = PdfBuilder.path(name: "dangling", objects: objects)
        image_for(path).conformance_report
      end

      it "is not conformant" do
        expect(report.valid).to eq(:no)
      end

      # The delegate's own string, verbatim, per 03-conform.md's mapping
      # table -- not re-worded, not re-coded per message.
      it "carries the delegate's own message as-is, with no location" do
        expect(report.issues).to contain_exactly(
          have_attributes(
            severity: "error", code: "PDF_STRUCTURE",
            message: "object 3 references 42 0 R (unresolved)", location: nil
          )
        )
      end
    end

    # Found by this handler's own adversarial pass, not named in
    # 03-conform.md's table: a /Pages node whose own /Kids cites itself
    # sends `Document::Pages#walk` into infinite recursion.
    # `SystemStackError` is not a `StandardError` subclass, so a bare
    # `rescue *MALFORMED_INPUT` misses it unless it is named explicitly.
    # Same reasoning the plan gives for EMF's truncation `FormatError`:
    # the delegate's reporting style is an exception, the user-visible
    # meaning is the same nonconformance a returned issue would carry.
    describe "a circular /Pages reference" do
      let(:report) do
        objects = [[1, 0, PdfBuilder::CATALOG],
                   [2, 0, "<< /Type /Pages /Kids [2 0 R] /Count 1 >>"]]
        path = PdfBuilder.path(
          name: "circular", objects: objects, trailer: "<< /Size 3 /Root 1 0 R >>"
        )
        image_for(path).conformance_report
      end

      it "is not conformant, rather than crashing the process" do
        expect(report.valid).to eq(:no)
      end

      it "maps the raised SystemStackError to the same synthetic issue" do
        expect(report.issues).to contain_exactly(
          have_attributes(
            severity: "error", code: "PDF_STRUCTURE_UNREADABLE",
            message: "PDF structure could not be validated", location: nil
          )
        )
      end
    end

    # The allowlist has to be narrow, or a real defect in this handler
    # would silently read as an ordinary nonconformant file (exit 1)
    # instead of the internal-error code (exit 4) that says something
    # needs fixing.
    it "does not rescue an exception off its malformed-input allowlist" do
      allow(Pdfrb::Validator).to receive(:validate).and_raise(RuntimeError, "boom")
      path = PdfBuilder.path(name: "valid")

      expect { image_for(path).conformance_report }.to raise_error(RuntimeError, "boom")
    end

    # Found while multi-agent-reviewing this handler: a `startxref`
    # pointer that resolves to neither an `xref` keyword nor a
    # parseable object -- an ordinary corrupt-file shape no fixture
    # here had tried -- raises `NoMethodError: undefined method
    # 'rindex' for nil` from `Document#find_xref_keyword`, inside
    # `Document.open` itself, not `Validator.validate`. An earlier
    # version of this handler left `Document.open` outside the rescue
    # on the strength of "every malformed shape measured opens without
    # raising" -- a contract measured on the shapes tried and wrongly
    # generalised to "every shape" (dev.md's "measured on one input
    # shape and generalised"). Reproduced directly against the real
    # gem, not stubbed: the bytes below are handwritten rather than
    # `PdfBuilder`-built because the corruption is in the trailer's
    # own `startxref` line, which `PdfBuilder` always computes
    # correctly.
    it "is not conformant for a corrupt startxref, rather than raising" do
      bytes = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" \
              "garbage garbage garbage not an xref and not an object\n" \
              "startxref\n9999\n%%EOF\n".b
      path = PdfBuilder.path_for(bytes)

      report = image_for(path).conformance_report

      expect(report.valid).to eq(:no)
      expect(report.issues).to contain_exactly(
        have_attributes(
          severity: "error", code: "PDF_STRUCTURE_UNREADABLE",
          message: "PDF structure could not be validated", location: nil
        )
      )
    end

    # The rescue wraps `Document.open` and `Validator.validate` --
    # pdfrb's own two calls -- and nothing this handler writes itself.
    # A `NoMethodError` from `Models::Report` construction (a real
    # defect in Claricle's own code, not a validation fault) must
    # still propagate rather than read as nonconformance.
    #
    # Raises on the FIRST call only, then calls through -- not
    # `and_raise` unconditionally. A rescue mistakenly widened to cover
    # `report_for` would swallow the first raise and simply build the
    # `Report` a second time, which this stub's SECOND call lets
    # succeed -- so an unconditional stub could not tell "the rescue
    # correctly excludes report_for" from "it wrongly includes it and
    # retries", since both would observably raise the same error.
    # Measured: this distinction is exactly what an earlier, broader
    # version of this stub missed.
    it "does not rescue a NoMethodError raised outside pdfrb's own calls" do
      calls = 0
      allow(Claricle::Models::Report).to receive(:new).and_wrap_original do |original, **kwargs|
        calls += 1
        raise NoMethodError, "boom" if calls == 1

        original.call(**kwargs)
      end
      path = PdfBuilder.path(name: "valid")

      expect { image_for(path).conformance_report }.to raise_error(NoMethodError, "boom")
    end

    # Found in copilot-review: an earlier version built the mapped
    # `Issue`s (`issue_from`) INSIDE the same method as the rescue, so
    # `Models::Issue.new` raising would have read as an ordinary
    # nonconformant file instead of propagating. Same
    # raise-once-then-succeed stub as the `Models::Report` case above,
    # for the same reason -- and driven against the dangling-reference
    # fixture specifically, since that is the one shape that reaches
    # `issue_from` at all (every raising shape maps through
    # `unreadable_issue` instead, never touching `issue_from`).
    it "does not rescue a NoMethodError raised out of issue construction" do
      calls = 0
      allow(Claricle::Models::Issue).to receive(:new).and_wrap_original do |original, **kwargs|
        calls += 1
        raise NoMethodError, "boom" if calls == 1

        original.call(**kwargs)
      end
      page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources 42 0 R >>"
      objects = [[1, 0, PdfBuilder::CATALOG], [2, 0, PdfBuilder::PAGES], [3, 0, page]]
      path = PdfBuilder.path(name: "dangling-issue-construction", objects: objects)

      expect { image_for(path).conformance_report }.to raise_error(NoMethodError, "boom")
    end
  end
end
