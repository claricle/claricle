# frozen_string_literal: true

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
        # D21: a generic `conform` runs the `base` requirement set. The
        # other five profiles are reached through `--profile`, which this
        # method does not take yet.
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
        PROFILE = :base

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
        def self.report(image)
          image.with_path { |path| report_for(image, path) }
        end

        # `clear_cache!` is not tidiness. `Profiles.available_profiles`
        # collapses to just the profile last validated with -- measured on
        # 0.2.2, all six before a `base` run and `[:base]` after it -- so
        # a process that validated once would go on to answer a later
        # `--profile` check against a list of one.
        def self.report_for(image, path)
          result = ::SvgConform::Validator.new.validate_file(path, profile: PROFILE)

          Models::Report.new(
            source_path: image.path, format: image.format.to_s,
            profile: PROFILE.to_s, validator_version: ::SvgConform::VERSION,
            issues: issues_from(result)
          )
        ensure
          ::SvgConform::Profiles.clear_cache!
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

        private_class_method :report_for, :issues_from, :issue_from, :location_for
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
      def conformance_report(image)
        # Lazily required (D5), matching `Png#conformance_report`: the
        # detector's `emf` is the only eager delegate, and svg_conform
        # pulls in a profile loader and a SAX stack that a plain
        # `inspect` run has no use for.
        require "svg_conform"

        ConformanceMapper.report(image)
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
