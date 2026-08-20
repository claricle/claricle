# frozen_string_literal: true

require "emf"

require_relative "base"
require_relative "../models/inspection"
require_relative "../models/issue"

module Claricle
  module Handlers
    # Reads an EMF header. WMF is deliberately absent: the released emf
    # parser reports "WMF parser not yet implemented" (D14), so nothing
    # registers `:wmf` and it reaches exit 3 through the registry.
    class Metafile < Base
      formats :emf

      # EMR_HEADER's declared size, a 4-byte little-endian value at a
      # fixed offset. Below the minimum there is no header to read.
      SIZE_OFFSET = 4
      MINIMUM_HEADER = 88
      MILLIMETRES_PER_INCH = 25.4

      # Every way this delegate fails on input rather than on a defect.
      # Measured: FormatError for garbage and short prefixes, EOFError and
      # IOError when a declared nSize sends it reading past the end.
      PARSE_FAILURES = [::Emf::Error, IOError].freeze

      ISSUE_CODE = "emf.header_unreadable"
      ISSUE_MESSAGE = "EMF header could not be read"

      private_constant :SIZE_OFFSET, :MINIMUM_HEADER, :MILLIMETRES_PER_INCH,
                       :PARSE_FAILURES, :ISSUE_CODE, :ISSUE_MESSAGE

      # Two passes, because one cannot tell the cases apart. A file
      # truncated mid-record and a file whose declared nSize is wrong both
      # raise IOError with the same message, and `Emf.parse` discards the
      # header it already read. So the header is parsed alone first: that
      # decides the status and supplies every figure, and the full stream
      # is a second, optional pass for records and EMF+.
      def inspection(image)
        content = image.content
        header = read_header(content)
        return unreadable(image) unless header

        readable(image, header, read_stream(content))
      end

      private

      def read_header(content)
        prefix = header_prefix(content)
        return nil unless prefix

        ::Emf.parse(prefix).header
      rescue *PARSE_FAILURES
        nil
      end

      # A record failing after a good header is not a failed inspection
      # (D17), so this returning nil is an ordinary outcome rather than an
      # error -- it only costs the EMF+ metadata.
      def read_stream(content)
        ::Emf.parse(content)
      rescue *PARSE_FAILURES
        nil
      end

      def header_prefix(content)
        return nil if content.bytesize < SIZE_OFFSET + 4

        declared = content.byteslice(SIZE_OFFSET, 4).unpack1("V")
        return nil if declared.nil? || declared < MINIMUM_HEADER || declared > content.bytesize

        content.byteslice(0, declared)
      end

      def readable(image, header, metafile)
        Models::Inspection.new(
          format: image.format.to_s,
          width: Integer(header.bounds.width).to_f,
          height: Integer(header.bounds.height).to_f,
          dpi: dpi(header),
          meta: metadata(header, metafile),
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

      # Every scalar coerced: the delegate hands back BinData wrappers,
      # which behave like Integers but serialize as JSON strings.
      def metadata(header, metafile)
        {
          "frame" => size_of(header.frame),
          "device_pixels" => size_of(header.device_pixels),
          "device_mm" => size_of(header.device_mm),
          "n_records" => Integer(header.n_records),
          "n_handles" => Integer(header.n_handles)
        }.merge(emf_plus(metafile))
      end

      def size_of(value)
        width = value.respond_to?(:width) ? value.width : value.cx
        height = value.respond_to?(:height) ? value.height : value.cy
        { "width" => Integer(width), "height" => Integer(height) }
      end

      # Presence and size only. The payload is packed binary and `to_json`
      # refuses it. A stream that did not parse reports false rather than
      # nil: the key is part of the schema, and "we could not tell" is
      # reported as absence.
      def emf_plus(metafile)
        payload = metafile&.emf_plus
        return { "emf_plus_present" => false } unless payload

        { "emf_plus_present" => true, "emf_plus_bytes" => payload.bytesize }
      end
    end
  end
end
