# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"

require_relative "../../support/pdf_builder"
require_relative "../../support/pdf_objstm_builder"

RSpec.describe "Claricle PDF handler" do
  pdf_class = Claricle.const_get(:Handlers).const_get(:Pdf)

  let(:handler) { pdf_class.new }

  # Path-born by default. The handler opens the path `with_path` yields,
  # so a path-born image is the shape every read actually takes; the
  # content-born case gets its own examples rather than being the way
  # every other example happens to run.
  def inspect_pdf(path)
    handler.inspection(Claricle::Image.new(format: :pdf, path: path))
  end

  def pdf(**parts) = PdfBuilder.path(**parts)
  def objstm(**parts) = PdfObjstmBuilder.path(**parts)
  def raw_pdf(bytes) = PdfBuilder.write(bytes.b, name: "raw")

  # The baseline's parts, so a fixture overrides exactly one of them.
  def objects(cat: PdfBuilder::CATALOG, pages: PdfBuilder::PAGES, extra: [], gens: [0, 0, 0])
    [[1, gens[0], cat], [2, gens[1], pages], [3, gens[2], PdfBuilder::PAGE]] + extra
  end

  def pages_node(count) = "<< /Type /Pages /Kids [3 0 R]#{count} >>"

  # A page tree whose `/Count` is the indirect object 4, with that object
  # spelled by the caller. Five objects, so the trailer's `/Size` grows.
  def indirect_count_pdf(body, **parts)
    pdf(objects: objects(pages: pages_node(" /Count 4 0 R"), extra: [[4, 0, body]]),
        trailer: "<< /Size 5 /Root 1 0 R >>", **parts)
  end

  # What BARE pdfrb does with the same file. Every refusal fixture whose
  # guard is this handler's own asserts this as a precondition, because
  # the guard is worth nothing if the delegate refused the file anyway.
  def bare_walk(path)
    require "pdfrb"
    Pdfrb::Document.open(path) do |doc|
      catalog = doc.object(doc.trailer[:Root])
      doc.object(catalog.value[:Pages])
    end
  end

  # `SystemStackError` is not a `StandardError`, and two fixtures raise
  # it, so both are named rather than reaching for a bare `Exception`.
  def raised_by(path)
    bare_walk(path)
    nil
  rescue StandardError, SystemStackError => e
    e.class
  end

  # Every exception that reached `guarded`, whether or not it swallowed
  # it. `super` runs the real method with a recording block, so the
  # allowlist under test still decides the outcome -- replacing `guarded`
  # outright would have tested the recorder instead.
  def recording_handler
    caught = []
    handler.singleton_class.prepend(recorder_for(caught))
    [handler, caught]
  end

  def recorder_for(caught)
    Module.new do
      define_method(:guarded) do |&block|
        super() do
          block.call
        rescue StandardError, SystemStackError => e
          caught << e.class
          raise
        end
      end
    end
  end

  # stub_const restores a constant with const_set, which makes it public
  # again -- the same hazard registry_spec's own hook exists for.
  around do |example|
    example.run
  ensure
    pdf_class.send(:private_constant, :DEADLINE_SECONDS)
  end

  def with_deadline(seconds)
    stub_const("#{pdf_class}::DEADLINE_SECONDS", seconds)
  end

  describe "the version, and the gate that reads it" do
    it "reports the baseline exactly, with no dimensions" do
      inspection = inspect_pdf(pdf)

      expect(inspection.format).to eq("pdf")
      expect(inspection.parse_status).to eq("ok")
      expect(inspection.meta).to eq("version" => "1.4", "pages" => 1)
      expect([inspection.width, inspection.height, inspection.dpi,
              inspection.color_space]).to all(be_nil)
      expect(inspection.issues).to be_empty
    end

    # 1.4 is what the delegate FABRICATES for an unreadable header, so the
    # baseline alone cannot tell a reading from the default.
    it "reads the declared version rather than the delegate's default" do
      expect(inspect_pdf(pdf(first_line: "%PDF-1.7")).meta["version"]).to eq("1.7")
    end

    it "refuses an empty file, though the delegate opens it and offers 1.4" do
      path = raw_pdf("")
      expect(Pdfrb::Document.open(path, &:version)).to eq("1.4")

      inspection = inspect_pdf(path)
      expect(inspection.parse_status).to eq("failed")
      expect(inspection.meta).to be_nil
    end

    it "refuses garbage, though the delegate opens it too" do
      path = raw_pdf("this is not a pdf at all\n")
      expect(Pdfrb::Document.open(path, &:version)).to eq("1.4")
      expect(inspect_pdf(path).parse_status).to eq("failed")
    end

    it "refuses a version with no minor digit" do
      expect(inspect_pdf(pdf(first_line: "%PDF-1.")).parse_status).to eq("failed")
    end

    # No document behind them to build, so they stay inline byte strings
    # exactly as detector_spec.rb writes its own PDF cases.
    it "anchors the declaration at offset zero" do
      ["x%PDF-1.4", "%PDF", " %PDF-1.4"].each do |bytes|
        expect(inspect_pdf(raw_pdf(bytes)).parse_status).to eq("failed"), bytes
      end
    end

    # The two prefix traps, and the precondition is the point: a regex
    # without the lookahead captures "1.7" for BOTH of them.
    it "refuses a numeric prefix that is not the whole declaration" do
      { "%PDF-1.7junk" => "junk_version", "%PDF-1.7.2" => "dotted_version" }.each_key do |line|
        expect(line[/\A%PDF-(\d+\.\d+)/, 1]).to eq("1.7")
        expect(inspect_pdf(pdf(first_line: line)).parse_status).to eq("failed")
      end
    end

    # Without this the group proves nothing: a body that was also missing
    # a Catalog would report "failed" whatever the gate did, and the
    # refusals above would be right for the wrong reason.
    it "refuses those bodies ONLY because of their header" do
      ["%PDF-x.y", "%PDF-1.7junk", "%PDF-1.7.2", PdfBuilder.padded_version_line(4096)]
        .each do |line|
          expect(inspect_pdf(pdf(first_line: line)).parse_status).to eq("failed"), line[0, 20]
        end

      inspection = inspect_pdf(pdf)
      expect(inspection.parse_status).to eq("ok")
      expect(inspection.meta["pages"]).to eq(1)
    end

    # The detector's PDF signature is a bare `%PDF-`, so a file this gate
    # must refuse is routed here in the first place. That gap is what the
    # gate closes, and this asserts the gap is real.
    it "is reached through the detector's bare %PDF- signature" do
      path = pdf(first_line: "%PDF-x.y")
      expect(Claricle.detect(File.binread(path))).to eq(:pdf)
      expect(Claricle::Image.from_path(path).inspection.parse_status).to eq("failed")
    end

    it "keeps both version components unbounded" do
      expect(inspect_pdf(pdf(first_line: "%PDF-12.345")).meta["version"]).to eq("12.345")
    end

    it "accepts CR and CRLF header terminators" do
      expect(inspect_pdf(pdf(eol: "\r")).meta["version"]).to eq("1.4")
      expect(inspect_pdf(pdf(eol: "\r\n")).meta["version"]).to eq("1.4")
    end

    # The capture is matched against a BINARY view. An ASCII-only
    # document would pass this against a handler that never re-tagged at
    # all, so the fixture carries 0xFF 0xFE 0x80 right behind the header.
    it "re-tags the captured version as valid UTF-8, over high bytes" do
      path = pdf(first_line: "%PDF-1.7", eol: "\n%\xFF\xFE\x80\n".b)
      expect(File.binread(path)).to include("\xFF\xFE\x80".b)

      version = inspect_pdf(path).meta["version"]
      expect(version).to eq("1.7")
      expect(version.encoding).to eq(Encoding::UTF_8)
      expect(version).to be_valid_encoding
    end

    it "discards a captured version when a later stage fails" do
      path = pdf(startxref: 999_999)
      expect(File.binread(path)).to start_with("%PDF-1.4")

      inspection = inspect_pdf(path)
      expect(inspection.parse_status).to eq("failed")
      expect(inspection.meta).to be_nil
    end
  end

  describe "how far the header read goes" do
    # 1024 is read, 1025 is refused, and each is driven twice -- once
    # ending at EOF and once with further input -- because `\z` and a line
    # terminator are different exits from the same regex.
    it "reads a first line of exactly HEADER_SCAN_BYTES" do
      { "" => "eof", "% more\n" => "more" }.each do |suffix, label|
        line = PdfBuilder.padded_version_line(1024)
        expect(line.bytesize).to eq(1024)

        inspection = inspect_pdf(pdf(first_line: line, suffix: suffix))
        expect(inspection.parse_status).to eq("ok"), label
        expect(inspection.meta["version"].bytesize).to eq(1019)
        expect(inspection.meta["pages"]).to eq(1)
      end
    end

    it "refuses a first line one byte longer" do
      { "" => "eof", "% more\n" => "more" }.each do |suffix, label|
        line = PdfBuilder.padded_version_line(1025)
        expect(line.bytesize).to eq(1025)
        expect(inspect_pdf(pdf(first_line: line, suffix: suffix)).parse_status)
          .to eq("failed"), label
      end
    end

    it "refuses a first line far past the bound" do
      expect(inspect_pdf(pdf(first_line: PdfBuilder.padded_version_line(4096))).parse_status)
        .to eq("failed")
    end

    # A short read would let `\z` pass on a line the gate only saw part
    # of, which is not a refusal but a plausible WRONG version.
    it "takes at most HEADER_SCAN_BYTES + 1 bytes from the yielded path" do
      path = pdf(suffix: "%#{"p" * 20_000}\n")
      lengths = []
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(path, "rb").and_wrap_original do |original, *args, &block|
        original.call(*args) do |file|
          spy = Object.new
          spy.define_singleton_method(:read) do |count|
            lengths << count
            file.read(count)
          end
          block.call(spy)
        end
      end

      inspect_pdf(path)
      expect(lengths).to eq([1025])
    end

    it "never reaches for the image's bytes on a path-born image" do
      image = Claricle::Image.new(format: :pdf, path: pdf)
      allow(image).to receive(:content).and_raise("the handler read image.content")

      expect(handler.inspection(image).meta["pages"]).to eq(1)
    end

    # The non-block branch of Document.open is a `File.binread` into a
    # StringIO held for the document's life. Measured on 1 MB: its
    # `doc.io.string` is exactly the file.
    it "takes the block form, so no whole-file buffer is retained" do
      seen = nil
      allow(Pdfrb::Document).to receive(:open).and_wrap_original do |original, *args, &block|
        original.call(*args) { |doc| seen = doc.io and block.call(doc) }
      end

      inspect_pdf(pdf)
      expect(seen).to be_a(File)
      expect(seen).not_to respond_to(:string)
    end
  end

  describe "reading a key raw, and the mutation that makes it necessary" do
    # All three rows, not just the spoiling one: pinning only the last
    # would let a later draft re-forbid the safe reads and make this
    # design impossible again. Each row opens its OWN document, because
    # the typed subscript mutates permanently.
    it "keeps /Count raw unless the SAME key was read typed first" do
      readers = { nothing: nil, raw_other: ->(n) { n.value[:Type] },
                  typed_other: ->(n) { n[:Type] }, typed_same: ->(n) { n[:Count] } }
      results = readers.transform_values do |first|
        Pdfrb::Document.open(pdf(objects: objects(pages: pages_node(" /Count 5.0")))) do |doc|
          node = bare_pages(doc)
          first&.call(node)
          node.value[:Count]
        end
      end

      expect(results).to eq(nothing: 5.0, raw_other: 5.0, typed_other: 5.0, typed_same: 5)
    end

    # Worse than losing a Float: the typed read on /Pages destroys the
    # REFERENCE, and the generation guard then has nothing left to check.
    it "keeps /Pages a Reference unless the SAME key was read typed first" do
      readers = { nothing: nil, typed_other: ->(c, _d) { c[:Type] },
                  typed_same: ->(c, _d) { c[:Pages] },
                  page_count: ->(_c, d) { d.catalog.page_count } }
      results = readers.transform_values do |first|
        Pdfrb::Document.open(pdf) do |doc|
          catalog = doc.object(doc.trailer[:Root])
          first&.call(catalog, doc)
          catalog.value[:Pages].class
        end
      end

      expect(results).to eq(nothing: Pdfrb::Model::Reference,
                            typed_other: Pdfrb::Model::Reference,
                            typed_same: Pdfrb::Model::Type::PageTreeNode,
                            page_count: Pdfrb::Model::Type::PageTreeNode)
    end

    # So a refactor reaching for `document.catalog` turns this red rather
    # than silently retiring the generation guard.
    it "leaves /Pages a Reference after a whole inspection" do
      seen = nil
      allow(Pdfrb::Document).to receive(:open).and_wrap_original do |original, *args, &block|
        original.call(*args) do |doc|
          block.call(doc)
          seen = doc.object(doc.trailer[:Root]).value[:Pages].class
        end
      end

      expect(inspect_pdf(pdf).parse_status).to eq("ok")
      expect(seen).to be(Pdfrb::Model::Reference)
    end

    it "reports no count for a Float, however the file spells it" do
      inspection = inspect_pdf(pdf(objects: objects(pages: pages_node(" /Count 5.0"))))
      expect(inspection.parse_status).to eq("ok")
      expect(inspection.meta).to eq("version" => "1.4")
    end
  end

  def bare_pages(doc)
    doc.object(doc.object(doc.trailer[:Root]).value[:Pages])
  end
end
