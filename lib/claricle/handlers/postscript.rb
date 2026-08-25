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
      # The sentinel is the WHOLE line. `%%EndComments-Bogus` is an
      # ordinary comment, and treating it as the terminator silently
      # suppressed every header comment after it.
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

      # A DSC keyword ends at a colon, at whitespace, or at the end of
      # its line. Nothing else ends one, which is why `%%Page-Bogus` and
      # `%%EndComments-Bogus` are ordinary comments rather than the
      # keywords they open with. `\b` got this wrong: it treats the `-`
      # as a boundary and dropped the whole header behind such a line.
      DELIMITED = /(?=[:\t ]|\r|\n|\z)/

      # The DSC comments that belong to some OTHER part of the document.
      # None is a header comment, so each one ends the header:
      #
      #   `Begin<Anything>` opens a section -- `%%BeginProlog` by
      #   definition, `%%BeginDocument` because what follows is a CHILD's
      #   header, `%%BeginData` because what follows is declared opaque,
      #   so a `%%BoundingBox` inside one is bytes that happen to look
      #   like a comment.
      #
      #   `End<Anything>` closes one. Most are unreachable here, since
      #   their opener stopped the scan already -- but `%%EndProlog` and
      #   `%%EndSetup` are legal on their own, for an empty prolog or
      #   setup. A BARE `%%EndComments` never reaches this: it is the
      #   sentinel, and `header` tests for it first. One WITH a colon
      #   does reach here, though -- DSC makes the colon part of the
      #   keyword, so `%%EndComments: fake` is not that sentinel and not
      #   any other DSC comment either, and matching it as an `End<X>`
      #   closer ended the header there, dropping a real box and title
      #   behind it. `Comments` is excluded from this branch for exactly
      #   that reason; DSC never defines a `%%BeginComments` for it to
      #   close.
      #
      #   `Include<Anything>` is a body comment -- `%%IncludeResource`,
      #   `%%IncludeFeature`, `%%IncludeDocument` -- and cannot appear in
      #   a header at all.
      #
      #   A leading `?` marks any of the three as a query. `%%?` is DSC's
      #   query prefix and nothing else uses it: a `%!PS-Adobe-3.0 Query`
      #   file opens `%%?BeginVMStatus` straight after its header
      #   comments and never writes `%%EndComments`.
      #
      #   `Page`, `Trailer`, `PageTrailer` and `EOF` open the body, open
      #   the trailer, open a page's own trailer and end the document.
      #   `Page` is not `%%Pages`, which is a genuine header comment --
      #   the delimiter is what tells them apart. `PageTrailer` has no
      #   delimiter between the two words, so neither the `Page` nor the
      #   `Trailer` alternative matches it -- each requires a delimiter
      #   immediately after -- and it stayed inside the header, letting a
      #   body box and title behind it publish as header metadata.
      #
      # `%%EndComments` hid every one of these: a file that has it stops
      # earlier for another reason. Without it, each read a body box as
      # the page size, or read one and then dropped the header box the
      # file plainly declared for disagreeing with it.
      OTHER_PART = /\??(?:Begin|Include)[A-Za-z]*|\??End(?!Comments\b)[A-Za-z]*|
                    PageTrailer|Page|Trailer|EOF/x
      NOT_HEADER = /\A%%(?:#{OTHER_PART})#{DELIMITED}/

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

      # DSC's own padding, and its own line terminators. Nothing wider:
      # `String#strip` also removes NUL, VT and FF, none of which DSC
      # admits as whitespace, so `%%BoundingBox: 0 0 100 50\0` reached
      # the anchored grammar with the NUL already gone and published a
      # box from a line the file never legally declared.
      PADDING = /\A[ \t]+/
      TERMINATOR = /[ \t]*(?:\r\n|\r|\n)?\z/

      # `%%LanguageLevel` takes an UNSIGNED integer. Ruby's own
      # conversion is wider -- `Integer("2_0", 10)` is 20 and
      # `Integer("+2", 10)` is 2 -- so a file declaring `2_0` and then
      # `20` had the SECOND value published under the first one's
      # authority. That is the wrong `hex_first_box` records for boxes,
      # reached through a different conversion.
      UNSIGNED = /\A\d+\z/

      # A `%%+` line continues the comment above it. 0.2.0 does not
      # reconstruct the logical value -- it puts the continuation in
      # `custom` and leaves the first fragment in the field -- so
      # publishing that fragment reports a truncated value as a complete
      # one. The field is omitted instead.
      CONTINUATION = /\A%%\+/

      # The header only: from `%!` to `%%EndComments`, or to the first
      # line that is not a header comment. Everything the handler reports
      # is defined to live there, and everything that bites lives in the
      # body.
      #
      # 0.2.0 applies every DSC token globally and lets later values
      # overwrite earlier ones, so a document declaring 200x100 that
      # contains a `%%BeginDocument` child reported the CHILD's 10x20.
      # Scoping fixes that by never handing the body over in the first
      # place -- and it takes the body's exceptions with it, which is how a
      # `FloatDomainError` from `1e9999 idiv` and a `SystemStackError`
      # from deep nesting stop escaping. `SystemStackError` is not even a
      # `StandardError`, so the delegate's own error classes could never
      # have covered it.
      #
      # The bytes are passed on unchanged; only where they end is decided.
      # The sentinel is tested first, and taken with the header. It is
      # itself an `%%End<Anything>` comment, so the boundary rule would
      # otherwise stop one line short of it.
      def self.header(content)
        offset = 0
        content.scan(LINE) do |line|
          ended = HEADER_END.match?(line)
          break if !ended && offset.positive? && !header_line?(line)

          offset += line.bytesize
          break if ended || line.empty?
        end
        offset.zero? ? content : content.byteslice(0, offset)
      end

      def self.header_line?(line)
        HEADER_LINE.match?(line) && !NOT_HEADER.match?(line)
      end

      # `header`, applied incrementally to an IO already holding `chunk`
      # as its first read: grows `chunk` by reading more only when
      # `header` consumed the whole of it without finding a boundary
      # strictly inside -- a boundary sitting exactly on `chunk`'s own
      # edge cannot be trusted yet, since the next unread byte could
      # still belong to that same line. DSC sets no ceiling on a
      # header's size, so this grows rather than truncating, at the cost
      # of at most one extra read past a header that happens to end
      # exactly on a chunk boundary.
      #
      # Lets a path-born image's header be read without pulling the rest
      # of the file -- often the bulk of it -- into memory for bytes
      # nothing here reads.
      def self.windowed_header(io, chunk)
        scoped = header(chunk)
        return scoped if scoped.bytesize < chunk.bytesize || io.eof?

        chunk << io.read
        header(chunk)
      end

      # `header`, but only once `raw` -- a String already in memory, or
      # an IO to read from -- is confirmed to open with `signature`, or
      # nil for a source that does not. Checked with `byteslice` and
      # `==`, not `start_with?`: a UTF-16-tagged String raises
      # `Encoding::CompatibilityError` out of `start_with?` against a
      # binary-tagged signature, where a byte comparison just answers
      # false -- measured across ASCII-8BIT, UTF-8, UTF-16LE, UTF-16BE
      # and ISO-8859-1.
      #
      # Unifies the String and IO paths behind one call, so
      # `Handlers::Postscript` chooses neither `header` nor
      # `windowed_header` itself -- and reads only `probe_bytes` of an
      # IO before it is known to be worth reading further at all.
      def self.signed_header(raw, signature, probe_bytes)
        if raw.respond_to?(:read)
          chunk = raw.read(probe_bytes) || ""
          return nil unless signed?(chunk, signature)

          windowed_header(raw, chunk)
        else
          return nil unless signed?(raw, signature)

          header(raw)
        end
      end

      def self.signed?(bytes, signature)
        bytes.byteslice(0, signature.bytesize) == signature
      end

      # The header's own lines, on DSC's three boundaries. Every lookup
      # below goes through it, so no two of them can disagree about
      # which line is the first declaration.
      def self.lines(source)
        source.scan(LINE)
      end

      def self.index_of(lines, name)
        lines.index { |line| line.start_with?("%%#{name}:") }
      end

      # Whether the first `%%<name>:` line is continued by a `%%+`.
      def self.continued?(source, name)
        header = lines(source)
        index = index_of(header, name)
        return false unless index

        CONTINUATION.match?(header[index + 1].to_s)
      end

      # The text of the FIRST `%%<name>:` line, or nil. DSC gives
      # precedence to the first occurrence of a header comment; 0.2.0
      # keeps the last, so every published field is checked against this,
      # not just the boxes.
      #
      # Found by line, not by Ruby's `^`, which starts a line only after
      # LF. In a file mixing CR and LF, `^` walked straight past a
      # CR-delimited first declaration onto the next one -- where it
      # agreed with the delegate's last-wins value and published a box
      # that was not the file's first.
      def self.first_text(source, name)
        header = lines(source)
        index = index_of(header, name)
        return nil unless index

        trim(header[index].delete_prefix("%%#{name}:"))
      end

      def self.trim(text)
        text.sub(PADDING, "").sub(TERMINATOR, "")
      end

      # The declared text as an unsigned DSC integer, or nil.
      def self.unsigned(text)
        return nil unless UNSIGNED.match?(text)

        Integer(text, 10)
      end

      # `source`, keeping only the opening `%!` line, the exact
      # `%%EndComments` sentinel, and lines whose keyword (colon included
      # -- DSC makes the colon part of it) is in `names`.
      #
      # `%%+` is dropped unconditionally, never kept even right behind a
      # comment that IS kept -- measured, 0.2.0 does not attach a
      # continuation to whichever comment preceded it at all: every
      # `%%+` line lands in `custom` regardless of context, the same
      # bucket an unrecognised comment does, and `custom` is exactly
      # what this filter exists to keep the delegate from paying
      # quadratic cost on. A field this handler reads keeps only its
      # first fragment either way (0.2.0 never reconstructs the
      # continued value), so a kept field's own continuations are as
      # unread as an unrecognised comment's.
      #
      # Reads irrelevant comments out of what the delegate ever sees --
      # `Handlers::Postscript` uses this to keep 0.2.0's own quadratic
      # cost on unrecognised comments from being paid on comments no
      # caller of `names` reads in the first place.
      def self.filter(source, names)
        keyword = /\A%%(?:#{Regexp.union(names)}):/
        lines(source).each_with_object(+"") do |line, kept|
          next if CONTINUATION.match?(line)

          relevant = line.start_with?("%!") || HEADER_END.match?(line) || keyword.match?(line)
          kept << line if relevant
        end
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

      # The delegate's own answer for the fields this handler reads, so
      # the set is not restated: the two box names, plus the four scalar
      # ones `metadata` populates.
      #
      # 0.2.0 merges every comment it does NOT recognise into a growing
      # `custom` hash and duplicates the whole hash on each merge --
      # measured, a 629 KB header of 32,000 unique `%%For:` comments (a
      # real DSC General Header Comment, not malformed input) took over
      # 20 seconds to parse. Nothing here ever reads `custom`, so
      # filtering to only these six comments before the delegate ever
      # sees the header turns that quadratic cost into linear work over
      # the comments this handler actually consumes.
      FIELD_COMMENTS = (BOX_COMMENTS.values + %w[Title Creator CreationDate LanguageLevel]).freeze

      # The most a single probe reads before checking whether the header
      # ended inside it. Generous for the common case -- a handful of
      # scalar comments and a box are a few hundred bytes -- and not a
      # ceiling: `header_source` reads past it when a real header runs
      # longer, exactly the 629 KB case `FIELD_COMMENTS` exists for.
      HEADER_PROBE_BYTES = 8192

      private_constant :SIGNATURE, :PARSE_FAILURES, :BOX_COMMENTS,
                       :FIELD_COMMENTS, :HEADER_PROBE_BYTES,
                       :ISSUE_CODE, :ISSUE_MESSAGE

      # `image.content` would cost a path-born image a file-sized
      # allocation it retains for the image's whole lifetime, for a
      # handler that reads only the header -- measured on a large body,
      # +file-size RSS and the body kept alive -- so this goes through
      # `with_source` instead, the same reader `Handlers::Svg` uses for
      # the same reason.
      def inspection(image)
        source = image.with_source { |raw| Dsc.signed_header(raw, SIGNATURE, HEADER_PROBE_BYTES) }
        return unreadable(image) unless source

        header = read_header(source)
        return unreadable(image) unless header

        readable(image, header, source)
      end

      private

      def read_header(source)
        ::Postscript.parse(Dsc.filter(source, FIELD_COMMENTS)).header
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
      # it is simply unresolved here -- a concrete `%%HiResBoundingBox`
      # beside it still supplies the dimensions, and with no concrete box
      # at all they are nil while the header is still `"ok"`. Searching
      # the trailer would need the nested-document and data-section
      # handling this slice exists to avoid.
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
      # would give a count for some files and nil for others with nothing
      # in `meta` to tell the cases apart -- and `pages` is the obsolete
      # page-order argument, not a count. `custom` is the UNRECOGNISED-comment
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
      #
      # The numeric side reads the declared text through DSC's own
      # unsigned-integer grammar, not Ruby's `Integer`. `Integer` is
      # wider, and a file declaring `2_0` and then `20` had the second
      # value published as though it were the first.
      #
      # Textual means the delegate's own text, byte for byte. 0.2.0
      # hands back `%%Title: (Draft)` as `"(Draft)"`, parentheses and
      # all, and that is what reaches `meta`. Decoding DSC's text syntax
      # here would report something the parser never saw -- the same
      # line `cr_only.ps` draws.
      def agrees?(declared, value)
        return declared == value if value.is_a?(String)
        return Dsc.unsigned(declared) == value if value.is_a?(Integer)

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
