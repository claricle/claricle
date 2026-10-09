# frozen_string_literal: true

require "rexml/document"
require_relative "../lossiness"

module Claricle
  module PostscriptFidelity
    # The lossiness of an svg -> ps/eps conversion: `:lossless` only holds
    # when `repair` could read the SVG it was meant to fix.
    module Verdict
      module_function

      def classify(source_format, target, svg)
        lossiness = Lossiness.classify(source_format: source_format, target_format: target, source: svg)
        return lossiness unless lossiness == "lossless" && POSTSCRIPT_TARGETS.include?(target)

        repairable?(svg) && renderable?(svg) ? lossiness : "unknown"
      end

      # A viewBox with no area disables rendering, so nothing it draws is right.
      def renderable?(svg)
        text = Detector.read_root(svg)&.last&.fetch("viewBox", nil)
        box = ViewBox.parse(text)
        text.nil? || box.nil? || box.last(2).all?(&:positive?)
      end

      def repairable?(svg)
        return true unless svg.match?(HINT)

        doc = REXML::Document.new(svg)
        !doc.root.nil? && doc.encoding == "UTF-8"
      rescue REXML::ParseException, RuntimeError, EncodingError, ArgumentError
        false
      end
    end
  end
end
