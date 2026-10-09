# frozen_string_literal: true

require "rexml/document"

# Reads what a converted document DRAWS, so a spec can assert the output still
# holds the source's shapes instead of only that bytes came out.
module ConvertSemantics
  FIXTURES = File.expand_path("../fixtures/convert", __dir__)

  Shape = Struct.new(:kind, :points, :color, :width)

  module_function

  def fixture_path(name, ext = "svg") = File.join(FIXTURES, "#{name}.#{ext}")

  def hex_to_rgb(paint)
    return [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, Regexp.last_match(3).to_i] if
      paint =~ /\Argb\((\d+),\s*(\d+),\s*(\d+)\)\z/

    paint.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
  end

  # What the SVG source asks to be drawn, in document order: SVG's own default
  # fill is black and its default stroke is none, and neither rect nor line
  # inside `defs` is rendered. Written from the SVG rules, not from any output.
  def expected_shapes(svg_path)
    root = REXML::Document.new(File.read(svg_path)).root
    shapes = []
    walk(root) { |element| shapes.concat(shapes_of(element)) }
    shapes
  end

  def walk(element, &block)
    return if element.name == "defs"

    yield element
    element.each_element { |child| walk(child, &block) }
  end

  def shapes_of(element)
    case element.name
    when "rect" then [rect_shape(element)]
    when "line" then line_shape(element)
    else []
    end
  end

  def rect_shape(element)
    x, y, w, h = %w[x y width height].map { |name| number(element.attributes[name]) }
    fill = element.attributes["fill"]
    Shape.new(:fill, [[x, y], [x + w, y + h]], fill ? hex_to_rgb(fill) : [0, 0, 0], nil)
  end

  def line_shape(element)
    stroke = element.attributes["stroke"]
    return [] unless stroke

    points = %w[x1 y1 x2 y2].map { |name| number(element.attributes[name]) }
    [Shape.new(:stroke, [points.first(2), points.last(2)], hex_to_rgb(stroke), 1)]
  end

  def number(text) = text.to_s.delete_suffix("px").to_f

  def painted_shapes(postscript) = Interpreter.new.run(postscript)

  # [min_x, min_y, max_x, max_y] of a path.
  def extent(points)
    xs = points.map(&:first)
    ys = points.map(&:last)
    [xs.min, ys.min, xs.max, ys.max]
  end

  # A small PostScript interpreter for the operators these writers emit:
  # path construction, colour, line width, gsave/grestore, fill and stroke.
  # Returns the painted shapes with ABSOLUTE points and colours scaled to
  # 0..255. Raises on an operator it does not know, so an unmodelled operator
  # is a failure here, never a silently skipped shape.
  class Interpreter
    NUMBER = "(-?[\\d.]+)"
    PATH_OP = /\A#{NUMBER} #{NUMBER} (moveto|lineto|rlineto)\z/
    COLOUR = /\A#{NUMBER} #{NUMBER} #{NUMBER} setrgbcolor\z/
    WIDTH = /\A#{NUMBER} setlinewidth\z/
    IGNORED = /\A(\d+ set(linecap|linejoin)|closepath|showpage|%.*)?\z/

    def initialize
      @state = { color: [0, 0, 0], width: 1, path: [] }
      @stack = []
      @shapes = []
    end

    def run(postscript)
      postscript.each_line { |line| apply(line.strip) }
      @shapes
    end

    private

    def apply(line)
      return if IGNORED.match?(line)

      case line
      when "newpath", "gsave", "grestore", "fill", "stroke" then operator(line)
      when PATH_OP then step(Regexp.last_match)
      when COLOUR then colour(Regexp.last_match)
      when WIDTH then @state[:width] = Regexp.last_match(1).to_f
      else raise "ConvertSemantics: unmodelled PostScript line #{line.inspect}"
      end
    end

    def colour(match)
      @state[:color] = match.captures.map { |channel| (channel.to_f * 255).round }
    end

    def operator(name)
      case name
      when "newpath" then @state[:path] = []
      when "gsave" then @stack.push(@state.merge(path: @state[:path].dup))
      when "grestore" then @state = @stack.pop
      else paint(name.to_sym)
      end
    end

    def paint(kind)
      @shapes << Shape.new(kind, @state[:path].dup, @state[:color], kind == :stroke ? @state[:width] : nil)
    end

    def step(match)
      x = match[1].to_f
      y = match[2].to_f
      if match[3] == "rlineto"
        x += @state[:path].last[0]
        y += @state[:path].last[1]
      end
      @state[:path] << [x, y]
    end
  end
end
