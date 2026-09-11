# frozen_string_literal: true

require "json"

module Claricle
  # Command-line interface for Claricle
  class Cli < Thor
    def self.exit_on_failure?
      true
    end

    # Thor >= 1.5 contributes both `help` and `tree` to every subclass.
    # Claricle keeps `help` and drops `tree`. Guarded because the gemspec
    # permits Thor down to 1.2, where `tree` does not exist and
    # `undefine: true` on a missing method raises NameError.
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

    desc "inspect FILE", "Report a file's format and metadata"
    option :json, type: :boolean, default: false, desc: "Emit JSON"
    # Named `inspect_file`, because a Thor command is an instance method
    # and `def inspect(file)` would override `Object#inspect` on every
    # Cli instance -- `p cli` then raises ArgumentError. This is D2's
    # rule (`Image#inspect` became `#inspection`) applied one layer up.
    # The command users type is still `inspect`; the re-key and the
    # override below are what keep the method name from leaking out.
    def inspect_file(file)
      inspection = Image.from_path(file).inspection
      payload = options[:json] ? inspection.to_json : Presenter.inspection(inspection)
      tolerate_closed_output { puts payload }
    end
    # Thor registers a command under its METHOD name, so this shipped as
    # the command `inspect_file` -- and `normalize_command_name`
    # translates dashes to underscores, so `inspect-file` reached it too.
    # `map "inspect" => :inspect_file` added a third spelling on top
    # rather than replacing the first two.
    #
    # Re-keying the registry entry leaves exactly `inspect`. The Command
    # object keeps its `inspect_file` name, so dispatch still reaches the
    # method above and `Object#inspect` is never shadowed.
    #
    # The `map` alias is dropped rather than kept, because with the entry
    # re-keyed `normalize_command_name("inspect")` would follow the alias
    # back to the name that no longer exists.
    commands["inspect"] = commands.delete("inspect_file")

    # Thor prints a command's METHOD name in an arity error, and the
    # method behind `inspect` is `inspect_file` -- so `claricle inspect`
    # with no file answered `ERROR: "claricle inspect_file" was called
    # with no arguments`, naming the one spelling this CLI rejects.
    # Measured.
    #
    # The registry key is Thor's CANONICAL name for the command, which
    # is not always what the user typed -- Thor resolves abbreviations
    # first, so `claricle ins` arrives here with key `inspect`. That is
    # the name worth printing either way. The message is built from a
    # copy carrying it; a copy, because the original's name is what Thor
    # dispatches on. A command whose key already matches is passed
    # through untouched.
    def self.handle_argument_error(command, error, args, arity)
      key = commands.key(command)
      command = command.dup.tap { |copy| copy.name = key } if key && key != command.name

      super
    end

    desc "formats", "List the formats Claricle handles and what it can do with each"
    option :json, type: :boolean, default: false, desc: "Emit JSON"
    def formats
      rows = Registry.formats.map { |format| Presenter.format_row(format) }
      payload = options[:json] ? JSON.generate(rows) : Presenter.format_table(rows)
      tolerate_closed_output { puts payload }
    end

    desc "conform FILE...", "Check files against their format's conformance rules"
    option :pattern, type: :string,
                     desc: "Read this as a glob, whatever the filename looks like"
    option :json, type: :boolean, default: false, desc: "Emit JSON"
    option :strict, type: :boolean, default: false,
                    desc: "Require a clean verdict, not merely the absence of errors"
    option :profile, type: :string,
                     desc: "Require conformance to this profile; no format defines one yet"
    def conform(*files)
      result = Claricle.conformance_batch(*files, pattern: options[:pattern],
                                                  strict: options[:strict],
                                                  profile: options[:profile])
      # The status is settled before anything is written. `tolerate_closed_output`
      # answers 0, which is right for a command that can only succeed and
      # would silently turn a nonconformant batch into a passing one here.
      tolerate_closed_output { write_conformance(result) }
      Runner::Status.new(result.exit_code)
    end

    # Rendering, kept together so the commands only choose a payload and
    # write it. Nothing here touches `options` or writes output.
    module Presenter
      # C0, DEL, C1, and Unicode's own two line breaks. Not just C0:
      # U+0085 is NEL, a next-line control, and U+009B is CSI, the
      # introducer an escape sequence uses -- both reachable as
      # character references, both measured arriving in the output
      # intact. U+2028 and U+2029 are line and paragraph separators by
      # definition. Nothing here is a character a file has a reason to
      # put in its metadata.
      CONTROL = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/
      # Named here rather than read off the model, so the printed order is
      # chosen rather than whatever order the attributes happen to sit in.
      LOCATION_FIELDS = %i[chunk byte_offset byte_length line column node_path].freeze
      private_constant :CONTROL, :LOCATION_FIELDS

      module_function

      # Per file: the path, the tri-state verdict, and every mapped issue on
      # one line. A conformant file prints its path and verdict, nothing
      # more. A file whose operation could not run has no verdict to print
      # and is reported on stderr instead.
      def conformance(items)
        items.reject { |item| item.status == "error" }
             .flat_map { |item| ["#{visible(item.path)}: #{item.result.valid}", *issues(item)] }
             .join("\n")
      end

      def conformance_failures(items)
        items.select { |item| item.status == "error" }
             .map { |item| "claricle: #{visible(item.path)}: #{visible(item.error.message)}" }
      end

      def issues(item)
        item.result.issues.map do |issue|
          ["  #{visible(issue.severity)}", code(issue.code),
           visible(issue.message), location(issue.location)].compact.join(" ")
        end
      end

      # Absent, not `[]`: Issue#code is optional, and an empty bracket
      # pair would read as a code nobody chose rather than one the
      # delegate never reported.
      def code(code)
        return if code.nil?

        "[#{visible(code)}]"
      end

      # Only what a delegate actually reported. Spelling out six fields
      # would print four nils, and printing none would lose the ones that
      # were measured.
      def location(location)
        return if location.nil?

        populated = LOCATION_FIELDS.filter_map do |name|
          value = location.public_send(name)
          "#{name}: #{visible(value)}" unless value.nil?
        end
        "(#{populated.join(", ")})" unless populated.empty?
      end

      # Capabilities are derived from the handler, so this cannot
      # advertise an operation that is still a raising stub. `convert_to`
      # stays empty until item 04 gives handlers a target list.
      def format_row(format)
        capabilities = Registry.capabilities_for(format)

        {
          "format" => format.to_s,
          "inspect" => capabilities.include?(:inspect),
          "conform" => capabilities.include?(:conform),
          "convert" => capabilities.include?(:convert),
          # The list of targets is item 04's; the boolean above already
          # tells the truth about whether convert works at all.
          "convert_to" => []
        }
      end

      def format_table(rows)
        rows.map do |row|
          operations = %w[inspect conform convert].select { |name| row[name] }
          "#{row["format"]}\t#{operations.join(", ")}"
        end.join("\n")
      end

      def inspection(inspection)
        rows(inspection)
          .filter_map { |label, value| "#{visible(label)}: #{visible(value)}" unless value.nil? }
          .join("\n")
      end

      # Metadata is free text out of the file, and an SVG root attribute
      # can hold a newline: `&#xA;` is a character reference, so XML
      # keeps it as a real newline rather than folding it to a space.
      # Printed raw, `id="a&#xA;error: forged"` produced an "error:"
      # line of Claricle's own shape, and `&#xD;` overwrote the line in
      # a terminal. Control characters are shown escaped instead.
      #
      # Only the human rendering needs this. `--json` carries the true
      # value and JSON escapes it on the way out, so the two disagree on
      # presentation and agree on the bytes.
      def visible(text)
        text.to_s.gsub(CONTROL) { |char| escaped(char.ord) }
      end

      # `\xNN` up to a byte, `\u{NNNN}` above it. One form for both
      # would either print `\x2028` -- which reads as `\x20` followed by
      # "28" -- or spell a newline `\u{000A}`.
      def escaped(code)
        code > 0xFF ? format("\\u{%04X}", code) : format("\\x%02X", code)
      end

      # Label/value pairs filtered once, rather than a conditional per
      # field: a nil field is simply absent, and adding a field later does
      # not add a branch. Pairs rather than a Hash, because two issues can
      # share a severity and a Hash would silently drop one.
      def rows(inspection)
        [
          ["format", inspection.format], *dimension_rows(inspection),
          ["dpi", inspection.dpi], ["color space", inspection.color_space],
          *meta_rows(inspection), ["parse status", inspection.parse_status],
          *inspection.issues.map { |issue| [issue.severity, issue.message] }
        ]
      end

      # Metadata keys come out of the file, and an SVG root may declare
      # any attribute it likes. Unprefixed, `error="forged"` printed a
      # line shaped exactly like an issue and `format="png"` printed a
      # second, contradictory format line. The prefix keeps the file's
      # own words in their own namespace.
      #
      # It settles a collision that was already there, too: an SVG
      # declaring `width="10mm"` produced a `width` line for the raw
      # declaration and another for the computed 37.79 px.
      def meta_rows(inspection)
        inspection.meta.to_a.sort.map { |key, value| ["meta.#{key}", value] }
      end

      # One line when both are known, separate lines when only one is.
      # SVG can carry a width and no height, and "7.0x" is not a
      # dimension -- but dropping the line would lose the width entirely.
      def dimension_rows(inspection)
        width = inspection.width
        height = inspection.height
        return [["dimensions", "#{width}x#{height}"]] if width && height

        [["width", width], ["height", height]]
      end
    end

    private_constant :Presenter

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

      # Errors Claricle recognises, whose own message already reads as a
      # sentence. Everything else gets its class named.
      MAPPED = [Error, Thor::Error, Errno::ENOENT].freeze
      private_constant :MAPPED

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

        # The library owns the map, because a batch has to reach the same
        # answer for the same exception. Thor's own errors are the one row
        # that belongs here: they cannot arise inside an operation, and
        # Fault is deliberately Thor-free.
        def exit_code(error)
          error.is_a?(Thor::Error) ? 2 : Fault.exit_code(error)
        end

        # An unexpected failure names its class: "claricle: missing gem" is
        # not much help when the class was LoadError. A recognised error
        # does not need one -- ENOENT included, now that `inspect` takes a
        # path and a typo is an ordinary user error rather than a defect.
        def error_message(error)
          message = Fault.message(error)
          # Errno::ENOENT joins the bare-message set now that a command
          # takes a path. It was already exit code 2, but its message was
          # unreachable while nothing opened a file, so naming the class
          # went unnoticed. A missing file is an ordinary user mistake and
          # reads as one.
          return "claricle: #{message}" if MAPPED.any? { |kind| error.is_a?(kind) }

          "claricle: #{error.class}: #{message}"
        end
      end
    end

    private

    def tolerate_closed_output
      yield
    rescue Errno::EPIPE
      Runner::Status.new(0)
    end

    # JSON is always an array, a single result included: a filename may
    # legally contain glob characters and a shell expands an unquoted glob
    # before Claricle sees it, so which form the user typed is not knowable
    # and the shape must not depend on it.
    #
    # Human output splits: verdicts to stdout, one line per failed file to
    # stderr. Skipped entirely when every file failed, so `puts` cannot
    # print a bare blank line where the JSON form prints a whole array.
    def write_conformance(result)
      return puts(Models::BatchItem.to_json(result.items)) if options[:json]

      verdicts = Presenter.conformance(result.items)
      puts verdicts unless verdicts.empty?
      Presenter.conformance_failures(result.items).each { |line| warn line }
    end
  end
end
