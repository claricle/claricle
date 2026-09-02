# frozen_string_literal: true

require "rexml/parsers/baseparser"

require_relative "base"
require_relative "../detector"
require_relative "../models/inspection"
require_relative "../models/issue"

module Claricle
  module Handlers
    # Reports what an SVG's root element declares. It reads the root and
    # nothing else: everything inspection reports lives there, and parsing
    # megabytes of path data to fetch the root's attributes would be work
    # with no output.
    #
    # So `parse_status` is scoped to the root prefix, and says only that
    # the root start tag was readable. Bytes past that tag are read --
    # the bound is 8192 either way -- but nothing in them is parsed, so
    # a document malformed only after it still reports "ok". Measured on
    # five shapes: damage after the root, a second root element, an
    # unclosed root, a mismatched end tag and a truncation mid-body.
    # REXML's DOM rejects all five, this reports "ok" for all five, and
    # a spec pins each one.
    #
    # That is a narrower promise than well-formedness, not a weaker
    # check. D23 asks that the status come from Claricle's own
    # structural check rather than from a delegate staying quiet, and
    # this one is affirmative: the reader must hand back a root start
    # event or the inspection fails. Judging the whole document is
    # conformance (D16, item 03), and it would cost the bounded read --
    # a 64.0 MiB SVG costs +0.8 MiB here and +64.5 MiB once every byte
    # has to be parsed.
    class Svg < Base
      formats :svg

      # CSS absolute lengths, all defined against 1in = 96px. Computed
      # from that anchor rather than copied: 72pt, 6pc and 1in all come
      # to 96.0. Q is listed because CSS defines it: an absolute unit
      # missing from this table is indistinguishable from a relative one,
      # and both come back nil -- the right answer for `%`, the wrong
      # answer for `Q`. Relative units need no table of their own; they
      # are simply anything absent here.
      PX_PER_INCH = 96.0
      ABSOLUTE_UNITS = {
        "px" => 1.0,
        "in" => PX_PER_INCH,
        "pc" => PX_PER_INCH / 6.0,
        "pt" => PX_PER_INCH / 72.0,
        "cm" => PX_PER_INCH / 2.54,
        "mm" => PX_PER_INCH / 25.4,
        "q" => PX_PER_INCH / 101.6
      }.freeze

      # SVG's own number grammar, not Ruby's: `Float("1.")` is 1.0 and
      # `Float("1.e2")` is 100.0, but SVG requires a digit after the
      # decimal point, so those are not dimensions at all.
      NUMBER = /[+-]?(?:\d+\.\d+|\.\d+|\d+)(?:e[+-]?\d+)?/i
      # Surrounding whitespace survives XML attribute-value normalization
      # for a CDATA attribute -- `width=" 100"` arrives with the space --
      # and it is not part of the value the document means.
      #
      # XML's whitespace set explicitly, not `\s`: `\s` also matches
      # vertical tab and form feed, which XML does not treat as
      # whitespace, so `width="&#xB;100"` would read as 100 when it is
      # not a dimension at all.
      XML_SPACE = /[ \t\r\n]*/
      DIMENSION = /\A#{XML_SPACE}(?<number>#{NUMBER})(?<unit>[a-z%]*)#{XML_SPACE}\z/i
      ISSUE_CODE = "svg.root_unreadable"
      ISSUE_MESSAGE = "SVG root element could not be read"

      private_constant :PX_PER_INCH, :ABSOLUTE_UNITS, :NUMBER, :XML_SPACE, :DIMENSION,
                       :ISSUE_CODE, :ISSUE_MESSAGE

      # Claricle's own structural verdict on a WHOLE SVG (D23), as
      # against `inspection` below, which is scoped to the root prefix
      # and stays that way. No delegate is consulted: svg_conform's
      # `base` profile returns zero errors for raw binary, and UTF-32
      # was measured passing every profile silently, so both have to be
      # REFUSED here before any profile validation runs.
      #
      # "Refused", not "diagnosed as an encoding problem". Four routes
      # reach `svg.encoding_unusable` and they do not divide along
      # "REXML could not decode it":
      #
      #   * a bad encoding NAME, which decodes perfectly -- a bare
      #     ArgumentError from REXML's encoding setter;
      #   * undecodable bytes in the prolog -- a bare EncodingError;
      #   * undecodable bytes after a start tag -- the same failure
      #     WRAPPED in a ParseException;
      #   * undecodable bytes REXML reports as a wrapped ArgumentError.
      #
      # Everything else is `svg.not_well_formed`, and which code a given
      # file gets is REXML's decision rather than a promise made here --
      # measured on UTF-32, only big-endian WITH a BOM reaches the
      # encoding code while the other three describe stray null bytes,
      # and across nine raw-binary shapes it is seven against two. Both
      # codes are a refusal, which is what D23 needs.
      #
      # It reads the entire document and holds it. The overhead on top
      # of that tracks the largest single construct the parser holds --
      # one attribute value, or one element's attribute set -- and NOT
      # the file size, so there is no meaningful multiplier to quote.
      # Measured on 64.0 MiB inputs against a 64 MiB bare read:
      # ordinary documents (deep nesting, 40 attributes an element,
      # many small elements) cost 1.7x the file, while one valid
      # document carrying millions of attributes on a single element
      # cost 12.0x, and a single 64 MiB attribute value 4.6x. The
      # blow-up needs an adversarial document, which is exactly what a
      # conformance checker is handed. That is conformance's cost to
      # pay: item 02 puts the bounded 8192-byte read in `inspect` and
      # says whole-document well-formedness belongs here.
      #
      # What it never does, on any input, is build a document tree --
      # measured at zero REXML::Element objects where REXML's DOM builds
      # one per element and peaked at 1.0-1.4 GiB on the same files.
      # That is a structural property, not a memory bound: the
      # many-attribute run above also built zero.
      module Structure
        # Narrower than XML's full well-formedness, in a way worth
        # stating precisely because item 03 documents per format exactly
        # what `conform` checks, and it will quote this.
        #
        # `REXML::Text.check` enforces TWO rules, and it runs only when
        # the DOM builds Text nodes. This route builds none, so BOTH are
        # skipped:
        #
        #   * the Char production -- `<svg>a\u0000b</svg>`, and the
        #     references `&#xD800;`, `&#0;`, `&#1;`, `&#xFFFE;`;
        #   * XML 1.0 2.4's markup delimiters -- a bare `&` or a raw `<`
        #     where a reference was required, as in the commonest
        #     malformed SVG there is, `<svg>Tom & Jerry</svg>`, and in
        #     `id="a<b"`.
        #
        # Every gap named here -- the two families above and the third
        # below -- is a false NEGATIVE: input this scan calls clean that
        # a validator rejects. That direction is the one card 03 needs
        # stated, and it is not interchangeable with the opposite risk
        # of flagging valid input.
        #
        # A THIRD family is unrelated to `Text.check`: a CDATA section
        # at top level AFTER the root element. `count_roots` sees a
        # :cdata event, which it ignores, so `<svg/><![CDATA[x]]>` scans
        # clean while xmllint calls it "Extra content at the end of the
        # document". The boundary is narrow and was measured: a comment,
        # a PI or whitespace after the root are LEGAL and correctly
        # clean; text after the root, and a CDATA section BEFORE it, are
        # both already caught as not-well-formed.
        #
        # The second family is NOT a Char-production case: `&` and `<`
        # are perfectly legal XML Chars, which is why naming only the
        # Char production described half the gap. Every shape measured
        # when that sentence was written happened to be a Char
        # violation, so the corpus could not tell "the Char production
        # is unchecked" from "Text.check never runs" -- and the sentence
        # asserted the narrower reading. The `&` examples above separate
        # the two; the Char examples do not.
        #
        # Distinct from the undefined-entity limit below: REXML's DOM
        # ACCEPTS `&nope;`, so that limit is a place the DOM agrees with
        # us, not a case it catches and we miss.
        NOT_WELL_FORMED_CODE = "svg.not_well_formed"
        ENCODING_UNUSABLE_CODE = "svg.encoding_unusable"
        MULTIPLE_ROOTS_CODE = "svg.multiple_root_elements"
        UNDECODABLE_MESSAGE = "SVG source is not decodable text"
        UNDECODABLE_CAUSES = [ArgumentError, EncodingError].freeze
        # CHARACTERS, not bytes. REXML's first message line bounds lines
        # and not bytes -- the spec's 50,000-character token yields a
        # 50,028-byte first line -- and an issue has to stay printable
        # as one line. So the real
        # bound is 200 characters, hence at most 800 bytes; the byte
        # count is script-dependent and there is no fixed multiplier.
        # `byteslice` is deliberately not used: it split a CJK codepoint
        # and Models::Issue then refused the value outright.
        MESSAGE_CHARACTER_LIMIT = 200

        class << self
          # At most one issue, which is what is currently KNOWABLE
          # rather than a law: the parser stops at its first fatal
          # error, and the root count is only complete when none
          # occurred. A document with two genuine problems reports the
          # first. The Array return keeps room for a later non-fatal
          # check, which would coexist with the root count.
          def scan(source)
            roots = count_roots(tagged(source))
            return [] unless roots > 1

            [issue(MULTIPLE_ROOTS_CODE, "document has #{roots} root elements")]
          rescue REXML::ParseException => e
            [parse_failure(e)]
          # Its own clause, sitting between the ParseException rescue
          # above and the ArgumentError rescue below. All three classes
          # are pairwise non-subtypes in both directions -- measured --
          # so no clause can shadow another and the order is free.
          # REXML transcodes lazily
          # while parsing, so a source whose bytes are truncated
          # mid-character raises from inside the pull loop rather than
          # arriving as a ParseException -- measured on 13 bytes, a
          # UTF-16LE BOM followed by an odd-length PI, which escaped
          # this method entirely on both source arms. All four of the
          # Encoding::* errors are genuine "not decodable text", the
          # same verdict raw binary gets.
          rescue EncodingError
            [issue(ENCODING_UNUSABLE_CODE, UNDECODABLE_MESSAGE)]
          rescue ArgumentError => e
            [issue(ENCODING_UNUSABLE_CODE, e.message)]
          end

          private

          # Tag, never transcode: REXML still finds a BOM or a
          # declaration and switches encodings itself. Both arms arrive
          # binary-tagged -- `Image.from_content` normalises to
          # ASCII-8BIT and a path-born source is opened "rb" -- and
          # measured, a multibyte ROOT NAME reads back as "no root
          # element" from a binary-tagged source and parses from a
          # UTF-8-tagged one.
          def tagged(source)
            bytes = source.respond_to?(:read) ? source.read : source.dup
            bytes.force_encoding(Encoding::UTF_8)
          end

          # Loops to :end_document rather than on `has_next?` because
          # the final pull is what runs REXML's end-of-input check.
          # Parsing `<svg>` both ways:
          #
          #   has_next?      -> no raise
          #   :end_document  -> REXML::ParseException
          #
          # Root COUNTING is not what buys this. Collecting the events
          # of `<svg/><g/>` under `has_next?` gives
          # [:start_element, :end_element, :start_element], which the
          # depth walk below counts as 2 roots -- the same answer. The
          # EOF check is the whole difference.
          #
          # The root count is Claricle's own. REXML accepts four of the
          # five second-root shapes measured -- only `<svg/><g></g>`
          # raises -- so nothing here can be delegated to it.
          def count_roots(text)
            parser = REXML::Parsers::BaseParser.new(text)
            roots = 0
            depth = 0
            while (type = parser.pull[0]) != :end_document
              roots += 1 if type == :start_element && depth.zero?
              depth += 1 if type == :start_element
              depth -= 1 if type == :end_element
            end
            roots
          end

          # Undecodable bytes reach us wrapped in a ParseException, and
          # the wrapped class is either an ArgumentError or an
          # Encoding::InvalidByteSequenceError -- both are ENCODING
          # failures rather than well-formedness ones, and
          # UNDECODABLE_CAUSES names both. Routing on the OUTER
          # exception class alone would file them under
          # svg.not_well_formed.
          #
          # Which binary files land here is REXML's decision, not ours:
          # measured across nine shapes, seven carry the wrapped
          # ArgumentError and two -- a run of NULs, and every byte value
          # 0-255 in order -- decode cleanly enough to fail as markup
          # instead. Both outcomes refuse the file.
          def parse_failure(error)
            return issue(ENCODING_UNUSABLE_CODE, UNDECODABLE_MESSAGE) if undecodable?(error)

            issue(NOT_WELL_FORMED_CODE, prose(error))
          end

          # Both classes, because the SAME failure reaches us as either
          # depending only on WHERE inside REXML it was raised. REXML's
          # `pull_event` wraps one region and the prolog sits outside it,
          # so a BOM plus a character truncated in the PROLOG arrives
          # bare as Encoding::InvalidByteSequenceError, while the same
          # truncation after a start tag arrives WRAPPED in a
          # ParseException whose prose is the useless "Exception
          # parsing" -- measured on 13 bytes and on 9. Same defect, same
          # verdict.
          def undecodable?(error)
            UNDECODABLE_CAUSES.any? { |kind| error.continued_exception.is_a?(kind) }
          end

          # RuntimeError#to_s, not `error.message`, for three measured
          # reasons. ParseException#to_s reaches `current_line`, which
          # re-reads the whole document at its default newline separator
          # -- +52 MiB against +0 MiB here on a 64 MiB newline-free
          # document. It appends REXML's own backtrace, so `e.message`
          # on a real PNG is 674 characters carrying absolute
          # filesystem paths where this is 17. And an issue has to stay
          # printable as one line.
          def prose(error)
            RuntimeError.instance_method(:to_s).bind_call(error)
          end

          # Every issue this module builds passes through here, so the
          # length bound is applied ONCE, at the funnel, rather than at
          # each call site. An unusable encoding NAME is document
          # content and so is attacker-controlled -- measured, a
          # 100,000-character name produced a 100,018-character message
          # when only `prose` truncated.
          def issue(code, message)
            Models::Issue.new(severity: "error", code: code, message: printable(message))
          end

          # Length only. Control characters are deliberately NOT stripped
          # here: `Cli::Presenter::CONTROL` already owns that rule for
          # every rendered row, issue messages included (`cli.rb:126`),
          # over a wider set than `[[:cntrl:]]` -- it covers U+2028 and
          # U+2029, which `[[:cntrl:]]` does not match. A second copy
          # here would be the weaker of two rules for one thing, and it
          # would DESTROY the character where the render layer escapes
          # it, breaking the stated contract that `--json` carries the
          # true value while only the human rendering escapes. `meta` is
          # free document text and is handled exactly this way.
          #
          # Slice BEFORE scrubbing: slicing is safe on an invalid
          # encoding and bounds the work, where scanning the whole
          # string RAISES on one -- measured, ArgumentError -- and
          # scrubbing 8,000,000 characters to keep 200 costs 0.0118s
          # against 0.0000s. Scrub then repairs whatever the cut left
          # half-formed, which `Models::Issue` refuses outright.
          def printable(message)
            message[0, MESSAGE_CHARACTER_LIMIT].scrub
          end
        end
      end

      # After the module body: `private_constant` on a name that does
      # not exist yet raises NameError.
      private_constant :Structure

      def inspection(image)
        # Detector.read_root, not a second reader: it owns the 8192-byte
        # bound, the ATTLIST precedence and the reference resolution, and
        # a copy here would have to agree with all three forever.
        #
        # with_source, not content: read_root takes an IO as happily as a
        # String, and asks for 8192 bytes either way. Measured on a
        # 64.0 MiB SVG, `image.content` cost +64.5 MiB RSS and retained
        # the file for the lifetime of the image, to reach those bytes.
        root = image.with_source { |source| Detector.read_root(source) }
        return unreadable(image) unless root

        readable(image, root.last)
      end

      private

      def readable(image, attributes)
        Models::Inspection.new(
          format: image.format.to_s,
          width: dimension(attributes["width"]),
          height: dimension(attributes["height"]),
          # Passed straight through: `Models::FreeFormHash.cast` does the
          # copy itself, explicitly, so the inspection never shares the
          # reader's hash. That is Claricle's own type rather than
          # generic lutaml behaviour -- lutaml's `:hash` reshapes `text`
          # and `elements`, which is why FreeFormHash exists at all. A
          # `.dup` here would repeat a copy that already happened --
          # measured, and pinned by a spec.
          meta: attributes,
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

      # nil rather than a wrong number, in every case it cannot answer:
      # no attribute, an unparseable one, a relative unit, or a value
      # that overflows. The viewBox is deliberately not consulted -- it
      # defines an aspect ratio, not an intrinsic size (D15).
      def dimension(declared)
        match = DIMENSION.match(declared.to_s)
        return nil unless match

        unit = match[:unit].downcase
        factor = unit.empty? ? 1.0 : ABSOLUTE_UNITS[unit]
        return nil unless factor

        scale(match[:number], factor)
      end

      # Finiteness is checked on the CONVERTED value, not the parsed one:
      # 1e308 is finite, and 1e308 * 96 is Infinity, which an Inspection
      # refuses to hold. Measured: building one raises
      # Lutaml::Model::ValidationError, "width expects a finite number,
      # got Infinity", from `validate_finite` during `initialize` -- so
      # `inspect` on a file that parsed fine would die before any
      # serialisation ran, not in `to_json`.
      def scale(number, factor)
        parsed = Float(number, exception: false)
        return nil unless parsed

        converted = parsed * factor
        converted.finite? ? converted : nil
      end
    end
  end
end
