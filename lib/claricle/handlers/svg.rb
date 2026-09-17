# frozen_string_literal: true

require "rexml/document"
require "vectory"
require "postsvg"
require "rexml/parsers/baseparser"

require_relative "base"
require_relative "../detector"
require_relative "../models/inspection"
require_relative "../models/issue"
require_relative "../models/location"
require_relative "../models/report"
require_relative "../models/conversion"
require_relative "../lossiness"

# `Postsvg::Model::UnknownOperator` (postsvg-0.3.0, model/operators.rb:59) is
# declared via a WRONG-FILE autoload -- model.rb:13 points at the singular
# model/operator.rb, where the class does not live. Measured: a genuinely
# fresh process raises `NameError` converting any SVG whose rendered output
# needs it (embedded_raster.svg, both to_eps and to_ps), and it stops
# reproducing forever once anything else in the process has gone through the
# same path first -- an ordinary autoload race, not input-dependent.
# `Operators.load_all!` (model/operators.rb:49-53, public, documented "force-
# load every operator category... call this once") forces the whole registry
# to populate up front, closing the race. Every real CLI invocation is cold,
# so this runs once, here, at require time -- not lazily inside `#convert`,
# and not left to warm by accident the way metafile.rb's identical exposure
# is (that file's own scope, not fixed here). Costs ~0.008s, measured
# idempotent.
Postsvg::Model::Operators.load_all!

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
      convert_to :eps, :ps, :emf

      # Symbol -> the vectory method it dispatches to, matching
      # Handlers::Metafile's own TARGET_METHODS convention for the same job.
      CONVERT_TARGET_METHODS = { eps: :to_eps, ps: :to_ps, emf: :to_emf }.freeze

      # Matches Handlers::Metafile's own MAX_CONVERT_BYTES: bound the READ
      # itself, not the bytesize checked after the fact -- #content and
      # #bytesize are different filesystem calls for a path-born image, so a
      # stat-then-read check still materialises an oversized file before
      # refusing it.
      MAX_CONVERT_BYTES = 200 * 1024 * 1024

      # svg_conform's own six, measured from `Profiles.available_profiles`
      # on a cleared cache rather than copied from its README, and pinned
      # by a spec so a release that adds or drops one says so here. `base`
      # is FIRST because D21 makes it what a plain `conform` runs.
      profiles :base, :lucid_fix, :metanorma, :no_external_css,
               :svg_1_2_rfc, :svg_1_2_rfc_with_rdf

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

      # Builds the `Report` a conform operation returns, kept apart from
      # root-attribute interpretation for the same reason `Png` keeps its
      # own mapper apart: the two share a file and nothing else.
      class ConformanceMapper
        # D21: a generic `conform` runs the `base` requirement set, which
        # is why `Svg.profiles` lists it first. The other five are reached
        # through `--profile`.
        #
        # What matters is that it is passed AT ALL. svg_conform's own
        # default is `:svg_1_2_rfc`, a far stricter set: measured on 0.2.2,
        # it reports a `color_restrictions` error against
        # `spec/fixtures/conform/valid.svg`, which `base` passes clean. So
        # omitting the profile does not mean "no profile", it means the
        # wrong one, quietly.
        #
        # Either route reaches it, and an earlier version of this comment
        # had that backwards. `validate_file` declares
        # `profile: :svg_1_2_rfc`, then calls on with
        # `profile: profile, **merged_options` -- and `merged_options`
        # carries whatever `Validator.new` was given, splatted AFTER the
        # keyword, so a constructor option WINS over it. Measured all three
        # ways against that fixture: constructor-only `[]`, keyword-only
        # `[]`, neither `["color_restrictions"]`. The keyword is used here
        # because it reads as an argument to the call it applies to.
        # svg_conform's own three buckets. `ValidationResult` carries
        # exactly these -- it takes `context.errors`, `context.warnings`
        # and `context.validity_errors` in its constructor and drops
        # `context.infos` on the floor, so a notice raised by a
        # requirement cannot be reported however it is collected here.
        # Measured on 0.2.2; `ValidationResult` has no `infos` reader.
        BUCKETS = %i[errors warnings validity_errors].freeze

        # An issue's own `severity` is optional and usually absent:
        # `Errors::ValidationIssue#initialize` defaults it to nil, and
        # `ErrorTracker#add_warning` and `#add_notice` never pass one. So
        # `type` is the fallback, and it is the reliable field -- the
        # tracker sets it to :error, :warning or :info at every one of the
        # three places it builds an issue.
        #
        # `:validity_error` is the one value that is a severity and not a
        # type: `add_error` reads it to file the issue under
        # `validity_errors` while still stamping `type: :error`. It means
        # error here, so it maps to one.
        SEVERITIES = {
          error: "error", validity_error: "error",
          warning: "warning", info: "info"
        }.freeze

        # An issue whose type svg_conform grows past the three above. It
        # is reported rather than dropped, at the severity that cannot
        # understate it -- a report is read to decide whether a file is
        # usable, and a silently missing error is the one outcome worth
        # refusing.
        DEFAULT_SEVERITY = "error"

        # `requirement_id` is derived, never nil: it falls back to the
        # rule's id, then to the rule class's name, then to the string
        # "unknown". So unlike PNG, no code has to be slugged out of the
        # message here.
        # Well-formedness FIRST, and it is not belt-and-braces. svg_conform
        # 0.2.2 collects XML parse failures in `SaxValidationHandler`'s own
        # `@parse_errors`, which `ValidationResult` never carries -- so
        # mapping its three buckets cannot tell a valid document from an
        # unparseable one. Measured on three shapes, every one reported
        # `valid: :yes`, no issues, CLI exit 0:
        #
        #   <svg ...><g></svg>            mismatched end tag
        #   <svg ...><rect wid            truncated mid-attribute
        #   <svg .../><svg/>              two root elements
        #
        # A conformance report that calls a broken file conformant is the
        # one answer this operation must never give, so the check runs
        # before the delegate and short-circuits it.
        #
        # This is where the whole document gets parsed, and that is
        # correct HERE where it is wrong in `inspection`: D16 makes
        # judging the whole document conformance's job, and the bounded
        # 8192-byte read exists to keep `inspect` cheap, not to keep
        # `conform` shallow.
        def self.report(image, profile:)
          image.with_path do |path|
            malformed = not_well_formed(path)
            next malformed if malformed

            report_for(image, path, profile)
          end
        end

        # REXML is already a runtime dependency and raises one class for
        # every shape above, so nothing here has to enumerate what "broken"
        # means. Encoding failures come back as the same refusal: a
        # document Ruby cannot decode is one no validator can judge.
        def self.not_well_formed(path)
          ::REXML::Document.new(::File.read(path))
          nil
        rescue ::REXML::ParseException, ::EncodingError, ::ArgumentError => e
          malformed_report(path, e)
        end

        # The first line of REXML's message only: it renders the whole
        # offending source after it, which would put an arbitrary slice of
        # someone's document into a report a caller may well print.
        def self.malformed_report(path, error)
          Models::Report.new(
            source_path: path, format: "svg",
            validator_version: ::SvgConform::VERSION,
            issues: [Models::Issue.new(
              severity: "error", code: "svg.not_well_formed",
              message: "the document is not well-formed XML: #{error.message.lines.first.to_s.strip}"
            )]
          )
        end

        def self.report_for(image, path, profile)
          warm_profile_cache
          result = ::SvgConform::Validator.new.validate_file(path, profile: profile)

          Models::Report.new(
            source_path: image.path, format: image.format.to_s,
            profile: profile.to_s, validator_version: ::SvgConform::VERSION,
            issues: issues_from(result)
          )
        end

        # ADDS to svg_conform's profile cache; never clears it. Validating
        # loads only the profile it used, and `Profiles.available_profiles`
        # answers from the cache once the cache is non-empty -- so one
        # `base` run leaves the process believing `base` is the only
        # profile that exists, measured six before and `[:base]` after.
        #
        # Clearing the cache fixes that count and breaks something worse.
        # `Profiles` keys its cache in a CLASS VARIABLE shared with every
        # other user of the gem in the process, so a host that customised
        # a profile through svg_conform's own public API loses that
        # customisation the first time Claricle conforms anything --
        # measured: a host removing `viewbox_required` from `base` saw it
        # come back after one Claricle call. A library inside someone
        # else's process does not get to reset their state.
        #
        # Warming from OUR OWN declaration is what makes this possible.
        # `available_profiles` cannot be the source, because once the cache
        # has collapsed it reports the collapsed list -- the very thing
        # being repaired. `Svg.profiles` is declared, not derived, so it
        # says the same six whatever the cache currently holds.
        #
        # Idempotent and cheap when warm: every call is a cache hit.
        # Measured cold, all six load in 54.7 ms once; a warm validation
        # costs 0.08 ms against 0.81 ms when the cache was cleared each
        # time, so a glob batch stops paying a reload per file.
        def self.warm_profile_cache
          Svg.supported_profiles.each { |name| ::SvgConform::Profiles.get(name) }
        end

        def self.issues_from(result)
          BUCKETS.flat_map { |bucket| result.public_send(bucket).to_a }.map { |raw| issue_from(raw) }
        end

        def self.issue_from(raw)
          Models::Issue.new(
            severity: SEVERITIES.fetch(raw.severity || raw.type, DEFAULT_SEVERITY),
            code: raw.requirement_id.to_s,
            message: raw.message.to_s,
            location: location_for(raw)
          )
        end

        # `line` and `column` are read off the issue's node, and the SAX
        # path leaves both nil on every issue measured. nil rather than an
        # all-nil Location, for the same reason Png gives: nothing here
        # should invent a position svg_conform did not report.
        def self.location_for(raw)
          line = raw.line
          column = raw.column
          return nil if line.nil? && column.nil?

          Models::Location.new(line: line, column: column)
        end

        private_class_method :report_for, :issues_from, :issue_from, :location_for,
                             :not_well_formed, :warm_profile_cache,
                             :malformed_report
      end

      private_constant :ConformanceMapper

      private_constant :PX_PER_INCH, :ABSOLUTE_UNITS, :NUMBER, :XML_SPACE, :DIMENSION,
                       :ISSUE_CODE, :ISSUE_MESSAGE, :CONVERT_TARGET_METHODS, :MAX_CONVERT_BYTES

      def convert(image, to:)
        raise UnsupportedFormat.new(image.format, :convert, target: to) unless self.class.convert_targets.include?(to)

        content = bounded_content(image)
        converted = convert_content(content, to)
        build_conversion(image, to, content, converted)
      end

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
        # DIVERGES from XML's full well-formedness in BOTH directions,
        # in a way worth stating precisely because item 03 documents per
        # format exactly what `conform` checks, and it will quote this.
        # It stays silent on three families a validator rejects, and it
        # reports an error on four names a validator accepts. Neither
        # direction implies the other, so both are stated below.
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
        # The three families in this section are all false NEGATIVES:
        # input this scan calls clean that a validator rejects. The
        # opposite direction is real too and is stated at the end of
        # this comment.
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
        #
        # FIXED, not disclosed: four characters are legal in an XML name
        # and REXML's OWN published NCNAME_STR accepts them, but REXML's
        # live grammar refused them, which would have reported a VALID
        # document as svg.not_well_formed (U+00B7 middle dot, U+0300
        # combining grave, U+203F undertie, U+2040 character tie --
        # measured against xmllint, which calls all four valid). Fixed by
        # parsing through `Detector.canonical_source` (see `count_roots`
        # below), the same grammar patch `Detector::RootSource` already
        # applies for the bounded root read, rather than reimplementing
        # it here.
        NOT_WELL_FORMED_CODE = "svg.not_well_formed"
        ENCODING_UNUSABLE_CODE = "svg.encoding_unusable"
        MULTIPLE_ROOTS_CODE = "svg.multiple_root_elements"
        UNDECODABLE_MESSAGE = "SVG source is not decodable text"
        UNDECODABLE_CAUSES = [ArgumentError, EncodingError].freeze
        # CHARACTERS, not bytes. REXML's first message line bounds lines
        # and not bytes -- the spec's 50,000-character token yields a
        # 50,027-byte first line -- and an issue has to stay printable
        # as one line. So the real
        # bound is 200 characters, hence at most 800 bytes; the byte
        # count is script-dependent and there is no fixed multiplier.
        # `byteslice` is deliberately not used: it split a CJK codepoint
        # and Models::Issue then refused the value outright.
        MESSAGE_CHARACTER_LIMIT = 200
        # 64 MiB matches the size class this module's own header comment
        # measures against (1.7x-12.0x overhead depending on shape); past
        # this, refuse to scan rather than read further into an
        # attacker-controlled document with no bound at all.
        MAX_SCAN_BYTES = 64 * 1024 * 1024
        TOO_LARGE_CODE = "svg.too_large_to_scan"
        TOO_LARGE_MESSAGE = "SVG source exceeds the #{MAX_SCAN_BYTES}-byte scan limit".freeze

        class << self
          # `tagged(source)` (the caller's own reader) runs OUTSIDE
          # `do_scan`'s rescue, so a reader's own `ArgumentError` is no
          # longer reported as `svg.encoding_unusable` -- measured with a
          # reader whose `#read` itself raises.
          def scan(source)
            do_scan(tagged(source))
          end

          private

          # At most one issue, which is what is currently KNOWABLE
          # rather than a law: the parser stops at its first fatal
          # error, and the root count is only complete when none
          # occurred. A document with two genuine problems reports the
          # first. The Array return keeps room for a later non-fatal
          # check, which would coexist with the root count.
          def do_scan(text)
            return [issue(TOO_LARGE_CODE, TOO_LARGE_MESSAGE)] if text == :too_large

            roots = count_roots(text)
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

          # Tag, never transcode: REXML still finds a BOM or a
          # declaration and switches encodings itself. Both arms arrive
          # binary-tagged -- `Image.from_content` normalises to
          # ASCII-8BIT and a path-born source is opened "rb" -- and
          # measured, a multibyte ROOT NAME reads back as "no root
          # element" from a binary-tagged source and parses from a
          # UTF-8-tagged one.

          # Capped at MAX_SCAN_BYTES + 1: past it returns `:too_large`
          # instead of reading further (measured: RSS tracked an
          # uncapped read 1:1 with input size).
          #
          # keep the `+ 1` argument on `source.read` even though no spec
          # can catch its removal: an over-cap input returns the same
          # `:too_large` verdict whether `read` stopped at the cap or
          # read the whole source, so no output-observable spec
          # distinguishes them -- only RSS does, which is what this
          # class is measured against, not asserted in-suite. This
          # becomes the only check once the cap is dropped.
          def tagged(source)
            bytes = if source.respond_to?(:read)
                      source.read(MAX_SCAN_BYTES + 1)
                    else
                      source.byteslice(0, MAX_SCAN_BYTES + 1)
                    end
            bytes ||= ::String.new
            return :too_large if bytes.bytesize > MAX_SCAN_BYTES

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
          #
          # `Detector.canonical_source`, not a bare `BaseParser.new(text)`:
          # REXML's own live grammar refuses four characters that are
          # legal in an XML name (U+00B7, U+0300, U+203F, U+2040) and its
          # OWN published NCNAME_STR accepts -- `Detector::RootSource`
          # already patches that gap for the bounded root read, and
          # reusing it here (over the whole document rather than just the
          # root) avoids reimplementing the same grammar fix a second
          # time and risking disagreement with it.
          def count_roots(text)
            parser = REXML::Parsers::BaseParser.new(Detector.canonical_source(text))
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
          # UNDECODABLE_CAUSES names ArgumentError and the wider
          # EncodingError, which InvalidByteSequenceError subclasses, so
          # a sibling EncodingError REXML has not been measured wrapping
          # yet is still caught. Routing on the OUTER
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
          # against 0.0000s. The slice is by CHARACTER, not byte, so it
          # cannot itself leave anything half-formed; scrub guards
          # against a message that was already invalid before the cut,
          # which `Models::Issue` refuses outright.
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

      # The mapping, and every fact it rests on, are documented on
      # `ConformanceMapper.report` below.
      #
      # The default comes from the DECLARATION, not from a second constant
      # naming `base` again -- one rule in two places is one that can
      # drift, and `profiles` already puts the default first.
      def conformance_report(image, profile: nil)
        # Lazily required (D5), matching `Png#read_chunks`'s own lazy
        # `require "png_conform"`: the detector's `emf` is the only eager
        # delegate, and svg_conform pulls in a profile loader and a SAX
        # stack that a plain `inspect` run has no use for.
        require "svg_conform"

        ConformanceMapper.report(image, profile: profile || self.class.supported_profiles.first)
      end

      private

      # Bounds the READ itself rather than trusting a stat taken on a
      # separate filesystem call -- the same reasoning as MetafileConvert's
      # own `bounded_content` (metafile.rb). Reading MAX_CONVERT_BYTES + 1
      # and getting that many back is the proof the stream is over the
      # limit whatever a stat would have said.
      def bounded_content(image)
        content = image.with_source { |source| bounded_read(source, MAX_CONVERT_BYTES + 1) }
        return content if content.bytesize <= MAX_CONVERT_BYTES

        raise ConversionError, "svg image exceeds the #{MAX_CONVERT_BYTES}-byte convert limit"
      end

      # Near-verbatim copy of MetafileConvert#bounded_read (metafile.rb) --
      # kept as its own small copy rather than a shared Handlers::Base
      # helper: metafile.rb belongs to a separate, independently-mergeable,
      # already-approved PR, and editing it here to extract a shared helper
      # would be cross-PR coupling into a diff this branch doesn't own.
      def bounded_read(source, length)
        return source.read(length) || "".b if source.respond_to?(:read)

        source.byteslice(0, length)
      end

      # Scoped to only the delegate call, not `build_conversion` below --
      # that method's own Lossiness.classify/Models::Conversion.new are
      # this file's local logic, not the delegate chain this rescue exists
      # to cover.
      #
      # NOT an exhaustive list of what the delegate chain can raise --
      # `rescue StandardError` mirrors Handlers::Metafile's own documented
      # deviation (metafile.rb) rather than a narrower explicit-class list.
      # `utf16_gradient.svg` is a real, permanent input-shape failure
      # (Vectory::ParsingError) with no equivalent fix; the cold-process
      # `Postsvg::Model::UnknownOperator` NameError this same rescue used to
      # exist for is fixed outright above, at file-load time.
      def convert_content(content, to)
        ::Vectory::Svg.from_content(content).public_send(CONVERT_TARGET_METHODS.fetch(to))
      rescue StandardError => e
        raise ConversionError, "#{e.class}: #{e.message}"
      end

      # `output_path` is deliberately absent here -- the caller
      # (Claricle.convert_one) does not know the real written path until
      # after Writer#write runs, and Models::Base seals (and therefore
      # freezes) every instance at construction.
      def build_conversion(image, to, content, converted)
        Models::Conversion.new(
          source_path: image.path,
          source_format: image.format.to_s,
          target_format: to.to_s,
          lossiness: Lossiness.classify(source_format: image.format, target_format: to, source: content),
          content: converted.content
        )
      end

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
      # no attribute, an unparseable one, a relative unit, a negative
      # value, or one that overflows. The viewBox is deliberately not
      # consulted -- it defines an aspect ratio, not an intrinsic size
      # (D15).
      #
      # Negative is nulled, zero is not: SVG 1.1 5.1.2 on width/height,
      # "A negative value is an error ... A value of zero disables
      # rendering of the element." The spec draws the line at the sign,
      # not at zero, so a declared zero is a real (if degenerate)
      # measurement and only a negative one joins the unusable cases
      # above.
      def dimension(declared)
        match = DIMENSION.match(declared.to_s)
        return nil unless match

        unit = match[:unit].downcase
        factor = unit.empty? ? 1.0 : ABSOLUTE_UNITS[unit]
        return nil unless factor

        value = scale(match[:number], factor)
        # -0.0.negative? is false (-0.0 == 0.0 under IEEE 754), so a
        # declared "-0" falls through as a kept zero, not a nulled
        # negative -- no separate case needed for it.
        value&.negative? ? nil : value
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
