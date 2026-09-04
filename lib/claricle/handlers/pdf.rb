# frozen_string_literal: true

require_relative "base"
require_relative "../models/issue"
require_relative "../models/report"

module Claricle
  module Handlers
    # PDF conformance is `pdfrb`'s pre-write structural check
    # (`Validator.validate`) -- catalog, pages, MediaBox, and reference
    # resolution -- not ISO 32000 conformance (03-conform.md, D16). There
    # is no separate structural pre-pass for PDF the way PNG, SVG and EMF
    # have one (D23): the plan's own Design table names
    # `Validator.validate` as the whole structural check, so this handler
    # adds nothing on top of it.
    #
    # This handler implements `conform` only. `inspect` for PDF is a
    # different unit of work.
    class Pdf < Base
      formats :pdf

      # Builds the `Report` a conform operation returns. A sibling class
      # rather than instance methods, matching `Handlers::Png`'s own
      # `ConformanceMapper` -- the mapping owes nothing to any metadata
      # interpretation this handler might grow later.
      class ConformanceMapper
        # Measured against the installed pdfrb gem (0.7.49, resolved from
        # claricle.gemspec's `~> 0.7.23`) rather than assumed --
        # 03-conform.md's own summary is a starting point, not a source,
        # and it is what this class's own tests pin.
        #
        # A catalog-less document (no `/Root` in the trailer, or a
        # `/Root` pointing at an oid absent from the xref) raises
        # `Pdfrb::Error` ("Document has no Catalog"). For THAT shape it
        # is not `check_catalog` that raises -- it only appends a string
        # to the error array and returns; the raise comes from
        # `check_pages` walking into `Document::Pages#pages_root`, which
        # re-derives the catalog and raises when it is nil.
        #
        # `check_catalog` DOES raise directly for a related but distinct
        # shape: a `/Root` reference the xref marks "in use" but whose
        # bytes cannot be found anywhere in the file (a corrupt offset
        # with no matching "N G obj" elsewhere either). There,
        # `document.catalog` itself raises `Pdfrb::MalformedPdfError` --
        # a `Pdfrb::Error` subclass, not the base class, and not the
        # "Document has no Catalog" message -- from
        # `ObjectReader#recover_parse`. Rescuing the base `Pdfrb::Error`
        # class (not just literal instances of it) is what catches this,
        # and every other subclass the gem may raise, on the same
        # reasoning: pdfrb's own error hierarchy reporting a structural
        # fault is the same nonconformance an ordinary returned issue
        # would carry.
        #
        # A `/Pages` reference to a missing object raises `NoMethodError:
        # undefined method '[]' for nil` from `Document::Pages#walk`,
        # which subscripts the unresolved node directly.
        #
        # `Document.open` itself can ALSO raise: a `startxref` pointer
        # that resolves to neither an `xref` keyword nor a parseable
        # object -- an ordinary corrupt-file shape, not one any fixture
        # here had tried -- reaches `Document#find_xref_keyword`'s
        # `chunk.rindex(...)` with `chunk` nil (a short/absent read past
        # EOF), raising `NoMethodError: undefined method 'rindex' for
        # nil`. Measured live; an earlier version of this handler left
        # `Document.open` outside the rescue on the strength of "every
        # malformed shape measured ... opens without raising", which
        # this shape falsifies -- a contract measured on the shapes
        # tried and wrongly generalised to "every shape". `issues_for`
        # below wraps both pdfrb calls for exactly this reason.
        #
        # Scoped to just those two calls, not to Claricle's own code
        # (03-conform.md: "wrapping the call rather than allowlisting
        # NoMethodError globally") -- `report_for`, `Image#with_path`,
        # and Report/Issue construction are outside `issues_for`'s
        # rescue, so a `NoMethodError` from a real defect in THIS
        # handler's own code, or in `Image`, still propagates to exit 4
        # rather than reading as an ordinary nonconformant file.
        #
        # `SystemStackError` is not in the plan's own table -- found by
        # this handler's own adversarial pass: a `/Pages` node whose own
        # `/Kids` cites itself sends `Document::Pages#walk` into infinite
        # recursion. `SystemStackError` is not a `StandardError`
        # subclass, so the rescue below needs it named explicitly to
        # catch it. Rescuing it here is safe -- Ruby's stack is usable
        # again the moment the exception has unwound to this frame
        # (measured) -- and the user-visible meaning is the same
        # nonconformance a returned issue would carry, so it goes on the
        # allowlist for the same reason the plan puts EMF's truncation
        # `FormatError` on its own: the exit code follows the meaning,
        # not the delegate's reporting style. This does not conflict
        # with the Runner's own `SystemStackError` -> 4 mapping
        # (01-core.md, `Cli::Runner.run`): that is the default for a
        # `SystemStackError` no handler has positively identified, the
        # same role `StandardError` -> 4 plays for `NoMethodError`
        # everywhere this handler does NOT rescue it. A handler
        # reclassifying a MEASURED, deterministic raise as nonconformance
        # is the pattern the plan already uses for EMF's `FormatError`,
        # not an exception to it.
        #
        # Named directly in the `rescue` clause below rather than in a
        # frozen constant: `Pdfrb::Error` does not exist until `require
        # "pdfrb"` has run (D5 -- the gem is loaded lazily, inside
        # `conformance_report`), and a class-level constant is evaluated
        # when this file is required, well before that -- measured, that
        # ordering raised `NameError: uninitialized constant Pdfrb` at
        # load time. A `rescue` clause's exception list is evaluated only
        # when `issues_for` actually runs, by which point the require has
        # already happened.

        # The code and message 03-conform.md assigns the STRING mapping
        # case -- a returned error, not a raised one.
        STRUCTURE_CODE = "PDF_STRUCTURE"

        # A sibling, stable code for the cases pdfrb reports by raising
        # instead of returning. Distinct from STRUCTURE_CODE so a caller
        # can still tell "the delegate told us this directly" from "the
        # delegate's own check could not run at all" -- and a fixed
        # message rather than the raised exception's own text, which for
        # `NoMethodError` ("undefined method '[]' for nil") would leak a
        # Ruby internal rather than say anything about the PDF.
        UNREADABLE_CODE = "PDF_STRUCTURE_UNREADABLE"
        UNREADABLE_MESSAGE = "PDF structure could not be validated"

        def self.report(image)
          # `image.with_path`, not `image.with_source`: `Document.open`
          # takes a path (or an IO through its block form).
          report_for(image, image.with_path { |path| issues_for(path) })
        end

        def self.report_for(image, issues)
          Models::Report.new(source_path: image.path, format: image.format.to_s, issues: issues)
        end

        # Both pdfrb calls this handler makes, in one rescue -- see the
        # class comment above for why both need it. Nothing else is in
        # this method: `issue_from` (Claricle's own `Models::Issue`
        # construction) runs in `issues_for` below, OUTSIDE this rescue
        # -- an earlier version built the issues inside this same
        # method, which put `issue_from` inside the same rescue too
        # (found in copilot-review). A `NoMethodError` from this
        # handler's own code belongs on the same footing as one from
        # `report_for`: it propagates, rather than reading as an
        # ordinary nonconformant file.
        def self.validate(path)
          document = ::Pdfrb::Document.open(path)
          ::Pdfrb::Validator.validate(document)
        rescue ::Pdfrb::Error, NoMethodError, SystemStackError
          :malformed
        end

        def self.issues_for(path)
          errors = validate(path)
          return [unreadable_issue] if errors == :malformed

          errors.map { |message| issue_from(message) }
        end

        def self.issue_from(message)
          Models::Issue.new(severity: "error", code: STRUCTURE_CODE, message: message, location: nil)
        end

        def self.unreadable_issue
          Models::Issue.new(severity: "error", code: UNREADABLE_CODE,
                            message: UNREADABLE_MESSAGE, location: nil)
        end

        private_class_method :report_for, :validate, :issues_for, :issue_from, :unreadable_issue
      end

      private_constant :ConformanceMapper

      def conformance_report(image)
        require "pdfrb"

        ConformanceMapper.report(image)
      end
    end
  end
end
