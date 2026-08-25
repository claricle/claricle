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
      # the only ones anything below reads, and skipping IDAT alone still
      # kept whatever else the file carried -- measured: a PNG with a
      # 4 MB tEXt held all 4 MB to reach 13 bytes of IHDR.
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

      private_constant :IHDR_LAYOUT, :IHDR_BYTES, :PHYS_LAYOUT, :PHYS_BYTES,
                       :METRE_UNIT, :METRES_PER_INCH, :WANTED_CHUNKS,
                       :COLOR_SPACES

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
      # Measured against StreamingReader, both malformed tails take the
      # SAME route -- `IOError: data truncated` -- so the loss was
      # uniform, not an arbitrary cliff between two exception classes. An
      # earlier version of this comment claimed a data-short chunk raises
      # a swallowed EOFError; that is not what this reader does.
      def read_chunks(image)
        require "png_conform"

        chunks = []
        image.with_path do |path|
          PngConform::Readers::StreamingReader.open(path) { |reader| gather(reader, into: chunks) }
        end
        chunks
      # The allowlist, measured against png_conform 0.1.4 rather than
      # assumed. Each entry is a way the reader fails on *input*, which is
      # a "failed" inspection, not a defect. IOError is the reader's own
      # bare "data truncated", raised when a chunk header promises more
      # bytes than the file holds. EINVAL is what a chunk declaring
      # 0x8000000d bytes produces, when the reader asks the OS for that
      # many. Anything else is a defect and propagates to exit 4 rather
      # than being absorbed.
      #
      # ENOENT is deliberately absent. A file that vanished is not
      # malformed input, and absorbing it reported "PNG header (IHDR)
      # could not be read" about a file that was no longer there. It
      # propagates, and the runner already maps it to exit 2 -- the code
      # the README gives for a missing file.
      #
      # A short or absent signature raises nothing at all under this
      # reader -- it yields zero chunks, and the IHDR gate below is what
      # fails the file. EOFError likewise never escapes: `read_chunk`
      # rescues it internally.
      #
      # PngConform::Error stays named although no code path in 0.1.4
      # raises it: it is the delegate's declared parse failure, the
      # gemspec allows any 0.1.x, and a patch release that starts raising
      # it would otherwise turn a bad file into exit 4. ParseError
      # descends from it, so naming both is redundant.
      rescue PngConform::Error, Errno::EINVAL, IOError
        chunks
      end

      # Appends into the caller's array rather than returning one, so a
      # chunk that fails part-way through does not take the chunks read
      # before it down with it.
      def gather(reader, into:)
        reader.each_chunk do |chunk|
          into << chunk if WANTED_CHUNKS.include?(chunk.type.to_s)
        end
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
