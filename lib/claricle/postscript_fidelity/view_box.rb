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
