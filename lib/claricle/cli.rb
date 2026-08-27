# frozen_string_literal: true

module Claricle
  # Command-line interface for Claricle
  class Cli < Thor
    def self.exit_on_failure?
      true
    end

    # Thor >= 1.5 adds `tree` to every subclass. This CLI ships the
    # `version` it declares plus the `help` Thor contributes, and the
    # README documents both -- `tree` is the one it drops. Guarded
    # because the gemspec permits Thor down to 1.2, where `tree` does
    # not exist and `undefine: true` on a missing method raises
    # NameError.
    remove_command :tree, undefine: true if method_defined?(:tree)

    desc "version", "Display Claricle version"
    def version
      tolerate_closed_output { puts "Claricle version #{Claricle::VERSION}" }
    end

    # Thor supplies this command. Keep a closed consumer of command output
    # successful without hiding an EPIPE raised by the command's own work.
    def help(command = nil, subcommand = false) # rubocop:disable Style/OptionalBooleanParameter
      tolerate_closed_output { super(command, subcommand) }
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
          arguments = argv.dup
          validate_arguments(arguments)
          normalize_command_arguments(arguments)
          result = invoke(arguments)
          result.is_a?(Status) ? result.code : 0
        rescue SystemExit => e
          # A command may exit deliberately. The status still has to be a
          # byte: `exit 256` reports success.
          bounded_status(e.status)
        rescue StandardError, ScriptError, SystemStackError => e
          report(error_message(e), output)
          exit_code(e)
        end

        private

        # Thor's public `start` turns every EPIPE into success, including
        # one raised by a command's own operation. Dispatch directly so the
        # runner can map those failures; Cli handles only its output writes.
        def invoke(arguments)
          Cli.send(:dispatch, nil, arguments, nil, { shell: Thor::Base.shell.new })
        end

        # Thor assumes argv text is valid and ASCII-compatible. Reject input
        # it cannot parse as a bad invocation instead of an internal error.
        def validate_arguments(arguments)
          arguments.each_with_index do |argument, index|
            valid = argument.is_a?(String) &&
                    argument.encoding.ascii_compatible? &&
                    argument.valid_encoding?
            next if valid

            raise InvocationError, "argument #{index + 1} must be valid ASCII-compatible text"
          end
        end

        # Command names are semantic text, unlike future positional paths.
        # Thor compares them with UTF-8 command keys and can choke on another
        # valid ASCII-compatible encoding, so normalize only that boundary.
        def normalize_command_arguments(arguments)
          command_name = arguments[0]
          # A leading terminator selects Thor's default command without itself
          # becoming a command name; leave it in argv for Thor to consume.
          command_name = nil if command_name == "--"
          arguments[0] = command_name = command_text(command_name) if command_name
          return unless help_command?(command_name) && arguments[1]

          arguments[1] = command_text(arguments[1])
        end

        def command_text(argument)
          argument.encode(Encoding::UTF_8)
        rescue EncodingError
          raise InvocationError, "command name cannot be converted to UTF-8"
        end

        def help_command?(name)
          Cli.send(:normalize_command_name, name) == "help"
        end

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
          message = utf8_message(error.message)
          return "claricle: #{message}" if error.is_a?(Error) || error.is_a?(Thor::Error)

          "claricle: #{error.class}: #{message}"
        end

        def utf8_message(message)
          message.encode(Encoding::UTF_8, invalid: :replace)
        rescue EncodingError
          message.b.encode(Encoding::UTF_8, undef: :replace)
        end
      end
    end

    private

    def tolerate_closed_output
      yield
    rescue Errno::EPIPE
      Runner::Status.new(0)
    end
  end
end
