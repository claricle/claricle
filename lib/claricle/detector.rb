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
    # The EPSF spec puts `EPSF` or `EPSF-<version>` in the header as a
    # whitespace-delimited field. A bare substring match calls
    # "%!PS-Adobe-3.0 NOT-EPSFILE" and "... XEPSFY" EPS files, which the
    # PostScript parser does not.
    EPS_FIELD = /(?<![\w-])EPSF(?!\w)/
    # The field match needs one byte either side of the token, so a
    # window must carry that much context across a chunk boundary.
    EPS_CARRY_BYTES = 5
    SVG_NAMESPACE = "http://www.w3.org/2000/svg"

    # PostScript ends a line with CR, LF or CRLF.
    LINE_END = /[\r\n]/

    # The signature probes need 44 bytes: Emf::Detector reads the EMF magic
    # as a uint32 at offset 0x28, and below that every valid EMF raises
    # FormatError and falls through to UnknownFormat. 512 is deliberate
    # slack over that floor -- no probe's correctness depends on it.
    HEADER_BYTES = 512
    # The SVG probe stops at the first start element, but REXML holds one
    # live string for the construct it is reading -- so a file beginning
    # "<" with no ">" cost +52MB RSS for 1MB of input, and +217MB for
    # 16MB. Bounding the prefix makes the worst case fixed instead of
    # proportional. A conventional XML declaration plus a full SVG 1.1
    # DOCTYPE is about 140 bytes, so 8192 is generous; XML permits an
    # arbitrarily long prolog, so this is a sniffing limit, not a
    # complete one.
    SVG_PROLOG_BYTES = 8192

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

      # Streams the first line looking for the EPSF field. `gets` would
      # materialise the whole line, and a newline-free %!PS file would
      # allocate its full size -- the SVG probe never runs for
      # PostScript, so nothing else absorbs that cost. PostScript ends a
      # line with CR, LF or CRLF, so the scan stops at whichever comes
      # first.
      #
      # The carry is sized for the *field* match, not a bare substring:
      # the pattern inspects one byte either side of `EPSF`, so a token
      # split across chunks needs its neighbours to travel with it.
      def eps_first_line?(source)
        each_first_line_window(source) do |scan, final|
          return eps_field?(scan, final: true) if final
          return true if eps_field?(scan, final: false)
        end
        false
      end

      # Yields the first line a window at a time, flagging the window
      # that ends it. The carry is sized for the *field* match, not a
      # bare substring: the pattern inspects one byte either side of
      # `EPSF`, so a token split across chunks needs its neighbours to
      # travel with it. The line ending and the end of the file are both
      # final -- a token against either is genuinely followed by nothing.
      def each_first_line_window(source)
        carry = "".b
        loop do
          chunk = source.read(CHUNK_BYTES)
          # nil.to_s is "", so EOF needs no branch of its own here.
          window = carry + chunk.to_s.b
          stop = window.index(LINE_END)
          final = !stop.nil? || chunk.nil?

          yield(stop ? window[0, stop] : window, final)
          return if final

          carry = window[-EPS_CARRY_BYTES..] || window
        end
      end

      # A match ending exactly at the buffer's edge had its trailing
      # delimiter supplied by end-of-string rather than by the file, so
      # unless this really is the end of the line it is deferred to the
      # next window, where the following byte is known.
      def eps_field?(scan, final:)
        found = EPS_FIELD.match(scan)
        return false unless found

        final || found.end(0) < scan.bytesize
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
        parser = REXML::Parsers::PullParser.new(bounded(source))
        defaults = {}
        while parser.has_next?
          event = parser.pull
          defaults[event[0]] = event[1] if event.event_type == :attlistdecl
          return svg_root?(event[0], root_attributes(event, defaults)) if event.start_element?
        end
        false
      rescue REXML::ParseException, ArgumentError
        false
      end

      # XML 1.0 requires a processor to apply attribute defaults declared
      # in the internal subset, and REXML's own DOM does -- so without
      # this an SVG whose xmlns comes from `<!ATTLIST svg xmlns CDATA
      # #FIXED "...">` was rejected as an unknown format. A specified
      # attribute wins over the declared default, hence the merge order.
      def root_attributes(event, defaults)
        defaults.fetch(event[0], {}).merge(event[1])
      end

      # Only the prolog and the root start tag can matter here, and both
      # fit well inside the bound.
      def bounded(source)
        StringIO.new(source.read(SVG_PROLOG_BYTES) || "")
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
