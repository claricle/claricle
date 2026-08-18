# frozen_string_literal: true

module Claricle
  # Command-line interface for Claricle
  class Cli < Thor
    def self.exit_on_failure?
      true
    end

    desc "version", "Display Claricle version"
    def version
      puts "Claricle version #{Claricle::VERSION}"
    end

    # Turns an exception into a process status. `run` returns an Integer
    # and never exits; only exe/claricle exits, so every code is reachable
    # from a spec without trapping SystemExit.
    module Runner
      # A command sets its status by returning one of these. A bare Integer
      # is ignored, because thor passes a command's return value straight
      # through and any incidental `File.write` would otherwise become the
      # exit status.
      class Status
        RANGE = (0..255)

        attr_reader :code

        def initialize(code)
          unless code.is_a?(Integer) && RANGE.cover?(code)
            raise ArgumentError, "status must be an Integer in #{RANGE}, got #{code.inspect}"
          end

          @code = code
          freeze
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
          in_range(e.status)
        rescue StandardError, ScriptError, SystemStackError => e
          output.puts(error_message(e))
          exit_code(e)
        end

        private

        # Returns rather than raises: an ArgumentError from here would be
        # inside the SystemExit rescue and could not reach the next clause.
        def in_range(code)
          Status::RANGE.cover?(code) ? code : 4
        end

        def exit_code(error)
          case error
          when Thor::Error, Errno::ENOENT, InvocationError then 2
          when UnknownFormat, UnsupportedFormat then 3
          else 4
          end
        end

        def error_message(error)
          "claricle: #{error.message}"
        end
      end
    end
  end
end
