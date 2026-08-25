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
      # else is skipped over unread, so a PNG carrying a huge ancillary
      # chunk never costs more than its own 8-byte header (D-bounded-read).
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

      # Headroom over IHDR_BYTES (13) and PHYS_BYTES (9): neither
      # `readable` nor `dpi` ever needs more of a wanted chunk than
      # that, so nothing here trusts a declared length past this cap --
      # not even for IHDR or pHYs themselves (D-bounded-read).
      MAX_CHUNK_READ = 32

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
              skip(length + 4) # payload plus the CRC neither side reads
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

        # `seek`, unless the IO can't. `Errno::ESPIPE` is what a pipe or
        # `/dev/fd/<n>` raises -- input `Image.from_path` accepts today,
        # and which `Detector`'s own specs already treat as a supported
        # shape rather than an accident. Falling back to reading and
        # discarding in bounded increments keeps memory capped even
        # though the byte count read off a pipe is not.
        def skip(length)
          io.seek(length, IO::SEEK_CUR)
        rescue Errno::ESPIPE
          drain(length)
        end

        def drain(length)
          remaining = length
          while remaining.positive?
            requested = [remaining, MAX_CHUNK_READ].min
            chunk = io.read(requested)
            break unless chunk

            remaining -= chunk.bytesize
            break if chunk.bytesize < requested
          end
        end
      end

      private_constant :IHDR_LAYOUT, :IHDR_BYTES, :PHYS_LAYOUT, :PHYS_BYTES,
                       :METRE_UNIT, :METRES_PER_INCH, :WANTED_CHUNKS,
                       :COLOR_SPACES, :MAX_CHUNK_READ, :Chunk, :ChunkReader

      def inspection(image)
        chunks = read_chunks(image)
        ihdr = chunks.find { |chunk| chunk.type.to_s == "IHDR" }

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
      # gemspec allows any 0.1.x, and a patch release that starts raising
      # it would otherwise turn a bad file into exit 4. ParseError
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
      # Naming only the length case would misdescribe the other three.
      def unreadable_issue
        Models::Issue.new(
          severity: "error",
          code: "png.ihdr_unreadable",
          message: "PNG header (IHDR) could not be read"
        )
      end

      # nil when pHYs is absent, and nil when it records an aspect ratio
      # rather than a physical unit. Both are ordinary files, not errors.
      #
      # The length is checked before unpacking, because unpack skips a
      # directive it has too few bytes for but keeps reading the rest from
      # where it started: a 1-byte pHYs gives [nil, nil, 1], which passes
      # the unit check and then multiplies nil, and a 5-byte one gives
      # [value, nil, 1], which yields a dpi the chunk never carried.
      def dpi(chunks)
        phys = chunks.find { |chunk| chunk.type.to_s == "pHYs" }
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
