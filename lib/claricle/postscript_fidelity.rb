# frozen_string_literal: true

require "rexml/document"
require_relative "detector"
require_relative "postscript_fidelity/view_box"

module Claricle
  # Closes six silent losses in postsvg-0.3.0's SVG -> PS/EPS writer, so the
  # `:lossless` verdict for the shapes Lossiness proves kept is true.
  # `repair` rewrites the SVG before the writer sees it; `orient` fixes the
  # PostScript it returns. Both pass their input through untouched when they
  # cannot read it, leaving the writer's own error to surface.
  #
  #   color.rb:60             /\argb\(/ is BEL, not \A: rgb() never parses, paint is dropped
  #   attribute_parser.rb:25  number() takes bare "-?\d+(\.\d+)?" only: "10px", ".5", "+5" read as 0
  #   line_handler.rb:12      a <line> is always stroked; SVG's default stroke is none
  #   (no code)               user space is y-down; PostScript is y-up and nothing flips it.
  #                         `translate` + `scale`, not `concat`: Postsvg.to_svg ignores concat.
  #   svg/parser.rb:27-33     viewBox is read as [llx lly urx ury], so a non-zero origin is
  #                         misplaced: `repair` rewrites it to origin 0 0, `orient` shifts by it.
  #   (no code)               the flip mirrors `show` text: each is counter-flipped about its origin.
  #                         (`<image>` is emitted as a bare `image` operator with no data: nothing to flip.)
  module PostscriptFidelity
    SVG_NAMESPACE = "http://www.w3.org/2000/svg"
    LENGTH_ATTRIBUTES = %w[width height x y x1 y1 x2 y2].freeze
    PAINT_ATTRIBUTES = %w[fill stroke].freeze
    LENGTH = /\A[ \t\r\n]*([+-]?(?:\d+\.\d+|\.\d+|\d+))(?:px)?[ \t\r\n]*\z/i
    RGB = /\A[ \t\r\n]*rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)[ \t\r\n]*\z/
    STROKE_INHERITING = %w[stroke style class].freeze
    BBOX = /^%%BoundingBox: (\S+) (\S+) (\S+) (\S+)$/
    HINT = /px|rgb\(|<line|[+.]\d|viewBox/i
    SHOW = /^(\S+) (\S+) moveto\n(\((?:\\.|[^\\)])*\) show)$/

    POSTSCRIPT_TARGETS = %i[eps ps].freeze

    module_function

    # Yields the SVG to hand the delegate and returns what it produced,
    # corrected. Other targets pass straight through.
    def convert(svg, target)
      return yield(svg) unless POSTSCRIPT_TARGETS.include?(target)

      fixed = repair(svg)
      orient(yield(fixed), fixed, ViewBox.rebased_origin(svg, fixed))
    end

    def repair(svg)
      return svg unless svg.match?(HINT)

      doc = REXML::Document.new(svg)
      return svg unless doc.root && doc.encoding == "UTF-8"

      changed = svg_elements(doc.root).map { |element| repaired?(element, doc) }
      changed << ViewBox.rebase_origin?(doc.root)
      changed.any? ? doc.to_s : svg
    rescue REXML::ParseException, RuntimeError, EncodingError, ArgumentError
      svg
    end

    def orient(postscript, svg, origin = [0.0, 0.0])
      match = BBOX.match(postscript)
      return postscript unless match && postscript.include?("%%EndComments\n")

      box = match.captures.map { |text| Float(text, exception: false) }
      return postscript unless box.all?

      upright(reflect(postscript, box, ViewBox.viewport_sum(svg) || (box[1] + box[3]), origin))
    end

    def reflect(postscript, box, sum, origin)
      llx, lly, urx, ury = box
      bbox = [llx, sum - ury, urx, sum - lly].map { |value| number(value) }.join(" ")
      shift = origin.all?(&:zero?) ? "" : "#{origin.map { |value| number(-value) }.join(" ")} translate\n"
      postscript.sub(BBOX) { "%%BoundingBox: #{bbox}" }
                .sub("%%EndComments\n") { "%%EndComments\n0 #{number(sum)} translate\n1 -1 scale\n#{shift}" }
    end

    # The page flip mirrors glyphs; flip each `show` back about its own origin.
    def upright(postscript)
      postscript.gsub(SHOW) do
        x, y, text = Regexp.last_match.captures
        "gsave\n#{x} #{y} translate\n1 -1 scale\n0 0 moveto\n#{text}\ngrestore"
      end
    end

    def svg_elements(root)
      found = [root]
      root.each_recursive { |el| found << el }
      found.select { |el| el.namespace == SVG_NAMESPACE }
    end

    def repaired?(element, doc)
      return removed_unstroked_line?(element, doc) if element.name == "line"

      edits = element.attributes.map { |name, value| [name, rewrite(name, value)] }
      edits.reject! { |name, value| value.nil? || element.attributes[name] == value }
      edits.each { |name, value| element.attributes[name] = value }
      edits.any?
    end

    def rewrite(name, value)
      if LENGTH_ATTRIBUTES.include?(name) && (match = LENGTH.match(value))
        number(Float(match[1]))
      elsif PAINT_ATTRIBUTES.include?(name) && (match = RGB.match(value))
        match.captures.map { |channel| format("%02x", [channel.to_i, 255].min) }.join.prepend("#")
      end
    end

    # Only a line whose stroke is certainly none: its own `stroke` says so, or
    # nothing from it, its ancestors or a stylesheet can supply one.
    def removed_unstroked_line?(line, doc)
      return false if line.attributes["style"] || line.attributes["class"]
      return false unless line.attributes["stroke"] == "none" || stroke_free?(line, doc)

      line.remove
      true
    end

    def stroke_free?(line, doc)
      return false if line.attributes["stroke"] || svg_elements(doc.root).any? { |el| el.name == "style" }

      ancestors = []
      node = line.parent
      while node.is_a?(REXML::Element)
        ancestors << node
        node = node.parent
      end
      ancestors.none? { |el| STROKE_INHERITING.any? { |name| el.attributes[name] } }
    end

    def number(value)
      text = format("%.12f", value).sub(/\.?0+\z/, "")
      text == "-0" ? "0" : text
    end

    private_class_method :svg_elements, :repaired?, :rewrite, :removed_unstroked_line?, :stroke_free?, :number,
                         :reflect, :upright
  end

  private_constant :PostscriptFidelity
end
