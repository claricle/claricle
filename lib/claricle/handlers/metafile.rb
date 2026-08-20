# frozen_string_literal: true

require "emf"

require_relative "base"
require_relative "../models/inspection"
require_relative "../models/issue"

module Claricle
  module Handlers
    # Finds EMF+ by walking the record framing, because the delegate
    # cannot answer the question. emf 0.1.0 does not parse EMF+ at all --
    # its EMF+ parser is unimplemented, and its full pass only recognises
    # the marker and concatenates the bytes, which is exactly what this
    # does. It also gets the question wrong twice: it raises NoMethodError
    # on a comment whose cbData overruns its own record, because the
    # extraction step checks cbData >= 4 without checking four bytes are
    # there; and it fails outright on the valid 92- and 96-byte described
    # headers, reporting no EMF+ for files that may carry it.
    #
    # The handler stays a wrapper -- emf still owns every substantive
    # header field. Only the marker hunt is local, and only because
    # upstream's path for it is broken.
    module EmfPlus
      # EMR_EOF closes the stream and EMR_COMMENT is the only record type
      # EMF+ travels in. A comment's own header is iType, nSize and
      # cbData, so its declared payload begins twelve bytes in, and the
      # signature occupies the first four of those.
      EOF_RECORD = 14
      # EMR_EOF is Type, Size, nPalEntries, offPalEntries and SizeLast,
      # so a shorter type-14 record is not an end of stream at all. The
      # delegate records such a record as Raw and keeps going, and a
      # carrier after it is real: measured, with nSize 8, 12 or 16 the
      # gem still finds 12 bytes of EMF+ where stopping finds none.
      EOF_RECORD_BYTES = 20
      COMMENT_RECORD = 70
      RECORD_HEADER_BYTES = 8
      COMMENT_HEADER_BYTES = 12
      SIGNATURE = "EMF+".b.freeze
      ALIGNMENT = 4

      # A distinct marker rather than a zero advance. Overloading zero
      # would make a malformed record declaring no size look like a clean
      # end of stream, which retires the guard that catches it.
      END_OF_STREAM = :end_of_stream

      # Bytes of EMF+ payload, or **nil when the walk did not run**.
      #
      # Those are different answers and an earlier version conflated
      # them. Zero means the walk ran and found none -- including when
      # framing broke partway, since what it read before the break is
      # still established. Nil means the stream is over the scan limit
      # and nothing was examined at all, which must not be reported as
      # absence: measured, a fully framed 200 MiB stream carrying `EMF+`
      # at byte 100 was reported as having none.
      #
      # The limit stays because the walk is linear in records, and a
      # 200 MiB stream of minimum-size records takes about ten seconds
      # to cross. A ten-second stall and a false negative are both bad;
      # this reports neither.
      def self.size(content, declared, limit)
        return nil if content.bytesize > limit

        walk(content, declared)
      end

      # Broken framing stops the walk and keeps what came before it.
      # Discarding a validated total was a false negative: measured, a
      # stream whose final EMR_EOF declares nSize 0 still carries two
      # intact carriers, and the delegate reports their 40 bytes while
      # an all-or-nothing rule reported none. Every record counted here
      # had its own framing checked before it was counted, so a later
      # break says nothing about the ones already read.
      def self.walk(content, offset)
        total = 0

        while offset < content.bytesize
          step = step_at(content, offset)
          break unless step
          break if step == END_OF_STREAM

          total += step.first
          offset += step.last
        end
        total
      end

      # One record: `[payload, advance]`, `END_OF_STREAM` at EMR_EOF, or
      # nil when the framing is broken.
      def self.step_at(content, offset)
        type, size = record_at(content, offset)
        return nil unless size
        return END_OF_STREAM if type == EOF_RECORD && size >= EOF_RECORD_BYTES

        [payload_of(content, offset, type, size), size]
      end

      # A record must declare a size that is aligned, at least a header
      # long, and inside what is left. Anything else means the framing is
      # broken and the walk cannot continue. The minimum also guarantees
      # forward progress: a record declaring zero would otherwise pin the
      # walk on one offset forever.
      def self.record_at(content, offset)
        return nil if content.bytesize - offset < RECORD_HEADER_BYTES

        type, size = content.byteslice(offset, RECORD_HEADER_BYTES).unpack("VV")
        return nil if size < RECORD_HEADER_BYTES || !(size % ALIGNMENT).zero?
        return nil if size > content.bytesize - offset

        [type, size]
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
      def self.payload_of(content, offset, type, size)
        return 0 unless type == COMMENT_RECORD
        return 0 if size < COMMENT_HEADER_BYTES

        declared = content.byteslice(offset + RECORD_HEADER_BYTES, 4).unpack1("V")
        return 0 if declared > size - COMMENT_HEADER_BYTES
        return 0 if declared < SIGNATURE.bytesize

        data = content.byteslice(offset + COMMENT_HEADER_BYTES, declared)
        return 0 unless data.byteslice(0, SIGNATURE.bytesize).b == SIGNATURE

        declared - SIGNATURE.bytesize
      end

      private_class_method :walk, :step_at, :record_at, :payload_of
    end

    private_constant :EmfPlus

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
      # not go further than the parser it replaces would have.
      #
      # It bounds the WALK only. Applying it to the header turned a
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
      def inspection(image)
        content = image.content
        declared = declared_size(content)
        return unreadable(image) unless declared

        header = read_header(content)
        return unreadable(image) unless header

        readable(image, header, EmfPlus.size(content, declared, SCAN_LIMIT))
      end

      private

      # The delegate is handed the fixed 88-byte header with `nSize`
      # normalised to 88, rather than the declared prefix. emf 0.1.0 reads
      # anything above 88 as the extension records, so it accepts only 88,
      # 100 and 108 and raises EOFError on the sizes in between --
      # including a standards-valid header carrying a short description,
      # which MS-EMF places directly after the fixed 88 bytes. Measured: a
      # 92-byte header fails on the declared prefix AND on the full stream,
      # so re-slicing cannot rescue it.
      #
      # Every field reported here lives inside those 88 bytes and `nSize` is
      # not one of them, so normalising it changes nothing that is read --
      # verified to agree with the delegate figure-for-figure on the files
      # it parses natively. The real `nSize` is still validated, by
      # `declared_size`, before this runs.
      def read_header(content)
        ::Emf.parse(fixed_header(content)).header
      rescue *PARSE_FAILURES
        nil
      end

      # `Image#content` guarantees BINARY, which matters here because
      # `String#[]=` indexes by CHARACTER -- a UTF-16LE tag would make
      # this raise on a file the delegate reads correctly. `byteslice`
      # always allocates, so the caller's string is never written to.
      def fixed_header(content)
        prefix = content.byteslice(0, MINIMUM_HEADER)
        prefix[SIZE_OFFSET, 4] = [MINIMUM_HEADER].pack("V")
        prefix
      end

      # The declared header size, or nil when the stream does not declare a
      # usable one. EMF control-record sizes are multiples of four: without
      # that check an nSize of 109 parses as a header -- the delegate
      # reports ok? true and the full baseline metadata -- while the record
      # stream is framed from an impossible offset. This is record framing,
      # not the nBytes/nRecords/nHandles conformance that item 03 owns.
      def declared_size(content)
        return nil if content.bytesize < MINIMUM_HEADER

        declared = content.byteslice(SIZE_OFFSET, 4).unpack1("V")
        return nil if declared.nil? || declared < MINIMUM_HEADER
        return nil if declared > content.bytesize || !(declared % ALIGNMENT).zero?

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
        return nil unless resolution_uniform?(pixels, millimetres)

        (pixels["width"] / (millimetres["width"] / MILLIMETRES_PER_INCH)).round(2)
      end

      # A cross product, in integers: Float equality would be fragile,
      # and comparing the AXES rather than the ratios would be wrong.
      # Our own baseline is 100x50 pixels over 26x13 millimetres --
      # unequal on both axes, with both ratios at 97.69.
      def resolution_uniform?(pixels, millimetres)
        return false if millimetres["width"].zero? || millimetres["height"].zero?

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

      # Presence and size only. The payload is packed binary and `to_json`
      # refuses it.
      #
      # Three outcomes, not two. A stream the walk never examined carries
      # NO EMF+ keys at all -- silence is the only honest report for a
      # question that was not asked, and `false` would be a claim about
      # bytes nobody read.
      def emf_plus(bytes)
        return {} if bytes.nil?
        return { "emf_plus_present" => false } if bytes.zero?

        { "emf_plus_present" => true, "emf_plus_bytes" => bytes }
      end
    end
  end
end
