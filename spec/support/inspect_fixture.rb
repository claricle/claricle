# frozen_string_literal: true

# Resolves a name under spec/fixtures/inspect/ to its full path. The two PDF
# names are the exception: they are built by PdfBuilder into its temp
# directory instead of committed. A module
# method rather than a `let` (this takes an argument and `let` has no
# arity) or an in-block `def` inside a describe block (which would define
# an instance method on that one anonymous example group class instead of
# living somewhere another spec file could reuse it).
require_relative "pdf_builder"

module InspectFixture
  # The cut sits inside the header and the objects, before the trailer;
  # any cut from byte 9 through 297 reports the same "no trailer" result.
  NO_TRAILER_BYTES = 60

  module_function

  def path(name)
    case name
    when "valid.pdf" then PdfBuilder.path(name: "inspect_valid")
    when "no_trailer.pdf" then truncated_pdf(name)
    else File.join(__dir__, "..", "fixtures", "inspect", name)
    end
  end

  def truncated_pdf(name)
    bytes = File.binread(PdfBuilder.path(name: "inspect_full"))
    PdfBuilder.write(bytes[0, NO_TRAILER_BYTES], name: name)
  end
end
