# frozen_string_literal: true

require "stringio"
require "rexml/parsers/pullparser"
require "rexml/text"
require "emf"

module Claricle
  module Detector
    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
    PDF_SIGNATURE = "%PDF-".b.freeze
    POSTSCRIPT_SIGNATURE = "%!PS".b.freeze
    EPS_TOKEN = "EPSF".b.freeze
    SVG_NAMESPACE = "http://www.w3.org/2000/svg"

    # PostScript ends a line with CR, LF or CRLF.
    LINE_END = /[\r\n]/

    # The signature probes need 44 bytes: Emf::Detector reads the EMF magic
    # as a uint32 at offset 0x28, and below that every valid EMF raises
    # FormatError and falls through to UnknownFormat. 512 is deliberate
    # slack over that floor -- no probe's correctness depends on it.
    HEADER_BYTES = 512

    CHUNK_BYTES = 4096

    class << self
      def detect(bytes)
        content = bytes.b
        classify(content[0, HEADER_BYTES]) { StringIO.new(content) }
      end

      def detect_path(path)
        File.open(path, "rb") do |io|
          header = (io.read(HEADER_BYTES) || "").b
          classify(header) do
            io.rewind
            io
          end
        end
      end

      private

      # The block yields the source rewound to byte 0. The PNG, PDF and
      # metafile probes match at fixed offsets and read `header`; the
      # PostScript and SVG probes need more than a header, so they pull
      # from the source themselves.
      def classify(header)
        return :png if header.start_with?(PNG_SIGNATURE)
        return :pdf if header.start_with?(PDF_SIGNATURE)
        return postscript_flavour(yield) if header.start_with?(POSTSCRIPT_SIGNATURE)

        format = metafile_format(header)
        return format if format
        return :svg if svg?(yield)

        raise UnknownFormat, "no known image signature"
      end

      def postscript_flavour(source)
        eps_first_line?(source) ? :eps : :ps
      end

      # Streams the first line looking for EPS_TOKEN. `gets` would
      # materialise the whole line, and a newline-free %!PS file would
      # allocate its full size -- the SVG probe never runs for PostScript,
      # so nothing else absorbs that cost. PostScript ends a line with CR,
      # LF or CRLF, so the scan stops at whichever comes first.
      def eps_first_line?(source)
        carry = "".b
        while (chunk = source.read(CHUNK_BYTES))
          window = carry + chunk.b
          line_end = window.index(LINE_END)
          return true if (line_end ? window[0, line_end] : window).include?(EPS_TOKEN)
          return false if line_end

          carry = window[-(EPS_TOKEN.bytesize - 1)..] || window
        end
        false
      end

      def metafile_format(header)
        ::Emf.detect_format(header)
      rescue ::Emf::FormatError
        nil
      end

      # An unusable encoding name in the XML declaration reaches us as a bare
      # ArgumentError from REXML::Encoding#encoding=, not as a ParseException.
      # It means "not SVG" like any other parse failure; letting it escape
      # would turn a malformed file into an internal error rather than
      # UnknownFormat. Undecodable bytes already arrive as a ParseException.
      def svg?(source)
        parser = REXML::Parsers::PullParser.new(source)
        while parser.has_next?
          event = parser.pull
          return svg_root?(event[0], event[1]) if event.start_element?
        end
        false
      rescue REXML::ParseException, ArgumentError
        false
      end

      def svg_root?(qname, attributes)
        prefix, local_name = qname.include?(":") ? qname.split(":", 2) : [nil, qname]
        return false unless local_name == "svg"

        declared = attributes[prefix ? "xmlns:#{prefix}" : "xmlns"]
        return false unless declared

        resolve_references(declared) == SVG_NAMESPACE
      end

      # PullParser hands back the raw attribute. XML normalization replaces
      # character references, so resolve those before comparing -- but not
      # general entities, which unnormalize leaves alone and we never fetch.
      #
      # The limit caps expansion at the input's own size: without a doctype
      # every reference REXML resolves is at most as long as its source, so
      # this only rules out the runaway case. An out-of-range numeric
      # reference still raises RangeError out of pack, which just means the
      # value is not a namespace we recognise.
      def resolve_references(value)
        REXML::Text.unnormalize(value, entity_expansion_text_limit: value.bytesize)
      rescue RangeError
        nil
      end
    end
  end
end
