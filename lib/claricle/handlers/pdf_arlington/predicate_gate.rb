# frozen_string_literal: true

module Claricle
  module Handlers
    module PdfArlington
      # Runs a field's `fn:IsRequired(...)` predicate through pdfrb's
      # evaluator. pdfrb 0.7.49 does not parse every predicate in its own
      # tables (measured: 78 of 192 Required predicates raise SyntaxError)
      # and lacks some functions, so anything it cannot parse or run is
      # "not known to be required" -- never an issue.
      class PredicateGate
        def initialize(version)
          @version = version
          @parsed = {}
        end

        def required?(source, dict)
          ast = @parsed.fetch(source) { @parsed[source] = parse(source) }
          ast ? evaluate(ast, dict) == true : false
        end

        private

        def parse(source)
          ::Pdfrb::Arlington::Predicate::Parser.parse(source)
        rescue ::Pdfrb::Error
          nil
        end

        def evaluate(ast, dict)
          context = ::Pdfrb::Arlington::Predicate::Context.new(current: dict, version: @version)
          ::Pdfrb::Arlington::Predicate::Evaluator.call(ast, context)
        rescue ::Pdfrb::Error, NoMethodError, TypeError, ArgumentError
          nil
        end
      end
    end
  end
end
