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
    # PostScript ends a line with CR, LF or CRLF.
    LINE_END = /[\r\n]/
    CHUNK_BYTES = 4096
    # A DSC header's first line is short in every real PostScript/EPS file.
    # A first line that runs past this many windows is treated the same as
    # one with no EPSF field at all, rather than scanned indefinitely --
    # the same trade-off SVG_PROLOG_BYTES makes for the SVG probe, and for
    # the same reason: worst-case cost has to be a fixed constant, not
    # proportional to an attacker-chosen input.
    MAX_WINDOWS = 3
    # The most this module will ever read from a source. Public so
    # Detector can size its own read bound to match.
    MAX_SCAN_BYTES = MAX_WINDOWS * CHUNK_BYTES

    private_constant :FIELD, :CARRY_BYTES, :LINE_END, :CHUNK_BYTES, :MAX_WINDOWS

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
        each_window(source) do |scan, final, at_end, carried|
          return match?(scan, final: at_end, carried: carried) if final
          return true if match?(scan, final: false, carried: carried)
        end
        false
      end

      # Yields the first line a window at a time, flagging the window
      # that ends it. The carry is sized for the *field* match, not a
      # bare substring: the pattern inspects one byte either side of
      # `EPSF`, so a token split across chunks needs its neighbours to
      # travel with it.
      #
      # `final` and `at_end` differ at the scan ceiling: reaching it
      # stops the scan (`final`), but the byte after the ceiling was
      # never read, so a match resting on that unseen byte has no
      # evidence for it and `at_end` stays false. Only a genuine line
      # ending or a genuine end of file (`at_end`) can back a match that
      # ends exactly at the window's edge -- see `match?`.
      def each_window(source)
        carry = "".b
        windows_read = 0
        loop do
          windows_read += 1
          window, chunk, stop = next_window(source, carry)
          at_end, final = window_status(stop, chunk, windows_read)

          yield(stop ? window[0, stop] : window, final, at_end, carry.bytesize)
          return if final

          carry = window[-CARRY_BYTES..] || window
        end
      end

      # nil.to_s is "", so EOF needs no branch of its own here.
      def next_window(source, carry)
        chunk = source.read(CHUNK_BYTES)
        window = carry + chunk.to_s.b
        [window, chunk, window.index(LINE_END)]
      end

      # `read(CHUNK_BYTES)` only ever returns fewer bytes than asked for
      # at genuine end of stream -- a short read is as reliable an EOF
      # signal as a nil one, and without it a file ending mid-window on
      # its final, partial chunk was mistaken for one cut off by the
      # ceiling instead.
      def window_status(stop, chunk, windows_read)
        at_end = !stop.nil? || chunk.nil? || chunk.bytesize < CHUNK_BYTES
        [at_end, at_end || windows_read >= MAX_WINDOWS]
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

  # Whether a value bound to a namespace-declaration attribute name
  # violates the two prefixes and two namespace names XML reserves for
  # itself. Its own module because the rule is a self-contained set of
  # constraints, unrelated to how Detector chooses between formats or
  # resolves a value's references.
  module ReservedNamespace
    # XML permanently binds `xml` to this namespace; no other prefix, or
    # the default namespace, may be bound to it either.
    XML = "http://www.w3.org/XML/1998/namespace"
    # Reserved for the `xmlns` prefix's own use; must never be bound to
    # any prefix, including `xmlns` itself.
    XMLNS = "http://www.w3.org/2000/xmlns/"
    # Whatever survives the caller's character-reference resolution is
    # an unexpanded general entity -- unproven, not provably safe.
    GENERAL_ENTITY_REFERENCE = /&[A-Za-z_:][\w.:-]*;/

    module_function

    # `name` is the raw attribute name ("xmlns" or "xmlns:prefix");
    # `bound` is its value after the caller has already resolved
    # character references.
    def violated_by?(name, bound)
      return true if bound.nil? || bound.match?(GENERAL_ENTITY_REFERENCE)
      return true if bound == XMLNS

      (name == "xmlns:xml") != (bound == XML)
    end
  end

  module Detector
    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
    PDF_SIGNATURE = "%PDF-".b.freeze
    POSTSCRIPT_SIGNATURE = "%!PS".b.freeze
    SVG_NAMESPACE = "http://www.w3.org/2000/svg"

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
    # The most any single probe below will ever read from a source. Public
    # so Claricle.detect can size its own bounded IO read to match --
    # nothing downstream needs more than this, on any entry point.
    MAX_PROBE_BYTES = [HEADER_BYTES, SVG_PROLOG_BYTES, EpsHeader::MAX_SCAN_BYTES].max
    # One "name TYPE [#DEFAULT] value" group of an ATTLIST body, enough to
    # recover declaration order. Values may be absent (#REQUIRED etc).
    ATTLIST_DECLARATION = /
      (?<name>[\w:.-]+)\s+
      (?:\([^)]*\)|[A-Z]+(?:\s*\([^)]*\))?)\s*
      (?:\#(?:REQUIRED|IMPLIED)|(?:\#FIXED\s+)?(?:"(?<dq>[^"]*)"|'(?<sq>[^']*)'))
    /x

    class << self
      def detect(bytes)
        content = ::String.new(bytes).force_encoding(Encoding::BINARY)
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
      # The raw scan is the authority, which is deliberate and broader
      # than "it only fixes the order". REXML does report a lone
      # `#IMPLIED` as a nil, but it loses that tombstone to a duplicate
      # later in the same declaration, and a tombstone has to outrank
      # that later declaration. The scan also corrects a value REXML
      # mis-reports, such as one separated from `#FIXED` by a tab, which
      # arrives as `"#FIXED\t"`.
      #
      # REXML is the fallback, consulted only for attributes the regex
      # could not read at all. So a declaration the scan cannot parse
      # still contributes its parsed value, and one it can parse is taken
      # whole, tombstone included.
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
        # REXML reports a lone `#IMPLIED` as a nil but drops the tombstone
        # once a duplicate follows it, so it is consulted only for
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

      # Only the prolog and the root start tag can matter here. XML lets a
      # prolog run arbitrarily long, so this cuts the source off rather
      # than promising the root sits inside it. A root past the bound
      # reads as an unknown format, and the examples pin both sides.
      def bounded(source)
        StringIO.new(source.read(SVG_PROLOG_BYTES) || "")
      end

      def svg_root?(qname, attributes)
        prefix, local_name = qname.include?(":") ? qname.split(":", 2) : [nil, qname]
        return false unless local_name == "svg"
        return false if reserved_prefix_declared?(attributes)

        declared = attributes[prefix ? "xmlns:#{prefix}" : "xmlns"]
        return false unless declared

        resolve_references(declared) == SVG_NAMESPACE
      end

      # A constraint on the root's own namespace declarations, explicit
      # or DTD-defaulted, regardless of which prefix the root itself
      # uses -- delegated to ReservedNamespace once this method has
      # picked out which merged attributes are namespace declarations
      # at all and resolved each one's references.
      def reserved_prefix_declared?(attributes)
        attributes.any? do |name, value|
          next true if name == "xmlns:xmlns"
          next false unless name == "xmlns" || name.start_with?("xmlns:")

          ReservedNamespace.violated_by?(name, resolve_references(value))
        end
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
