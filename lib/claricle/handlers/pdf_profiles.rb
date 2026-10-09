# frozen_string_literal: true

require_relative "../models/issue"
require_relative "../models/location"

module Claricle
  module Handlers
    # Dispatches pdfrb's named conformance families and maps their typed
    # violations into Claricle's common issue model.
    class PdfProfiles
      PROFILE_LEVELS = {
        pdf_a: %i[a1b a1a a2b a2a a3b a3a a4].freeze,
        pdf_ua: nil,
        pdf_x: %i[x1a x3 x4 x6].freeze,
        pdf_vt: %i[vt1 vt2].freeze,
        pades: %i[b-b b-t b-lt b-lta].freeze,
        ltv: nil,
        pdf_2_af: nil,
        tagged_pdf: nil
      }.freeze
      VALIDATORS = {
        pdf_a: :PdfA,
        pdf_ua: :PdfUA,
        pdf_x: :PdfX,
        pdf_vt: :PdfVT,
        pades: :Pades,
        ltv: :Ltv,
        pdf_2_af: :Pdf2AF,
        tagged_pdf: :TaggedPdf
      }.freeze
      PADES_LEVELS = {
        "b-b": :"B-B", "b-t": :"B-T",
        "b-lt": :"B-LT", "b-lta": :"B-LTA"
      }.freeze
      private_constant :PROFILE_LEVELS, :VALIDATORS, :PADES_LEVELS

      def self.profiles = PROFILE_LEVELS.keys

      def self.levels_for(profile) = PROFILE_LEVELS.fetch(profile)

      def self.issues(document, profile, level)
        validator = ::Pdfrb::Conformance.const_get(VALIDATORS.fetch(profile))
        arguments = level ? { level: delegate_level(profile, level) } : {}
        validator.validate(document, **arguments).violations.map { |violation| issue(violation) }
      end

      def self.delegate_level(profile, level)
        profile == :pades ? PADES_LEVELS.fetch(level) : level
      end
      private_class_method :delegate_level

      def self.issue(violation)
        location = violation.object && Models::Location.new(node_path: violation.object.to_s)
        Models::Issue.new(
          severity: violation.severity.to_s,
          code: violation.rule_id.to_s,
          message: violation.message,
          location: location
        )
      end
      private_class_method :issue
    end

    private_constant :PdfProfiles
  end
end
