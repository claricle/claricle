# frozen_string_literal: true

require "rexml/parsers/pullparser"

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
    # Matched against DECODED characters, never against source bytes.
    # utf16_gradient.svg holds 193 bytes below 0x20 that are ordinary UTF-16
    # code units, and a byte-level guard condemns that legal document. REXML
    # hands every payload back as valid UTF-8 or raises trying -- measured over
    # every convert fixture in four source shapes, and over 14 hostile encoding
    # cases with declared-vs-actual mismatches and all five BOMs among them.
    ILLEGAL_CHAR = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/

    # Names admitted whatever their value: structural and identity only.
    ATTR_HARMLESS = %w[version id].freeze

    # `xml:space` and `xml:lang` affect character-data handling only, and every
    # character-data-bearing element is already unclassified by ELEMENTS' own
    # catch-all -- so this allowance cannot produce a wrong `lossless`. No other
    # prefix is allowed.
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
    SELF_CONTAINED = /\A[+-]?(?:\d+\.\d+|\.\d+|\d+)(?:px)?\z/
    VIEWBOX = /\A\s*[+-]?[\d.]+(?:[\s,]+[+-]?[\d.]+){3}\s*\z/
    SOLID_COLOUR = Regexp.union(HEX_COLOUR, RGB_COLOUR)

    # Attribute name -> the pattern its value must match. One table rather than
    # two name lists plus a special case, following ELEMENTS and ATTR_FEATURES
    # above. A name absent here carries no value we have evidence for.
    VALUE_RULES = {
      "fill" => SOLID_COLOUR, "stroke" => SOLID_COLOUR,
      "width" => SELF_CONTAINED, "height" => SELF_CONTAINED,
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

        refuse_unpositioned(source)
        root_ok, present = Scanner.new(source).run
        verdict(rule, root_ok, present)
      end

      private

      def verdict(rule, root_ok, present)
        return "unknown" unless root_ok
        return "unknown" if present.empty?
        return "lossy" if present.intersect?(rule[:lost])

        (present - rule[:kept]).empty? ? "lossless" : "unknown"
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
    module CharacterRules
      module_function

      # Attribute values arrive as a Hash, and its KEYS are swept too: the
      # names REXML accepts are not the same set as the names XML 1.0 allows.
      # Only three classes reach here -- measured across every convert fixture
      # plus a document exercising all 14 event types: String, Hash, and nil
      # for an absent optional field such as an xmldecl's encoding.
      def illegal?(field)
        case field
        when String then ILLEGAL_CHAR.match?(field)
        when Hash then field.any? { |name, value| illegal?(name) || illegal?(value) }
        else false
        end
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
      def note_illegal_characters(event)
        note(:unclassified) if event[0..].any? { |field| CharacterRules.illegal?(field) }
      end

      def consume(event)
        note(:unclassified) unless KNOWN_EVENTS.include?(event.event_type)
        note_illegal_characters(event)
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
