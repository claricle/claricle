# frozen_string_literal: true

require_relative "errors"

module Claricle
  # An exception described as data: the status it means, and a message that
  # can be rendered. Both are needed in two places -- the CLI runner turns a
  # fault into a process status, and a batch turns one into an envelope --
  # and a second copy of either rule is a second place for them to disagree.
  #
  # Thor's own errors are deliberately absent. They are the CLI's business,
  # they cannot reach a batch operation, and naming them here would drag
  # `require "thor"` into the library layer.
  module Fault
    module_function

    def exit_code(error)
      case error
      when Errno::ENOENT, InvocationError then 2
      when UnknownFormat, UnsupportedFormat then 3
      else 4
      end
    end

    # A delegate's message is not guaranteed to be valid UTF-8. Left alone
    # it reaches a String attribute that Models::Base refuses because JSON
    # cannot render it, so reporting the failure would become the failure.
    def message(error)
      error.message.encode(Encoding::UTF_8, invalid: :replace)
    rescue EncodingError
      error.message.b.encode(Encoding::UTF_8, undef: :replace)
    end
  end

  private_constant :Fault
end
