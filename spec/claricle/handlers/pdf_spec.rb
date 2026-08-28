# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"

require_relative "../../support/pdf_builder"
require_relative "../../support/pdf_objstm_builder"

RSpec.describe "Claricle PDF handler" do
  # Nesting depth is a PLATFORM property, not a constant of PDF. 60,000
  # exhausts the stack on Ruby 3.4 with the default thread stack size,
  # and a larger RUBY_THREAD_VM_STACK_SIZE, another platform or a future
  # Ruby could raise the threshold. Both deep fixtures build their depth
  # from here, and both assert the raise as a PRECONDITION -- so a
  # machine where this no longer suffices fails saying "this fixture
  # stopped raising" rather than passing while testing nothing.
  def nesting = 60_000

  # A method rather than a block-local, so the nested groups' own helper
  # methods can reach it too.
  def pdf_class = Claricle.const_get(:Handlers).const_get(:Pdf)

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
        expect(inspection.parse_status).to eq("ok"), label.to_s
        expect(inspection.meta["version"].bytesize).to eq(1019)
        expect(inspection.meta["pages"]).to eq(1)
      end
    end

    it "refuses a first line one byte longer" do
      { "" => "eof", "% more\n" => "more" }.each do |suffix, label|
        line = PdfBuilder.padded_version_line(1025)
        expect(line.bytesize).to eq(1025)
        expect(inspect_pdf(pdf(first_line: line, suffix: suffix)).parse_status)
          .to eq("failed"), label.to_s
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

  describe "the structure gate" do
    it "refuses a header-only file the delegate opens happily" do
      path = raw_pdf("%PDF-1.4\n")
      expect(Pdfrb::Document.open(path, &:trailer)).to be_nil

      inspection = inspect_pdf(path)
      expect(inspection.parse_status).to eq("failed")
      expect(inspection.meta).to be_nil
    end

    # It passes the version gate AND opens; only the trailer check stops
    # it. The nil trailer is a gate check rather than a rescued
    # NoMethodError, so a pdfrb release that fixes its own error handling
    # cannot retire the refusal.
    it "refuses a file truncated mid-body, on the trailer and not a rescue" do
      path = raw_pdf(PdfBuilder.document[0, 60])
      expect(Pdfrb::Document.open(path, &:trailer)).to be_nil

      caught = recording_handler.last
      expect(inspect_pdf(path).parse_status).to eq("failed")
      expect(caught).to be_empty
    end

    it "refuses a real trailer that carries no /Root" do
      path = pdf(trailer: "<< /Size 4 >>")
      trailer = Pdfrb::Document.open(path, &:trailer)
      expect(trailer).to be_instance_of(Hash)
      expect(trailer).not_to have_key(:Root)

      expect(inspect_pdf(path).parse_status).to eq("failed")
    end

    # All three refused DETERMINISTICALLY. Without the Reference guard a
    # nil or an Integer reaches `.value` and the NoMethodError after it
    # made the outcome right by accident.
    it "refuses an absent, dangling or scalar /Pages with nothing rescued" do
      { absent: "<< /Type /Catalog >>",
        dangling: "<< /Type /Catalog /Pages 9 0 R >>",
        scalar: "<< /Type /Catalog /Pages 7 >>" }.each do |label, catalog|
        caught = recording_handler.last
        expect(inspect_pdf(pdf(objects: objects(cat: catalog))).parse_status)
          .to eq("failed"), label.to_s
        expect(caught).to be_empty, label.to_s
      end
    end

    it "refuses the right shape carrying the wrong /Type, with nothing rescued" do
      { root: objects(cat: "<< /Type /NotCatalog /Pages 2 0 R >>"),
        pages: objects(pages: "<< /Type /NotPages /Kids [3 0 R] /Count 1 >>") }
        .each do |label, parts|
          caught = recording_handler.last
          expect(inspect_pdf(pdf(objects: parts)).parse_status).to eq("failed"), label.to_s
          expect(caught).to be_empty, label.to_s
        end
    end

    it "refuses an unterminated dictionary and an unterminated string" do
      { "<< /Type /Catalog /Pages 2 0 R" => Pdfrb::SyntaxError,
        "<< /Type /Catalog /T (abc >>" => Pdfrb::LexError }.each do |catalog, klass|
        path = pdf(objects: objects(cat: catalog))
        expect(raised_by(path)).to be(klass)

        caught = recording_handler.last
        expect(inspect_pdf(path).parse_status).to eq("failed")
        expect(caught).to include(klass)
      end
    end
  end

  describe "the generation guard" do
    # Equality, in all four shapes. A handler testing `reference.gen == 0`
    # passes two of the refusals and still rejects a valid generation-9
    # document, so both accepting rows are named too.
    it "accepts a reference whose generation matches its xref entry" do
      expect(inspect_pdf(pdf).meta["pages"]).to eq(1)

      nine = pdf(objects: objects(gens: [9, 0, 0]), trailer: "<< /Size 4 /Root 1 9 R >>")
      expect(File.binread(nine)).to include("1 9 obj")
      expect(inspect_pdf(nine).meta["pages"]).to eq(1)
    end

    # Each carries the precondition that bare pdfrb resolves it ANYWAY:
    # pdfrb matches on object number alone, so this guard is the whole of
    # the guarantee and nothing else would catch its loss.
    it "refuses every mismatch, though bare pdfrb resolves all of them" do
      { entry_zero_reference_nine: pdf(trailer: "<< /Size 4 /Root 1 9 R >>"),
        pages_zero_reference_nine: pdf(objects: objects(cat: "<< /Type /Catalog /Pages 2 9 R >>")),
        entry_nine_reference_zero: pdf(objects: objects(gens: [9, 0, 0])) }.each do |label, path|
        expect(raised_by(path)).to be_nil, label.to_s
        expect(bare_walk(path).value[:Type]).to eq(:Pages), label.to_s

        caught = recording_handler.last
        expect(inspect_pdf(path).parse_status).to eq("failed"), label.to_s
        expect(caught).to be_empty, label.to_s
      end
    end
  end

  describe "compressed objects" do
    it "inspects a document whose catalog and page tree are compressed" do
      path = objstm
      Pdfrb::Document.open(path) do |doc|
        expect(doc.xref[1].type).to be(:compressed)
        expect(doc.xref[1].gen).to be_nil
        expect(doc.object(doc.trailer[:Root]).value[:Pages])
          .to be_a(Pdfrb::Model::Reference)
      end

      expect(inspect_pdf(path).meta).to eq("version" => "1.5", "pages" => 1)
    end

    # pdfrb performs NO generation check on the compressed path --
    # `add_compressed` never records one -- so this guard is the entire
    # guarantee, and its precondition says so.
    it "refuses a compressed reference asking for a non-zero generation" do
      path = objstm(root: "1 1 R")
      expect(bare_walk(path).value[:Type]).to eq(:Pages)

      caught = recording_handler.last
      expect(inspect_pdf(path).parse_status).to eq("failed")
      expect(caught).to be_empty
    end

    # One eager `map` over every declared pair, memoised on the first
    # compressed object anyone resolves. In this handler that is the
    # CATALOG, so a poisoned value anywhere in the stream body fails the
    # structure gate whatever index it sits at.
    it "fails the structure gate on a poisoned stream body, before any count read" do
      { NoMethodError => "(abc\\", SystemStackError => nested_array }
        .each do |klass, body|
          path = objstm(bodies: [PdfBuilder::CATALOG, PdfBuilder::PAGES, body])
          expect(raised_by(path)).to be(klass)

          caught = recording_handler.last
          allow(handler).to receive(:count_read).and_call_original
          expect(inspect_pdf(path).parse_status).to eq("failed")
          expect(caught).to include(klass)
          expect(handler).not_to have_received(:count_read)
        end
    end

    it "reports failed for every other malformed object stream, naming its class" do
      { Pdfrb::MalformedPdfError => { omit_stream: true },
        NoMethodError => { entries: { 4 => [0, 0, 65_535] } },
        TypeError => { stream_dict: objstm_dict("/N 3 /First /Bad") },
        Pdfrb::ParseError => { stream_dict: objstm_dict("/First 12") },
        ArgumentError => { stream_dict: objstm_dict(
          "/N 3 /First 12 /DecodeParms << /Predictor 12 /Columns -1 >>"
        ) } }.each do |klass, parts|
        path = objstm(**parts)
        expect(raised_by(path)).to be(klass)

        caught = recording_handler.last
        expect(inspect_pdf(path).parse_status).to eq("failed")
        expect(caught).to include(klass)
      end
    end
  end

  def objstm_dict(fields)
    "<< /Type /ObjStm #{fields} /Length LENGTH /Filter /FlateDecode >>"
  end

  describe "the count read" do
    # The whole set, each asserting the value or class the DELEGATE
    # produced, so the example says why the count was dropped rather than
    # only that it was.
    it "reports ok with no count for every unreadable /Count" do
      { missing: [pages_node(""), nil],
        nonnumeric: [pages_node(" /Count /Bad"), :Bad],
        negative: [pages_node(" /Count -3"), -3],
        float: [pages_node(" /Count 5.0"), 5.0] }.each do |label, (node, raw)|
        path = pdf(objects: objects(pages: node))
        expect(Pdfrb::Document.open(path) { |doc| bare_pages(doc).value[:Count] }).to eq(raw),
                                                                                      label.to_s

        expect(inspect_pdf(path).meta).to eq("version" => "1.4"), label.to_s
      end
    end

    it "reports ok with no count for an indirect /Count that is not a whole number" do
      { float: ["5.0", 5.0], name: ["/Bad", :Bad] }.each do |label, (body, resolved)|
        path = indirect_count_pdf(body)
        expect(Pdfrb::Document.open(path) { |doc| bare_pages(doc).value[:Count] })
          .to be_a(Pdfrb::Model::Reference)
        expect(bare_count(path)).to eq(resolved), label.to_s

        expect(inspect_pdf(path).meta).to eq("version" => "1.4"), label.to_s
      end
    end

    it "reports ok with no count when resolving /Count raises" do
      { "<< /V 1" => Pdfrb::SyntaxError, "(abc" => Pdfrb::LexError }.each do |body, klass|
        path = indirect_count_pdf(body)
        caught = recording_handler.last

        inspection = inspect_pdf(path)
        expect(inspection.parse_status).to eq("ok")
        expect(inspection.meta).to eq("version" => "1.4")
        expect(caught).to eq([klass])
      end
    end

    # Bare pdfrb resolves it anyway, by object number alone.
    it "refuses an indirect /Count whose generation does not match" do
      path = pdf(objects: objects(pages: pages_node(" /Count 4 9 R"), extra: [[4, 0, "1"]]),
                 trailer: "<< /Size 5 /Root 1 0 R >>")
      expect(bare_count(path)).to eq(1)

      caught = recording_handler.last
      expect(inspect_pdf(path).meta).to eq("version" => "1.4")
      expect(caught).to be_empty
    end

    # Outcome cannot discriminate this guard: pdfrb's own `object` also
    # answers nil for a free entry, so a handler with no entry-type check
    # reports exactly the same thing. The MECHANISM can. The guard exists
    # so a reference the xref does not authorise is never handed to the
    # delegate at all, and that is what this asserts.
    it "never asks the delegate to resolve a /Count whose entry is free" do
      path = pdf(objects: objects(pages: pages_node(" /Count 4 0 R"), extra: [[4, 0, "1"]]),
                 entries: { 4 => { type: "f" } }, trailer: "<< /Size 5 /Root 1 0 R >>")
      Pdfrb::Document.open(path) do |doc|
        expect(doc.xref[4].type).to be(:free)
        expect(doc.object(Pdfrb::Model::Reference.new(4, 0))).to be_nil
      end

      asked = asked_of_delegate
      expect(inspect_pdf(path).meta).to eq("version" => "1.4")
      expect(asked.map(&:oid)).to eq([1, 2])
    end

    # An out-of-range index RETURNS nil rather than raising, so a guard
    # expecting a raise accepts it silently. A huge one raises instead.
    it "handles both shapes of a bad object-stream index" do
      { out_of_range: [[1, 4, 2], 9, nil],
        huge: [[1, 4, 8], (2**64) - 1, RangeError] }.each do |label, (widths, index, klass)|
        path = objstm(bodies: [PdfBuilder::CATALOG, pages_node(" /Count 6 0 R"),
                               PdfBuilder::PAGE],
                      widths: widths, entries: { 6 => [2, 4, index] })
        expect(bare_count_raise(path)).to be(klass), label.to_s

        caught = recording_handler.last
        expect(inspect_pdf(path).meta).to eq("version" => "1.5"), label.to_s
        expect(caught).to eq([klass].compact), label.to_s
      end
    end

    # `pages.count` walks /Kids and recurses forever here -- but ONLY
    # when /Count is missing, which is why this fixture omits it. The
    # handler never messages `pages` at all, and that is the assertion:
    # the outcome alone would be identical if it did and were rescued.
    it "never messages Document#pages, even on a self-cycling /Kids tree" do
      path = pdf(objects: objects(pages: "<< /Type /Pages /Kids [2 0 R] >>"))
      expect(File.binread(path)).not_to include("/Count")
      expect { Pdfrb::Document.open(path) { |doc| doc.pages.count } }
        .to raise_error(SystemStackError)

      expect_any_instance_of(Pdfrb::Document).not_to receive(:pages)
      expect(inspect_pdf(path).meta).to eq("version" => "1.4")
    end
  end

  describe "counts that ARE read" do
    it "reports the DECLARED figure, whatever the page tree really holds" do
      path = pdf(objects: objects(pages: pages_node(" /Count 999")))
      expect(File.binread(path).scan("/Type /Page ").size).to eq(1)

      expect(inspect_pdf(path).meta["pages"]).to eq(999)
    end

    it "reports a count reached through a checked reference" do
      expect(inspect_pdf(indirect_count_pdf("1")).meta["pages"]).to eq(1)
    end

    # Zero is truthy in Ruby, so this is the row that stops a `if raw`
    # guard dropping a legitimate declaration.
    it "reports a declared zero rather than omitting the key" do
      path = pdf(objects: objects(pages: "<< /Type /Pages /Kids [] /Count 0 >>"))
      expect(inspect_pdf(path).meta).to eq("version" => "1.4", "pages" => 0)
    end
  end

  describe "failures at open" do
    it "reports failed for each way the delegate refuses to open a file" do
      open_failures.each do |label, (path, klass)|
        expect(open_raised_by(path)).to be(klass), label.to_s
        expect(inspect_pdf(path).parse_status).to eq("failed"), label.to_s
      end
    end

    # Three preconditions, because this fixture raises only while BOTH
    # bracketing conditions hold: the keyword must begin within the final
    # 1,024 bytes, and the file must be at most 999999 - 2048 bytes. The
    # third stops a regeneration quietly ballooning it toward that edge.
    it "keeps far_startxref inside both conditions that make it raise" do
      path = pdf(startxref: 999_999)
      bytes = File.binread(path)

      expect(bytes.bytesize - bytes.rindex("startxref")).to be <= 1024
      expect(bytes.bytesize).to be <= 997_951
      expect(bytes.bytesize).to be < 1024
    end

    # Depth is a platform property, not a constant: 60,000 exhausts the
    # stack on this Ruby with the default thread stack size, and a larger
    # RUBY_THREAD_VM_STACK_SIZE could raise the threshold. The
    # precondition is what makes that fail loudly rather than silently
    # passing while testing nothing.
    it "reports failed on a trailer nested past the stack" do
      path = deep_trailer_pdf
      expect(open_raised_by(path)).to be(SystemStackError)
      expect(inspect_pdf(path).parse_status).to eq("failed")
    end
  end

  describe "the deadline" do
    it "is five seconds in production" do
      expect(pdf_class.const_get(:DEADLINE_SECONDS)).to eq(5)
    end

    it "opens exactly one Timeout block, never one per stage" do
      allow(Timeout).to receive(:timeout).and_call_original
      inspect_pdf(pdf)

      expect(Timeout).to have_received(:timeout).once
    end

    # A `/Prev` pointing at its own xref offset never returns at all, so
    # this is the one fixture whose failure is a deadline rather than a
    # class -- and it is driven short, because at the production value it
    # would cost five real seconds twice over.
    it "returns failed on a document the delegate never finishes opening" do
      path = prev_cycle_pdf
      expect { Timeout.timeout(0.4) { Pdfrb::Document.open(path, &:trailer) } }
        .to raise_error(Timeout::Error)

      with_deadline(0.4)
      inspection = inspect_pdf(path)
      expect(inspection.parse_status).to eq("failed")
      expect(inspection.issues.first.code).to eq("pdf.timeout")
    end

    # Each stage blocks on its own rather than racing real work against a
    # short clock, which on a loaded machine reports "failed" and flakes.
    it "reports failed when it expires before the structure gate passes" do
      with_deadline(0.2)
      allow(handler).to receive(:structure_gate) { sleep 5 }

      expect(inspect_pdf(pdf).issues.first.code).to eq("pdf.timeout")
    end

    it "reports failed when it expires during the tempfile write or header read" do
      with_deadline(0.2)
      path = pdf
      allow_any_instance_of(Claricle::Image).to receive(:with_path) { sleep 5 }
      expect(inspect_pdf(path).issues.first.code).to eq("pdf.timeout")
    end

    # The node local is the flag: non-nil means the deadline expired
    # reading an OPTIONAL field, so the answer stays "ok" with the count
    # omitted rather than discarding a structure that was read.
    it "reports ok with no count when it expires at the count read" do
      with_deadline(0.2)
      allow(handler).to receive(:count_read) { sleep 5 }

      inspection = inspect_pdf(pdf)
      expect(inspection.parse_status).to eq("ok")
      expect(inspection.meta).to eq("version" => "1.4")
    end
  end

  describe "what it refuses to swallow" do
    # Stage B, not stage A. A handler that wrote `rescue StandardError`
    # inside `guarded` would still pass an Interrupt-from-open example,
    # because Interrupt is not a StandardError. This is the example that
    # pins the allowlist as not too BROAD.
    it "propagates an off-allowlist StandardError raised inside the gate" do
      klass = Class.new(StandardError)
      stub_const("OffAllowlistError", klass)
      allow(handler).to receive(:structure_gate).and_raise(klass, "not ours")

      expect { inspect_pdf(pdf) }.to raise_error(klass, "not ours")
    end

    it "propagates an Interrupt from the delegate's open" do
      allow(Pdfrb::Document).to receive(:open).and_raise(Interrupt)

      expect { inspect_pdf(pdf) }.to raise_error(Interrupt)
    end

    # A file that is simply gone is not an unreadable PDF, so reporting
    # "failed" would claim something untrue.
    it "propagates ENOENT for a file deleted after the header read" do
      path = pdf
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(path, "rb").and_wrap_original do |original, *args, &blk|
        original.call(*args, &blk).tap { FileUtils.rm_f(path) }
      end

      expect { inspect_pdf(path) }.to raise_error(Errno::ENOENT)
    end
  end

  describe "the inspection it hands back" do
    # One code per cause, each driven by a fixture from its own cause. A
    # single shared code would let three of these pass while describing
    # the wrong thing.
    it "pins each issue code and message to its own cause" do
      causes = {
        "pdf.header_unreadable" =>
          ["PDF header is not a valid version declaration", pdf(first_line: "%PDF-x.y")],
        "pdf.unreadable" =>
          ["PDF could not be opened", pdf(trailer: trailer_with("/Prev 3 0 R"))],
        "pdf.structure_unreadable" =>
          ["PDF structure could not be read", pdf(objects: objects(cat: "<< /Type /Catalog >>"))]
      }
      causes.each do |code, (message, path)|
        issue = inspect_pdf(path).issues.first
        expect([issue.code, issue.message, issue.severity]).to eq([code, message, "error"])
      end
    end

    it "interpolates the deadline that actually expired into its message" do
      with_deadline(0.25)
      allow(handler).to receive(:structure_gate) { sleep 5 }

      expect(inspect_pdf(pdf).issues.first.message)
        .to eq("PDF could not be read within 0.25 seconds")
    end

    it "round-trips through to_json on both branches" do
      ok = JSON.parse(inspect_pdf(pdf).to_json)
      expect(ok).to eq("format" => "pdf", "parse_status" => "ok",
                       "meta" => { "version" => "1.4", "pages" => 1 }, "issues" => [])

      failed = JSON.parse(inspect_pdf(raw_pdf("")).to_json)
      expect(failed).to eq(
        "format" => "pdf", "parse_status" => "failed",
        "issues" => [{ "severity" => "error", "code" => "pdf.header_unreadable",
                       "message" => "PDF header is not a valid version declaration" }]
      )
    end

    it "inspects a content-born PDF identically to a path-born one" do
      path = pdf
      born = Claricle::Image.from_content(File.binread(path), format: :pdf)

      expect(handler.inspection(born).to_json).to eq(inspect_pdf(path).to_json)
    end
  end

  def trailer_with(extra) = "<< /Size 4 /Root 1 0 R #{extra} >>"

  def nested_array = "#{"[" * nesting}#{"]" * nesting}"

  def deep_trailer_pdf
    pdf(trailer: trailer_with("/D #{nested_array}"))
  end

  # The offset is read from a document built with the default trailer.
  # Adding `/Prev` cannot move it, because the trailer sits after the
  # xref table it points at.
  def prev_cycle_pdf
    pdf(trailer: trailer_with("/Prev #{PdfBuilder.document[/startxref\n(\d+)/, 1]}"))
  end

  def open_failures
    { far_startxref: [pdf(startxref: 999_999), NoMethodError],
      huge_startxref: [pdf(startxref: 2**70), RangeError],
      prev_indirect: [pdf(trailer: trailer_with("/Prev 3 0 R")), TypeError],
      prev_negative: [pdf(trailer: trailer_with("/Prev -1")), Errno::EINVAL],
      bad_predictor_xref: [objstm(
        xref_extra: " /DecodeParms << /Predictor 12 /Columns -1 >>"
      ), ArgumentError],
      filter_error_xref: [objstm(xref_data: "not flate data at all"), Pdfrb::FilterError] }
  end

  def open_raised_by(path)
    Pdfrb::Document.open(path, &:trailer)
    nil
  rescue StandardError, SystemStackError => e
    e.class
  end

  def bare_count(path)
    Pdfrb::Document.open(path) { |doc| doc.object(bare_pages(doc).value[:Count])&.value }
  end

  def bare_count_raise(path)
    bare_count(path)
    nil
  rescue StandardError, SystemStackError => e
    e.class
  end

  # Every reference the handler actually handed to the delegate during
  # one inspection, recorded on the document instance rather than the
  # class, so nothing survives the example.
  def asked_of_delegate
    asked = []
    allow(Pdfrb::Document).to receive(:open).and_wrap_original do |original, *args, &block|
      original.call(*args) { |doc| block.call(recording_objects(doc, asked)) }
    end
    asked
  end

  def recording_objects(document, asked)
    allow(document).to receive(:object).and_wrap_original do |inner, value|
      asked << value
      inner.call(value)
    end
    document
  end

  def bare_pages(doc)
    doc.object(doc.object(doc.trailer[:Root]).value[:Pages])
  end
end
