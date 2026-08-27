# frozen_string_literal: true

require_relative "base"
require_relative "../detector"
require_relative "../models/inspection"
require_relative "../models/issue"

module Claricle
  module Handlers
    # DSC's own number syntax, anchored -- the second vocabulary
    # `Dsc` consults, beside `DscKeywords`. Both are what the DSC
    # spec says a token may look like; neither decides where a header
    # starts or stops.
    module DscNumbers
      # `Postscript.parse` is far looser than this: its
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

      # `%%LanguageLevel` takes an UNSIGNED integer. Ruby's own
      # conversion is wider -- `Integer("2_0", 10)` is 20 and
      # `Integer("+2", 10)` is 2 -- so a file declaring `2_0` and then
      # `20` had the SECOND value published under the first one's
      # authority. That is the wrong `hex_first_box` records for boxes,
      # reached through a different conversion.
      UNSIGNED = /\A\d+\z/

      # The declared text as an unsigned DSC integer, or nil.
      def self.unsigned(text)
        return nil unless UNSIGNED.match?(text)

        Integer(text, 10)
      end
    end

    # The DSC structuring comments that belong to some other part of
    # the document, enumerated with the punctuation each one requires.
    #
    # Beside `Dsc` rather than inside it: `Dsc` is about FRAMING -- where
    # a header starts and stops, and what its lines declare -- while this
    # is the vocabulary that framing consults. The list grows when DSC
    # does; the framing rules do not.
    module DscKeywords
      # None of these is a header comment, so each one ends the header.
      #
      # **A keyword's punctuation is part of the keyword.** DSC defines
      # each structuring comment with its arity, and the colon belongs to
      # the ones that take operands. A generic "colon, whitespace or end
      # of line" delimiter behind a `Begin`/`End`/`Include` STEM read
      # four spellings DSC does not define as though they were the
      # keywords they resemble -- `%%BeginFuture:`, `%%Trailer: fake`,
      # a bare `%%Page` and `%%PageTrailer: fake` each ended the header
      # and discarded a valid box and title behind it. A comment DSC does
      # not define is one a reader must IGNORE, which is what leaving it
      # unmatched here does.
      #
      # So the names are enumerated, split by arity, rather than matched
      # by stem. Nothing standard is lost: every structural comment the
      # old stems reached is named below.
      #
      #   ARGUMENT keywords take operands, so the colon is required.
      #   `%%Page:` opens the body -- and `%%Pages:` is a genuine header
      #   comment, which is why `Page` may not simply prefix-match.
      #   `%%BeginDocument:` is followed by a CHILD's header,
      #   `%%BeginData:` declares the lines after it opaque, so a
      #   `%%BoundingBox` inside one is bytes that happen to look like a
      #   comment. Every `%%Include<X>:` form names a resource and cannot
      #   appear in a header at all.
      #
      #   BARE keywords take none, so a colon after one makes it a
      #   different, unknown comment. `%%Trailer`, `%%PageTrailer` and
      #   `%%EOF` open the trailer, a page's own trailer, and end the
      #   document. `%%EndProlog` and `%%EndSetup` are the closers
      #   reachable while the header is still being read, since DSC
      #   allows either alone for an empty section.
      #
      # `%%EndComments` is deliberately absent from both lists. Bare, it
      # is the sentinel and `HeaderScanner#classify` tests for it first;
      # with a colon it is neither that sentinel nor any other DSC comment,
      # and matching it as a section closer ended the header on it.
      ARGUMENT_KEYWORDS = %w[
        Page
        BeginDocument BeginBinary BeginData BeginFeature BeginFile
        BeginFont BeginProcSet BeginResource BeginPreview
        BeginExitServer BeginEmulation BeginPaperSize BeginObject
        BeginCustomColor BeginProcessColor
        IncludeDocument IncludeFeature IncludeFile IncludeFont
        IncludeProcSet IncludeResource
      ].freeze

      BARE_KEYWORDS = %w[
        BeginProlog EndProlog BeginSetup EndSetup
        BeginPageSetup EndPageSetup BeginDefaults EndDefaults
        EndDocument EndBinary EndData EndFeature EndFile EndFont
        EndProcSet EndResource EndPreview EndExitServer EndEmulation
        EndPaperSize EndObject EndCustomColor EndProcessColor
        PageTrailer Trailer EOF
      ].freeze

      # A bare keyword ends at whitespace or at the end of its line, and
      # at nothing else -- which is why `%%Page-Bogus` and
      # `%%EndComments-Bogus` stay ordinary comments. `\b` got this
      # wrong: it treats the `-` as a boundary and dropped the whole
      # header behind such a line.
      BARE_END = /(?=[\t ]|\r|\n|\z)/

      # Query constructs are the forward-extensible `%%?Begin...` and
      # `%%?End...` families. The `%%?` prefix alone is not structural:
      # an unknown comment such as `%%?FutureHeader` is ignored like any
      # other unrecognised DSC comment.
      QUERY_PREFIXES = %w[?Begin ?End].freeze

      ARGUMENT_PART = /\A%%(?:#{Regexp.union(ARGUMENT_KEYWORDS)}):/
      BARE_PART = /\A%%(?:#{Regexp.union(BARE_KEYWORDS)})#{BARE_END}/
      QUERY_PART = /\A%%(?:#{Regexp.union(QUERY_PREFIXES)})/

      OTHER_PART = Regexp.union(
        ARGUMENT_PART,
        BARE_PART,
        QUERY_PART
      )

      # A partial line has no trustworthy end-of-string delimiter. These
      # forms are decisive before its terminator arrives: argument comments
      # once their colon is present, bare comments once real whitespace is
      # present, and either query-family prefix.
      PARTIAL_OTHER_PART = Regexp.union(
        ARGUMENT_PART,
        /\A%%(?:#{Regexp.union(BARE_KEYWORDS)})[\t \r\n]/,
        QUERY_PART
      )

      # Enough bytes to decide every structural prefix above. Deriving it
      # from the vocabulary keeps a future longer keyword from silently
      # making the partial-line scan stop before its colon or whitespace.
      PARTIAL_PREFIX_BYTES = (
        ARGUMENT_KEYWORDS.map { |keyword| "%%#{keyword}:" } +
        BARE_KEYWORDS.map { |keyword| "%%#{keyword} " } +
        QUERY_PREFIXES.map { |prefix| "%%#{prefix}" }
      ).map(&:bytesize).max
    end

    # Cursor state for the DSC header reader. Keeping it outside `Dsc`
    # separates the mutable stream walk from the framing predicates and
    # declaration lookups that remain module functions there.
    class HeaderScanner
      def initialize
        @bytes = +"".b
        @line_start = 0
        @search_from = 0
        @header_end = nil
      end

      def append(chunk)
        @bytes << chunk
        scan(final: false)
        self
      end

      def finish
        scan(final: true)
        @header_end = @line_start if @header_end.nil?
        self
      end

      def done?
        !@header_end.nil?
      end

      def header
        @bytes.byteslice(0, @header_end) if done?
      end

      private

      def scan(final:)
        scan_complete_lines(final)
        return if done?

        final ? scan_final_line : scan_partial_line
      end

      def scan_complete_lines(final)
        while (ending = @bytes.index(Dsc::LINE_BREAK, @search_from))
          return wait_on_cr(ending) if pending_cr?(ending, final)

          classify(line_end(ending))
          return if done?
        end
        @search_from = @bytes.bytesize
      end

      def pending_cr?(ending, final)
        !final && @bytes.getbyte(ending) == 13 && ending + 1 == @bytes.bytesize
      end

      def wait_on_cr(ending)
        @search_from = ending
      end

      def line_end(ending)
        crlf = @bytes.getbyte(ending) == 13 && @bytes.getbyte(ending + 1) == 10
        ending + (crlf ? 2 : 1)
      end

      def classify(line_end)
        line = @bytes.byteslice(@line_start, line_end - @line_start)
        if Dsc::HEADER_END.match?(line)
          @header_end = line_end
        elsif @line_start.positive? && !Dsc.header_line?(line)
          @header_end = @line_start
        else
          @line_start = line_end
          @search_from = line_end
        end
      end

      def scan_final_line
        classify(@bytes.bytesize) if @line_start < @bytes.bytesize
        @header_end = @line_start if @header_end.nil?
      end

      def scan_partial_line
        return unless @line_start.positive? && @line_start < @bytes.bytesize

        prefix = @bytes.byteslice(@line_start, DscKeywords::PARTIAL_PREFIX_BYTES)
        @header_end = @line_start if Dsc.partial_boundary?(prefix)
      end
    end

    # Finds the PostScript section of a source and feeds only that section to
    # the stateful scanner, one bounded probe at a time. Binary-preview EPS
    # files are reframed to the offset and length declared by their wrapper.
    module DscHeader
      def self.signed_header(raw, signature, probe_bytes)
        if raw.respond_to?(:read)
          io_header(raw, signature, probe_bytes)
        else
          string_header(raw, signature, probe_bytes)
        end
      end

      def self.io_header(io, signature, probe_bytes)
        first = io.read(probe_bytes) || "".b
        return scan_io(io, first, probe_bytes) if signed?(first, signature)

        range = EpsBinary.postscript_range(first, io.size)
        return nil unless range

        offset, length = range
        io.seek(offset)
        first = io.read([probe_bytes, length].min) || "".b
        return nil unless signed?(first, signature)

        scan_io(io, first, probe_bytes, length - first.bytesize)
      end

      def self.scan_io(io, first, probe_bytes, remaining = nil)
        scanner = HeaderScanner.new.append(first)
        until scanner.done?
          read = read_io_chunk(io, probe_bytes, remaining)
          break unless read

          chunk, remaining = read
          scanner.append(chunk)
        end
        scanner.finish unless scanner.done?
        scanner.header
      end

      def self.read_io_chunk(io, probe_bytes, remaining)
        return nil if remaining&.zero?

        amount = [probe_bytes, remaining || probe_bytes].min
        bytes = io.read(amount)
        return nil if bytes.nil? || bytes.empty?

        [bytes, remaining && (remaining - bytes.bytesize)]
      end

      def self.string_header(raw, signature, probe_bytes)
        return scan_string(raw, 0, raw.bytesize, probe_bytes) if signed?(raw, signature)

        range = EpsBinary.postscript_range(raw, raw.bytesize)
        return nil unless range

        offset, length = range
        return nil if length < signature.bytesize
        return nil unless signed?(raw.byteslice(offset, signature.bytesize), signature)

        scan_string(raw, offset, length, probe_bytes)
      end

      def self.scan_string(raw, offset, length, probe_bytes)
        scanner = HeaderScanner.new
        limit = offset + length
        until scanner.done? || offset >= limit
          amount = [probe_bytes, limit - offset].min
          scanner.append(raw.byteslice(offset, amount))
          offset += amount
        end
        scanner.finish unless scanner.done?
        scanner.header
      end

      def self.signed?(bytes, signature)
        bytes.byteslice(0, signature.bytesize) == signature
      end
    end

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

      # DSC's own padding, and its own line terminators. Nothing wider:
      # `String#strip` also removes NUL, VT and FF, none of which DSC
      # admits as whitespace, so `%%BoundingBox: 0 0 100 50\0` reached
      # the anchored grammar with the NUL already gone and published a
      # box from a line the file never legally declared.
      PADDING = /\A[ \t]+/
      TERMINATOR = /[ \t]*(?:\r\n|\r|\n)?\z/

      # A `%%+` line continues the comment above it. 0.2.0 does not
      # reconstruct the logical value -- it puts the continuation in
      # `custom` and leaves the first fragment in the field -- so
      # publishing that fragment reports a truncated value as a complete
      # one. The field is omitted instead.
      CONTINUATION = /\A%%\+/
      LINE_BREAK = /[\r\n]/

      def self.header_line?(line)
        HEADER_LINE.match?(line) && !DscKeywords::OTHER_PART.match?(line)
      end

      # A partial body's first line may never terminate, so wait only while
      # its prefix can still become a header comment or an exact boundary.
      def self.partial_boundary?(prefix)
        return true unless prefix.start_with?("%")
        return false if prefix.bytesize == 1
        return true unless HEADER_LINE.match?(prefix)

        DscKeywords::PARTIAL_OTHER_PART.match?(prefix)
      end

      # The header's own lines, on DSC's three boundaries. Every lookup
      # below goes through it, so no two of them can disagree about
      # which line is the first declaration.
      def self.lines(source)
        source.scan(LINE)
      end

      # What marks a line as declaring `name`. DSC makes the colon part
      # of the keyword, so it is part of the prefix. Stated once:
      # `continued?`, `disputed?` and `first_text` must not disagree
      # about which line is the first declaration, and they did while
      # two of them carried their own copy of this test.
      def self.declares?(line, name)
        line.start_with?("%%#{name}:")
      end

      # The trimmed text of EVERY `%%<name>:` line, in order.
      def self.declarations(header, name)
        header.filter_map do |line|
          trim(line.delete_prefix("%%#{name}:")) if declares?(line, name)
        end
      end

      # Whether the header declares `name` more than once, disagreeing
      # with itself.
      #
      # DSC gives precedence to the first occurrence, so a later one is
      # ignored -- but a file that declares the same comment twice with
      # different text has not said one thing, and this handler declines
      # to pick between them.
      #
      # This used to be inferred rather than checked: 0.2.0 is last-wins,
      # so a repeated comment left the delegate holding a value that
      # disagreed with the first declaration, and the field fell to the
      # equality check in `box` and `authoritative`. That inference was
      # wrong in two directions. It only held for the repeats 0.2.0
      # RECOGNISES -- a later `%%BoundingBox: (atend)` is not one, so the
      # delegate kept the earlier value and agreed with itself -- and
      # making it cost the delegate every repeated line, which is the
      # quadratic `filter` exists to stop paying.
      def self.disputed?(header, name)
        declarations(header, name).uniq.size > 1
      end

      # Whether the header states `name` once and states it whole, which
      # is what every published field needs of it: not continued by a
      # `%%+`, since 0.2.0 leaves only the first fragment behind, and not
      # repeated with text that disagrees with itself.
      #
      # One predicate rather than the two guards repeated at both call
      # sites: a box and a scalar field ask the same question of the
      # header, and asking it in two places invited them to drift.
      # Scanned once and shared: `continued?` and `disputed?` ask two
      # questions of the same header, and splitting the scan doubled it
      # for no answer either one needed alone.
      def self.settled?(source, name)
        header = lines(source)
        !continued?(header, name) && !disputed?(header, name)
      end

      # Whether the first `%%<name>:` line is continued by a `%%+`.
      def self.continued?(header, name)
        index = header.index { |line| declares?(line, name) }
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
        declarations(lines(source), name).first
      end

      def self.trim(text)
        text.sub(PADDING, "").sub(TERMINATOR, "")
      end

      # `source`, reduced to at most one line per thing the delegate is
      # asked about: the FIRST `%!` line, the FIRST `%%<name>:` line for
      # each name in `names`, and the `%%EndComments` sentinel.
      #
      # **The count is the bound, not the name.** 0.2.0 merges every
      # comment it does not recognise into a growing `custom` hash and
      # duplicates that hash on each merge, so its cost is quadratic in
      # the number of comments it fails to read. Keeping every occurrence
      # of a whitelisted name left that cost fully reachable -- the name
      # was bounded, the count was not, and whether a line landed in
      # `custom` turned on its VALUE. Measured at 16,000 comments:
      # `%%BoundingBox: (atend)` 1.823s (DSC-valid, deferring the box to
      # the trailer, which 0.2.0 does not recognise), a junk
      # `%%HiResBoundingBox` 1.775s, a junk `%%LanguageLevel` 1.117s, and
      # repeated `%!` lines 340 KB of delegate input.
      #
      # Keeping only the first occurrence closes all of them at once, and
      # closes the shapes nobody has thought of yet, because this filter
      # never looks at a value -- only at how many times a name has been
      # seen. What reaches the delegate is at most `names.size + 2`
      # lines, whatever the header contains.
      #
      # Dropping the later occurrences is what DSC says to do anyway: it
      # gives precedence to the FIRST occurrence of a header comment, and
      # `first_text` and `declaration` already read only that one. The
      # repeated declarations still have a say in whether a field is
      # published, but `disputed?` asks them here, from the file's own
      # bytes, instead of making the delegate parse them to find out.
      #
      # `%%+` is dropped unconditionally, never kept even right behind a
      # comment that IS kept -- measured, 0.2.0 does not attach a
      # continuation to whichever comment preceded it at all: every
      # `%%+` line lands in `custom` regardless of context, the same
      # bucket an unrecognised comment does. A field this handler reads
      # keeps only its first fragment either way (0.2.0 never
      # reconstructs the continued value), so a kept field's own
      # continuations are as unread as an unrecognised comment's.
      def self.filter(source, names)
        keyword = /\A%%(#{Regexp.union(names)}):/
        seen = {}
        lines(source).each_with_object(+"") do |line, kept|
          key = kept_key(line, keyword)
          next if key.nil? || seen.key?(key)

          seen[key] = true
          kept << line
        end
      end

      # What `line` would occupy in the filtered header, or nil for a
      # line the delegate is never asked about. Two lines sharing a key
      # are the same declaration repeated, and only the first is kept.
      def self.kept_key(line, keyword)
        return nil if CONTINUATION.match?(line)
        return :version if line.start_with?("%!")
        return :sentinel if HEADER_END.match?(line)

        matched = keyword.match(line)
        matched && matched[1]
      end

      # The four operands of that line, each well-formed in the grammar
      # its own comment takes -- integers for `%%BoundingBox`, reals for
      # `%%HiResBoundingBox`.
      def self.declaration(source, name)
        text = first_text(source, name)
        return nil unless text

        operands = DscNumbers::GRAMMARS.fetch(name).match(text)
        return nil unless operands

        operands.captures.map { |value| Float(value, exception: false) }
      end
    end

    private_constant :Dsc, :DscHeader, :DscKeywords, :DscNumbers, :HeaderScanner

    # Reports a PostScript program's DSC header: dimensions from the
    # bounding box, and the comments that 0.2.0 actually populates.
    #
    # `:eps` and `:ps` share this handler and differ only in what the
    # detector called them. `image.format` supplies the reported format,
    # so one class reports both correctly.
    class Postscript < Base
      formats :eps, :ps

      # The detector's own PostScript-section signature, not a second copy
      # of it. A plain file carries it at byte zero; a DOS EPS carries it
      # at the offset shared `EpsBinary` framing declares.
      #
      # `Postscript.parse` succeeds on "not postscript at all", so the
      # delegate not raising says nothing (D17) -- exactly as it said
      # nothing for PNG's chunk reader. Anchored, not `include?` and not
      # `lstrip`: a leading space or newline means the file does not
      # start with a header.
      SIGNATURE = Detector::POSTSCRIPT_SIGNATURE

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
      # 20 seconds to parse. Nothing here ever reads `custom`.
      #
      # Naming the six is only half of it: `Dsc.filter` also keeps just
      # the FIRST line for each, so the delegate sees a bounded number of
      # lines rather than a bounded set of names. Six names with no count
      # behind them left the same quadratic fully reachable through a
      # repeated whitelisted comment.
      FIELD_COMMENTS = (BOX_COMMENTS.values + %w[Title Creator CreationDate LanguageLevel]).freeze

      # The most a single probe reads before checking whether the header
      # ended inside it. Generous for the common case -- a handful of
      # scalar comments and a box are a few hundred bytes -- and not a
      # ceiling: the scanner reads past it when a real header runs
      # longer, exactly the 629 KB case `FIELD_COMMENTS` exists for.
      HEADER_PROBE_BYTES = 8192

      private_constant :SIGNATURE, :BOX_COMMENTS,
                       :FIELD_COMMENTS, :HEADER_PROBE_BYTES,
                       :ISSUE_CODE, :ISSUE_MESSAGE

      # `image.content` would cost a path-born image a file-sized
      # allocation it retains for the image's whole lifetime, for a
      # handler that reads only the header -- measured on a large body,
      # +file-size RSS and the body kept alive -- so this goes through
      # `with_source` instead, the same reader `Handlers::Svg` uses for
      # the same reason.
      def inspection(image)
        source = image.with_source { DscHeader.signed_header(_1, SIGNATURE, HEADER_PROBE_BYTES) }
        return unreadable(image) unless source

        header = read_header(source)
        return unreadable(image) unless header

        readable(image, header, source)
      end

      private

      def read_header(source)
        require "postscript"

        begin
          ::Postscript.parse(Dsc.filter(source, FIELD_COMMENTS)).header
        rescue ::Postscript::ParseError
          nil
        end
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
      # "Usable" is what `spans` accepts: both spans finite AND
      # non-negative. A box that fails on ONE axis is rejected whole --
      # taking width from the box whose height was just refused would
      # report a rectangle no one declared.
      def usable_spans(boxes)
        [boxes["hires_bounding_box"], boxes["bounding_box"]]
          .filter_map { |box| spans(box) }
          .first
      end

      # A box is published only when the delegate's four Floats match the
      # four operands of the FIRST declaration in the header, each of
      # which is well-formed in its own comment's grammar -- integers for
      # `%%BoundingBox`, reals for `%%HiResBoundingBox`.
      #
      # Two rules meet here. The delegate's numbers cannot be trusted on
      # their own, because its grammar fabricates finite values out of
      # lexemes like `e` -- so they must match the operands of the first
      # declaration, each well-formed in that grammar. And a header that
      # declares the box twice, disagreeing with itself, has not stated
      # one rectangle, so `disputed?` refuses it rather than picking.
      #
      # `Dsc.filter` hands the delegate only the first declaration, so
      # the value here can only have come from that one. It used to be
      # the equality check that established this, by catching 0.2.0's
      # last-wins value disagreeing -- but that held only for repeats
      # 0.2.0 recognises, and it cost the delegate every repeated line.
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
        # DSC allows `%%+` after ANY structuring comment, boxes included,
        # and a header may declare the box twice. Neither leaves one
        # rectangle stated: 0.2.0 keeps only a continued box's first
        # fragment, and a repeat that disagrees states two.
        return nil unless Dsc.settled?(source, name)

        operands = Dsc.declaration(source, name)
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
      # header comment, so a scalar field is refused on a disagreeing
      # repeat exactly as a box is, and is checked against the first
      # declaration's own text the same way a box is checked against its
      # first operands.
      def authoritative(value, source, name)
        return nil if value.nil?
        return nil unless Dsc.settled?(source, name)

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
        return DscNumbers.unsigned(declared) == value if value.is_a?(Integer)

        false
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

        box.dup if box.all?(&:finite?)
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
