# frozen_string_literal: true

require "English"
require "stringio"

RSpec.describe Claricle::Cli::Runner do
  status = described_class::Status

  # A real Thor subclass, not a double: the runner's whole job is what
  # happens to an exception on its way out of Thor. Status is captured in
  # a closure because stubbing Claricle::Cli replaces the namespace the
  # probe would otherwise look it up through.
  accepted_arguments = []
  errors = {
    "enoent" => [Errno::ENOENT, "nope"],
    "invocation" => [Claricle::InvocationError, "bad flags"],
    "unknown" => [Claricle::UnknownFormat, "no signature"],
    "unsupported" => [Claricle::UnsupportedFormat.new(:wmf, :convert)],
    "conversion" => [Claricle::ConversionError, "failed"],
    "standard" => [StandardError, "plain"],
    "argument" => [ArgumentError, "bad arg"],
    "load" => [LoadError, "missing gem"],
    "syntax" => [SyntaxError, "bad syntax"],
    "stack" => [SystemStackError, "too deep"],
    "unknown_utf16" => [Claricle::UnknownFormat, "no signature".encode(Encoding::UTF_16LE)],
    "standard_utf16" => [StandardError, "delegate failure".encode(Encoding::UTF_16LE)],
    "standard_utf7" => [StandardError, "converter missing".dup.force_encoding(Encoding.find("UTF-7"))],
    "standard_invalid_utf8" => [StandardError, "invalid \xFF".b.force_encoding(Encoding::UTF_8)],
    "standard_binary" => [StandardError, "binary \xFF".b],
    "interrupt" => [Interrupt]
  }.freeze

  probe = Class.new(Thor) do
    def self.exit_on_failure? = true

    desc "ok", "succeeds"
    def ok = :not_a_status

    desc "with_status CODE", "returns an explicit status"
    define_method(:with_status) { |code| status.new(code.to_i) }

    desc "integer", "returns a bare integer"
    def integer = 37

    desc "accept VALUE", "accepts a positional value"
    define_method(:accept) { |value| accepted_arguments << value }

    desc "boom CLASS", "raises the named error"
    define_method(:boom) { |name| raise(*errors.fetch(name)) }

    desc "broken_pipe", "fails while writing its own data"
    def broken_pipe
      reader, writer = IO.pipe
      reader.close
      writer.write("unread")
    ensure
      writer&.close
    end

    desc "quit CODE", "exits deliberately"
    def quit(code) = exit(code.to_i)
  end

  run = lambda do |argv|
    described_class.run(argv, output: StringIO.new)
  end

  describe "success" do
    before { stub_const("Claricle::Cli", probe) }

    it "returns 0 when nothing is raised" do
      expect(run.call(["ok"])).to eq(0)
    end

    it "returns an explicitly requested status" do
      expect(run.call(%w[with_status 1])).to eq(1)
    end

    # thor passes a command's return value straight through, so an
    # incidental File.write must not become the exit status.
    it "ignores a bare Integer return" do
      expect(run.call(["integer"])).to eq(0)
    end

    it "preserves valid ASCII-compatible positional text" do
      argument = "é".encode(Encoding.find("Big5-HKSCS"))
      accepted_arguments.clear

      expect(run.call(["accept", argument])).to eq(0)
      expect(accepted_arguments.first.encoding).to eq(argument.encoding)
      expect(accepted_arguments.first.bytes).to eq(argument.bytes)
    end
  end

  describe "Status" do
    it "accepts both ends of the byte range" do
      expect(status.new(0).code).to eq(0)
      expect(status.new(255).code).to eq(255)
    end

    it "refuses a code outside a byte" do
      expect { status.new(256) }.to raise_error(ArgumentError, /0\.\.255/)
      expect { status.new(-1) }.to raise_error(ArgumentError, /0\.\.255/)
    end

    it "refuses a non-Integer" do
      expect { status.new("1") }.to raise_error(ArgumentError, /Integer/)
    end

    it "is frozen" do
      expect(status.new(0)).to be_frozen
    end
  end

  # Everything above drives a probe, so none of it would notice the real
  # CLI losing its commands or its runner wiring.
  describe "the real CLI" do
    def with_closed_stdout
      reader, writer = IO.pipe
      reader.close
      previous_stdout = $stdout
      $stdout = writer
      yield
    ensure
      $stdout = previous_stdout
      writer&.close
    end

    it "returns 0 for version and prints it" do
      expect { expect(described_class.run(["version"])).to eq(0) }
        .to output("Claricle version #{Claricle::VERSION}\n").to_stdout
    end

    {
      ["--"] => /\ACommands:\n\s+\S+ help \[COMMAND\].*\n\s+\S+ version.*\n\n\z/,
      %w[-- version] => /\AUsage:\n\s+\S+ version\n\nDisplay Claricle version\n\z/,
      %w[-- --help] => /\AUsage:\n\s+\S+ help \[COMMAND\]\n\nDescribe available commands or one specific command\n\z/
    }.each do |arguments, expected_output|
      it "preserves #{arguments.inspect} as option-terminator input" do
        expect do
          expect(described_class.run(arguments, output: StringIO.new)).to eq(0)
        end.to output(expected_output).to_stdout

        expect { Claricle::Cli.start(arguments) }.to output(expected_output).to_stdout
      end
    end

    it "returns 2 for an unknown command" do
      expect(described_class.run(["nope"], output: StringIO.new)).to eq(2)
    end

    it "returns 2 for malformed argv text" do
      argument = "\xC3".b.force_encoding(Encoding::UTF_8)

      expect(described_class.run([argument], output: StringIO.new)).to eq(2)
    end

    it "returns 2 for non-ASCII-compatible argv text" do
      argument = "version".encode(Encoding::UTF_16LE)

      expect(described_class.run([argument], output: StringIO.new)).to eq(2)
    end

    it "returns 2 for a non-String argv element" do
      expect(described_class.run([nil], output: StringIO.new)).to eq(2)
    end

    it "returns 2 for a command name in another compatible encoding" do
      argument = "é".encode(Encoding.find("Big5-HKSCS"))

      expect(described_class.run([argument], output: StringIO.new)).to eq(2)
    end

    it "returns 2 when the command name cannot be transcoded" do
      stream = StringIO.new

      expect(described_class.run(["\xFF".b], output: stream)).to eq(2)
      expect(stream.string).to eq("claricle: command name cannot be converted to UTF-8\n")
    end

    it "returns 2 for an encoded abbreviated help target" do
      argument = "é".encode(Encoding.find("Big5-HKSCS"))

      expect(described_class.run(["h", argument], output: StringIO.new)).to eq(2)
    end

    it "returns 2 for an encoded help target after the option terminator" do
      argument = "é".encode(Encoding.find("Big5-HKSCS"))

      expect(described_class.run(["--", argument], output: StringIO.new)).to eq(2)
    end

    %w[help version].each do |command|
      it "returns 0 when #{command} output is closed" do
        result = with_closed_stdout do
          described_class.run([command], output: StringIO.new)
        end

        expect(result).to eq(0)
      end
    end

    it "does not hide a non-output error from help" do
      expect(described_class.run(%w[help nope], output: StringIO.new)).to eq(2)
    end

    it "does not consume the caller's argv array" do
      arguments = ["nope"]

      described_class.run(arguments, output: StringIO.new)

      expect(arguments).to eq(["nope"])
    end

    # Thor contributes help itself, so assert the deleted ones are gone
    # rather than that version stands alone.
    it "no longer exposes the deleted commands" do
      expect(Claricle::Cli.all_commands.keys).to include("version")
      expect(Claricle::Cli.all_commands.keys)
        .not_to include("validate", "convert", "compress")
    end
  end

  # The executable is the only place `exit` is called, and nothing above
  # would notice if it stopped passing the runner's result through.
  describe "exe/claricle" do
    root = File.expand_path("../..", __dir__)

    run_exe = lambda do |*args|
      system(RbConfig.ruby, "-I#{File.join(root, "lib")}", File.join(root, "exe", "claricle"),
             *args, out: File::NULL, err: File::NULL)
      $CHILD_STATUS.exitstatus
    end

    it "exits 0 for version" do
      expect(run_exe.call("version")).to eq(0)
    end

    it "exits with the runner's status for an unknown command" do
      expect(run_exe.call("nope")).to eq(2)
    end

    it "exits 2 for malformed argv text" do
      argument = "\xC3".b.force_encoding(Encoding::UTF_8)

      expect(run_exe.call(argument)).to eq(2)
    end
  end

  describe "the exit map" do
    before { stub_const("Claricle::Cli", probe) }

    # TODO.plan/01-core.md requires every named error to inherit
    # Claricle::Error. A direct StandardError subclass would keep every
    # exit-code mapping below green while silently dropping that.
    it "maps InvocationError and ConversionError through Claricle::Error" do
      expect(Claricle::InvocationError).to be < Claricle::Error
      expect(Claricle::ConversionError).to be < Claricle::Error
    end

    {
      2 => %w[enoent invocation],
      3 => %w[unknown unsupported],
      4 => %w[conversion standard argument load syntax stack]
    }.each do |code, names|
      names.each do |name|
        it "maps #{name} to #{code}" do
          expect(run.call(["boom", name])).to eq(code)
        end
      end
    end

    it "maps an unknown command to 2, through Thor" do
      expect(run.call(["nope"])).to eq(2)
    end

    # Measured as Thor::InvocationError -- the collision with
    # Claricle::InvocationError, exercised for real.
    it "maps a wrong-arity invocation to 2" do
      expect(run.call(%w[ok extra])).to eq(2)
    end

    it "rejects malformed positional text before invoking the command" do
      argument = "\xC3".b.force_encoding(Encoding::UTF_8)
      accepted_arguments.clear

      expect(run.call(["accept", argument])).to eq(2)
      expect(accepted_arguments).to be_empty
    end

    it "maps an operation's broken pipe to 4" do
      expect(run.call(["broken_pipe"])).to eq(4)
    end
  end

  describe "exits that are not errors" do
    before { stub_const("Claricle::Cli", probe) }

    it "returns the status a command exited with" do
      expect(run.call(%w[quit 7])).to eq(7)
    end

    # `exit 256` reports SUCCESS at the shell, so an out-of-range status
    # cannot be passed straight through.
    it "refuses a status that is not a byte" do
      expect(run.call(%w[quit 256])).to eq(4)
      expect(run.call(%w[quit -1])).to eq(4)
    end

    it "lets Interrupt propagate rather than mapping it" do
      expect { run.call(%w[boom interrupt]) }.to raise_error(Interrupt)
    end

    it "never raises SystemExit itself" do
      %w[enoent unknown standard load stack].each do |name|
        expect { run.call(["boom", name]) }.not_to raise_error
      end
    end
  end

  describe "output" do
    before { stub_const("Claricle::Cli", probe) }

    it "writes the message to the given stream, not stdout" do
      stream = StringIO.new
      expect { described_class.run(%w[boom standard], output: stream) }
        .not_to output.to_stdout
      expect(stream.string).to include("plain")
    end

    # "claricle: missing gem" is not much help when the class was
    # LoadError, so an unexpected failure names its class.
    it "names the class of an unexpected failure" do
      stream = StringIO.new
      described_class.run(%w[boom load], output: stream)
      expect(stream.string).to eq("claricle: LoadError: missing gem\n")
    end

    # A mapped Claricle error already reads as a sentence.
    # `output.puts` runs inside a rescue body, so nothing above catches
    # it. With stderr on a closed pipe the EPIPE escaped `run` and the
    # executable exited 1 -- the code the README reserves for a
    # nonconformant file. Both an original 2 and an original 4 are driven,
    # so a fix that flattens every status to one code cannot pass.
    describe "when the diagnostic cannot be written" do
      def closed_pipe
        reader, writer = IO.pipe
        reader.close
        writer
      end

      it "still returns the invocation status" do
        expect(described_class.run(["nope"], output: closed_pipe)).to eq(2)
      end

      it "still returns the unexpected-failure status" do
        expect(described_class.run(%w[boom standard], output: closed_pipe)).to eq(4)
      end

      it "does not let the write error escape" do
        expect { described_class.run(["nope"], output: closed_pipe) }.not_to raise_error
      end
    end

    it "does not name the class of a mapped error" do
      stream = StringIO.new
      described_class.run(%w[boom unknown], output: stream)
      expect(stream.string).to eq("claricle: no signature\n")
    end

    {
      "unknown_utf16" => [3, "claricle: no signature\n"],
      "standard_utf16" => [4, "claricle: StandardError: delegate failure\n"],
      "standard_utf7" => [4, "claricle: StandardError: converter missing\n"],
      "standard_invalid_utf8" => [4, "claricle: StandardError: invalid \uFFFD\n"],
      "standard_binary" => [4, "claricle: StandardError: binary \uFFFD\n"]
    }.each do |name, (code, message)|
      it "normalizes #{name} output without changing its status" do
        stream = StringIO.new

        expect(described_class.run(["boom", name], output: stream)).to eq(code)
        expect(stream.string).to eq(message)
        expect(stream.string).to be_valid_encoding
      end
    end
  end
end
