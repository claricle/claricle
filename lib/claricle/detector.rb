# frozen_string_literal: true

require "stringio"
require "rexml/parsers/pullparser"
require "rexml/text"
require "emf"

module Claricle
  # The EPSF header field, scanned out of a PostScript file's first line.
  # Its own module because the scan is a self-contained concern with three
  # collaborating pieces, and Detector is about choosing between formats.
  module EpsHeader
    # Whitespace-delimited, per the DSC grammar: `EPSF` or `EPSF-<ver>`
    # is its own header keyword. Excluding only word characters let
    # ".EPSF", "EPSF.foo" and "(EPSF)" through. The version suffix is
    # matched by the lookahead rather than consumed, so the longest match
    # stays four bytes and the carry can be sized for it.
    FIELD = /(?<!\S)EPSF(?=-|\s|\z)/
    # One byte of left context plus the four-byte token.
    CARRY_BYTES = 5

    private_constant :FIELD, :CARRY_BYTES

    class << self
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
      def field?(source)
        each_window(source) do |scan, final, carried|
          return match?(scan, final: true, carried: carried) if final
          return true if match?(scan, final: false, carried: carried)
        end
        false
      end

      # Yields the first line a window at a time, flagging the window
      # that ends it. The carry is sized for the *field* match, not a
      # bare substring: the pattern inspects one byte either side of
      # `EPSF`, so a token split across chunks needs its neighbours to
      # travel with it. The line ending and the end of the file are both
      # final -- a token against either is genuinely followed by nothing.
      def each_window(source)
        carry = "".b
        loop do
          chunk = source.read(Detector::CHUNK_BYTES)
          # nil.to_s is "", so EOF needs no branch of its own here.
          window = carry + chunk.to_s.b
          stop = window.index(Detector::LINE_END)
          final = !stop.nil? || chunk.nil?

          yield(stop ? window[0, stop] : window, final, carry.bytesize)
          return if final

          carry = window[-CARRY_BYTES..] || window
        end
      end

      # A match ending exactly at the buffer's edge had its trailing
      # delimiter supplied by end-of-string rather than by the file, so
      # unless this really is the end of the line it is deferred to the
      # next window, where the following byte is known.
      def match?(scan, final:, carried: 0)
        found = FIELD.match(scan)
        return false unless found
        # A match starting inside the carried bytes has already been
        # judged, in the window where its real left-hand neighbour was
        # visible. Reconsidering it here lets the buffer edge stand in
        # for that neighbour, which turned "%!PS XEPSF " into an EPS.
        return false if found.begin(0).zero? && carried.positive?

        final || found.end(0) < scan.bytesize
      end
    end
  end

  module Detector
    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
    PDF_SIGNATURE = "%PDF-".b.freeze
    POSTSCRIPT_SIGNATURE = "%!PS".b.freeze
    # The EPSF spec puts `EPSF` or `EPSF-<version>` in the header as a
    # whitespace-delimited field. A bare substring match calls
    # "%!PS-Adobe-3.0 NOT-EPSFILE" and "... XEPSFY" EPS files, which the
    # PostScript parser does not.
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
    # One "name TYPE [#DEFAULT] value" group of an ATTLIST body, enough to
    # recover declaration order. Values may be absent (#REQUIRED etc).
    ATTLIST_DECLARATION = /
      (?<name>[\w:.-]+)\s+
      (?:\([^)]*\)|[A-Z]+(?:\s*\([^)]*\))?)\s*
      (?:\#(?:REQUIRED|IMPLIED)|(?:\#FIXED\s+)?(?:"(?<dq>[^"]*)"|'(?<sq>[^']*)'))
    /x

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
        EpsHeader.field?(source) ? :eps : :ps
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
          collect_defaults(defaults, event) if event.event_type == :attlistdecl
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
      # XML accumulates ATTLIST declarations and the FIRST declaration of
      # an attribute binds, so a later one neither replaces the element's
      # earlier defaults nor overrides a duplicate.
      #
      # Duplicates *inside one* declaration need the raw source: REXML
      # collapses them last-wins before handing over the parsed hash, so
      # `<!ATTLIST svg xmlns ... "a" xmlns ... "b">` arrives as "b" where
      # XML binds "a".
      #
      # The raw scan wins where the two disagree, which is deliberate but
      # broader than "it only fixes the order": REXML also mis-reports a
      # value separated from `#FIXED` by a tab, returning `"#FIXED\t"`,
      # and the raw scan corrects that too. It is bounded the other way
      # instead -- only keys REXML already reported are considered, and
      # only when the scan found a value -- so a declaration the regex
      # cannot read leaves the parsed hash untouched.
      #
      # Known gap, upstream: REXML raises "Bad ATTLIST declaration!" for a
      # single-quoted default (`#FIXED \'...\'`), which XML permits. That
      # happens inside REXML before any event reaches us, so the document
      # is reported as an unknown format. It fails closed rather than
      # misdetecting, and working around REXML's DTD parser here would
      # cost more than the gap.
      def collect_defaults(defaults, event)
        element = event[0]
        # The raw scan carries the order AND the tombstones: an attribute
        # declared `#IMPLIED` has no default, and XML binds the first
        # declaration, so a later one with a value must not fill it in.
        # REXML's parsed hash has no tombstones, and is consulted only for
        # attributes the regex could not read.
        within = first_declarations(event[2])
        event[1].each { |name, value| within[name] = value unless within.key?(name) }
        # Earlier declarations win over later ones, tombstones included.
        defaults[element] = within.merge(defaults[element] || {})
      end

      # nil is a real answer here -- `#IMPLIED` means "declared, no
      # default" -- so first-wins is decided by key?, never by the value's
      # truthiness.
      def first_declarations(raw)
        body = raw.to_s.sub(/\A<!ATTLIST\s+\S+/, "").sub(/>\s*\z/, "")
        body.scan(ATTLIST_DECLARATION).each_with_object({}) do |(name, quoted, single), acc|
          acc[name] = quoted || single unless acc.key?(name)
        end
      end

      # Explicit attributes beat declared defaults, and only the final
      # merged hash is compacted -- dropping tombstones earlier would let
      # a later declaration resurrect an attribute XML left undeclared.
      def root_attributes(event, defaults)
        defaults.fetch(event[0], {}).merge(event[1]).compact
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
