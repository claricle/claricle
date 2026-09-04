# frozen_string_literal: true

require "emf"

require_relative "base"
require_relative "../models/inspection"
require_relative "../models/issue"
require_relative "../models/location"

module Claricle
  module Handlers
    # Record framing: where a record starts and stops, and which one ends the
    # stream.
    #
    # Beside `EmfPlus` rather than inside it: `EmfPlus` is about what an EMF+
    # carrier holds -- which record type carries it, the signature, and how
    # much payload to count -- while this is the vocabulary that walking the
    # records consults. `EmfStructure` walks the same vocabulary to a
    # different end, so a rule here changes both walks, which is why it is
    # stated once and in neither of them.
    module EmfRecords
      # EMR_EOF closes the stream.
      EOF_RECORD = 14
      # EMR_EOF is Type, Size, nPalEntries, offPalEntries and SizeLast,
      # so a shorter type-14 record is not an end of stream at all. The
      # delegate records such a record as Raw and keeps going, and a
      # carrier after it is real: measured, with nSize 8, 12 or 16 the
      # gem still finds 12 bytes of EMF+ where stopping finds none.
      EOF_RECORD_BYTES = 20
      RECORD_HEADER_BYTES = 8
      ALIGNMENT = 4

      # A record must declare a size that is aligned, at least a header
      # long, and inside what is left. Anything else means the framing is
      # broken and neither walk can continue: `EmfPlus` stops totalling, and
      # the structural pre-pass reports `emf.record_framing` at this offset.
      # The minimum also guarantees forward progress: a record declaring zero
      # would otherwise pin the walk on one offset forever.
      def self.record_at(content, offset)
        return nil if content.bytesize - offset < RECORD_HEADER_BYTES

        type, size = content.byteslice(offset, RECORD_HEADER_BYTES).unpack("VV")
        return nil if size < RECORD_HEADER_BYTES || !(size % ALIGNMENT).zero?
        return nil if size > content.bytesize - offset

        [type, size]
      end

      # 20 bytes is the MINIMUM, not the size -- a writer may pad an EMR_EOF,
      # and a bigger one still closes the stream.
      def self.eof?(type, size)
        type == EOF_RECORD && size >= EOF_RECORD_BYTES
      end
    end

    # Finds EMF+ by walking the record framing, because the delegate
    # cannot answer the question. emf 0.1.0 does not parse EMF+ at all --
    # its EMF+ parser is unimplemented, and its full pass only recognises
    # the marker and concatenates the bytes, which is close to what this
    # does. It gets the question wrong three ways. It raises NoMethodError
    # on a comment whose cbData overruns its own record, because the
    # extraction step checks cbData >= 4 without checking four bytes are
    # there. It fails outright on the valid 92- and 96-byte described
    # headers, reporting no EMF+ for files that may carry it. And it
    # counts a record's alignment padding as payload: measured, it reports
    # 4 bytes for `padded_comment.emf`, whose cbData leaves 1.
    #
    # The handler stays a wrapper -- emf still owns every substantive
    # header field. Only the marker hunt is local, and only because
    # upstream's path for it is broken.
    module EmfPlus
      # EMR_COMMENT is the only record type EMF+ travels in. A comment's
      # own header is iType, nSize and cbData, so its declared payload
      # begins twelve bytes in, and the signature occupies the first four
      # of those.
      COMMENT_RECORD = 70
      COMMENT_HEADER_BYTES = 12
      SIGNATURE = "EMF+".b.freeze

      # A distinct marker rather than a zero advance. Overloading zero
      # would make a malformed record declaring no size look like a clean
      # end of stream, which retires the guard that catches it.
      END_OF_STREAM = :end_of_stream

      # Bytes of EMF+ payload, or **nil when the stream was over the byte
      # limit and nothing was examined at all**.
      #
      # That is a different answer from zero and an earlier version
      # conflated them. Zero means the walk ran to completion and found
      # none -- including when framing broke partway, since what it read
      # before the break is still established. Nil means the walk never
      # ran, so it cannot say what the stream holds and must not report
      # absence on the strength of bytes nobody read. A stream one byte
      # over the limit can carry `EMF+` in its very first record;
      # answering zero there would be exactly that mistake.
      #
      # The byte limit matches the delegate's own:
      # `Emf::Emr::Parser::MAX_INPUT_BYTES` is the same 200 MiB and
      # refuses on the same `>`. What it buys is that the cost stops
      # growing past it.
      #
      # The iteration budget handed to `walk` is derived, not chosen. It
      # exists only so a defect in `EmfRecords.record_at` cannot spin the
      # walk on one offset forever: it refuses a record declaring fewer
      # than its eight-byte header, so every step advances at least that
      # far, and the content is at most `limit` bytes -- so
      # `limit / EmfRecords::RECORD_HEADER_BYTES` steps always outlast the
      # bytes and the budget can never bind first.
      #
      # It used to be a flat 500,000 and that WAS a ceiling a real file
      # could hit. EMR_SETMETARGN is a valid parameterless 8-byte record
      # and EMR_HEADER's record count is an unsigned 32-bit field, so an
      # internally consistent stream of 500,000 of them is ordinary EMF
      # and only 4.0 MiB long. Measured: it reported no EMF+ verdict at
      # all, and 499,999 of them reported `emf_plus_present: false`.
      #
      # The byte limit is therefore the only thing bounding CPU, and what
      # that costs is worth writing down. Measured on a stream of
      # minimum-size records: 3.8 MiB walks in 0.58s and 20.0 MiB in
      # 3.57s, so the 200 MiB boundary is around 36 seconds. The flat
      # budget held that near 0.6s -- and refused ordinary files to do
      # it. Answering a 4 MiB file correctly is worth the worst case.
      def self.size(content, declared, limit)
        return nil if content.bytesize > limit

        walk(content, declared, limit / EmfRecords::RECORD_HEADER_BYTES)
      end

      # Broken framing stops the walk and keeps what came before it.
      # Discarding a validated total was a false negative: measured, a
      # stream whose final EMR_EOF declares nSize 0 still carries two
      # intact carriers, and the delegate reports their 40 bytes while
      # an all-or-nothing rule reported none. Every record counted here
      # had its own framing checked before it was counted, so a later
      # break says nothing about the ones already read.
      #
      # The line after the loop is the budget running out. With the budget
      # derived from the byte limit it cannot be reached at all: offset
      # starts at `declared`, every step adds at least
      # `EmfRecords::RECORD_HEADER_BYTES`, and `budget` is the byte limit
      # divided by that, so the end of the content always arrives first.
      # It stays written for a budget that CAN bind, which is why it asks
      # where the offset landed -- a last budgeted step that finished the
      # stream walked it completely and keeps its total, while one that
      # stopped short answers nil, because the remainder it never reached
      # might carry EMF+ and a partial total would be silent about that.
      def self.walk(content, offset, budget)
        total = 0
        budget.times do
          return total if offset >= content.bytesize

          advance = step_forward(content, offset, total)
          return total unless advance

          total, offset = advance
        end
        offset < content.bytesize ? nil : total
      end

      # A record consumed and folded into the running total, as
      # `[total, offset]`, or nil at broken framing or EMR_EOF -- the
      # two ways a step is not a record to keep walking past.
      def self.step_forward(content, offset, total)
        step = step_at(content, offset)
        return nil if step.nil? || step == END_OF_STREAM

        [total + step.first, offset + step.last]
      end

      # One record: `[payload, advance]`, `END_OF_STREAM` at EMR_EOF, or
      # nil when the framing is broken.
      def self.step_at(content, offset)
        type, size = EmfRecords.record_at(content, offset)
        return nil unless size
        return END_OF_STREAM if EmfRecords.eof?(type, size)

        [payload_of(content, offset, type, size), size]
      end

      # Only the bytes the comment declares are inspected, and only the
      # declared count is added -- a record's padding is not payload.
      #
      # A comment whose `cbData` overruns its own record contributes
      # nothing and does NOT stop the walk. MS-EMF keeps the whole-record
      # `Size` and the inner `DataSize` separate, and the outer size was
      # already validated as aligned and in bounds -- so it still proves
      # where the next record begins, whatever the inner field claims.
      # Measured: stopping there reported no EMF+ for a stream whose
      # SECOND carrier was intact and which the delegate reads as 12
      # bytes. That is the same mistake as discarding a validated total
      # on a later break, one level down.
      #
      # The record minimum is load-bearing, not belt-and-braces: an
      # 8-byte comment record standing LAST in the stream has no bytes
      # after its header, so `unpack1` gives nil and the bound below
      # raises NoMethodError.
      #
      # The `cbData` minimum is a CORRECTNESS guard. It was written down
      # as a fast path and that was wrong: the signature is sliced from
      # the RECORD, not from the declared run, so a comment declaring
      # fewer than four bytes still gets four read out of it, matches,
      # and the subtraction below goes NEGATIVE. Measured on a 16-byte
      # comment declaring `cbData` 1 in front of an `EMF+` marker: with
      # the line removed the handler reported `emf_plus_present` true
      # and `emf_plus_bytes` -3.
      #
      # It also has to sit ahead of the slice, because reaching the
      # comparison costs two strings for a record that cannot match: the
      # four-byte slice and its `.b` copy. Measured over 20 MiB of
      # 12-byte comments declaring `cbData` 0 -- the densest a stream can
      # be, 1,747,626 records -- moving the check below the slice added
      # 3,495,252 objects, exactly two per record.
      #
      # Only the signature is sliced, never the declared payload, and a
      # comment may declare nearly the whole stream. `byteslice` COPIES
      # at that size: measured, taking 180 MiB out of a 200 MiB string
      # allocated 188,743,721 bytes and grew malloc by the same again.
      # Four bytes costs 40. Slicing the declared run instead would
      # therefore copy the carrier, not point into it.
      def self.payload_of(content, offset, type, size)
        return 0 unless type == COMMENT_RECORD
        return 0 if size < COMMENT_HEADER_BYTES

        declared = content.byteslice(offset + EmfRecords::RECORD_HEADER_BYTES, 4)
                          .unpack1("V")
        return 0 if declared > size - COMMENT_HEADER_BYTES
        return 0 if declared < SIGNATURE.bytesize

        signature = content.byteslice(offset + COMMENT_HEADER_BYTES, SIGNATURE.bytesize)
        return 0 unless signature.b == SIGNATURE

        declared - SIGNATURE.bytesize
      end

      private_class_method :walk, :step_at, :step_forward, :payload_of
    end

    # Structural pre-pass: how the record stream ends. Three ways it does not
    # end properly -- framing breaks, the stream runs out before an EMR_EOF,
    # or bytes follow the EMR_EOF -- reported as issues the conform report
    # will carry. Bytes are never read here beyond what `EmfRecords.record_at`
    # slices; the caller owns the read and its bound.
    module EmfStructure
      # `declared` is the caller's contract, not this method's to police: it
      # arrives from `declared_size`, which yields an Integer, 4-aligned and
      # at least MINIMUM_HEADER. Non-negative is the property this walk rests
      # on, and it is worth being exact about what a negative would cost,
      # because it does not fail one way. Measured on `valid.emf`: -1 raises
      # NoMethodError, -16 raises Lutaml::Model::ValidationError from a
      # negative `byte_offset`, and only -88 produces the quiet nonsense of a
      # `byteslice` counting from the end. Two of those three escape a method
      # whose contract is to RETURN issues. That is a reason to keep the
      # contract, not to add a check for an input the handler cannot deliver.
      #
      # `declared` is NOT guaranteed to be inside the bytes on hand.
      # `declared_size` bounds it by `available`, which is the read's own
      # length under the scan limit but the file's stat above it -- so a stat
      # reading high admits a declaration the content cannot hold, the
      # residual written down at `declared_size` itself. No guard is needed
      # for that either: the loop condition is false from the first step and
      # the answer is `[missing_eof]`.
      #
      # nil means "not examined": over the byte limit nothing was read, and
      # `[]` would be the stronger claim that the stream ends properly. The
      # guard is deliberately the same idiom as `EmfPlus.size`'s -- same `>`,
      # same figure, same reason. That the two walks therefore refuse the same
      # streams is a claim no spec can pin while this module has no caller;
      # the PR that wires it owns pinning it.
      #
      # The walk's bound is the loop condition, so `record_at` is never
      # called at `offset == content.bytesize`: a stream ending exactly on a
      # record boundary is a missing EOF, not broken framing.
      #
      # No iteration budget, unlike `EmfPlus.walk`. That budget exists to stop
      # a defect pinning the walk on one offset forever; here `EmfRecords.record_at`
      # already refuses a record declaring fewer than its eight-byte header, so
      # every step advances at least eight bytes and the byte bound is
      # sufficient on its own.
      def self.issues(content, declared, limit)
        return nil if content.bytesize > limit

        offset = declared
        while offset < content.bytesize
          type, size = EmfRecords.record_at(content, offset)
          return [framing(offset)] if size.nil?
          return trailing(content, offset + size) if EmfRecords.eof?(type, size)

          offset += size
        end
        [missing_eof]
      end

      def self.trailing(content, at)
        return [] if at >= content.bytesize

        count = content.bytesize - at
        noun = count == 1 ? "byte follows" : "bytes follow"
        [issue("emf.trailing_bytes", "#{count} #{noun} the EMR_EOF record",
               Models::Location.new(byte_offset: at, byte_length: count))]
      end

      # `record_at` refuses for four different reasons and returns a bare nil
      # carrying none of them, so the message names the offset and no reason.
      def self.framing(at)
        issue("emf.record_framing", "EMF record framing breaks at byte #{at}",
              Models::Location.new(byte_offset: at))
      end

      def self.missing_eof
        issue("emf.missing_eof", "EMF record stream ends without an EMR_EOF record", nil)
      end

      def self.issue(code, message, location)
        Models::Issue.new(severity: "error", code: code, message: message,
                          location: location)
      end

      private_class_method :trailing, :framing, :missing_eof, :issue
    end

    private_constant :EmfRecords, :EmfPlus, :EmfStructure

    # Reads an EMF header. WMF is deliberately absent: the released emf
    # parser reports "WMF parser not yet implemented" (D14), so nothing
    # registers `:wmf` and it reaches exit 3 through the registry.
    class Metafile < Base
      formats :emf

      # EMR_HEADER's declared size, a 4-byte little-endian value at a
      # fixed offset. Below the minimum there is no header to read.
      SIZE_OFFSET = 4
      MINIMUM_HEADER = 88
      ALIGNMENT = 4
      MILLIMETRES_PER_INCH = 25.4

      # Every way this delegate fails on input rather than on a defect.
      # `Emf::Error` alone, because the delegate is only ever handed a
      # normalised 88-byte header now: it can no longer be sent reading
      # past the end, which is what raised `EOFError` and `IOError` when
      # this took the declared prefix. Fuzzed over 8704 corrupted
      # headers -- every failure was an `Emf::Error`, none reached an
      # IO arm. An IOError raised AFTER the parse still propagates, and
      # a spec pins that.
      PARSE_FAILURES = [::Emf::Error].freeze

      # The delegate refuses whole streams above this, so the walk does
      # not go further than the parser it replaces would have. It bounds
      # the READ as well: nothing beyond one byte past it is ever
      # materialised, whatever the stat said the file was.
      #
      # It does not bound the HEADER. Applying it there turned a
      # fully framed 209 MB EMF with a perfectly readable 100x50 header
      # into `failed`, breaking the header-first contract this handler
      # exists to keep -- the delegate itself parses that header and
      # refuses only the full stream.
      SCAN_LIMIT = 200 * 1024 * 1024

      ISSUE_CODE = "emf.header_unreadable"
      ISSUE_MESSAGE = "EMF header could not be read"

      private_constant :SIZE_OFFSET, :MINIMUM_HEADER, :ALIGNMENT, :MILLIMETRES_PER_INCH,
                       :PARSE_FAILURES, :SCAN_LIMIT, :ISSUE_CODE, :ISSUE_MESSAGE

      # The header is parsed by the delegate; the EMF+ marker is found by
      # walking the record framing here. The delegate is not asked for the
      # second answer because it cannot give it -- see `EmfPlus.size`.
      #
      # `image.bytesize` is a `File.size` stat, and it decides ONE thing:
      # whether to bother reading past the fixed header. Every other
      # decision is made from the bytes `header_prefix` actually returned,
      # because the stat and the read are separate filesystem calls and
      # the file is free to change between them. A stat reading high only
      # makes this under-report, which is the safe direction. A stat
      # reading low used to send the whole stream through `image.content`
      # -- an unbounded `File.binread` -- so a file that grew after the
      # stat was materialised whole, defeating the limit for exactly the
      # streams it exists to bound.
      def inspection(image)
        bytesize = image.bytesize
        oversized = bytesize > SCAN_LIMIT
        prefix = header_prefix(image, oversized)
        declared = declared_size(prefix, oversized ? bytesize : prefix.bytesize)
        return unreadable(image) unless declared

        header = read_header(prefix)
        return unreadable(image) unless header

        readable(image, header, emf_plus_bytes(prefix, oversized, declared))
      end

      private

      # Every byte the rest of the inspection is allowed to rest on, and
      # never more than SCAN_LIMIT + 1 of them.
      #
      # Over the stat's limit that is the fixed header alone: the walk is
      # skipped anyway, so nothing past the header is worth reading.
      # Under it, one byte more than the walk can handle. Getting that
      # many back proves the stream is over the limit whatever the stat
      # said; getting fewer proves these bytes ARE the whole stream. So
      # both answers come from the read rather than from a stat taken
      # before it, and memory is bounded either way.
      def header_prefix(image, oversized)
        length = oversized ? MINIMUM_HEADER : SCAN_LIMIT + 1
        image.with_source { |source| bounded_read(source, length) }
      end

      # Takes an IO or a String, because `with_source` hands over
      # whichever the image is made of: an open file for a path-born
      # image, the bytes already in hand for a content-born one.
      #
      # Bounding a String costs nothing when there is nothing to cut.
      # Measured on 20 MB: a `byteslice` covering the whole string SHARES
      # it -- 40 bytes of object, no copy -- and only a partial one
      # copies, which here is the 88-byte header alone. So the String arm
      # needs no shortcut for the content-born image that is already
      # inside the bound.
      #
      # `IO#read` answers nil at end of stream for a non-zero length --
      # measured on an empty file -- and an empty stream still has to
      # reach `declared_size` as a String.
      def bounded_read(source, length)
        return source.read(length) || "".b if source.respond_to?(:read)

        source.byteslice(0, length)
      end

      # Over the scan limit `prefix` is only the fixed header, so there
      # is no walk to ask for. Under it the question is still
      # `EmfPlus.size`'s to refuse: a prefix that came back at
      # SCAN_LIMIT + 1 is a stream over the limit however the stat read,
      # and that call's own bytesize check is what catches it.
      def emf_plus_bytes(prefix, oversized, declared)
        oversized ? nil : EmfPlus.size(prefix, declared, SCAN_LIMIT)
      end

      # The delegate is handed the fixed 88-byte header with `nSize`
      # normalised to 88, rather than the declared prefix. Any `nSize`
      # above 88 makes emf 0.1.0 read the Win95 optional fields --
      # cbPixelFormat, offPixelFormat and bOpenGL, twelve more bytes --
      # and above 100 szlMicrometers as well, eight more. So it needs a
      # full 100 bytes once `nSize` passes 88, and 108 once it passes
      # 100, which leaves exactly three aligned sizes with no layout it
      # can map onto: 92, 96 and 104 each raise EOFError. Swept 88 to
      # 356, on a stream long enough for every one.
      #
      # Those three are the ones that matter. A standards-valid header
      # carrying a short description lands on them, because MS-EMF places
      # the description directly after the fixed 88 bytes. Measured: a
      # 92-byte header fails on the declared prefix AND on the full
      # stream, so re-slicing cannot rescue it.
      #
      # Every field reported here lives inside those 88 bytes and `nSize` is
      # not one of them, so normalising it changes nothing that is read --
      # verified to agree with the delegate figure-for-figure on the files
      # it parses natively. The real `nSize` is still validated, by
      # `declared_size`, before this runs.
      def read_header(prefix)
        ::Emf.parse(fixed_header(prefix)).header
      rescue *PARSE_FAILURES
        nil
      end

      # `header_prefix` guarantees BINARY -- an open file in "rb" mode,
      # the image's own binary content, or `"".b` -- which matters here
      # because `String#[]=` indexes by CHARACTER, and a UTF-16LE tag
      # would make this raise on a file the delegate reads correctly.
      # The caller's string is never written to. `byteslice` returns a
      # NEW String either way -- measured, a full-cover one SHARES the
      # buffer at 40 bytes of object while a partial one copies -- and a
      # shared buffer unshares on the first write, so the `[]=` below
      # lands on this copy alone. Measured: mutating a full-cover slice
      # of `"ABCDEFGH"` left the source unchanged.
      def fixed_header(prefix)
        header = prefix.byteslice(0, MINIMUM_HEADER)
        header[SIZE_OFFSET, 4] = [MINIMUM_HEADER].pack("V")
        header
      end

      # The declared header size, or nil when the stream does not declare a
      # usable one. EMF control-record sizes are multiples of four: without
      # that check an nSize of 109 parses as a header -- the delegate
      # reports ok? true and the full baseline metadata -- while the record
      # stream is framed from an impossible offset. This is record framing,
      # not the nBytes/nRecords/nHandles conformance that item 03 owns.
      #
      # `available` is how many bytes the stream is KNOWN to hold, and the
      # caller supplies it differently on each branch. Under the scan
      # limit it is `prefix.bytesize`, because there the prefix IS the
      # read: either the whole stream or SCAN_LIMIT + 1 bytes of it, and
      # both are lengths the stream really has. Over the limit the prefix
      # is deliberately only the fixed 88 bytes while a legal header may
      # declare 108, so `prefix.bytesize` would reject perfectly good
      # large files; there the stat is the only figure there is. The
      # residual is that a stat reading high over a short file can still
      # admit a declaration the file cannot hold.
      #
      # Measuring against the stat on BOTH branches was the defect:
      # measured, a stat of 200 over the 99-byte `declared_100_have_99`
      # reported `ok` for a header declaring 100, and the walk then began
      # at offset 100 -- past the real end -- and called that a completed
      # scan.
      #
      # The length guard has to be on `prefix`, not on `available`.
      # `byteslice(4, 4)` answers nil for a prefix under four bytes and a
      # short String for one under eight, so an empty or 1-3 byte read
      # raised `NoMethodError` before any nil `unpack1` could be checked
      # for -- measured, by stubbing a stat over the limit while the file
      # underneath is 0, 1 or 3 bytes long. At MINIMUM_HEADER and up the
      # field is always four bytes, so `unpack1` always gives an Integer.
      def declared_size(prefix, available)
        return nil if prefix.bytesize < MINIMUM_HEADER

        declared = prefix.byteslice(SIZE_OFFSET, 4).unpack1("V")
        return nil if declared < MINIMUM_HEADER
        return nil if declared > available || !(declared % ALIGNMENT).zero?

        declared
      end

      def readable(image, header, emf_plus_bytes)
        Models::Inspection.new(
          format: image.format.to_s,
          # `Rect` gives plain Integers, so this is `to_f` on an Integer;
          # `Integer()` first only so a delegate that starts wrapping them
          # fails loudly here rather than serialising as a string.
          width: Integer(header.bounds.width).to_f,
          height: Integer(header.bounds.height).to_f,
          dpi: dpi(header),
          meta: metadata(header, emf_plus_bytes),
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

      def dpi(header)
        pixels = size_of(header.device_pixels)
        millimetres = size_of(header.device_mm)
        return nil unless measurable?(pixels) && measurable?(millimetres)
        return nil unless resolution_uniform?(pixels, millimetres)

        (pixels["width"] / (millimetres["width"] / MILLIMETRES_PER_INCH)).round(2)
      end

      # Positive, not merely non-zero, and on BOTH pairs.
      #
      # MS-EMF's SIZEL holds signed 32-bit fields, and the delegate hands
      # them back signed -- `Size#cx` is a `BinData::Int32le`. A negative
      # one is not a measurement, and the arithmetic below divides it
      # happily: measured on `valid.emf`, device_mm -26 x -13 reported
      # -97.69 dpi, and negating the pixels as well reported a confident
      # 97.69 out of two nonsense values cancelling.
      #
      # Zero is here for two different reasons. Zero millimetres divides
      # by zero and the answer is Infinity, which `to_json` refuses
      # outright. Zero pixels divides fine and reported a dpi of 0.0,
      # which reads as a measured resolution rather than a missing one.
      def measurable?(size)
        size["width"].positive? && size["height"].positive?
      end

      # A cross product, in integers: Float equality would be fragile,
      # and comparing the AXES rather than the ratios would be wrong.
      # Our own baseline is 100x50 pixels over 26x13 millimetres --
      # unequal on both axes, with both ratios at 97.69.
      def resolution_uniform?(pixels, millimetres)
        pixels["width"] * millimetres["height"] == pixels["height"] * millimetres["width"]
      end

      # Coerced because SOME of these are BinData wrappers, which behave
      # like Integers and serialize as JSON strings. Measured across every
      # fixture: `Size#cx`/`#cy`, `n_records` and `n_handles` are
      # `BinData::Int32le`/`Uint32le`/`Uint16le` and render as `"100"`;
      # `Rect#width`/`#height` are already plain Integers, so `Integer()`
      # is a no-op there.
      #
      # It stays uniform rather than applied selectively: `size_of` serves
      # both `Rect` and `Size`, and one of them needs it. Splitting the
      # coercion by shape would make the two callers disagree about a
      # value the delegate is free to change the class of.
      def metadata(header, emf_plus_bytes)
        {
          "frame" => size_of(header.frame),
          "device_pixels" => size_of(header.device_pixels),
          "device_mm" => size_of(header.device_mm),
          "n_records" => Integer(header.n_records),
          "n_handles" => Integer(header.n_handles)
        }.merge(emf_plus(emf_plus_bytes))
      end

      def size_of(value)
        width = value.respond_to?(:width) ? value.width : value.cx
        height = value.respond_to?(:height) ? value.height : value.cy
        { "width" => Integer(width), "height" => Integer(height) }
      end

      # Presence and size only, because JSON has nowhere to put packed
      # binary. It fails LOUDLY on most payloads and quietly on the rest,
      # and the quiet one is worse. Measured on `emf_plus.emf`'s 40
      # bytes: `to_json` raises `JSON::GeneratorError` under BINARY,
      # UTF-8 and UTF-16LE. Measured on `padded_comment.emf`'s four,
      # where every byte happens to be valid text: it serialises as an
      # "X" followed by three escaped NULs, which reads like a value and
      # is really a byte dump -- and under UTF-16LE those same four
      # bytes come out as TWO characters, half of them silently gone.
      # A count avoids all of it.
      #
      # Three outcomes, not two. A stream the walk never examined carries
      # NO EMF+ keys at all -- silence is the only honest report for a
      # question that was not asked, and `false` would be a claim about
      # bytes nobody read.
      #
      # Presence follows the count, so a carrier declaring `cbData` 4 --
      # the marker and nothing behind it -- reports absent rather than
      # present-with-nothing. Deliberate: that comment is not valid EMF+,
      # since the first carrier has to hold an EmfPlusHeader record, and
      # the delegate offers no better answer to copy. Measured on a
      # marker-only comment: unpadded it returns nil for `emf_plus`,
      # which is exactly how it says absent, and padded it returns the
      # padding -- four zero bytes that are not EMF+ at all.
      def emf_plus(bytes)
        return {} if bytes.nil?
        return { "emf_plus_present" => false } if bytes.zero?

        { "emf_plus_present" => true, "emf_plus_bytes" => bytes }
      end
    end
  end
end
