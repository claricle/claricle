# frozen_string_literal: true

module Claricle
  # Command-line interface for Claricle
  class Cli < Thor
    def self.exit_on_failure?
      true
    end

    # Thor >= 1.5 adds `tree` to every subclass. This CLI documents and
    # ships only the commands it declares itself. Guarded because the
    # gemspec permits Thor down to 1.0, where `tree` does not exist and
    # `undefine: true` on a missing method raises NameError.
    remove_command :tree, undefine: true if method_defined?(:tree)

    desc "version", "Display Claricle version"
    def version
      puts "Claricle version #{Claricle::VERSION}"
    end

    # Turns an exception into a process status. `run` returns an Integer
    # for everything it maps, and never exits -- only exe/claricle exits,
    # so every code is reachable from a spec without trapping SystemExit.
    # Interrupt and other signals are deliberately not mapped and do
    # propagate, so Ctrl-C behaves like Ctrl-C.
    module Runner
      # A command sets its status by returning one of these. A bare Integer
      # is ignored, because thor passes a command's return value straight
      # through and any incidental `File.write` would otherwise become the
      # exit status.
      class Status
        RANGE = (0..255)
        private_constant :RANGE

        attr_reader :code

        def initialize(code)
          unless self.class.valid?(code)
            raise ArgumentError, "status must be an Integer in #{RANGE}, got #{code.inspect}"
          end

          @code = code
          freeze
        end

        def self.valid?(code)
          code.is_a?(Integer) && RANGE.cover?(code)
        end
      end

      class << self
        def run(argv, output: $stderr)
          result = Cli.start(argv, debug: true)
          result.is_a?(Status) ? result.code : 0
        rescue SystemExit => e
          # Thor turns Errno::EPIPE into SystemExit(0) even under debug,
          # and a command may exit deliberately. Neither is an error.
          # The status still has to be a byte: `exit 256` reports success.
          bounded_status(e.status)
        rescue StandardError, ScriptError, SystemStackError => e
          report(error_message(e), output)
          exit_code(e)
        end

        private

        # Writing the diagnostic must not become the failure. `output.puts`
        # sits inside a rescue body, so nothing above catches it: with
        # stderr on a closed pipe the EPIPE escaped `run` entirely and the
        # executable exited 1 -- the status the README reserves for a
        # nonconformant file. Failing to *report* an error cannot be
        # allowed to replace that error's own status.
        def report(message, output)
          output.puts(message)
        rescue StandardError
          nil
        end

        # Returns rather than raises: an ArgumentError from here would be
        # inside the SystemExit rescue and could not reach the next clause.
        def bounded_status(code)
          Status.valid?(code) ? code : 4
        end

        def exit_code(error)
          case error
          when Thor::Error, Errno::ENOENT, InvocationError then 2
          when UnknownFormat, UnsupportedFormat then 3
          else 4
          end
        end

        # An unexpected failure names its class: "claricle: missing gem" is
        # not much help when the class was LoadError. A mapped Claricle
        # error already reads as a sentence, so it does not need one.
        def error_message(error)
          return "claricle: #{error.message}" if error.is_a?(Error) || error.is_a?(Thor::Error)

          "claricle: #{error.class}: #{error.message}"
        end
      end
    end
  end
end
