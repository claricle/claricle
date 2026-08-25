# frozen_string_literal: true

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
