# frozen_string_literal: true

require "stringio"
require "rexml/parsers/pullparser"
require "rexml/text"
require "emf"

module Claricle
  # Attribute defaults declared in an internal DTD subset. XML 1.0
  # requires a processor to apply them and REXML's DOM does, but the
  # PullParser hands the declarations over raw, so this reassembles them.
  # Its own module because the precedence rules are a self-contained
  # concern, and Detector is about choosing between formats.
  #
  # Known gap, upstream: REXML raises "Bad ATTLIST declaration!" for a
  # single-quoted default, which XML permits. That happens inside REXML
  # before any event reaches us, so such a document is reported as an
  # unknown format. It fails closed rather than misdetecting, and working
  # around REXML's DTD parser would cost more than the gap.
  module AttributeDefaults
    # One "name TYPE [#DEFAULT] value" group of an ATTLIST body, enough
    # to recover declaration order. Values may be absent (#REQUIRED etc).
    DECLARATION = /
      (?<name>[\w:.-]+)\s+
      (?:\([^)]*\)|[A-Z]+(?:\s*\([^)]*\))?)\s*
      (?:\#(?:REQUIRED|IMPLIED)|(?:\#FIXED\s+)?(?:"(?<dq>[^"]*)"|'(?<sq>[^']*)'))
    /x

    private_constant :DECLARATION

    class << self
      # XML accumulates ATTLIST declarations and the FIRST declaration of
      # an attribute binds, so a later one neither replaces the element's
      # earlier defaults nor overrides a duplicate.
      #
      # Duplicates inside ONE declaration need the raw source: REXML
      # collapses them last-wins before handing over the parsed hash. The
      # raw scan is the authority -- it carries tombstones REXML cannot
      # report, and corrects a value REXML mis-reports, such as one
      # separated from `#FIXED` by a tab. REXML is the fallback, for
      # attributes the regex could not read at all.
      def collect(defaults, event)
        element = event[0]
        within = first_of(event[2])
        event[1].each { |name, value| within[name] = value unless within.key?(name) }
        defaults[element] = within.merge(defaults[element] || {})
      end

      # Explicit attributes beat declared defaults, and only the final
      # merged hash is compacted -- dropping tombstones earlier would let
      # a later declaration resurrect an attribute XML left undeclared.
      def for_root(event, defaults)
        defaults.fetch(event[0], {}).merge(event[1]).compact
      end

      private

      # nil is a real answer here -- `#IMPLIED` means "declared, no
      # default" -- so first-wins is decided by key?, never by the
      # value's truthiness.
      def first_of(raw)
        body = raw.to_s.sub(/\A<!ATTLIST\s+\S+/, "").sub(/>\s*\z/, "")
        body.scan(DECLARATION).each_with_object({}) do |(name, quoted, single), acc|
          acc[name] = quoted || single unless acc.key?(name)
        end
      end
    end
  end

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
        offset = 0

        while (found = FIELD.match(scan, offset))
          offset = found.end(0)
          # A match starting inside the carried bytes has already been
          # judged, in the window where its real left-hand neighbour was
          # visible. Reconsidering it here lets the buffer edge stand in
          # for that neighbour, which turned "%!PS XEPSF " into an EPS.
          #
          # Rejecting it must not end the search, which is what an
          # earlier version did by examining only the first match: a
          # decoy straddling the boundary then hid a real `EPSF` later in
          # the same window, and the file read as :ps.
          next if found.begin(0).zero? && carried.positive?

          return true if final || found.end(0) < scan.bytesize

          # This one ends exactly at the edge, so its trailing delimiter
          # came from the buffer rather than the file. Nothing after it
          # can end sooner, so the whole window defers.
          return false
        end

        false
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

      # The root element's qname and its resolved attributes, or nil.
      # nil covers every way the root can be unavailable: no root inside
      # the bound, markup REXML refuses, and an encoding name it cannot
      # use. Callers treat all three the same -- there is nothing to
      # report about -- so they are not distinguished here. Public because Handlers::Svg
      # needs exactly this and a second reader would have to reimplement
      # the bound, the ATTLIST precedence and the reference resolution --
      # three rules this file spent four review rounds getting right --
      # and then agree with this one. `Detector` is itself a private
      # constant, so nothing about the gem's documented surface changes.
      def read_root(source)
        found = root_event(source)
        return nil unless found

        # Resolution sits OUTSIDE the rescue below on purpose. That
        # rescue exists for the parser's own failures -- including the
        # bare ArgumentError REXML raises for an unusable encoding name
        # -- and an ArgumentError or RuntimeError raised while resolving
        # references is a different fault that must not be reported as
        # "this file has no root".
        [found.first, resolved(found.last)]
      end

      private

      def root_event(source)
        parser = REXML::Parsers::PullParser.new(bounded(source))
        defaults = {}
        while parser.has_next?
          event = parser.pull
          AttributeDefaults.collect(defaults, event) if event.event_type == :attlistdecl
          return [event[0], AttributeDefaults.for_root(event, defaults)] if event.start_element?
        end
        nil
      rescue REXML::ParseException, ArgumentError
        nil
      end

      # Every root attribute, not just xmlns: the PullParser hands values
      # back unexpanded, and `width="&#49;&#48;"` means ten, not zero.
      #
      # A reference that cannot be resolved keeps its raw declaration.
      # Two ways that happens, both measured: an out-of-range numeric
      # reference raises RangeError, and a surrogate such as `&#xD800;`
      # resolves to INVALID UTF-8, which is worse -- it does not raise
      # here, it detonates later, either in the dimension parse or in
      # `to_json`. The raw form is always valid and always truthful.
      def resolved(attributes)
        attributes.transform_values { |value| usable(resolve_references(value)) || value }
      end

      def usable(value)
        value if value&.valid_encoding?
      end

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
        root = read_root(source)
        return false unless root

        svg_root?(*root)
      end

      # Only the prolog and the root start tag can matter here, and both
      # fit well inside the bound. Takes an IO or a String: detection
      # streams from a file, while a handler already holds the content.
      def bounded(source)
        # byteslice, not slice: the bound is BYTES, and `source[0, n]`
        # counts characters, so a multibyte prolog would let the handler
        # read further than detection did and the two would disagree.
        prefix = if source.respond_to?(:read)
                   source.read(SVG_PROLOG_BYTES)
                 else
                   source.byteslice(0, SVG_PROLOG_BYTES)
                 end
        StringIO.new(prefix || "")
      end

      def svg_root?(qname, attributes)
        prefix, local_name = qname.include?(":") ? qname.split(":", 2) : [nil, qname]
        return false unless local_name == "svg"

        declared = attributes[prefix ? "xmlns:#{prefix}" : "xmlns"]
        return false unless declared

        # Already resolved by read_root. Resolving again would expand a
        # reference the document escaped on purpose: `&amp;#x67;` means
        # the literal text `&#x67;`, and a second pass turns it into `g`.
        declared == SVG_NAMESPACE
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
