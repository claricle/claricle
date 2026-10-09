# frozen_string_literal: true

require_relative "base"
require_relative "../models/inspection"

module Claricle
  module Handlers
    # A throwaway handler whose every operation faults, used only through
    # spec/support/extra_handler_cli.rb (copied into a scratch lib/, never
    # loaded in the spec process). The second word of the file picks the
    # fault: `defect` raises a non-Claricle RuntimeError, `epipe` raises a
    # broken pipe from the operation itself, `json_epipe` returns an
    # inspection whose JSON rendering raises one.
    class Boom < Base
      formats :boom
      detect { |header| :boom if header.start_with?("BOOM") }
      convert_to :svg

      class PipeBreakingInspection < Models::Inspection
        def to_json(*)
          raise Errno::EPIPE
        end
      end

      def inspection(image)
        case mode(image)
        when "epipe" then raise Errno::EPIPE
        when "json_epipe" then PipeBreakingInspection.new(format: "boom", parse_status: "ok")
        else raise "handler defect"
        end
      end

      def conformance_report(_image)
        raise "handler defect"
      end

      def convert(_image, to:)
        raise "handler defect for #{to}"
      end

      private

      def mode(image)
        image.content.split[1]
      end
    end
  end
end
