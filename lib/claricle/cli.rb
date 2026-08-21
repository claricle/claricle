# frozen_string_literal: true

require "json"

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

    desc "inspect FILE", "Report a file's format and metadata"
    option :json, type: :boolean, default: false, desc: "Emit JSON"
    # Named `inspect_file` and mapped, because a Thor command is an
    # instance method and `def inspect(file)` would override
    # `Object#inspect` on every Cli instance -- `p cli` then raises
    # ArgumentError. This is D2's rule (`Image#inspect` became
    # `#inspection`) applied one layer up. The command is still `inspect`.
    def inspect_file(file)
      inspection = Image.from_path(file).inspection
      puts(options[:json] ? inspection.to_json : Presenter.inspection(inspection))
    end
    # Thor registers a command under its METHOD name and `map` only adds
    # an alias on top, so `inspect_file` stayed callable -- and Thor's
    # `normalize_command_name` translates dashes to underscores, so
    # `inspect-file` worked too. Three spellings, one documented.
    #
    # Re-keying the command and dropping both the method-named entry and
    # the alias leaves exactly `inspect`. The Command object keeps its
    # `inspect_file` name, so dispatch still reaches the method above and
    # `Object#inspect` is never shadowed.
    #
    # Neither obvious one-liner works: removing the command alone breaks
    # `inspect` too, because the alias then points at nothing, and
    # keeping the alias re-resolves `inspect` back to the removed name.
    commands["inspect"] = commands.delete("inspect_file")
    map.delete("inspect")

    desc "formats", "List the formats Claricle handles and what it can do with each"
    option :json, type: :boolean, default: false, desc: "Emit JSON"
    def formats
      rows = Registry.formats.map { |format| Presenter.format_row(format) }
      puts(options[:json] ? JSON.generate(rows) : Presenter.format_table(rows))
    end

    # Rendering, kept together so the commands above stay one line each.
    # Nothing here touches `options` or writes output; the commands do
    # both.
    module Presenter
      module_function

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
          .filter_map { |label, value| "#{label}: #{value}" unless value.nil? }
          .join("\n")
      end

      # Label/value pairs filtered once, rather than a conditional per
      # field: a nil field is simply absent, and adding a field later does
      # not add a branch. Pairs rather than a Hash, because two issues can
      # share a severity and a Hash would silently drop one.
      def rows(inspection)
        [
          ["format", inspection.format], *dimension_rows(inspection),
          ["dpi", inspection.dpi], ["color space", inspection.color_space],
          *inspection.meta.to_a.sort, ["parse status", inspection.parse_status],
          *inspection.issues.map { |issue| [issue.severity, issue.message] }
        ]
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

        attr_reader :code

        def initialize(code)
          unless code.is_a?(Integer) && RANGE.cover?(code)
            raise ArgumentError, "status must be an Integer in #{RANGE}, got #{code.inspect}"
          end

          @code = code
          freeze
        end
      end

      # Errors Claricle recognises, whose own message already reads as a
      # sentence. Everything else gets its class named.
      MAPPED = [Error, Thor::Error, Errno::ENOENT].freeze
      private_constant :MAPPED

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
          Status::RANGE.cover?(code) ? code : 4
        end

        def exit_code(error)
          case error
          when Thor::Error, Errno::ENOENT, InvocationError then 2
          when UnknownFormat, UnsupportedFormat then 3
          else 4
          end
        end

        # An unexpected failure names its class: "claricle: missing gem" is
        # not much help when the class was LoadError. A recognised error
        # does not need one -- ENOENT included, now that `inspect` takes a
        # path and a typo is an ordinary user error rather than a defect.
        def error_message(error)
          return "claricle: #{error.message}" if MAPPED.any? { |kind| error.is_a?(kind) }

          "claricle: #{error.class}: #{error.message}"
        end
      end
    end
  end
end
