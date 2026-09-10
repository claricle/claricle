# frozen_string_literal: true

require "rexml/document"

require_relative "base"
require_relative "../detector"
require_relative "../models/inspection"
require_relative "../models/issue"
require_relative "../models/location"
require_relative "../models/report"

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
                       :ISSUE_CODE, :ISSUE_MESSAGE

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
        # Lazily required (D5), matching `Png#conformance_report`: the
        # detector's `emf` is the only eager delegate, and svg_conform
        # pulls in a profile loader and a SAX stack that a plain
        # `inspect` run has no use for.
        require "svg_conform"

        ConformanceMapper.report(image, profile: profile || self.class.supported_profiles.first)
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
