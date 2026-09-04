# frozen_string_literal: true

require "rexml/parsers/pullparser"
require "rexml/xmltokens"

require_relative "errors"

module Claricle
  # Decides whether one conversion loses anything, from what the SOURCE
  # document contains rather than from a table of edges.
  #
  # The governing rule, and every guard below follows from it: a `lossless`
  # verdict is a positive claim and needs positive evidence. `lossy` and
  # `unknown` both tell the caller to look; only `lossless` tells them not to,
  # so only `lossless` can cause silent data loss. Wherever the evidence runs
  # out the answer is `unknown`.
  #
  # No conversion is performed here and no delegate is loaded. The losses this
  # classifies were measured on vectory 0.12.0 during design; vectory is not a
  # dependency of this gem and is never reached.
  module Lossiness
    LEVELS = %w[lossless lossy unknown].freeze

    # A source may be a bare BasicObject exposing only reader methods, so a
    # type test must not dispatch a method to it. Same idiom, and the same
    # reason, as models/free_form_hash.rb:28.
    CORE_INSTANCE = ::Object.instance_method(:is_a?)

    SVG_NAMESPACE = "http://www.w3.org/2000/svg"

    # Per target: features measured LOST, and features measured KEPT. A feature
    # in neither is unmeasured, so it yields `unknown`. A single "discards"
    # list would treat "not on the list" as "proven safe" -- measured, that
    # calls an <image> going to EMF lossless, which nobody has tested.
    RULES = {
      eps: { lost: %i[gradient clip_path embedded_raster], kept: %i[basic_shape] },
      emf: { lost: %i[gradient clip_path], kept: %i[basic_shape] }
    }.freeze

    # Derived, so a feature added to any `kept:` list is covered by the prefix
    # guard automatically rather than needing a second list kept in step.
    KEPT_FEATURES = RULES.values.flat_map { |rule| rule[:kept] }.uniq.freeze

    # The root carries no mark of its own, and `defs` is a container whose
    # children are scanned anyway. Nothing else is ignored: waving through an
    # element that IS lossy costs a false `lossless`, the one direction that
    # matters.
    IGNORED = %w[svg defs].freeze

    ELEMENTS = {
      "linearGradient" => :gradient, "radialGradient" => :gradient,
      "clipPath" => :clip_path, "image" => :embedded_raster,
      "rect" => :basic_shape, "line" => :basic_shape
    }.freeze

    ATTR_FEATURES = { "clip-path" => :clip_path }.freeze

    # The complement of XML 1.0's `Char` production. PullParser does not
    # enforce it -- measured, a U+001C in character data or in an `id` value
    # reaches `lossless` while REXML::Document refuses the same bytes -- so a
    # file no conformant parser will read was getting the one verdict that
    # tells the caller not to look.
    #
    # Matched against the characters a value DENOTES, never the bytes it
    # spells -- CharacterRules resolves references first, because REXML hands
    # attribute values back raw. And never against SOURCE bytes:
    # utf16_gradient.svg holds 193 bytes below 0x20 that are ordinary UTF-16
    # code units, and a byte-level guard condemns that legal document. REXML
    # hands every payload back as valid UTF-8 or raises trying -- measured over
    # every convert fixture in four source shapes, and over 14 hostile encoding
    # cases with declared-vs-actual mismatches and all five BOMs among them.
    ILLEGAL_CHAR = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/

    # Names admitted whatever their value: structural and identity only.
    ATTR_HARMLESS = %w[version id].freeze

    # `xml:space` and `xml:lang` affect character-data handling only, and no
    # element ELEMENTS proves KEPT renders character data: `rect` and `line`
    # draw a shape, and SVG does not paint text placed inside either. So the
    # allowance cannot change what a proven-kept document renders.
    #
    # NOT the stronger claim this comment used to make. "Every
    # character-data-bearing element is already unclassified" is false --
    # measured, `<rect xml:space="preserve">` in a document carrying text
    # classifies `lossless`, because a `rect` can BEAR character data even
    # though it never renders it. The conclusion holds; that reason did not.
    # No other prefix is allowed.
    ATTR_ALLOWED_PREFIXED = { "xml" => %w[space lang] }.freeze

    # An internal subset can make a document mean more than its markup shows:
    # an entity carrying elements, or an ATTLIST default that appears in no
    # start tag. REXML applies neither.
    SUBSET_DECLARATIONS = %i[entitydecl attlistdecl elementdecl notationdecl].freeze

    # Every EMITTED event type this scanner accounts for. Anything else is
    # unmeasured and yields `unclassified`, which closes the class rather than
    # an instance: `:externalentity` is emitted by `<!DOCTYPE svg [%missing;]>`
    # and is handled by that fallback, not by this list.
    #
    # NOT the same set as PullEvent's predicate methods, and the matching
    # counts are a coincidence. Measured, the two overlap in 10 of 14:
    #   predicates not here : [:doctype, :entity, :error, :instruction]
    #   here, not predicates: [:start_doctype, :end_doctype,
    #                          :processing_instruction, :end_document]
    # `doctype?`/`instruction?` are predicate names for the emitted
    # `:start_doctype`/`:processing_instruction`; `entity?` and `error?` are
    # never emitted at all. Compare the two sets, never their sizes:
    #   ruby -rrexml/parsers/pullparser -e 'p REXML::Parsers::PullEvent
    #     .instance_methods(false).grep(/\?\z/).map { |m| m.to_s.chomp("?").to_sym }'
    #
    # The four declaration types come from SUBSET_DECLARATIONS rather than
    # being spelled a second time, and the direction is why. Listed twice, the
    # two could drift, and that drift FAILS OPEN: dropping `:entitydecl` from
    # SUBSET_DECLARATIONS while this list still carried it turned an ENTITY
    # document from `unknown` into `lossless`. Derived, the same edit drops the
    # name from both, the event stops being recognised, and it falls to the
    # `:unclassified` catch-all -- the safe direction. Same route KEPT_FEATURES
    # takes above.
    KNOWN_EVENTS = (%i[
      start_element end_element text cdata comment xmldecl
      start_doctype end_doctype processing_instruction end_document
    ] + SUBSET_DECLARATIONS).freeze

    # Opaque solid colour only. ARGUED from the card's measurement that SVG->EPS
    # renders a gradient as solid black, so an opaque solid colour is
    # representable; these are the closed-grammar forms that can denote only
    # that. Never a "looks like a colour" pattern -- such a pattern admits
    # `transparent`, which implies an alpha channel EPS cannot represent.
    HEX_COLOUR = /\A#(?:\h{3}|\h{6})\z/
    RGB_COLOUR = /\Argb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)\z/
    # Self-contained lengths. A percentage resolves against a viewport, `em`
    # against a font, `mm` through a DPI setting -- all context the scanner
    # cannot see. Units are unsettled anyway (D15).
    NUMBER = /[+-]?(?:\d+\.\d+|\.\d+|\d+)/
    SELF_CONTAINED = /\A#{NUMBER}(?:px)?\z/
    # `width` and `height` are EXTENTS and SVG forbids a negative one, so
    # `width="-1"` describes no renderable document and must never earn a
    # positive `lossless` claim. `x`, `y` and the line endpoints are signed
    # COORDINATES and keep SELF_CONTAINED -- one pattern served both, which is
    # how a negative extent passed.
    NON_NEGATIVE = /\A\+?(?:\d+\.\d+|\.\d+|\d+)(?:px)?\z/
    # Four NUMBERS. The old `[\d.]+` was a run of digits and dots, not a number
    # grammar, so `. . . .` and `1.2.3 0 10 10` both matched.
    VIEWBOX = /\A\s*#{NUMBER}(?:[\s,]+#{NUMBER}){3}\s*\z/
    SOLID_COLOUR = Regexp.union(HEX_COLOUR, RGB_COLOUR)

    # Attribute name -> the pattern its value must match. One table rather than
    # two name lists plus a special case, following ELEMENTS and ATTR_FEATURES
    # above. A name absent here carries no value we have evidence for.
    VALUE_RULES = {
      "fill" => SOLID_COLOUR, "stroke" => SOLID_COLOUR,
      "width" => NON_NEGATIVE, "height" => NON_NEGATIVE,
      "x" => SELF_CONTAINED, "y" => SELF_CONTAINED,
      "x1" => SELF_CONTAINED, "y1" => SELF_CONTAINED,
      "x2" => SELF_CONTAINED, "y2" => SELF_CONTAINED,
      "viewBox" => VIEWBOX
    }.freeze

    class << self
      # `source` is a String of bytes or an open IO positioned at byte 0.
      def classify(source_format:, target_format:, source:)
        return "unknown" unless source_format == :svg

        rule = RULES[target_format]
        return "unknown" if rule.nil?

        refuse_unreadable(source)
        refuse_unpositioned(source)
        root_ok, present = scan(source)
        verdict(rule, root_ok, present)
      end

      private

      # The caller's own fault reaches them as their own exception, not as
      # a verdict and not wrapped in one of ours.
      def scan(source)
        tagged = TaggedSource.new(source)
        found = Scanner.new(tagged).run
        # Checked AFTER the scan, not raised through it. A `read`, `eof?` or
        # `pos` fault propagates out of `Scanner#run` on its own (REXML never
        # wraps those calls in a rescue -- see `TaggedSource`), so this only
        # ever fires for the rare case that somehow reaches here anyway; the
        # rescue below carries it out unwrapped either way.
        raise tagged.fault if tagged.fault

        # A `readline` fault is deliberately never escalated (see
        # `TaggedSource`), so REXML can absorb it exactly as it would for a
        # String -- but "absorbed" means the parse stopped wherever the fault
        # landed, not that it reached the document's real end. Measured: two
        # SVG roots, the second carrying a `lost` feature, with a `readline`
        # fault landing right as the first root closes (depth back to 0, so
        # `note_truncation` sees nothing wrong) -- the scan completes on the
        # first root ALONE and calls it `lossless`, while the real, untruncated
        # document is `unknown`. This is not specific to a hostile caller: the
        # identical result comes from literally truncating a plain String at
        # the same byte, with no IO or fault involved at all -- a pre-existing
        # gap this fix must not make newly reachable through the one route it
        # deliberately stops escalating. So ANY absorbed `readline` fault
        # forces the same `[root_ok, present]` shape `verdict` already reads
        # as `unknown` for a bad root (`false`, empty), never whatever
        # `Scanner` computed from the partial content it saw before the fault
        # -- the governing rule at the top of this file: wherever the
        # evidence runs out, including RIGHT here, the answer is `unknown`.
        return [false, []] if tagged.readline_faulted

        found
      rescue SourceFault => e
        raise e.original
      end

      def verdict(rule, root_ok, present)
        return "unknown" unless root_ok
        return "unknown" if present.empty?
        return "lossy" if present.intersect?(rule[:lost])

        (present - rule[:kept]).empty? ? "lossless" : "unknown"
      end

      # REXML answers a source it cannot read at all with a bare
      # `RuntimeError: NilClass is not a valid input stream.` -- measured for
      # nil, Integer, Array and Hash. That is a caller error exactly like the
      # two below, and this module already converts those, so letting a third
      # leak raw contradicted the contract these comments state. It is raised
      # here, outside the parse, for the same reason they are.
      def refuse_unreadable(source)
        # `respond_to?` first, then the ORIGINAL `Object#is_a?` bound and
        # called via `bind_call`, never `source.is_a?`: a caller may hand
        # over a bare BasicObject exposing only the reader methods, and
        # dispatching `is_a?` straight to it is itself a forbidden call --
        # measured, it broke the bounded-IO example. `bind_call` runs the
        # real method without depending on `source` still having it.
        return if source.respond_to?(:read) || CORE_INSTANCE.bind_call(source, ::String)

        raise InvocationError, "source must be a String or a readable IO"
      end

      # A partially consumed IO hides everything already read -- measured, an
      # internal ATTLIST seeked past classifies `lossless`. A pipe cannot
      # answer at all (`IO.pipe#pos` raises Errno::ESPIPE). Both are caller
      # errors, never verdicts, so this is raised outside the parse rescue.
      def refuse_unpositioned(source)
        refuse_closed(source)
        return unless source.respond_to?(:pos)

        position = begin
          source.pos
        rescue Errno::ESPIPE
          raise InvocationError, "source position is not observable"
        end
        return if position.zero?

        raise InvocationError, "source must be positioned at byte 0"
      end

      # Asked BEFORE `pos`, because `pos` does not agree across IO classes on a
      # closed stream -- measured: `File#pos` raises IOError, while
      # `StringIO#pos` returns 0 and sails through a position check, so the
      # failure surfaced later as a raw IOError from inside the scan. `closed?`
      # answers the same for both. A pipe is not closed, so this leaves the
      # ESPIPE case above reachable.
      def refuse_closed(source)
        return unless source.respond_to?(:closed?)
        return unless source.closed?

        raise InvocationError, "source is not readable: closed stream"
      end
    end

    # Attribute rules, extracted so Scanner stays inside Metrics/ClassLength
    # without an exemption -- the same route detector.rb takes.
    #
    # Every rule here answers by VALUE where a value can carry meaning. A name
    # proves nothing about what it holds: `fill` admitted `url(...)` and
    # `width` admitted `50%` while both were whitelisted by name.
    module AttributeRules
      module_function

      # The prefix decides FIRST, and the ordering is the rule. A namespace
      # declaration is `xmlns=` with no prefix, or `xmlns:foo=`. `foo:xmlns` is
      # neither -- it is an ordinary attribute in the foo namespace whose local
      # name merely happens to be `xmlns`. Testing the local name first let it
      # skip `prefixed` and, at the SVG namespace value, come back harmless:
      # measured, a `lossless` verdict for a document carrying an attribute
      # from a namespace nobody has measured.
      def feature_for(prefix, name, value)
        return :unclassified if CharacterRules.ill_formed?(value)
        return nil if prefix == "xmlns"
        return prefixed(prefix, name) if prefix
        return namespace(value) if name == "xmlns"

        ATTR_FEATURES[name] || valued(name, value)
      end

      # A default namespace can be rebound on any descendant, so this is
      # checked on every element rather than only on the root. Value-sensitive:
      # a redundant redeclaration of the SVG namespace is harmless.
      def namespace(value)
        value == SVG_NAMESPACE ? nil : :unclassified
      end

      def prefixed(prefix, name)
        ATTR_ALLOWED_PREFIXED[prefix]&.include?(name) ? nil : :unclassified
      end

      def valued(name, value)
        return nil if ATTR_HARMLESS.include?(name)

        rule = VALUE_RULES[name]
        return :unclassified if rule.nil?

        rule.match?(value) ? nil : :unclassified
      end
    end

    # Extracted for the reason AttributeRules is: Scanner stays inside
    # Metrics/ClassLength without an exemption.
    #
    # "Unaccounted for" rather than "illegal", because a value can fail to
    # establish its characters two ways and both are the same answer here: it
    # denotes something XML forbids, or it denotes something this scanner
    # cannot resolve at all.
    module CharacterRules
      module_function

      # Attribute values arrive as a Hash, and its KEYS are swept too: the
      # names REXML accepts are not the same set as the names XML 1.0 allows.
      # Only three classes reach here -- measured across every convert fixture
      # plus a document exercising all 14 event types: String, Hash, and nil
      # for an absent optional field such as an xmldecl's encoding.
      def unaccounted?(field)
        case field
        when String then unaccounted_text?(field)
        when Hash then field.any? { |name, value| unaccounted?(name) || unaccounted?(value) }
        else false
        end
      end

      # What REXML hands back is RAW for an attribute value: `id="a&#28;b"`
      # DENOTES five characters and SPELLS eight. Only character data gets a
      # decoded second field, so checking the bytes as given caught text by
      # accident of the event shape and let every name-admitted attribute
      # through -- `id`, `version`, `xml:space`, `xml:lang` and `xmlns:*` all
      # reached `lossless`. detector.rb:423-424 states the same fact about the
      # same parser, and this reuses the resolver it states it beside.
      #
      # The reference test runs on the RAW and the character test on the
      # RESOLVED. That order is the rule, not a convenience: `&amp;nope;`
      # denotes the literal text "&nope;", which is legal, and after
      # resolution it is indistinguishable from a genuinely unresolved
      # `&nope;`. AttributeReferences documents the same asymmetry.
      # A complete reference, so an INCOMPLETE one can be told apart from a
      # merely unresolvable one.
      VALID_REFERENCE = /&(?:\#\d+;|\#x\h+;|#{REXML::XMLTokens::NAME};)/

      # Well-formedness, which is narrower than "every character is legal".
      # `&amp` and `&#xZZ;` match no reference at all, so the unresolved test
      # never sees them, and the characters they spell are perfectly legal --
      # three guards in a row passed them while `id` supplied positive evidence
      # by name. A raw `<` is never permitted here either. REXML::Document
      # refuses every such document; PullParser reads it.
      #
      # PARSED character data ONLY -- attribute values and text. CDATA and
      # comments legally carry a raw `<` and a bare `&`, so a rule applied to
      # every field would condemn two shapes this suite pins as `lossless`.
      def ill_formed?(raw)
        raw.include?("<") || raw.gsub(VALID_REFERENCE, "").include?("&")
      end

      def unaccounted_text?(raw)
        return true if AttributeReferences.unresolved?(raw)

        resolved = AttributeReferences.resolve(raw)
        # nil is RangeError -- a reference outside Unicode. Invalid UTF-8 is a
        # surrogate or a codepoint above U+10FFFF, which `resolve` produces
        # WITHOUT raising. Both mean the denoted characters are unestablished,
        # and `match?` would raise rather than answer about either.
        return true if resolved.nil? || !resolved.valid_encoding?

        ILLEGAL_CHAR.match?(resolved)
      end
    end

    # One small method per surface, dispatched from the pull loop. Decomposed
    # rather than exempted: only Metrics/BlockLength is configured in
    # .rubocop.yml, so every default limit is live, and every cop exemption in
    # lib/ is a Style one -- there is no Metrics exemption anywhere.
    # detector.rb is 686 lines and clean by this same route.
    #
    # (Spelling that directive out in full here would BE one: RuboCop reads the
    # token in a comment, not the sentence around it. Measured -- it reported
    # Lint/RedundantCopDisableDirective on the first draft of this paragraph.)
    # Carries a fault raised by the CALLER's own source out past both parse
    # rescues. REXML invokes the reader INSIDE them, so without this an IO
    # whose `readline` raises came back as `unknown` -- a verdict about the
    # caller's document, when the fault was in their object.
    #
    # This is why the fault is tagged at its ORIGIN rather than inferred from
    # where a rescue sits. `PullParser.new` being outside the rescue proves
    # only that CONSTRUCTION is safe; it says nothing about where REXML READS.
    class SourceFault < StandardError
      def initialize(cause)
        @original = cause
        super(cause.message)
      end

      attr_reader :original
    end
    private_constant :SourceFault

    # Forwards to the caller's source and tags anything it raises, for every
    # delegated call EXCEPT `readline` -- the canonical explanation for that
    # carve-out lives on the `rescue StandardError` below, where the decision
    # is actually made; every other mention here is a pointer to it, not a
    # restatement, so there is exactly one place to correct if REXML's own
    # behaviour ever changes. Every source is wrapped, including a String: a
    # String cannot raise while being read, so the special case that skipped
    # it was a branch nothing could distinguish -- measured, always wrapping
    # passes the whole suite. REXML reaches a String through `to_str` and
    # then reads a StringIO, so the wrapper sees two or three delegated
    # calls and nothing after.
    class TaggedSource
      def initialize(source) = @source = source

      def respond_to_missing?(name, include_private = false)
        @source.respond_to?(name, include_private)
      end

      # Recorded as well as raised, for the calls that reach here at all --
      # `readline` never sets this, it sets `readline_faulted` instead. See
      # the `rescue StandardError` below for why, and for the REXML citation
      # both share.
      attr_reader :fault

      # Set (never unset) the moment a `readline` fault is deliberately let
      # through unescalated -- `scan`, above, reads this to force `unknown`
      # rather than trust a verdict computed from a parse that stopped
      # early. See the `rescue StandardError` below for why a `readline`
      # fault is left through in the first place.
      attr_reader :readline_faulted

      def method_missing(name, *, &)
        # `__send__`, never `public_send`: a bounded source may be a bare
        # BasicObject, which does not define `public_send`, so that call
        # lands in its own method_missing and reads as a forbidden access.
        # `__send__` is a real BasicObject method and dispatches cleanly.
        @source.__send__(name, *, &)
      rescue SourceFault
        raise
      rescue StandardError => e
        # CANONICAL explanation for the `readline` carve-out -- every other
        # comment in this class and its specs points here rather than
        # restating it.
        #
        # `readline` is a delegated call REXML absorbs rather than lets
        # escape, on every source shape, String included -- that absorption
        # is what already makes a malformed String classify `unknown`
        # instead of raising. Two mechanisms do it, not one: most of the
        # time it's `IOSource#read`'s own `rescue Exception, NameError`
        # (rexml source.rb:245-264, the rescue at :260-262); when `readline`
        # is instead called from `read_until` (source.rb:266-282, reachable
        # when a comment/attribute/text run holds a literal `>` before its
        # real terminator), THAT call is unguarded and it is
        # `BaseParser#pull_event`'s bare `rescue` (baseparser.rb:527-529)
        # that converts it to a `REXML::ParseException` instead, which
        # `Scanner#next_event`'s own rescue then catches. Either way REXML
        # ends the parse rather than raising past its own boundary, so a
        # caller's `readline` that always fails is indistinguishable, from
        # outside REXML, from REXML's OWN read strategy hitting one of these
        # on a perfectly ordinary File: measured, `readline` fails on 7 real,
        # already-shipped fixtures (DOCTYPE internal subsets, UTF-16) only
        # after 6-10 PRIOR successful `readline` calls on the very same
        # object -- tagging this raised `EOFError`/`ArgumentError` as a
        # caller fault and re-reporting it after the scan (see `scan` above)
        # turned those ordinary fixtures into a raw exception instead of the
        # `unknown` their String form correctly gets.
        #
        # Left through unescalated, REXML does with this exactly what it
        # does for a String. That is not, on its own, enough to trust
        # whatever verdict the scan then computes -- see `readline_faulted`
        # and `scan`'s use of it -- but it is enough to guarantee the scan
        # completes instead of crashing, which is this whole carve-out's job.
        if name == :readline
          @readline_faulted = true
          raise e
        end

        @fault ||= e
        raise SourceFault, e
      end
    end
    private_constant :TaggedSource

    class Scanner
      # Raised by `next_event` and caught by `run`, so the two failures that
      # both mean "REXML refused this document" converge on one verdict without
      # a flag whose only job is to skip the lines after the loop. Never
      # escapes this class.
      class Unreadable < StandardError; end
      private_constant :Unreadable

      def initialize(source)
        @source = source
        @found = []
        @root_ok = false
        @depth = 0
        @roots = 0
        @phase = :prolog
      end

      # This rescue no longer covers the parser -- `next_event` does, and
      # `Unreadable` is how it reports one. What is left for this one is
      # `consume` and AttributeRules, which genuinely raise ArgumentError:
      # measured, every value rule raises `ArgumentError: invalid byte sequence
      # in UTF-8` on invalid-UTF-8 input. That stays unreachable while REXML
      # transcodes or raises first, and the direction is safe.
      #
      # REXML::ParseException is gone from here because it can no longer arrive
      # here: nothing outside the parser raises it.
      def run
        parser = REXML::Parsers::PullParser.new(@source)
        while (event = next_event(parser))
          consume(event)
        end
        note_truncation
        [@root_ok, @found.uniq]
      rescue Unreadable, ArgumentError
        [false, [:unclassified]]
      end

      private

      # The rescue wraps the parser ALONE, the route detector.rb:417-421 takes,
      # and that is what makes catching RuntimeError here safe. REXML defends
      # itself against entity bombs with two BARE `raise "..."` sites reachable
      # from this loop -- baseparser.rb:642 "number of entity expansions
      # exceeded" and :600 "entity expansion has grown too large" -- and both
      # escaped `classify`, which is documented to return one of three levels.
      #
      # Catching RuntimeError around the WHOLE scan instead would report a bug
      # in `consume` or AttributeRules as an unreadable document. Here nothing
      # of ours runs inside, so there is no fault of ours to swallow.
      #
      # It is also a NARROWING, not a widening: REXML::ParseException is itself
      # a RuntimeError -- measured, `[ParseException, RuntimeError, StandardError,
      # Exception]` -- so the class this used to catch is a subset of the one it
      # catches now. Listing both would be Lint/ShadowedException. ArgumentError
      # is separate: it is REXML's answer to an unusable encoding name.
      #
      # `PullParser.new` sits OUTSIDE, deliberately. A source that is neither
      # String nor IO raises `RuntimeError: NilClass is not a valid input
      # stream.` there -- measured for nil, Integer, Array and Hash -- and that
      # is a caller error, never a verdict.
      def next_event(parser)
        parser.pull if parser.has_next?
      rescue RuntimeError, ArgumentError
        raise Unreadable
      end

      # PullParser does NOT report an unclosed element stack at EOF; only
      # REXML::Document does. So "REXML raised" is not the whole of
      # malformedness -- measured, `malformed.svg` is a MISMATCHED END TAG,
      # which raises, while EOF-with-an-open-stack does not. Truncating
      # large_trailing_gradient.svg by 30 bytes turned `lossy` into
      # `lossless`: losing evidence made the verdict MORE confident, the exact
      # inversion the rule at the top of this file forbids.
      #
      # The depth was already tracked and simply never consulted. A bare
      # self-closing root (`<svg .../>`) also ends at depth 1, because REXML
      # emits `[:start_element]` alone for it -- that document always has an
      # empty feature set, so the ladder answers `unknown` either way and this
      # guard costs it nothing. Both are pinned by fixture.
      def note_truncation
        note(:unclassified) unless @depth.zero?
      end

      def note(feature)
        @found << feature
      end

      # EVERY field of every event, not the character-data ones alone. The
      # obvious guard checks `:text`, `:cdata` and `:comment`; `id` is exactly
      # the route that list misses, because ATTR_HARMLESS admits it by NAME and
      # its value never reaches a value rule -- measured, `id="a\u001Cb"`
      # classified `lossless`. A list of the routes we thought of is what let
      # this through in the first place.
      #
      # `event[0..]` is PullEvent's Range form, `@contents.slice(1..nil)`, so it
      # yields the whole tail whatever the event's arity -- measured 0 to 5
      # across all 14 emitted types, the widest being an entity declaration
      # with a PUBLIC id and an NDATA notation. No bound to keep in step.
      # A `:text` event carries the raw source AND REXML's own decoding of
      # it; only the first is source. The decoded copy answers a question
      # this file answers for itself, and reading it made an ESCAPED
      # reference indistinguishable from a genuine one -- measured, the
      # decoded forms of `a&amp;nope;b` and `a&nope;b` are byte-identical
      # while the raw forms are not. The attribute path always read the raw,
      # which is why attributes were right when text was not.
      def note_unaccounted_characters(event)
        text = event.event_type == :text
        fields = text ? [event[0]] : event[0..]
        note(:unclassified) if fields.any? { |f| CharacterRules.unaccounted?(f) }
        note(:unclassified) if text && CharacterRules.ill_formed?(event[0])
      end

      def consume(event)
        note(:unclassified) unless KNOWN_EVENTS.include?(event.event_type)
        note_unaccounted_characters(event)
        note_declarations(event)
        return close_element if event.event_type == :end_element

        note_epilog(event)
        visit_element(event) if event.start_element?
      end

      # An external subset is never fetched and an internal one is never
      # applied, so either can change what the document means unobserved.
      def note_declarations(event)
        note(:unclassified) if SUBSET_DECLARATIONS.include?(event.event_type)
        note(:unclassified) if event.event_type == :processing_instruction
        return unless event.event_type == :start_doctype

        note(:unclassified) if %w[SYSTEM PUBLIC].include?(event[1].to_s)
      end

      def close_element
        @depth -= 1
        @phase = :epilog if @depth.zero?
      end

      # REXML accepts a second root and post-root CDATA without raising --
      # measured, [svg, rect, line, rect] for a document with two roots.
      #
      # Two omissions from this list are deliberate, both measured over every
      # post-root shape. `:text` is DEAD: post-root text raises ParseException
      # before reaching here, and post-root whitespace emits no text event at
      # all, so it never fires -- removed rather than kept as a fail-safe,
      # because an unreachable branch is indistinguishable from an untested
      # one to the next reader. `:comment` is absent because a comment after
      # the root is legal XML, not evidence of anything.
      def note_epilog(event)
        return unless @phase == :epilog
        return unless %i[start_element cdata].include?(event.event_type)

        note(:unclassified)
      end

      def visit_element(event)
        prefix, name = split_name(event[0])
        root = @depth.zero?
        visit_root(prefix, name, event[1]) if root
        @depth += 1
        visit_attributes(event[1])
        feature = element_feature(prefix, name, root)
        note(feature) if feature
      end

      # A local name alone is not proof: `<svg xmlns="...notsvg">` and a bare
      # `<svg>` both pass it. The namespace must be declared POSITIVELY --
      # "not foreign" is satisfied vacuously by an absent declaration.
      def visit_root(prefix, name, attributes)
        @roots += 1
        return note(:unclassified) if @roots > 1

        @root_ok = name == "svg" && prefix.nil? &&
                   attributes["xmlns"] == SVG_NAMESPACE
        # Absent dimensions depend on the same unseen viewport context as a
        # percentage; handlers/svg.rb:116-119 takes the same position.
        note(:unclassified) unless attributes["width"] && attributes["height"]
      end

      def visit_attributes(attributes)
        attributes.each do |qualified, value|
          feature = AttributeRules.feature_for(*split_name(qualified), value)
          note(feature) if feature
        end
      end

      # Two orderings matter here.
      #
      # The prefix test runs BEFORE the IGNORED skip: `<foo:defs/>` strips to
      # "defs", and being skipped as structural is how a foreign-namespace
      # element reached a `lossless` verdict.
      #
      # And only the CONFIRMED ROOT `<svg>` is structural. A nested `<svg>` is
      # a new viewport with its own coordinate system, and is unmeasured --
      # measured, ignoring it by name classified such a document `lossless`
      # while everything inside the inner viewport went uncounted. So IGNORED
      # membership is positional, not nominal.
      def element_feature(prefix, name, root)
        return :unclassified if prefix && IGNORED.include?(name)
        return structural_feature(name, root) if IGNORED.include?(name)

        content_feature(prefix, name)
      end

      def structural_feature(name, root)
        return nil if name == "defs" || root

        :unclassified
      end

      def content_feature(prefix, name)
        feature = ELEMENTS.fetch(name, :unclassified)
        prefix && KEPT_FEATURES.include?(feature) ? :unclassified : feature
      end

      def split_name(qualified)
        qualified.include?(":") ? qualified.split(":", 2) : [nil, qualified]
      end
    end
  end

  private_constant :Lossiness
end
