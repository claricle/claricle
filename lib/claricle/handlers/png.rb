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
                       :METRE_UNIT, :METRES_PER_INCH, :COLOR_SPACES

      def inspection(image)
        chunks = read_chunks(image)
        ihdr = chunks&.find { |chunk| chunk.type.to_s == "IHDR" }

        return unreadable(image) unless usable_ihdr?(ihdr)

        readable(image, ihdr, chunks)
      end

      private

      # Lazily required (D5): the detector's `emf` is the sole eager
      # delegate, and a gem should not pay for a parser it may never use.
      def read_chunks(image)
        require "png_conform"

        image.with_path do |path|
          reader = PngConform::Readers::FullLoadReader.new(path)
          [].tap { |chunks| reader.each_chunk { |chunk| chunks << chunk } }
        end
      # The allowlist, measured rather than assumed. Every entry is a way
      # the reader fails on *input*, which is a "failed" inspection, not a
      # defect. ParseError descends from Error, so naming both is
      # redundant. IOError covers EOFError (its subclass, raised on an
      # empty file) and the bare "data truncated" raised by a partial
      # signature. EINVAL is what a chunk declaring a huge length
      # produces, when the reader asks the OS for that many bytes.
      # ENOENT covers a file that vanishes mid-read. Anything else is a
      # defect and propagates to exit 4 rather than being absorbed.
      rescue PngConform::Error, Errno::ENOENT, Errno::EINVAL, IOError
        nil
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
