# frozen_string_literal: true

require_relative "base"

module Claricle
  module Handlers
    # A throwaway format used only by spec/claricle/one_class_per_format_spec.rb.
    # It is the whole of what adding a format costs.
    class Qoi < Base
      formats :qoi
      detect { |header| :qoi if header.start_with?("qoif") }
      convert_from(:svg) { |content, _to| "qoif#{content.bytesize}".b }
      loss_rules lost: %i[gradient], kept: %i[basic_shape]
    end
  end
end
