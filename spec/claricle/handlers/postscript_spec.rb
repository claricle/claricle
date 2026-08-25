# frozen_string_literal: true

require "json"
require "postscript"

RSpec.describe "Claricle PostScript handler" do
  let(:handler) { Claricle.const_get(:Handlers).const_get(:Postscript).new }

  def fixture(name)
    File.join(__dir__, "..", "..", "fixtures", "inspect", name)
  end

  # Explicit format throughout. Several fixtures deliberately cannot be
  # DETECTED -- an empty file and plain prose have no signature -- and
  # detection would raise before the handler ever ran.
  def inspect_ps(name, format: :eps)
    handler.inspection(
      Claricle::Image.from_content(File.binread(fixture(name)), format: format)
    )
  end

  describe "dimensions" do
    it "reads the bounding box" do
      expect(inspect_ps("basic.eps"))
        .to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
    end

    # Subtraction, not urx/ury. A zero-origin fixture cannot tell the two
    # apart, since there both readings agree.
    it "subtracts a non-zero origin" do
      expect(inspect_ps("offset.eps"))
        .to have_attributes(width: 100.0, height: 50.0)
    end

    it "prefers the hires box when both are declared" do
      expect(inspect_ps("hires.eps"))
        .to have_attributes(width: 100.5, height: 50.25)
    end

    # The hires path must subtract too, rather than inheriting that only
    # from the integer path.
    it "subtracts a non-zero origin on the hires box" do
      expect(inspect_ps("hires_offset.eps"))
        .to have_attributes(width: 100.0, height: 50.0)
    end

    it "reads a file declaring only the hires box" do
      expect(inspect_ps("hires_only.eps"))
        .to have_attributes(width: 100.5, height: 50.25)
    end

    # A program need not declare a box. That is not a parse failure.
    it "leaves dimensions nil when no box is declared" do
      expect(inspect_ps("no_box.ps", format: :ps))
        .to have_attributes(width: nil, height: nil, parse_status: "ok")
    end

    it "is ok with nil dimensions for a bare header" do
      expect(inspect_ps("bare.ps", format: :ps))
        .to have_attributes(width: nil, height: nil, parse_status: "ok")
    end
  end

  describe "the signature gate" do
    # Postscript.parse succeeds on plain prose, so "the delegate did not
    # raise" means nothing here (D17). This example passes every other
    # test in this file for a handler wired to the parse alone.
    it "fails prose that the delegate parses cleanly" do
      expect(Postscript.parse(File.binread(fixture("garbage.ps")))).to be_truthy

      expect(inspect_ps("garbage.ps", format: :ps).parse_status).to eq("failed")
    end

    it "fails an empty file" do
      expect(inspect_ps("empty.ps", format: :ps).parse_status).to eq("failed")
    end

    # The whole four bytes, anchored at byte zero. `prefixed.ps`,
    # `leading_space.ps` and `leading_newline.ps` put a real `%!PS`
    # somewhere other than offset zero, and the last two are what makes
    # the anchor load-bearing: without them `lstrip.start_with?` passes.
    # `pdf_header.ps` is the other axis -- `%!PDF` shares three bytes
    # with the signature, so a shorter prefix compare reads it as
    # PostScript.
    %w[prefixed.ps pdf_header.ps leading_space.ps leading_newline.ps].each do |name|
      it "fails #{name}, which does not open with the signature" do
        expect(inspect_ps(name, format: :ps).parse_status).to eq("failed")
      end
    end

    # The gate cuts both ways. An unmatched brace parses, and D22 already
    # records that a clean parse says nothing about conformance -- so
    # rejecting it here would make inspect quietly mean conform.
    it "reports ok for structurally odd input the delegate accepts" do
      expect(inspect_ps("unmatched_brace.ps", format: :ps).parse_status).to eq("ok")
    end
  end

  describe "parse failures" do
    # These raise on the WHOLE file and are still "ok", because both
    # faults are in the body and the handler only parses the header.
    # parse_status means the metadata parsed, not that the PostScript
    # program is valid -- the same line D22 draws for conformance.
    {
      "lex_error.ps" => Postscript::LexError,
      "syntax_error.ps" => Postscript::SyntaxError
    }.each do |name, error|
      it "reports ok for #{name}, whose #{error} is in the body" do
        expect { Postscript.parse(File.binread(fixture(name))) }
          .to raise_error(error)
        expect(error).to be < Postscript::ParseError

        expect(inspect_ps(name, format: :ps))
          .to have_attributes(parse_status: "ok", width: 100.0, height: 50.0)
      end
    end

    # The allowlist stays around the header parse even though the body
    # can no longer reach it. It is not exercised by parsing the body on
    # purpose, and it is not broadened.
    # No real header reaches the allowlist under 0.2.0 -- the scoped
    # input is all comment tokens. The gemspec permits any 0.2.x, so the
    # guard is pinned by stubbing rather than left as an ancestry
    # assertion that exercises nothing.
    [Postscript::LexError, Postscript::SyntaxError].each do |error|
      it "reports failed when the header parse raises #{error}" do
        allow(Postscript).to receive(:parse).and_raise(error, "from the header")

        expect(inspect_ps("basic.eps").parse_status).to eq("failed")
      end
    end

    it "propagates an off-allowlist error" do
      allow(Postscript).to receive(:parse).and_raise(NoMethodError, "delegate defect")

      expect { inspect_ps("basic.eps") }.to raise_error(NoMethodError)
    end
  end

  describe "one handler, two formats" do
    it "reports the image's own format for eps" do
      expect(inspect_ps("basic.eps").format).to eq("eps")
    end

    # A genuine non-EPSF program, not the EPS bytes relabelled: reusing
    # them would not catch extraction wrongly gated on the EPSF field.
    it "reports the image's own format for ps" do
      expect(inspect_ps("plain.ps", format: :ps))
        .to have_attributes(format: "ps", width: 200.0, height: 120.0)
    end

    # Everything but the label, or the example passes for a handler that
    # relabels a failed inspection.
    it "reads the same bytes under either format" do
      as_eps = inspect_ps("basic.eps")
      as_ps = inspect_ps("basic.eps", format: :ps)

      expect([as_eps.format, as_ps.format]).to eq(%w[eps ps])
      expect(as_ps).to have_attributes(width: 100.0, height: 50.0,
                                       meta: as_eps.meta, parse_status: "ok")
    end

    # The failed constructor must not hardcode its format either.
    %i[eps ps].each do |format|
      it "reports #{format} on the failed branch too" do
        expect(inspect_ps("garbage.ps", format: format))
          .to have_attributes(format: format.to_s, parse_status: "failed")
      end
    end
  end

  describe "non-finite boxes" do
    # An endpoint that overflows outright. A HIRES box, because
    # `%%BoundingBox` takes integers and would refuse `1e9999` on
    # grammar alone, never reaching the finiteness check.
    it "leaves dimensions nil when an endpoint is infinite" do
      expect(inspect_ps("overflow_endpoint.ps", format: :ps))
        .to have_attributes(width: nil, height: nil, parse_status: "ok")
    end

    # Every endpoint finite, the computed width Infinity. An endpoint
    # check misses exactly this, and the array is still JSON-safe -- so
    # the dimension and the meta entry are decided separately.
    #
    # It has to be a HIRES box: `%%BoundingBox` takes integers, so
    # `-1e308` is not a legal coarse declaration and is refused before
    # the span is ever computed.
    it "leaves the width nil while still carrying the box" do
      result = inspect_ps("overflow_width.ps", format: :ps)

      expect(result).to have_attributes(width: nil, parse_status: "ok")
      expect(result.meta["hires_bounding_box"])
        .to eq([-1.0e308, 0.0, 1.0e308, 10.0])
      expect { result.to_json }.not_to raise_error
    end

    # The hires box overflows on ONE axis. The whole coarse PAIR is
    # reported: taking width from the box whose height was refused would
    # give 10.0 x 50.0, a rectangle the file never declared.
    it "falls back to the whole coarse box, not one axis of it" do
      expect(inspect_ps("overflow_hires_axis.ps", format: :ps))
        .to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
    end

    # Without this pair the fallback cannot be told from "hires is
    # simply ignored".
    it "leaves dimensions nil when the overflowing hires box stands alone" do
      expect(inspect_ps("overflow_hires_only.ps", format: :ps))
        .to have_attributes(width: nil, height: nil, parse_status: "ok")
    end

    it "serializes every non-finite case" do
      %w[overflow_endpoint.ps overflow_width.ps
         overflow_hires_axis.ps overflow_hires_only.ps].each do |name|
        expect { inspect_ps(name, format: :ps).to_json }.not_to raise_error
      end
    end
  end

  # The handler does no shape-checking on a box, because the delegate
  # rejects every malformed form itself. This pins that contract: if a
  # release ever hands back a three-element or non-numeric box, the
  # handler would raise instead of reporting nil, and this goes red
  # first.
  describe "what the delegate can return for a bounding box" do
    ["0 0 100", "0 0 100 50 7", "a b c d", "0 0 abc 50", "", "(atend)", "5"]
      .each do |declared|
      it "returns nil for %%BoundingBox: #{declared.inspect}" do
        source = "%!PS-Adobe-3.0\n%%BoundingBox: #{declared}\n%%EndComments\n"

        expect(Postscript.parse(source).header.bounding_box).to be_nil
      end
    end

    it "returns exactly four Floats for a readable box" do
      source = "%!PS-Adobe-3.0\n%%BoundingBox:  0   0   100   50  \n%%EndComments\n"
      box = Postscript.parse(source).header.bounding_box

      expect(box).to eq([0.0, 0.0, 100.0, 50.0])
      expect(box.map(&:class).uniq).to eq([Float])
    end
  end

  # The first-declaration check compares textually for a String field and
  # semantically for an Integer one, so which branch a field takes is
  # decided by its CLASS. That rests on 0.2.0 handing back those two
  # classes and nothing else. The gemspec permits any 0.2.x, so the
  # contract is pinned rather than assumed at each call site: a release
  # that returns a Date for `%%CreationDate` turns a textual comparison
  # into a comparison against `to_s`, and this goes red first.
  it "types the header fields it populates" do
    header = Postscript.parse(File.binread(fixture("basic.eps"))).header

    expect(header).to have_attributes(title: an_instance_of(String),
                                      creator: an_instance_of(String),
                                      creation_date: an_instance_of(String),
                                      language_level: an_instance_of(Integer))
  end

  # The handler parses the DSC header only. Everything it reports is
  # defined to live there, and everything that bites lives in the body.
  describe "the DSC header boundary" do
    # 0.2.0 applies every DSC token globally and lets later values
    # overwrite earlier ones, so this document reported its CHILD's
    # 10x20 / Inner. Scoping fixes it by construction.
    it "reads the outer header, not a nested document's" do
      full = Postscript.parse(File.binread(fixture("nested_document.ps"))).header
      expect(full).to have_attributes(bounding_box: [0.0, 0.0, 10.0, 20.0],
                                      title: "Inner")

      expect(inspect_ps("nested_document.ps", format: :ps))
        .to have_attributes(width: 200.0, height: 100.0, parse_status: "ok")
      expect(inspect_ps("nested_document.ps", format: :ps).meta)
        .to include("title" => "Outer")
    end

    # Both faults escape the allowlist on the whole file -- and
    # SystemStackError is not even a StandardError, so no list of the
    # delegate's own error classes could have held it. Scoping means
    # neither is ever reached.
    {
      "float_domain.ps" => "an operator that overflows",
      "deep_nesting.ps" => "3000 levels of nesting"
    }.each do |name, description|
      it "never reaches #{description} in the body" do
        expect { Postscript.parse(File.binread(fixture(name))) }
          .to raise_error(Exception)

        expect(inspect_ps(name, format: :ps))
          .to have_attributes(parse_status: "ok", width: 100.0, height: 50.0)
      end
    end

    # DSC ends the header at %%EndComments OR at the first line that is
    # not a header comment. Several fixtures reach that second rule; this
    # is the one where the header it has to keep is a real one, and where
    # the body past the boundary raises FloatDomainError if it is read.
    it "ends the header at the first non-comment line" do
      expect { Postscript.parse(File.binread(fixture("no_end_comments.ps"))) }
        .to raise_error(FloatDomainError)

      result = inspect_ps("no_end_comments.ps", format: :ps)

      expect(result).to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
      expect(result.meta).to include("title" => "No EndComments")
    end

    # `%X` continues the header for any printable non-whitespace `X`.
    # Vendor comments in this form appear in Adobe's own DSC examples,
    # and allowing only `%%` and `%!` dropped the whole header at the
    # first one -- the opposite over-correction to letting every `%` line
    # through.
    # DSC requires the character after `%` to be PRINTABLE. `[^ \t\r\n]`
    # also admitted NUL, ESC, VT, FF, DEL and high bytes, none of which
    # is a comment character -- so a control byte kept the header open
    # and a body box behind it was read.
    it "ends the header at a control byte after the percent" do
      result = inspect_ps("control_byte_comment.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil,
                                        parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    it "keeps reading the header past a %X vendor comment" do
      expect(inspect_ps("vendor_comment.ps", format: :ps))
        .to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
    end

    # DSC makes `% `, `%\t` and a lone `%` implicit TERMINATORS -- they
    # are ordinary body comments, not header ones. Treating every `%`
    # line as header let a body box leak into the inspection.
    %w[body_comment.ps lone_percent.ps percent_tab.ps].each do |name|
      it "ends the header at #{name}'s body comment" do
        result = inspect_ps(name, format: :ps)

        expect(result).to have_attributes(width: nil, height: nil,
                                          parse_status: "ok")
        expect(result.meta).to include("title" => "Outer")
        expect(result.meta).not_to have_key("bounding_box")
      end
    end

    # The sentinel is the whole line. `%%EndComments-Bogus` is an
    # ordinary comment, and treating it as the terminator silently
    # suppressed every header comment after it.
    it "does not mistake %%EndComments-Bogus for the sentinel" do
      expect(inspect_ps("endcomments_bogus.ps", format: :ps))
        .to have_attributes(width: 10.0, height: 20.0, parse_status: "ok")
    end

    # A vendor comment and a second box sit behind the CRLF sentinel, so
    # a sentinel that does not allow for the `\r` reads them: the
    # delegate then reports the body's 10x20, that disagrees with the
    # header's first declaration, and the box is refused. Without them
    # the next line is `showpage`, which ends the header on the
    # non-comment rule and gives the same answer either way.
    it "ends the header at CRLF boundaries too" do
      expect(inspect_ps("crlf_header.ps", format: :ps))
        .to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
    end

    # `%%Begin<Something>` opens a section, and a section is never
    # header. `%%BeginData` declares the lines after it opaque, so the
    # `%%BoundingBox` inside one is bytes that happen to look like a
    # comment -- it was published as the page size.
    it "does not read a data section as header" do
      result = inspect_ps("begin_data.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    # The same rule, costing a real box rather than inventing one. With
    # no `%%EndComments` the scan ran on into the child's header, where
    # the delegate's last-wins value became the CHILD's 10x20 -- which
    # disagreed with the outer first declaration, so the outer 200x100
    # was dropped. `nested_document.ps` cannot reach this: it has
    # `%%EndComments`, which stops the scan earlier for another reason.
    it "does not read a nested document's header as the outer one's" do
      full = Postscript.parse(File.binread(fixture("begin_document.ps"))).header
      expect(full.bounding_box).to eq([0.0, 0.0, 10.0, 20.0])

      expect(inspect_ps("begin_document.ps", format: :ps))
        .to have_attributes(width: 200.0, height: 100.0, parse_status: "ok")
    end

    # `%%?` is DSC's query prefix. A `%!PS-Adobe-3.0 Query` file opens
    # `%%?BeginVMStatus` straight after its header comments and never
    # writes `%%EndComments`, so a rule matching only `%%Begin` read the
    # query body as header and published its box.
    it "does not read a query section as header" do
      result = inspect_ps("query_section.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    # `%%EOF` ends the document, so nothing behind it is header. This
    # published a box the file declares after its own end.
    it "does not read past %%EOF" do
      result = inspect_ps("eof_comment.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    # `%%Page` opens the body and `%%Trailer` opens the trailer. Here
    # the cost is the other way round: reading past either one let the
    # body's 10x20 become the delegate's last-wins value, which then
    # disagreed with the header's own first declaration and took the
    # real box down with it.
    %w[page_comment.ps trailer_comment.ps].each do |name|
      it "keeps the header box declared before #{name}'s boundary" do
        expect(inspect_ps(name, format: :ps))
          .to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
      end
    end

    # `%%Pages` is a header comment and must survive the rule that ends
    # the header at `%%Page`. Its box is what shows it did.
    it "does not mistake %%Pages for the body's %%Page" do
      expect(inspect_ps("two_arg_pages.ps", format: :ps))
        .to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
    end

    # `%%EndProlog` closes a section that may never have been opened --
    # DSC allows it alone for an empty prolog -- so it is the one
    # `%%End` form reachable while the header is still being read.
    # Reading past it made the body's 10x20 and "Body" the delegate's
    # last-wins values, and both real header values were dropped for
    # disagreeing with them.
    it "keeps the header declared before %%EndProlog" do
      result = inspect_ps("end_prolog.ps", format: :ps)

      expect(result).to have_attributes(width: 200.0, height: 100.0,
                                        parse_status: "ok")
      expect(result.meta).to include("title" => "Header")
    end

    # `%%IncludeResource` is a body comment and cannot appear in a
    # header. Reading past it published a body box as the page size.
    it "does not read past %%IncludeResource" do
      result = inspect_ps("include_resource.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    # The boundary keywords are whole words followed by a DSC delimiter.
    # A word-character suffix is only half the problem: `\b` treats the
    # `-` in `%%Page-Bogus` as a boundary, so an ordinary comment DSC
    # allows in a header ended the header and took everything behind it.
    # `%%EndComments-Bogus` is the same mistake on the other sentinel.
    it "does not mistake %%Page-Bogus for the body's %%Page" do
      result = inspect_ps("page_bogus.ps", format: :ps)

      expect(result).to have_attributes(width: 100.0, height: 50.0,
                                        parse_status: "ok")
      expect(result.meta).to include("title" => "Kept")
    end
  end

  # The delegate's numbers are not evidence on their own. Its box grammar
  # accepts lexemes like `e`, `.` and `1..2`, then to_f turns them into
  # finite values -- so a box is published only when the delegate's four
  # Floats match the four operands of the FIRST declaration in the
  # header, each a well-formed DSC real.
  describe "boxes the delegate fabricates" do
    it "falls back to the coarse box when the hires one is fabricated" do
      hires = Postscript.parse(File.binread(fixture("fabricated_hires.ps")))
                        .header.hires_bounding_box
      expect(hires).to eq([0.0, 0.0, 0.0, 0.0])

      expect(inspect_ps("fabricated_hires.ps", format: :ps))
        .to have_attributes(width: 100.0, height: 50.0, parse_status: "ok")
    end

    # Nothing to fall back to, so the answer is nil -- never the
    # fabricated zeroes, which would report a 0x0 page as a fact.
    it "publishes nothing when the only box is fabricated" do
      result = inspect_ps("fabricated_coarse.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    # This is the case that disproved my own claim that the strict number
    # grammar was ceremony. `0x10` is not a DSC real, but Ruby's Float
    # reads it as 16.0 -- which AGREES with the delegate's value from the
    # SECOND declaration. A loosened grammar therefore publishes a box
    # built from a hex literal the file never legally declared.
    it "refuses a first declaration whose operand is not a DSC real" do
      header = Postscript.parse(File.binread(fixture("hex_first_box.ps"))).header
      expect(header.bounding_box).to eq([16.0, 0.0, 116.0, 50.0])
      expect(Float("0x10", exception: false)).to eq(16.0)

      result = inspect_ps("hex_first_box.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    # First-occurrence precedence is not a box rule -- DSC applies it to
    # every header comment, and 0.2.0 is last-wins throughout.
    it "refuses a repeated %%Title rather than publishing the last" do
      header = Postscript.parse(File.binread(fixture("duplicate_title.ps"))).header
      expect(header.title).to eq("Second")

      expect(inspect_ps("duplicate_title.ps", format: :ps).meta)
        .not_to have_key("title")
    end

    # DSC gives precedence to the FIRST repeated header comment; 0.2.0
    # keeps the last. Validating one declaration and publishing a value
    # that came from another is its own kind of wrong, so they have to
    # agree.
    it "refuses a box when the delegate reports a later declaration" do
      header = Postscript.parse(File.binread(fixture("duplicate_box.ps"))).header
      expect(header.bounding_box).to eq([0.0, 0.0, 999.0, 999.0])

      result = inspect_ps("duplicate_box.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end
  end

  # (atend) defers the value to the trailer. It is valid, so it is
  # unresolved rather than malformed. Searching the trailer would need
  # the nested-document and data-section handling this slice avoids.
  # The two box comments do not share a grammar.
  describe "coarse boxes take integers" do
    # DSC gives `%%BoundingBox` four INTEGERS; only `%%HiResBoundingBox`
    # takes reals. Applying real syntax to both published these.
    %w[real_coarse_box.ps exponent_coarse.ps].each do |name|
      it "refuses #{name}, whose coarse operands are not integers" do
        expect(Postscript.parse(File.binread(fixture(name))).header.bounding_box)
          .not_to be_nil

        result = inspect_ps(name, format: :ps)

        expect(result).to have_attributes(width: nil, height: nil,
                                          parse_status: "ok")
        expect(result.meta).not_to have_key("bounding_box")
      end
    end

    it "still accepts a real hires box" do
      expect(inspect_ps("hires_only.eps"))
        .to have_attributes(width: 100.5, height: 50.25)
    end
  end

  # DSC orders the box lower-left then upper-right, so a reversed one is
  # malformed rather than merely flipped -- unlike PDF, which permits
  # either diagonal pair. Measured, this published -100.0 x -50.0.
  it "refuses a reversed box rather than reporting negative dimensions" do
    result = inspect_ps("reversed_box.ps", format: :ps)

    expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
    expect(result.meta["bounding_box"]).to eq([100.0, 50.0, 0.0, 0.0])
  end

  # DSC allows `%%+` after ANY structuring comment, boxes included. The
  # continuation guard covered the scalar fields first; a continued box
  # truncates exactly the same way.
  it "omits a bounding box whose declaration is continued by %%+" do
    header = Postscript.parse(File.binread(fixture("continued_box.ps"))).header
    expect(header.bounding_box).to eq([0.0, 0.0, 100.0, 50.0])

    result = inspect_ps("continued_box.ps", format: :ps)

    expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
    expect(result.meta).not_to have_key("bounding_box")
  end

  # A `%%+` line continues the comment above it. 0.2.0 leaves the first
  # fragment in the field and puts the rest in `custom`, so publishing
  # the field reports a truncated value as a complete one.
  it "omits a field whose declaration is continued by %%+" do
    header = Postscript.parse(File.binread(fixture("continued_title.ps"))).header
    expect(header.title).to eq("First part")

    result = inspect_ps("continued_title.ps", format: :ps)

    expect(result.meta).not_to have_key("title")
    expect(result).to have_attributes(width: 100.0, parse_status: "ok")
  end

  # `%%LanguageLevel: 02` is a valid unsigned integer and 0.2.0 reads it
  # as 2, but "02" != "2", so a textual comparison suppressed a
  # correctly-read value. Numeric fields are compared semantically.
  it "accepts a zero-padded LanguageLevel" do
    expect(inspect_ps("padded_level.ps", format: :ps).meta)
      .to include("language_level" => 2)
  end

  describe "a deferred bounding box" do
    it "reports nil dimensions and stays ok" do
      result = inspect_ps("atend_box.ps", format: :ps)

      expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
      expect(result.meta).not_to have_key("bounding_box")
    end

    it "still uses a concrete hires box beside it" do
      expect(inspect_ps("atend_with_hires.ps", format: :ps))
        .to have_attributes(width: 100.5, height: 50.25, parse_status: "ok")
    end
  end

  describe "metadata" do
    it "carries the header comments the delegate populates" do
      expect(inspect_ps("basic.eps").meta).to eq(
        "bounding_box" => [0.0, 0.0, 100.0, 50.0],
        "title" => "Baseline figure",
        "creator" => "claricle specs",
        "creation_date" => "2026-08-20",
        "language_level" => 2
      )
    end

    it "carries both boxes when both are declared" do
      expect(inspect_ps("hires.eps").meta).to include(
        "bounding_box" => [0.0, 0.0, 100.0, 50.0],
        "hires_bounding_box" => [0.0, 0.0, 100.5, 50.25]
      )
    end

    # epsf is never populated, even for a genuine EPSF header, so a nil
    # would read as "the document did not declare it" when the truth is
    # "the delegate does not report it".
    it "omits epsf, which the delegate never populates" do
      header = Postscript.parse(File.binread(fixture("basic.eps"))).header
      expect(header.epsf).to be(false)

      expect(inspect_ps("basic.eps").meta).not_to have_key("epsf")
    end

    # The page fields are populated ONLY by the two-argument form. That
    # asymmetry is why they are omitted rather than merely absent: a
    # consumer would see a count for some files and nil for others with
    # no way to tell which case it was in.
    it "omits the page fields even when the delegate populates them" do
      header = Postscript.parse(File.binread(fixture("two_arg_pages.ps"))).header
      expect(header).to have_attributes(page_count: 3, pages: 1)

      meta = inspect_ps("two_arg_pages.ps", format: :ps).meta
      expect(meta).not_to have_key("page_count")
      expect(meta).not_to have_key("pages")
    end

    it "gets nil page fields from the one-argument form" do
      header = Postscript.parse(File.binread(fixture("one_arg_pages.ps"))).header

      expect(header).to have_attributes(page_count: nil, pages: nil)
    end

    # custom is the UNRECOGNISED-comment bucket, keyed by the whole
    # comment text. The one-argument %%Pages lands there precisely
    # because the delegate could not interpret it -- the two-argument
    # form, which it does understand, leaves custom empty. So it is a
    # record of what the parser failed to read, wearing a Hash, and
    # forwarding it would put that shape into meta.
    it "omits custom, which collects the comments it could not read" do
      unread = Postscript.parse(File.binread(fixture("one_arg_pages.ps"))).header
      understood = Postscript.parse(File.binread(fixture("two_arg_pages.ps"))).header

      expect(unread.custom).to eq("Pages: 3" => true)
      expect(understood.custom).to be_empty

      expect(inspect_ps("one_arg_pages.ps", format: :ps).meta).not_to have_key("custom")
    end

    it "omits keys the file does not declare" do
      expect(inspect_ps("bare.ps", format: :ps).meta).to eq({})
    end
  end

  describe "string safety" do
    # JSON safety, not encoding validity. File.binread gives ASCII-8BIT,
    # where valid_encoding? is true for any bytes at all while to_json
    # still raises -- so a content-born-only example passes an
    # implementation using that check.
    %i[content path].each do |origin|
      it "omits a non-UTF-8 title, #{origin}-born" do
        image = if origin == :path
                  Claricle::Image.from_path(fixture("bad_title.eps"))
                else
                  Claricle::Image.from_content(File.binread(fixture("bad_title.eps")),
                                               format: :eps)
                end

        result = handler.inspection(image)

        expect(result.meta).not_to have_key("title")
        expect(result.meta).to include("creator" => "still fine")
        expect { result.to_json }.not_to raise_error
      end
    end

    # A title that IS valid UTF-8 still arrives tagged ASCII-8BIT from a
    # path. json 2.21 serializes that while warning it will raise in
    # json 3.0, so the value carried is the UTF-8 dup.
    it "carries a valid title tagged UTF-8, not binary" do
      image = Claricle::Image.from_path(fixture("utf8_title.eps"))

      title = handler.inspection(image).meta["title"]

      expect(title).to eq("café notes")
      expect(title.encoding).to eq(Encoding::UTF_8)
    end
  end

  # A delegate limitation, recorded rather than worked around.
  # Pre-normalising the bytes would make inspect report something the
  # parser never saw, and the same file would inspect and conform
  # differently. If 0.2.0 ever reads CR comments, this goes red.
  it "reads no DSC comments from a CR-only file" do
    expect(Postscript.parse(File.binread(fixture("cr_only.ps"))).header.bounding_box)
      .to be_nil

    expect(inspect_ps("cr_only.ps", format: :ps))
      .to have_attributes(width: nil, height: nil, parse_status: "ok")
  end

  # The first-declaration check has to find lines the way DSC does, not
  # the way Ruby's `^` does. `^` starts a line only after LF, so in a
  # file mixing CR and LF it walked past the CR-delimited first box onto
  # the second -- where it agreed with the delegate's last-wins value and
  # published 100.0 x 200.0, a box that was not the file's first.
  it "refuses a box whose first declaration is CR-delimited" do
    header = Postscript.parse(File.binread(fixture("mixed_endings.ps"))).header
    expect(header.bounding_box).to eq([0.0, 0.0, 100.0, 200.0])

    result = inspect_ps("mixed_endings.ps", format: :ps)

    expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
    expect(result.meta).not_to have_key("bounding_box")
  end

  # `String#strip` is wider than DSC, which admits only space and tab:
  # it also removes NUL, VT and FF. Stripping first handed the anchored
  # grammar a clean `0 0 100 50` and published a box from a declaration
  # ending in a byte DSC does not allow.
  it "refuses a box declaration padded with a NUL" do
    header = Postscript.parse(File.binread(fixture("nul_padded_box.ps"))).header
    expect(header.bounding_box).to eq([0.0, 0.0, 100.0, 50.0])

    result = inspect_ps("nul_padded_box.ps", format: :ps)

    expect(result).to have_attributes(width: nil, height: nil, parse_status: "ok")
    expect(result.meta).not_to have_key("bounding_box")
  end

  # `%%LanguageLevel` takes an unsigned integer, and Ruby's `Integer` is
  # wider than that. `Integer("2_0", 10)` is 20, so the first
  # declaration agreed with a value the delegate had read from the
  # SECOND one -- the wrong `hex_first_box.ps` records for boxes,
  # reached through a different conversion. The box in the same file
  # still comes through, so the level alone is what this refuses.
  it "refuses a LanguageLevel whose first declaration is not DSC syntax" do
    header = Postscript.parse(File.binread(fixture("underscored_level.ps"))).header
    expect(header).to have_attributes(language_level: 20,
                                      custom: { "LanguageLevel: 2_0" => true })
    expect(Integer("2_0", 10, exception: false)).to eq(20)

    result = inspect_ps("underscored_level.ps", format: :ps)

    expect(result.meta).not_to have_key("language_level")
    expect(result).to have_attributes(width: 100.0, parse_status: "ok")
  end

  # A delegate limitation, recorded rather than worked around. DSC wraps
  # a text argument in parentheses and 0.2.0 hands that form back
  # verbatim, so that is what reaches `meta`. Decoding it here would
  # make inspect report something the parser never saw, and the same
  # file would inspect and conform differently -- the line `cr_only.ps`
  # already draws. If 0.2.0 ever decodes the form, this goes red.
  it "carries a parenthesized title exactly as the delegate read it" do
    expect(Postscript.parse(File.binread(fixture("parenthesized_title.ps")))
                     .header.title).to eq("(Draft)")

    expect(inspect_ps("parenthesized_title.ps", format: :ps).meta)
      .to include("title" => "(Draft)")
  end

  describe "the complete inspection" do
    it "is pinned exactly on the ok branch" do
      expect(inspect_ps("offset.eps")).to have_attributes(
        format: "eps", width: 100.0, height: 50.0,
        dpi: nil, color_space: nil, parse_status: "ok", issues: []
      )
    end

    it "is pinned exactly on the failed branch" do
      result = inspect_ps("garbage.ps", format: :ps)

      expect(result).to have_attributes(
        format: "ps", width: nil, height: nil, dpi: nil,
        color_space: nil, meta: nil, parse_status: "failed"
      )
      expect(result.issues.map { |i| [i.severity, i.code, i.message] }).to eq(
        [["error", "postscript.header_unreadable",
          "PostScript header could not be read"]]
      )
    end
  end

  # The delegate takes a String, so there is no path round-trip to make.
  # An `eq` on the bytes handed to it cannot prove that alone: a fresh
  # `File.binread(image.path)` would return the same bytes and pass it
  # too. `not_to receive(:binread)` is what actually rules a re-read
  # out, since the file was already read once building `content`.
  it "parses the image's own content without touching the path" do
    image = Claricle::Image.from_path(fixture("basic.eps"))
    content = image.content
    seen = []

    allow(Postscript).to receive(:parse).and_wrap_original do |original, arg|
      seen << arg
      original.call(arg)
    end
    expect(image).not_to receive(:with_path)
    expect(File).not_to receive(:binread)

    handler.inspection(image)

    expect(content.encoding).to eq(Encoding::BINARY)
    expect(seen.length).to eq(1)
    # The exact header prefix, not the whole file: the handler scopes
    # the parse to the DSC header and hands those bytes on unchanged.
    expect(seen.first).to eq(content[0, content.index("%%EndComments") + 14])
    expect(content).to end_with("showpage\n")
  end

  # Nothing guarantees the tag on a String of raw bytes, and these bytes
  # are a perfectly good EPS whatever it says. The delegate disagrees --
  # it raises Encoding::CompatibilityError out of String#strip on the
  # UTF-16 tags -- so the handler hands it a binary view. ASCII-8BIT,
  # UTF-8 and ISO-8859-1 all pass without that fix, which is exactly why
  # a single-encoding example misses it.
  describe "encoding tags on the same bytes" do
    %w[ASCII-8BIT UTF-8 UTF-16LE UTF-16BE ISO-8859-1].each do |encoding|
      it "reads an EPS tagged #{encoding}" do
        bytes = File.binread(fixture("basic.eps")).dup.force_encoding(encoding)
        image = Claricle::Image.from_content(bytes, format: :eps)

        result = handler.inspection(image)

        expect(result).to have_attributes(width: 100.0, height: 50.0,
                                          parse_status: "ok")
        expect(result.meta).to include("title" => "Baseline figure")
      end
    end

    # Identity here, since there is a single object to compare: bytes
    # already tagged BINARY are handed straight through, not re-tagged
    # into a copy. The header the delegate sees is a slice of them.
    it "leaves a frozen binary content string as the very object it was given" do
      # Frozen as well as binary: Image hands back the caller's own
      # object only when it is both, because sharing an unfrozen buffer
      # would let a caller mutate bytes an image is still reading.
      bytes = File.binread(fixture("basic.eps")).freeze
      image = Claricle::Image.from_content(bytes, format: :eps)
      seen = []

      allow(Postscript).to receive(:parse).and_wrap_original do |original, arg|
        seen << arg
        original.call(arg)
      end
      handler.inspection(image)

      expect(image.content).to be(bytes)
      expect(seen.first).to eq(bytes[0, bytes.index("%%EndComments") + 14])
    end
  end
end
