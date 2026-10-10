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
    CLASS_OF = ::Object.instance_method(:class)
    KIND_OF = ::Object.instance_method(:is_a?)
    MODULE_NAME = ::Module.instance_method(:name)
    MODULE_TO_S = ::Module.instance_method(:to_s)
    private_constant :CLASS_OF, :KIND_OF, :MODULE_NAME, :MODULE_TO_S

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
      value = raw_message(error)
      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    rescue EncodingError
      value.b.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    # Call the core readers directly. An exception is an ordinary Ruby
    # object and can override #class just as it can override #message; the
    # diagnostic path must still name the exception that was actually raised.
    def class_name(error)
      klass = CLASS_OF.bind_call(error)
      MODULE_NAME.bind_call(klass) || MODULE_TO_S.bind_call(klass)
    end

    def matches_class?(error, kind)
      KIND_OF.bind_call(error, kind)
    end

    # Exception subclasses can override #message, including with a non-String
    # result or another exception. Reporting must not replace the original
    # failure with a failure from its diagnostic path. Copy a real String into
    # the core class so an overridden #encode cannot do the same thing later.
    def raw_message(error)
      value = error.message
      return ::String.new(value) if ::String === value # rubocop:disable Style/CaseEquality

      class_name(error)
    rescue StandardError
      class_name(error)
    end
    private_class_method :raw_message
  end

  private_constant :Fault
end
