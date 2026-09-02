# frozen_string_literal: true

require_relative "base"
require_relative "../models/inspection"
require_relative "../models/issue"

module Claricle
  module Handlers
    # Reads PNG metadata. It deliberately does not validate: png_conform's
    # ValidationService would hand us a parsed ImageInfo for free, but it
    # runs conformance checks along the way, so `inspect` would mean
    # "conforms" for PNG and "metadata" for every other format (D17).
    class Png < Base
      formats :png

      # IHDR is a fixed 13-byte layout in the PNG spec: two 4-byte
      # dimensions then five single bytes. Hand-unpacking it agrees with
      # ImageInfo on a real file, which a spec pins.
      IHDR_LAYOUT = "NNC5"
      IHDR_BYTES = 13
      PHYS_LAYOUT = "NNC"
      PHYS_BYTES = 9
      # pHYs unit 1 is pixels per metre; unit 0 means aspect ratio only,
      # so there is no physical resolution to report.
      METRE_UNIT = 1
      METRES_PER_INCH = 0.0254

      # An allowlist, not "everything except IDAT". These two chunks are
      # the only ones `gather` ever reads the payload of -- everything
      # else is stepped over, so a PNG carrying a huge ancillary chunk
      # never costs more than its own 8-byte header where the IO can
      # seek. Where it cannot, `drain` reads those bytes and throws them
      # away, so what stays bounded there is memory, not bytes read
      # (D-bounded-read).
      WANTED_CHUNKS = %w[IHDR pHYs].freeze

      # png_conform's own vocabulary, verified against ImageInfo#color_type
      # for all five types, so the two never disagree if a later slice does
      # reach for the validator. Note "palette", not "indexed" -- that is
      # the delegate's word for colour type 3.
      COLOR_SPACES = {
        0 => "grayscale",
        2 => "truecolor",
        3 => "palette",
        4 => "grayscale+alpha",
        6 => "truecolor+alpha"
      }.freeze

      # Lives out here rather than inside StructureScanner, its only
      # consumer, because the `header_at` guard added alongside it pushed
      # that class to 102 lines against Metrics/ClassLength's 100 --
      # measured by moving this back, which fires the cop. Headroom is two
      # lines, so item 03 should decompose the scanner rather than hoist
      # another constant.
      STRUCTURE_MESSAGES = {
        duplicate_ihdr: "duplicate IHDR chunk; a PNG datastream carries exactly one",
        missing_iend: "PNG datastream ends without an IEND chunk",
        duplicate_iend: "a second IEND chunk follows the end of the datastream",
        trailing_data: "unexpected bytes after the IEND chunk",
        # The whole record span against the bytes really left. Comparing
        # a payload length with remaining record bytes reads as
        # "declares 13 bytes but only 17 remain", which compares two
        # different units and tells the reader nothing.
        chunk_overruns: "chunk needs %d bytes but only %d remain in the file",
        header_residue: "%s left, too few for a chunk header",
        shorter_than_signature: "file is shorter than the PNG signature"
      }.freeze

      # Headroom over IHDR_BYTES (13) and PHYS_BYTES (9): neither
      # `readable` nor `dpi` ever needs more of a wanted chunk than
      # that, so nothing here trusts a declared length past this cap --
      # not even for IHDR or pHYs themselves (D-bounded-read).
      MAX_CHUNK_READ = 32

      # How much `drain` discards per read when the IO cannot seek.
      # Deliberately its own number rather than MAX_CHUNK_READ: that cap
      # bounds what is KEPT in memory, this one only bounds how many
      # syscalls it takes to throw bytes away, and nothing it reads is
      # retained. Measured, draining a 20 MiB unwanted chunk off a real
      # pipe: 32 bytes took 655,360 reads and 5.29s, 16 KiB took 1,280
      # reads and 0.031s.
      DRAIN_BUFFER = 16_384

      # What `ChunkReader#gather` collects. png_conform's own chunk
      # object is gone from this handler entirely now that its bytes
      # come from a hand read rather than `StreamingReader#each_chunk`;
      # only `.type` and `.data` were ever read off it, so this replaces
      # it exactly.
      Chunk = Data.define(:type, :data)

      # Drives a chunk stream's raw IO directly, deciding purely from an
      # 8-byte header whether to read a chunk's payload or skip it --
      # kept apart from PNG metadata interpretation (IHDR/pHYs decoding,
      # dpi, colour spaces) so the two concerns stay easy to read apart.
      #
      # png_conform 0.1.4 has no public API that exposes a chunk's
      # length+type without first reading its data (measured against
      # every method on `StreamingReader`), so bounding the read means
      # reading the header by hand and deciding before the payload is
      # ever touched.
      class ChunkReader
        def initialize(io)
          @io = io
        end

        # `into` doubles as the "already captured" record -- no separate
        # tracking is needed since `WANTED_CHUNKS` only has two entries
        # -- so a second chunk of a type already in `into` is skipped
        # exactly like an unwanted one, keeping only the first.
        def gather(into:)
          loop do
            length, type = read_header
            break unless type && type != "IEND"

            if wanted?(type, into)
              break unless capture!(type, length, into: into)
            else
              skip(length + 4) # payload plus the CRC, neither read here
            end
          end
        end

        private

        attr_reader :io

        # A wanted type not already in `into` -- the second of two
        # chunks sharing a type is treated exactly like an unwanted one.
        def wanted?(type, into)
          WANTED_CHUNKS.include?(type) && into.none? { |chunk| chunk.type == type }
        end

        # `nil` on a short payload or a short CRC -- either means this
        # chunk didn't fully arrive, so `gather` stops rather than
        # keeping a partial read.
        def capture!(type, length, into:)
          data = read_chunk_data(length)
          return nil unless data && read_crc

          into << Chunk.new(type: type, data: data)
          data
        end

        # `nil` on a short or absent header -- the same "stop, keep what
        # `into` already holds" outcome a truncated read used to reach
        # by raising and being rescued.
        def read_header
          header = io.read(8)
          return [nil, nil] unless header && header.bytesize == 8

          header.unpack("Na4")
        end

        # Reads at most MAX_CHUNK_READ bytes of a wanted chunk's
        # payload, and accounts for the rest of `length` by skipping it
        # -- so a chunk declaring more than the cap (an
        # attacker-labelled "IHDR", or simply a real IHDR with trailing
        # bytes) never leaves the stream misaligned for whatever chunk
        # comes next. `nil` on a short read: a wanted chunk that didn't
        # fully arrive is truncation, not something to keep.
        def read_chunk_data(length)
          wanted = [length, MAX_CHUNK_READ].min
          data = io.read(wanted)
          return nil unless data && data.bytesize == wanted

          skip(length - wanted) if length > wanted
          data
        end

        # Read, not skipped: a wanted chunk is only appended to `into`
        # once its CRC is confirmed present, matching png_conform's own
        # atomic chunk read, which never hands `gather` a chunk whose
        # CRC didn't fully arrive either.
        def read_crc
          crc = io.read(4)
          crc && crc.bytesize == 4
        end

        # `seek`, unless the IO can't. A pipe and a `/dev/fd/<n>` onto
        # one both raise `Errno::ESPIPE` -- measured off a real pipe,
        # not assumed.
        #
        # Reaching that shape means naming the format:
        # `Image.new(format: :png, path: "/dev/fd/<n>")`. It is NOT
        # `Image.from_path`, which detects first, and detection reads
        # the stream -- a pipe hands its bytes out once, so inspection
        # reopens a path that has already moved past the signature.
        # Measured on the same pipe: `from_path` reports "failed" with
        # `png.ihdr_unreadable`, and the constructor with the format
        # given reports "ok". Widening that is the detector's business,
        # not this handler's.
        #
        # Falling back to reading and discarding in bounded increments
        # keeps memory capped even though the byte count read off a
        # pipe is not.
        def skip(length)
          io.seek(length, IO::SEEK_CUR)
        rescue Errno::ESPIPE
          drain(length)
        end

        def drain(length)
          remaining = length
          while remaining.positive?
            requested = [remaining, DRAIN_BUFFER].min
            chunk = io.read(requested)
            break unless chunk

            remaining -= chunk.bytesize
            break if chunk.bytesize < requested
          end
        end
      end

      # Chunk-sequence faults png_conform 0.1.4 does not correctly
      # report (D23). Reads ONLY 8-byte chunk headers and seeks over
      # every payload, so the bytes read are 8 x the HEADERS EXAMINED --
      # measured 24 bytes for a 75-byte file and for a 10 MiB one. Not
      # "independent of file size", which overstates it: a 20-byte
      # IEND-only stream reads 8 bytes, and 100 empty chunks plus IEND read
      # 808 (the 100 alone read 800). The
      # guarantee is that no payload is ever read, whatever it declares.
      #
      # Beside `ChunkReader` rather than inside it: that one stops at
      # IEND, keeps payloads, and supports a non-seekable pipe through
      # `drain`. This needs `io.size` and absolute seeks, treats a short
      # read as a fault rather than an ending, and classifies what lies
      # past IEND.
      class StructureScanner
        SIGNATURE_BYTES = 8
        HEADER_BYTES = 8
        # Length field, type and CRC: what a chunk costs beyond its payload.
        FRAMING_BYTES = 12
        # REC-PNG-20031110 5.4 restricts a type code to four ASCII
        # letters. Anything else is not a name, and handing raw bytes to
        # `Location#chunk` is not merely untidy -- a high byte makes
        # lutaml raise, which would take the scan down on exactly the
        # malformed input this exists to report.
        LETTERS = /\A[A-Za-z]{4}\z/

        # Where the walk stopped, carrying the header it stopped on so
        # the terminal issue never re-reads one.
        Stop = Data.define(:state, :offset, :length, :type)

        def initialize(io)
          @io = io
          @size = io.size
          @seen_ihdr = false
        end

        # Byte-ordered, with the terminal issue last. Empty for a
        # well-formed datastream -- never nil.
        #
        # Memoized because scanning twice would append twice, and the
        # bounded-read guarantee would go with it. Both exits return the
        # same accumulator, so they cannot drift apart into two contracts.
        def issues
          @issues ||= scan
        end

        private

        def scan
          found = []
          return found << rangeless("png.chunk_truncated", :shorter_than_signature) if @size < SIGNATURE_BYTES

          @found = found
          terminate(walk)
          found
        end

        # Ends in exactly one of three states, and the short-file guard
        # above is what keeps that true: with `size` at least 8 and
        # `offset` only advancing when a whole record fits,
        # `size - offset` can never go negative.
        def walk
          offset = SIGNATURE_BYTES
          until offset == @size
            length, type = header_at(offset)
            return Stop[:truncated, offset, length, type] unless record_fits?(offset, length)

            note_duplicate(type, offset, span(length))
            offset += span(length)
            return Stop[:complete, offset, nil, nil] if type == "IEND"
          end
          Stop[:ended, offset, nil, nil]
        end

        def terminate(stop)
          case stop.state
          when :ended then @found << rangeless("png.missing_iend", :missing_iend, chunk: "IEND")
          when :truncated then @found << truncated(stop)
          when :complete then trailing(stop.offset)
          end
        end

        # Only a COMPLETE repeat counts. The bounds test above returns
        # first, so a repeated IHDR whose record is cut never arrives
        # here -- which is the right answer, since its range would name
        # bytes the file does not contain.
        def note_duplicate(type, offset, span)
          return unless type == "IHDR"

          @found << issue("png.duplicate_ihdr", STRUCTURE_MESSAGES[:duplicate_ihdr], offset, span, "IHDR") if @seen_ihdr
          @seen_ihdr = true
        end

        # The range is what is really there, not what was declared: a
        # half-open range must never name bytes the file lacks.
        #
        # Stated against a TRUTHFUL `io.size`, which this scanner documents
        # rather than enforces. Under a size that over-reports, this range and
        # `trailing`'s both name bytes past EOF -- measured, a real file
        # truncated to 41 bytes after `io.size` was captured yields
        # byte_offset 56, which is 15 bytes past its end. That is the deferred
        # gap the over-reporting examples in the spec pin as known.
        def truncated(stop)
          remaining = @size - stop.offset
          message =
            if stop.length
              format(STRUCTURE_MESSAGES[:chunk_overruns], span(stop.length), remaining)
            else
              format(STRUCTURE_MESSAGES[:header_residue], bytes_phrase(remaining))
            end
          issue("png.chunk_truncated", message, stop.offset, remaining, letters(stop.type))
        end

        # Everything past IEND is outside the datastream and gets exactly
        # one issue over the whole remainder.
        def trailing(offset)
          remaining = @size - offset
          return if remaining.zero?

          @found <<
            if complete_iend_at?(offset)
              issue("png.duplicate_iend", STRUCTURE_MESSAGES[:duplicate_iend], offset, remaining, "IEND")
            else
              issue("png.trailing_data", STRUCTURE_MESSAGES[:trailing_data], offset, remaining, nil)
            end
        end

        # A type code alone is not a chunk. Calling a nine-byte remainder
        # whose header declares 25 "a second IEND chunk" asserts a record
        # that is not there -- the same completeness rule `note_duplicate`
        # obeys.
        def complete_iend_at?(offset)
          length, type = header_at(offset)
          type == "IEND" && record_fits?(offset, length)
        end

        # The whole record, payload and framing together.
        def span(length) = FRAMING_BYTES + length

        # Under a truthful `io.size` a residue is 1 to 7 bytes, so the
        # singular is reachable -- the over-reporting rows in the spec do
        # reach larger values, e.g. "1000 bytes left". Either way
        # "1 bytes left" is copy a person reads while something is wrong.
        def bytes_phrase(count) = "#{count} byte#{"s" unless count == 1}"

        # The one completeness rule, in one place. `walk` and
        # `complete_iend_at?` are its callers -- writing it twice, once as an
        # overrun test and once as its inverse, is how the two drift apart.
        # (`note_duplicate` does NOT call it; it is handed the span `walk`
        # already computed.)
        def record_fits?(offset, length)
          !length.nil? && offset + span(length) <= @size
        end

        # nil when no header fits, which `walk` reads as truncation.
        #
        # The size test is not enough on its own, because it trusts
        # `io.size`. A short or absent read is checked too, so the walk
        # stays total even where that number lies -- measured, `read(8)`
        # at EOF returns nil and `nil.unpack` raises NoMethodError. A
        # short read is a fault here exactly as it is everywhere else in
        # this scanner, not an ending. `ChunkReader#read_header` already
        # takes the same care for the same reason -- cited by NAME, not by
        # line: a same-file line range rots the moment anything above it
        # moves, which is exactly how this comment was wrong once already.
        def header_at(offset)
          return nil if offset + HEADER_BYTES > @size

          @io.seek(offset)
          header = @io.read(HEADER_BYTES)
          return nil unless header&.bytesize == HEADER_BYTES

          header.unpack("Na4")
        end

        def letters(type)
          type if type&.match?(LETTERS)
        end

        def issue(code, message, offset, length, chunk)
          Models::Issue.new(
            severity: "error", code: code, message: message,
            location: Models::Location.new(byte_offset: offset, byte_length: length, chunk: chunk)
          )
        end

        # Absent is not zero: a fault with no chunk to point at carries no
        # range rather than an invented one at EOF.
        def rangeless(code, key, chunk: nil)
          Models::Issue.new(severity: "error", code: code, message: STRUCTURE_MESSAGES[key],
                            location: Models::Location.new(chunk: chunk))
        end
      end

      private_constant :IHDR_LAYOUT, :IHDR_BYTES, :PHYS_LAYOUT, :PHYS_BYTES,
                       :METRE_UNIT, :METRES_PER_INCH, :WANTED_CHUNKS,
                       :COLOR_SPACES, :STRUCTURE_MESSAGES, :MAX_CHUNK_READ, :DRAIN_BUFFER,
                       :Chunk, :ChunkReader, :StructureScanner

      def inspection(image)
        chunks = read_chunks(image)
        ihdr = chunks.find { |chunk| chunk.type == "IHDR" }

        return unreadable(image) unless usable_ihdr?(ihdr)

        readable(image, ihdr, chunks)
      end

      private

      # Lazily required (D5): the detector's `emf` is the sole eager
      # delegate, and a gem should not pay for a parser it may never use.
      #
      # `StreamingReader.open`, not `FullLoadReader.new`. The full reader
      # is `read_until: :eof`, and using it cost three separate defects,
      # all measured:
      #
      # - it reads PAST `IEND`. A valid `pHYs` chunk appended after a
      #   complete PNG was reported as that file's DPI (72.009), and two
      #   concatenated PNGs reported `"failed"` although the first image
      #   is perfectly readable.
      # - it owns the file it opens and closes it only on `#close`, which
      #   this never called. 100 inspections held 100 descriptors open
      #   until GC.
      # - it accepts only a String, so `Image.from_path(Pathname(...))`
      #   detected and read fine and then raised `NoMethodError` on
      #   `rewind` -- an exit-4 defect code for ordinary library input.
      #
      # The streaming reader stops at `IEND` itself, closes its own file,
      # and takes a Pathname.
      #
      # `chunks` is built outside the block and returned by both exits, so
      # a failure part-way through keeps what was already read. Dropping
      # it cost a real defect: a complete IHDR followed by two stray bytes
      # raised the truncation error and reported "PNG header (IHDR) could
      # not be read" for a header this had just read.
      #
      # A truncated chunk no longer raises to get that behaviour --
      # `ChunkReader#gather` reads its own header, payload and CRC by
      # hand and stops the loop on any short read, so "keep what's
      # already collected" is just where the loop ends, not something
      # caught here.
      def read_chunks(image)
        require "png_conform"

        chunks = []
        image.with_path do |path|
          PngConform::Readers::StreamingReader.open(path) { |reader| ChunkReader.new(reader.io).gather(into: chunks) }
        end
        chunks
      # `gather` no longer hands a declared length to `#read` unbounded,
      # so `Errno::EINVAL` (what a chunk declaring 0x8000000d bytes used
      # to produce asking the OS for that many) and the reader's own
      # `IOError: data truncated` cannot happen from THIS path any more
      # -- measured against png_conform 0.1.4 rather than assumed. This
      # is scoped to malformed input, not "impossible in general": an
      # `IOError` from an IO that closes unexpectedly mid-inspection
      # would still be a real defect and still propagate to exit 4.
      #
      # ENOENT is deliberately absent. A file that vanished is not
      # malformed input, and absorbing it reported "PNG header (IHDR)
      # could not be read" about a file that was no longer there. It
      # propagates, and the runner already maps it to exit 2 -- the code
      # the README gives for a missing file.
      #
      # PngConform::Error stays named although no code path in 0.1.4
      # raises it: it is the delegate's declared parse failure, the
      # gemspec admits every later 0.1.x, and a patch release that starts
      # raising it would otherwise turn a bad file into exit 4. ParseError
      # descends from it, so naming both is redundant.
      rescue PngConform::Error
        chunks
      end

      # A signature-only file yields zero chunks and raises nothing, and a
      # well-formed chunk can carry a short payload -- unpack returns nils
      # for the missing fields rather than failing. Both are measured, so
      # absence of an exception proves nothing and this gate is what makes
      # "the metadata parsed" a real claim (D17).
      def usable_ihdr?(ihdr)
        !ihdr.nil? && ihdr.data.bytesize == IHDR_BYTES
      end

      def readable(image, ihdr, chunks)
        width, height, depth, color_type, *encoding = ihdr.data.unpack(IHDR_LAYOUT)

        Models::Inspection.new(
          format: image.format.to_s,
          width: width.to_f, height: height.to_f,
          dpi: dpi(chunks), color_space: COLOR_SPACES[color_type],
          meta: meta(depth, encoding), parse_status: "ok"
        )
      end

      # Inspection has named slots for dimensions, dpi and colour space;
      # what is left of IHDR is format-native, so it goes here.
      def meta(depth, encoding)
        compression, filter, interlace = encoding

        { "bit_depth" => depth, "compression" => compression,
          "filter" => filter, "interlace" => interlace }
      end

      def unreadable(image)
        Models::Inspection.new(
          format: image.format.to_s,
          parse_status: "failed",
          issues: [unreadable_issue]
        )
      end

      # One message for every way the header can be unreadable: absent,
      # the wrong length, or never reached because the read itself failed.
      # Naming only the length case would misdescribe the other two.
      def unreadable_issue
        Models::Issue.new(
          severity: "error",
          code: "png.ihdr_unreadable",
          message: "PNG header (IHDR) could not be read"
        )
      end

      # The structural pre-pass (D23). Built and spec'd here; the call
      # from `conformance_report` lands with item 03's conform wiring,
      # which must also decide the delegate reader -- neither of
      # png_conform's is safe on every input.
      def structural_issues(image)
        image.with_path { |path| File.open(path, "rb") { |io| StructureScanner.new(io).issues } }
      end

      # nil when pHYs is absent, and nil when it records an aspect ratio
      # rather than a physical unit. Both are ordinary files, not errors.
      #
      # The length is checked before unpacking, because unpack skips a
      # directive it has too few bytes for but keeps reading the rest
      # from where it started. Measured across every length below 9:
      # 1 to 3 give [nil, nil, 1], which passes the unit check and then
      # multiplies nil. 5 to 7 give [value, nil, 1], which the axis check
      # below rejects on its own. So this gate stops a crash, not a wrong
      # number.
      def dpi(chunks)
        phys = chunks.find { |chunk| chunk.type == "pHYs" }
        return nil unless phys && phys.data.bytesize >= PHYS_BYTES

        # dpi is a single number, so a PNG with non-square pixels has no
        # one value to report -- and reporting the x axis alone would say
        # 72 for an image that is 72x144. Measured: X=2835 Y=5669 is
        # exactly that case. Unequal axes give nil rather than half the
        # truth.
        horizontal, vertical, unit = phys.data.unpack(PHYS_LAYOUT)
        return nil unless unit == METRE_UNIT && horizontal == vertical

        horizontal * METRES_PER_INCH
      end
    end
  end
end
