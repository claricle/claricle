# frozen_string_literal: true

require_relative "pdf_arlington/walker"

module Claricle
  module Handlers
    # Arlington-model conformance for a parsed pdfrb document: required
    # keys, value types and enumerated names, checked from the Catalog
    # down. pdfrb ships Arlington's tables, predicate evaluator and
    # loader but no document runner (measured on 0.7.49), so the walk is
    # ours.
    module PdfArlington
      module_function

      # `document` is a `Pdfrb::Document`. Returns an Array of
      # `Models::Issue`; empty when the document has no Catalog (the
      # structural check reports that).
      def issues(document)
        return [] unless catalog?(document)

        Walker.new(document, version_of(document)).issues
      end

      # A Catalog that cannot be read is the structural check's finding.
      def catalog?(document)
        Kind.plain(document.catalog).is_a?(::Hash)
      rescue ::Pdfrb::Error, NoMethodError, SystemStackError
        false
      end

      def version_of(document)
        ::Pdfrb::Arlington::PdfVersion.new(document.version.to_s)
      rescue ::Pdfrb::Error, ArgumentError
        ::Pdfrb::Arlington::PdfVersion.new("1.0")
      end
    end
  end
end
