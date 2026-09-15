# frozen_string_literal: true

require "vectory"
require "postsvg"

require_relative "base"
require_relative "../detector"
require_relative "../models/inspection"
require_relative "../models/issue"
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
                       :ISSUE_CODE, :ISSUE_MESSAGE, :CONVERT_TARGET_METHODS, :MAX_CONVERT_BYTES

      def convert(image, to:)
        raise UnsupportedFormat.new(image.format, :convert, target: to) unless self.class.convert_targets.include?(to)

        content = bounded_content(image)
        converted = convert_content(content, to)
        build_conversion(image, to, content, converted)
      end

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
