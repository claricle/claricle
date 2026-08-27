# frozen_string_literal: true

require "stringio"
require "rexml/parsers/pullparser"
require "rexml/source"
require "rexml/text"
require "rexml/xmltokens"
require "emf"

module Claricle
  # Attribute defaults declared in an internal DTD subset. XML 1.0
  # requires a processor to apply them and REXML's DOM does, but the
  # PullParser hands the declarations over raw, so this reassembles them.
  # Its own module because the precedence rules are a self-contained
  # concern, and Detector is about choosing between formats.
  #
  # Known gap, upstream: REXML raises "Bad ATTLIST declaration!" for a
  # `#FIXED '...'` default, which XML permits. Only that combination --
  # measured: a plain single-quoted default reads fine, and so does
  # `#FIXED "..."`. It happens inside REXML before any event reaches us,
  # so such a document is reported as an unknown format. It fails closed
  # rather than misdetecting, and working around REXML's DTD parser
  # would cost more than the gap.
  module AttributeDefaults
    XML_NAME = "#{REXML::XMLTokens::NAME_START_CHAR}" \
               "#{REXML::XMLTokens::NAME_CHAR}*".freeze

    # One "name TYPE [#DEFAULT] value" group of an ATTLIST body, enough
    # to recover declaration order. Values may be absent (#REQUIRED etc).
    DECLARATION = /
      (?<name>#{XML_NAME})\s+
      (?:\([^)]*\)|[A-Z]+(?:\s*\([^)]*\))?)\s*
      (?:\#(?:REQUIRED|IMPLIED)|(?:\#FIXED\s+)?(?:"(?<dq>[^"]*)"|'(?<sq>[^']*)'))
    /x

    private_constant :XML_NAME, :DECLARATION

    class << self
      # XML accumulates ATTLIST declarations and the FIRST declaration of
      # an attribute binds, so a later one neither replaces the element's
      # earlier defaults nor overrides a duplicate.
      #
      # Duplicates inside ONE declaration need the raw source: REXML
      # collapses them last-wins before handing over the parsed hash. The
      # raw scan is the authority, and broader than "it only fixes the
      # order". REXML DOES report a lone `#IMPLIED` as a nil, but it
      # loses that tombstone to a duplicate later in the same
      # declaration, and a tombstone has to outrank that later
      # declaration. The scan also corrects a value REXML mis-reports,
      # such as one separated from `#FIXED` by a tab, which arrives as
      # `"#FIXED\t"`. REXML is the fallback, for attributes the regex
      # could not read at all.
      def collect(defaults, event, declarations)
        element = event[0]
        event[1].each { |name, value| declarations[name] = value unless declarations.key?(name) }
        defaults[element] = declarations.merge(defaults[element] || {})
      end

      # Explicit attributes beat declared defaults, and only the final
      # merged hash is compacted -- dropping tombstones earlier would let
      # a later declaration resurrect an attribute XML left undeclared.
      def for_root(event, defaults)
        defaults.fetch(event[0], {}).merge(event[1]).compact
      end

      # nil is a real answer here -- `#IMPLIED` means "declared, no
      # default" -- so first-wins is decided by key?, never by the
      # value's truthiness. RootParser also uses this exact scan to make
      # canonical DTD-defaulted namespace prefixes visible to REXML's
      # namespace validator before it reaches the root.
      def declarations(raw)
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

  # The shared leaf of attribute-value resolution. Extracted because its
  # callers want different things. `Detector.resolve` validates the result
  # and falls back to its already-normalized input. `svg_root?` and
  # `reserved_prefix_declared?` need the leaf raw instead: a nil from an
  # out-of-range reference has to reach `ReservedNamespace.violated_by?` so
  # it fails closed, and detection has to see that same failure rather than
  # read the raw text as if it had resolved to itself. One entry point
  # cannot serve both without hiding that.
  module AttributeReferences
    # The five entities XML itself defines -- measured: `unnormalize`
    # expands exactly these (plus numeric references) and leaves every
    # other named reference, of any case, byte-for-byte untouched, since
    # it has no entity table beyond them. Checked against the RAW value,
    # never a resolved one: raw "&amp;foo;b=2" resolves to "&foo;b=2",
    # an escaped ampersand in a query string followed by ordinary text,
    # and once resolution has run that is indistinguishable from a
    # genuinely unresolved "&foo;". Deliberately not "&amp;" as the
    # example -- the lookahead already excludes those five, so they read
    # the same whichever value is checked and prove nothing.
    #
    # Use REXML's canonical XML Name production rather than maintaining a
    # second transcription that can drift from the parser adapter below.
    UNRESOLVED_REFERENCE = /&(?!amp;|lt;|gt;|apos;|quot;)#{REXML::XMLTokens::NAME};/

    module_function

    def resolve(value)
      REXML::Text.unnormalize(value, entity_expansion_text_limit: value.bytesize)
    rescue RangeError
      nil
    end

    # True for a raw value `resolve` cannot fully account for: a named
    # reference it has no table for, left exactly as written rather than
    # expanded. Unproven, not provably safe -- Claricle never fetches a
    # DTD-declared entity, so a reserved namespace name smuggled in
    # through one would sail past a check that only compared bytes.
    #
    # The encoding check makes the predicate total, which it stopped
    # being when the pattern gained non-ASCII ranges: `match?` RAISES
    # rather than answers on a subject that is neither ASCII-only nor
    # valid UTF-8 (measured: Encoding::CompatibilityError for BINARY
    # carrying a high byte, ArgumentError for invalid UTF-8). So a
    # subject it cannot read reads as unresolved -- unproven, which is
    # this module's whole meaning. Measured unreachable from `detect`
    # today: every value REXML hands over arrives valid UTF-8, across
    # every declared encoding and BOM tried.
    def unresolved?(raw)
      return true unless raw.ascii_only? ||
                         (raw.encoding == Encoding::UTF_8 && raw.valid_encoding?)

      raw.match?(UNRESOLVED_REFERENCE)
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

    module_function

    # `name` is the raw attribute name ("xmlns" or "xmlns:prefix");
    # `bound` is its resolved value, or nil for an out-of-range
    # reference. The caller has already refused an unresolved general
    # entity reference before calling this -- see
    # `AttributeReferences.unresolved?` -- so `bound` here is always
    # either nil or fully accounted for. A lone surrogate half resolves
    # to invalid UTF-8 without raising, so it reaches here as a string,
    # not nil; checked before `==`, because a comparison against invalid
    # encoding is exactly as unproven as one that raised outright.
    def violated_by?(name, bound)
      return true if bound.nil? || !bound.valid_encoding?
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

      # The root element's qname and its attributes, or nil. The qname
      # comes back raw: a reference is not permitted in a name, so there
      # is nothing there to resolve. Each attribute is resolved once,
      # falling back to its normalized-but-unresolved text when
      # resolution cannot answer -- the right default for something
      # about to be reported as metadata, not decided on. nil covers
      # every way the root can be unavailable: no root inside the
      # bound, markup REXML refuses, and an encoding name it cannot
      # use. Callers treat all three the same -- there is nothing to
      # report about -- so they are not distinguished here. Public
      # because Handlers::Svg needs exactly this and a second reader
      # would have to reimplement the bound and the ATTLIST precedence
      # -- rules this file spent four review rounds getting right --
      # and then agree with this one. `svg?` below shares that same
      # parsing through `root_event`, but resolves its own xmlns-bearing
      # attributes bare, with no fallback: detection has to fail closed
      # when a reference can't be resolved, where this method's fallback
      # would hide that. `Detector` is itself a private constant, so
      # nothing about the gem's documented surface changes.
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

      # The rescue wraps the parser alone, for the same reason resolution
      # sits outside it in read_root: an ArgumentError raised while
      # assembling attribute defaults is a fault in this file, and
      # reporting it as "this file has no root" would hide it behind an
      # unknown format.
      def root_event(source)
        parser = RootParser.new(bounded(source))
        defaults = {}
        while (event = next_event(parser))
          parser.collect_defaults(defaults, event) if event.event_type == :attlistdecl
          return [event[0], AttributeDefaults.for_root(event, defaults)] if event.start_element?
        end
        nil
      end

      # nil for end of input and for a document the parser refuses,
      # which callers already treat the same way. The bare ArgumentError
      # is REXML's answer to an unusable encoding name; every other
      # ArgumentError belongs to whoever raised it.
      def next_event(parser)
        REXML::Parsers::PullEvent.new(parser.pull) if parser.has_next?
      rescue REXML::ParseException, ArgumentError
        parser.propagate_adapter_error
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
        attributes.transform_values { |value| resolve(normalized(value)) }
      end

      def resolve(value)
        usable(AttributeReferences.resolve(value)) || value
      end

      # XML 1.0 3.3.3, and the reason it has to happen BEFORE references
      # are expanded: in a CDATA attribute a literal tab, CR or newline
      # is replaced by a space, while a character reference to one is
      # kept as that character. So `id="a<LF>b"` is "a b" and
      # `id="a&#xA;b"` is "a\nb", and both arrive here as raw text --
      # without this they would be reported identically.
      #
      # CRLF is one line ending and becomes ONE space (XML 2.11 runs
      # first). Doing it here rather than leaving it to REXML is
      # measured, not assumed: REXML folds a literal CR to LF, but only
      # later, inside reference resolution -- too late to be normalized
      # -- and its own DOM never normalizes attribute values at all.
      #
      # The CDATA rule and only that rule. XML also trims and collapses
      # spaces for a NON-CDATA attribute, and this deliberately does
      # not: the type comes from the DTD, and an external subset is the
      # normal way to declare one -- SVG's own DTD is external -- which
      # a bounded reader can neither fetch nor should. Implementing the
      # internal-subset half would make the value right for a locally
      # declared NMTOKENS and wrong for the same attribute declared
      # externally, with nothing to tell the two apart. One uniform
      # rule is the honest answer. Measured: REXML's DOM does not
      # collapse an internally declared NMTOKENS either.
      def normalized(value)
        value.gsub(/\r\n|[\t\r\n]/, " ")
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
        found = root_event(source)
        return false unless found

        svg_root?(*found)
      end

      # Only the prolog and the root start tag can matter here, and the
      # bound is where they stop mattering: a root that begins after
      # SVG_PROLOG_BYTES is not found at all, and the document reads as
      # an unknown format. That is the sniffing limit SVG_PROLOG_BYTES
      # describes, deliberately, not an accident of sizing.
      #
      # Takes an IO or a String, because both callers hand over
      # whichever the image is made of: an open file for a path-born
      # source, the bytes already in hand for a content-born one.
      def bounded(source)
        prefix = if source.respond_to?(:read)
                   # Nothing to normalise on this side: `read(n)` answers
                   # in ASCII-8BIT whatever the source's own encoding is.
                   # Measured for File in r, rb, r:Shift_JIS and
                   # r:ISO-8859-1, and for StringIO over a UTF-16LE string.
                   source.read(SVG_PROLOG_BYTES)
                 else
                   # byteslice, not slice: the bound is BYTES, and
                   # `source[0, n]` counts characters, so a multibyte
                   # prolog would let the handler read further than
                   # detection did and the two would disagree.
                   #
                   # `.b` because byteslice keeps the String's encoding
                   # tag. It is not what protects handler inspection --
                   # `Image.from_content` binary-tags on the way in, so
                   # a handler's bytes arrive ASCII-8BIT already. It
                   # protects whoever calls `read_root` with a String of
                   # their own: the SAME ASCII bytes tagged UTF-16LE
                   # read back zero events without it, because REXML
                   # decoded ASCII as UTF-16 and the pull loop ended, so
                   # inspection said "failed" without raising.
                   source.byteslice(0, SVG_PROLOG_BYTES).b
                 end
        # XML defaults to UTF-8 when neither a declaration nor a BOM says
        # otherwise. Tag, do not transcode, the already-bounded copy; REXML
        # still detects either marker and switches encodings itself. dup also
        # keeps a frozen read result or the empty fallback safe to retag.
        RootSource.for((prefix || "").dup.force_encoding(Encoding::UTF_8))
      end

      def svg_root?(qname, attributes)
        prefix, local_name = qname.include?(":") ? qname.split(":", 2) : [nil, qname]
        return false unless local_name == "svg"
        return false if reserved_prefix_declared?(attributes)

        declared = attributes[prefix ? "xmlns:#{prefix}" : "xmlns"]
        return false unless declared

        # Normalized and resolved here, fresh from the raw attribute
        # `root_event` handed over -- never from an ALREADY-resolved
        # value, and never `resolve`'s raw-on-failure fallback: deciding
        # whether this document IS an SVG needs to know a reference
        # failed, not read its raw text as if it had resolved to itself.
        # `reserved_prefix_declared?` below resolves this same raw text
        # again, independently, for its own guard -- two resolutions of
        # the SAME raw input agree and cost nothing worth threading a
        # value through two methods to avoid. What must never happen is
        # CASCADING, resolving one method's already-resolved output a
        # second time: `&amp;#x67;` means the literal text `&#x67;`, and
        # a second pass on THAT output turns it into `g`.
        AttributeReferences.resolve(normalized(declared)) == SVG_NAMESPACE
      end

      # A constraint on the root's own namespace declarations, explicit
      # or DTD-defaulted, regardless of which prefix the root itself
      # uses. Each value is resolved fresh from the raw attribute
      # `root_event` handed over, never from an already-resolved one --
      # delegated to ReservedNamespace once this method has picked out
      # which merged attributes are namespace declarations at all,
      # refused one still carrying an unresolved reference, and resolved
      # the rest.
      def reserved_prefix_declared?(attributes)
        attributes.any? do |name, value|
          next true if name == "xmlns:xmlns"
          next false unless name == "xmlns" || name.start_with?("xmlns:")
          next true if AttributeReferences.unresolved?(value)

          ReservedNamespace.violated_by?(name, AttributeReferences.resolve(normalized(value)))
        end
      end
    end
  end

  module Detector
    # REXML publishes XML's canonical name grammar in XMLTokens, but its
    # BaseParser's live root, attribute, prolog and internal-subset scans use
    # older, narrower productions. Keep the workaround on this one bounded
    # source rather than changing REXML's process-wide constants. Rewriting
    # the grammar fragments, rather than enumerating current regex objects,
    # also reaches NAME copies embedded in ATTLIST and ENTITY patterns while
    # preserving every surrounding capture exactly.
    class RootSource < REXML::IOSource
      base = REXML::Parsers::BaseParser
      tokens = REXML::XMLTokens
      SUBSTITUTIONS = [
        [base::NCNAME_STR.dup.freeze, tokens::NCNAME_STR.dup.freeze].freeze,
        [base::NAME.dup.freeze, tokens::NAME.dup.freeze].freeze,
        [base::NMTOKEN.dup.freeze, tokens::NMTOKEN.dup.freeze].freeze
      ].freeze

      private_constant :SUBSTITUTIONS

      attr_reader :adapter_error

      def self.for(content)
        content.ascii_only? ? StringIO.new(content) : new(content)
      end

      def initialize(content)
        super(StringIO.new(content))
      end

      # Positional `consume` matches the REXML method BaseParser calls.
      def match(pattern, consume = false) # rubocop:disable Style/OptionalBooleanParameter
        pattern = canonical(pattern)
        # The first argument was deliberately replaced, so zsuper would send
        # the original regex and silently undo the adapter.
        super(pattern, consume) # rubocop:disable Style/SuperArguments
      end

      private

      def canonical(pattern)
        return pattern unless pattern.is_a?(Regexp)

        @canonical_patterns ||= {}.compare_by_identity
        @canonical_patterns[pattern] ||= rewritten(pattern)
      rescue StandardError => e
        @adapter_error = e
        raise
      end

      def rewritten(pattern)
        source = SUBSTITUTIONS.reduce(pattern.source) do |candidate, (narrow, canonical)|
          candidate.gsub(narrow) { canonical }
        end
        return pattern if source == pattern.source

        Regexp.new(source, pattern.options)
      end
    end

    # BaseParser validates a root prefix against namespaces it learned while
    # parsing. Its direct String#scan of an ATTLIST body cannot be adapted by
    # RootSource, so register canonical DTD-defaulted namespace declarations
    # from the same scan Detector later uses to merge attribute defaults.
    class RootParser < REXML::Parsers::BaseParser
      def propagate_adapter_error
        error = source.adapter_error if source.is_a?(RootSource)
        raise error if error
      end

      # Called between pulls so Claricle-owned failures remain outside the
      # parser-only rescue in Detector.next_event.
      def collect_defaults(defaults, event)
        declarations = AttributeDefaults.declarations(event[2])
        register_declared_namespaces(declarations)
        AttributeDefaults.collect(defaults, event, declarations)
      end

      private

      def register_declared_namespaces(declarations)
        declarations.each do |name, value|
          next unless value && name.start_with?("xmlns:")

          prefix = name.delete_prefix("xmlns:")
          @namespaces[prefix] = value unless @namespaces.key?(prefix)
        end
      end
    end

    private_constant :RootSource, :RootParser
  end

  private_constant :Detector, :EpsHeader, :ReservedNamespace,
                   :AttributeDefaults, :AttributeReferences
end
