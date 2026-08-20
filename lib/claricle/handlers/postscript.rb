# frozen_string_literal: true

require "postscript"

require_relative "base"
require_relative "../detector"
require_relative "../models/inspection"
require_relative "../models/issue"

module Claricle
  module Handlers
    # DSC framing: where the header ends, and what a box comment declares.
    #
    # Extracted because it is the part that reads the file's own bytes
    # rather than the delegate's answers, and because `Handlers::Metafile`
    # sets the precedent with `EmfPlus` -- the byte-level reader lives
    # beside the handler, not inside it.
    module Dsc
      # One line, ending in CR, LF, CRLF or the end of input -- DSC's
      # three line boundaries, not Ruby's one.
      LINE = /[^\r\n]*(?:\r\n|\r|\n|\z)/
      # The sentinel is the WHOLE line. `%%EndComments-Bogus` and
      # `%%EndComments: fake` are ordinary comments, and treating them as
      # the terminator silently suppressed every header comment after
      # them.
      HEADER_END = /\A%%EndComments[ \t]*\r?\n?\z/

      # `%X` continues the header when `X` is PRINTABLE, which includes
      # vendor comments like `%GBDNodeName:` from Adobe's own DSC
      # examples. `[!-~]`, not `[^ \t\r\n]`: the latter also accepts NUL,
      # ESC, VT, FF, DEL and arbitrary high bytes, none of which DSC
      # admits as a comment character. The implicit TERMINATORS are the
      # whitespace forms -- `% `, `%\t` and a lone `%`.
      #
      # This predicate has been wrong three times, in three directions:
      # every `%` line continuing (a body box leaked in), only `%%` and
      # `%!` continuing (a valid header dropped at its first vendor
      # comment), and any non-whitespace byte continuing (control bytes
      # treated as comments).
      HEADER_LINE = /\A%[!-~]/

      # Anchored DSC number syntax. `Postscript.parse` is far looser: its
      # box grammar accepts `e`, `.`, `+`, `1e` and `1..2`, then `to_f`
      # turns them into finite numbers -- so `%%HiResBoundingBox: e e e e`
      # arrives as four zeroes and beats a valid coarse box, reporting a
      # 0x0 page as a fact. Nothing in the delegate's output distinguishes
      # that from a genuine `0 0 0 0`.
      #
      # This is NOT redundant with Ruby's `Float()`, which was my own
      # earlier claim. `Float("0x10")` is 16.0, and with
      # `%%BoundingBox: 0x10 0 116 50` followed by a second declaration of
      # `16 0 116 50`, the delegate reports the second and `Float` agrees
      # with it -- so a looser grammar publishes a box built from a hex
      # literal the file never legally declared.
      #
      # **The two box comments have different grammars.**
      # `%%BoundingBox` takes four INTEGERS; only `%%HiResBoundingBox`
      # takes reals. Applying real syntax to both published
      # `0.5 0 100.5 50` and `1e2 0 2e2 50` as coarse boxes.
      REAL = /[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?/
      INTEGER = /[+-]?\d+/

      def self.operands(number)
        /\A[ \t]*(#{number})[ \t]+(#{number})[ \t]+(#{number})[ \t]+(#{number})[ \t]*\z/
      end

      GRAMMARS = { "BoundingBox" => operands(INTEGER),
                   "HiResBoundingBox" => operands(REAL) }.freeze

      # A `%%+` line continues the comment above it. 0.2.0 does not
      # reconstruct the logical value -- it puts the continuation in
      # `custom` and leaves the first fragment in the field -- so
      # publishing that fragment reports a truncated value as a complete
      # one. The field is omitted instead.
      CONTINUATION = /\A%%\+/

      # The header only: from `%!` to `%%EndComments`, or to the first
      # line that is not a comment. Everything the handler reports is
      # defined to live there, and everything that bites lives in the
      # body.
      #
      # 0.2.0 applies every DSC token globally and lets later values
      # overwrite earlier ones, so a document declaring 200x100 that
      # contains a `%%BeginDocument` child reported the CHILD's 10x20.
      # Scoping fixes that by construction rather than by enumeration --
      # and it takes the body's exceptions with it, which is how a
      # `FloatDomainError` from `1e9999 idiv` and a `SystemStackError`
      # from deep nesting stop escaping. `SystemStackError` is not even a
      # `StandardError`, so no allowlist would have held it.
      #
      # The bytes are passed on unchanged; only where they end is decided.
      def self.header(content)
        offset = 0
        content.scan(LINE) do |_|
          line = Regexp.last_match(0)
          break if offset.positive? && !HEADER_LINE.match?(line)

          offset += line.bytesize
          break if HEADER_END.match?(line)
          break if line.empty?
        end
        offset.zero? ? content : content.byteslice(0, offset)
      end

      # Whether the first `%%<name>:` line is continued by a `%%+`.
      def self.continued?(source, name)
        lines = source.scan(LINE)
        index = lines.index { |line| line.start_with?("%%#{name}:") }
        return false unless index

        CONTINUATION.match?(lines[index + 1].to_s)
      end

      # The text of the FIRST `%%<name>:` line, or nil. DSC gives
      # precedence to the first occurrence of a header comment; 0.2.0
      # keeps the last, so every published field is checked against this,
      # not just the boxes.
      def self.first_text(source, name)
        match = /^%%#{name}:([^\r\n]*)/.match(source)
        match && match[1].strip
      end

      # The four operands of that line, each a well-formed DSC real.
      def self.declaration(source, name)
        text = first_text(source, name)
        return nil unless text

        operands = GRAMMARS.fetch(name).match(text)
        return nil unless operands

        operands.captures.map { |value| Float(value, exception: false) }
      end
    end

    private_constant :Dsc

    # Reports a PostScript program's DSC header: dimensions from the
    # bounding box, and the comments that 0.2.0 actually populates.
    #
    # `:eps` and `:ps` share this handler and differ only in what the
    # detector called them. `image.format` supplies the reported format,
    # so one class reports both correctly.
    class Postscript < Base
      formats :eps, :ps

      # The detector's own signature, not a second copy of it. Both are
      # anchored at byte zero -- `Detector.classify` tests
      # `start_with?(POSTSCRIPT_SIGNATURE)` on a prefix from offset zero
      # -- so two definitions would be one rule stated twice that must
      # agree forever. Broaden the detector and a file it calls `:eps`
      # would get `"failed"` here: claricle naming a format it then
      # refuses to read. `Handlers::Svg` reuses `Detector.read_root` for
      # the same reason.
      #
      # `Postscript.parse` succeeds on "not postscript at all", so the
      # delegate not raising says nothing (D17) -- exactly as it said
      # nothing for PNG's chunk reader. Anchored, not `include?` and not
      # `lstrip`: a leading space or newline means the file does not
      # start with a header.
      SIGNATURE = Detector::POSTSCRIPT_SIGNATURE

      # Every way this delegate fails on input rather than on a defect.
      # `ParseError` and not `LexError` alone: an unmatched brace raises
      # `SyntaxError`, and both descend from it.
      #
      # Currently unreachable, and kept deliberately. Now that only the
      # DSC header is parsed there is nothing left to raise -- measured
      # across an unterminated string, a brace, a null byte and a 100 KB
      # comment, every header-only input parses. This is a rescue on a
      # third-party call whose failure modes we do not control, which is
      # a boundary guard rather than an internal nil-check, and the
      # narrow list is what keeps a delegate defect propagating.
      PARSE_FAILURES = [::Postscript::ParseError].freeze

      # The `meta` key each box comment supplies.
      BOX_COMMENTS = { "bounding_box" => "BoundingBox",
                       "hires_bounding_box" => "HiResBoundingBox" }.freeze

      ISSUE_CODE = "postscript.header_unreadable"
      ISSUE_MESSAGE = "PostScript header could not be read"

      private_constant :SIGNATURE, :PARSE_FAILURES, :BOX_COMMENTS,
                       :ISSUE_CODE, :ISSUE_MESSAGE

      def inspection(image)
        content = image.content
        return unreadable(image) unless signed?(content)

        source = Dsc.header(content)
        header = read_header(source)
        return unreadable(image) unless header

        readable(image, header, source)
      end

      private

      def signed?(content)
        content.byteslice(0, SIGNATURE.bytesize) == SIGNATURE
      end

      def read_header(source)
        ::Postscript.parse(source).header
      rescue *PARSE_FAILURES
        nil
      end

      def readable(image, header, source)
        boxes = BOX_COMMENTS.to_h { |key, name| [key, box(header, source, key, name)] }
        spans = usable_spans(boxes)

        Models::Inspection.new(
          format: image.format.to_s,
          width: spans&.first,
          height: spans&.last,
          meta: metadata(header, boxes, source),
          parse_status: "ok"
        )
      end

      def unreadable(image)
        Models::Inspection.new(
          format: image.format.to_s,
          parse_status: "failed",
          issues: [Models::Issue.new(severity: "error", code: ISSUE_CODE,
                                     message: ISSUE_MESSAGE)]
        )
      end

      # First usable candidate: hires, then coarse, then nil. The DSC
      # defines `%%BoundingBox` as the rounded counterpart of
      # `%%HiResBoundingBox`, so a file declaring both declares one
      # rectangle twice. Falling back reports the document's own coarser
      # statement rather than inventing a number, and reporting nil for a
      # file carrying a readable `%%BoundingBox` would be less honest.
      #
      # "Usable" means both spans come out finite, so a box that
      # overflows on ONE axis is rejected whole -- taking width from the
      # box whose height was just refused would report a rectangle no
      # one declared.
      def usable_spans(boxes)
        [boxes["hires_bounding_box"], boxes["bounding_box"]]
          .filter_map { |box| spans(box) }
          .first
      end

      # A box is published only when the delegate's four Floats match the
      # four operands of the FIRST declaration in the header, each of
      # which is a well-formed DSC real.
      #
      # Two rules meet here. The delegate's numbers cannot be trusted on
      # their own, because its grammar fabricates finite values out of
      # lexemes like `e`. And DSC gives precedence to the FIRST repeated
      # header comment while 0.2.0 keeps the last, so validating one
      # declaration and publishing a value that came from another would
      # be its own kind of wrong. Requiring them to agree settles both:
      # the delegate supplies the values, the file decides which
      # declaration they had to come from.
      #
      # `%%BoundingBox: (atend)` defers to the trailer. It is valid, so
      # it is simply unresolved here -- the coarse box is used if it is
      # concrete, otherwise dimensions are nil and the header is still
      # `"ok"`. Searching the trailer would need the nested-document and
      # data-section handling this slice exists to avoid.
      def box(header, source, key, name)
        declared = header.public_send(key)
        return nil unless declared.is_a?(Array)
        # DSC allows `%%+` after ANY structuring comment, boxes included.
        # 0.2.0 leaves the first fragment in the field either way, so a
        # continued box is as truncated as a continued title.
        return nil if Dsc.continued?(source, name)

        operands = Dsc.declaration(source, name)
        return nil unless operands
        return nil unless operands == declared

        declared
      end

      # `[width, height]`, or nil when either cannot be computed.
      #
      # Finiteness on the COMPUTED span, not on the endpoints: in
      # `-1e308 0 1e308 10` every endpoint is a finite Float while the
      # difference is Infinity, which `to_json` refuses. An endpoint
      # check misses exactly that case.
      #
      # Both spans or neither. A box overflowing on ONE axis is rejected
      # whole, since taking the width from a box whose height was just
      # refused would report a rectangle nobody declared.
      #
      # Spans must also be NON-NEGATIVE. DSC orders `%%BoundingBox` as
      # lower-left then upper-right, so `100 50 0 0` is malformed rather
      # than merely reversed -- unlike PDF, which permits either diagonal
      # pair and is normalised with `abs`. Measured, it published
      # `-100.0 x -50.0`. The raw box still reaches `meta`, since that
      # reports what the file declared.
      def spans(box)
        return nil unless box

        width = box[2] - box[0]
        height = box[3] - box[1]
        return nil unless width.finite? && height.finite?

        width.negative? || height.negative? ? nil : [width, height]
      end

      # Only the fields 0.2.0 populates reliably. `epsf` is never set,
      # even for a genuine EPSF header. `page_count` and `pages` are set
      # only by the two-argument `%%Pages: n m` form, so reporting them
      # would give a count for some files and nil for others with no way
      # to tell the cases apart -- and `pages` is the obsolete page-order
      # argument, not a count. `custom` is the UNRECOGNISED-comment
      # bucket, keyed by the whole comment text: `%%Pages: 3` lands there
      # as `{"Pages: 3" => true}` precisely because 0.2.0 cannot read the
      # one-argument form, so it is a record of what the parser failed at.
      def metadata(header, boxes, source)
        {
          "bounding_box" => carried_box(boxes["bounding_box"]),
          "hires_bounding_box" => carried_box(boxes["hires_bounding_box"]),
          "title" => authoritative(header.title, source, "Title"),
          "creator" => authoritative(header.creator, source, "Creator"),
          "creation_date" => authoritative(header.creation_date, source,
                                           "CreationDate"),
          "language_level" => authoritative(header.language_level, source,
                                            "LanguageLevel")
        }.compact
      end

      # DSC's first-occurrence rule is not about boxes; it covers every
      # header comment. 0.2.0 is last-wins throughout, so a repeated
      # `%%Title` published the second one. Each field is checked against
      # the first declaration's own text, the same way a box is checked
      # against its first operands.
      def authoritative(value, source, name)
        return nil if value.nil?
        return nil if Dsc.continued?(source, name)

        declared = Dsc.first_text(source, name)
        return nil unless declared
        return nil unless agrees?(declared, value)

        value.is_a?(String) ? carried(value) : value
      end

      # Textual for a string field, semantic for a numeric one.
      # `%%LanguageLevel: 02` is a valid unsigned integer and 0.2.0 reads
      # it as 2, but `"02" != "2"`, so a textual comparison suppressed a
      # correctly-read value.
      def agrees?(declared, value)
        return declared == value if value.is_a?(String)
        return Integer(declared, 10, exception: false) == value if value.is_a?(Integer)

        declared == value.to_s
      end

      # A box reaches `meta` on its own endpoints being finite, not on
      # the dimensions being usable: those two fail independently, and a
      # box whose endpoints are finite is JSON-safe even when its span
      # overflows.
      #
      # No shape check, because the delegate does it. Measured across
      # three, five, one and zero values, non-numeric and mixed
      # operands: every malformed `%%BoundingBox` comes back nil, and a
      # readable one is always exactly four Floats. Guarding a case the
      # delegate cannot produce would be dead code, and a spec pins the
      # contract so a delegate that changes its mind is caught.
      def carried_box(box)
        return nil unless box

        box.all?(&:finite?) ? box : nil
      end

      # JSON safety, not encoding validity. A path-born string comes from
      # `File.binread` tagged ASCII-8BIT, where `valid_encoding?` is true
      # for any bytes at all while `to_json` still raises.
      #
      # The value carried is the UTF-8 dup, not the original: json 2.21
      # serializes a BINARY-tagged UTF-8 string while warning that it
      # will raise in json 3.0.
      def carried(value)
        return nil unless value.is_a?(String)

        candidate = value.dup.force_encoding(Encoding::UTF_8)
        candidate.valid_encoding? ? candidate : nil
      end
    end
  end
end
