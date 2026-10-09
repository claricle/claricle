# frozen_string_literal: true

require_relative "../detector"

module Claricle
  module PostscriptFidelity
    # The root viewBox, which postsvg reads as [llx lly urx ury] instead of
    # [x y width height]: only an origin of 0 0 is read correctly.
    module ViewBox
      module_function

      # [x, y, width, height], or nil unless four numbers.
      def parse(text)
        parts = text.to_s.strip.split(/[\s,]+/).map { |part| Float(part, exception: false) }
        parts if parts.length == 4 && parts.all?
      end

      def root(svg) = parse(Detector.read_root(svg)&.last&.fetch("viewBox", nil))

      # The height of the viewport `orient` flips about, or nil when unknown.
      def viewport_sum(svg)
        attributes = Detector.read_root(svg)&.last or return
        return height_at_origin(attributes["viewBox"]) if attributes["viewBox"]

        height = PostscriptFidelity::LENGTH.match(attributes["height"].to_s)
        Float(height[1]) if height
      end

      # [width, height, scale, dx, dy] mapping the viewBox into the width/height
      # viewport (preserveAspectRatio's default, xMidYMid meet), or nil when
      # the viewBox already is the viewport.
      def fit(svg)
        attributes = Detector.read_root(svg)&.last or return
        box = parse(attributes["viewBox"])
        return unless box && box[2].positive? && box[3].positive?

        width, height = viewport(attributes, box)
        place(width, height, box) unless [width, height] == box[2, 2]
      end

      def place(width, height, box)
        scale = [width / box[2], height / box[3]].min
        [width, height, scale, *[width - (scale * box[2]), height - (scale * box[3])].map { |slack| slack / 2 }]
      end

      # A missing width or height follows the viewBox's aspect ratio.
      def viewport(attributes, box)
        width, height = %w[width height].map { |name| length(attributes[name]) }
        width ||= height ? height * box[2] / box[3] : box[2]
        [width, height || (width * box[3] / box[2])]
      end

      def length(text)
        match = PostscriptFidelity::LENGTH.match(text.to_s)
        Float(match[1]) if match
      end
      private_class_method :place, :viewport, :length

      # The origin the delegate was NOT shown: `rebase_origin?` zeroed it, so `orient` must shift by it.
      def rebased_origin(original, fixed)
        before = root(original)
        after = root(fixed)
        after && after[0, 2] == [0.0, 0.0] && before ? before[0, 2] : [0.0, 0.0]
      end

      # Rewrites a non-zero origin to 0 0; true when it changed.
      def rebase_origin?(element)
        box = parse(element.attributes["viewBox"])
        return false if box.nil? || box[0, 2] == [0.0, 0.0]

        element.attributes["viewBox"] = "0 0 #{box[2]} #{box[3]}"
        true
      end

      def height_at_origin(text)
        x, y, _, height = parse(text)
        height if x&.zero? && y&.zero?
      end
      private_class_method :height_at_origin
    end
  end
end
