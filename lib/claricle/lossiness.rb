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
    KNOWN_EVENTS = %i[
      start_element end_element text cdata comment xmldecl
      start_doctype end_doctype entitydecl attlistdecl elementdecl
      notationdecl processing_instruction end_document
    ].freeze

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

      def feature_for(prefix, name, value)
        return namespace(value) if name == "xmlns"
        return nil if prefix == "xmlns"
        return prefixed(prefix, name) if prefix

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
      def initialize(source)
        @source = source
        @found = []
        @root_ok = false
        @depth = 0
        @roots = 0
        @phase = :prolog
      end

      # The rescue wraps the WHOLE scan, not the parse alone -- `consume` and
      # AttributeRules run inside it, and they genuinely raise ArgumentError:
      # measured, every value rule raises `ArgumentError: invalid byte sequence
      # in UTF-8` on invalid-UTF-8 input. That is unreachable today because
      # REXML raises ParseException on such a document first, and the direction
      # is safe (an unreadable document is `unknown`), but the comment used to
      # claim a narrower scope than the code has.
      #
      # RuntimeError is deliberately omitted, matching detector.rb:383-393: an
      # unusable encoding name raises a bare ArgumentError from the parser,
      # while a RuntimeError raised elsewhere is a different fault that must
      # not be reported as an unreadable document.
      def run
        parser = REXML::Parsers::PullParser.new(@source)
        consume(parser.pull) while parser.has_next?
        note_truncation
        [@root_ok, @found.uniq]
      rescue REXML::ParseException, ArgumentError
        [false, [:unclassified]]
      end

      private

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

      def consume(event)
        note(:unclassified) unless KNOWN_EVENTS.include?(event.event_type)
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

      # REXML accepts a second root and post-root character data without
      # raising -- measured, [svg, rect, line, rect] for a document with two.
      def note_epilog(event)
        return unless @phase == :epilog
        return unless %i[start_element text cdata].include?(event.event_type)

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
