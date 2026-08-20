# frozen_string_literal: true

require "English"
require "stringio"

RSpec.describe Claricle::Cli::Runner do
  status = described_class::Status

  # A real Thor subclass, not a double: the runner's whole job is what
  # happens to an exception on its way out of Thor. Status is captured in
  # a closure because stubbing Claricle::Cli replaces the namespace the
  # probe would otherwise look it up through.
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
    "epipe" => [Errno::EPIPE],
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

    desc "boom CLASS", "raises the named error"
    define_method(:boom) { |name| raise(*errors.fetch(name)) }

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
    it "returns 0 for version and prints it" do
      expect { expect(described_class.run(["version"])).to eq(0) }
        .to output(/Claricle version/).to_stdout
    end

    it "returns 2 for an unknown command" do
      expect(described_class.run(["nope"], output: StringIO.new)).to eq(2)
    end

    # Thor contributes help itself, so assert the deleted ones are gone
    # rather than that version stands alone.
    it "no longer exposes the deleted commands" do
      expect(Claricle::Cli.all_commands.keys).to include("version")
      expect(Claricle::Cli.all_commands.keys)
        .not_to include("validate", "convert", "compress")
    end
  end

  describe "inspect" do
    let(:png) { File.join(__dir__, "..", "fixtures", "inspect", "valid.png") }

    it "prints the metadata and returns 0" do
      expect { expect(described_class.run(["inspect", png])).to eq(0) }
        .to output(/format: png.*dimensions: 4\.0x3\.0.*parse status: ok/m).to_stdout
    end

    # Every field the presenter can emit, or dropping one from the
    # renderer leaves the assertions above green.
    it "prints dpi, colour space and the meta fields" do
      phys = File.join(__dir__, "..", "fixtures", "inspect", "phys.png")

      expect { described_class.run(["inspect", phys]) }
        .to output(/dpi: 72\.009/).to_stdout
      expect { described_class.run(["inspect", phys]) }
        .to output(/color space: truecolor\+alpha/).to_stdout
      expect { described_class.run(["inspect", phys]) }
        .to output(/bit_depth: 8.*compression: 0.*filter: 0.*interlace: 0/m).to_stdout
    end

    it "prints an issue's severity and message when one is reported" do
      failed = File.join(__dir__, "..", "fixtures", "inspect", "signature_only.png")

      expect { described_class.run(["inspect", failed]) }
        .to output(/error: PNG header \(IHDR\) could not be read/).to_stdout
    end

    # Empty collections have to survive serialization, or a consumer
    # cannot tell "no issues" from "field absent".
    it "keeps an empty issues array under --json" do
      expect { described_class.run(["inspect", png, "--json"]) }
        .to output(/"issues":\[\]/).to_stdout
    end

    it "reports a file that does not parse, and still exits 0" do
      failed = File.join(__dir__, "..", "fixtures", "inspect", "signature_only.png")

      expect { expect(described_class.run(["inspect", failed])).to eq(0) }
        .to output(/parse status: failed/).to_stdout
    end

    # The plan requires an SVG example end to end, not just PNG.
    it "prints SVG dimensions with units resolved" do
      Tempfile.create(["logo", ".svg"]) do |file|
        file.write(%(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="5mm"/>))
        file.flush

        expect(described_class.run(["inspect", file.path])).to eq(0)
      end
    end

    it "prints both SVG dimensions and the declared units" do
      Tempfile.create(["logo", ".svg"]) do |file|
        file.write(%(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="5mm"/>))
        file.flush

        # Both axes, and enough digits that a wrong conversion cannot
        # hide behind a truncated match.
        expect { described_class.run(["inspect", file.path]) }
          .to output(
            /dimensions: 37\.79527559055118\d*x18\.89763779527559\d*.*height: 5mm.*width: 10mm/m
          ).to_stdout
      end
    end

    it "exits 2 for a missing file" do
      expect(described_class.run(["inspect", "no/such.png"], output: StringIO.new)).to eq(2)
    end

    # A typo is an ordinary user error, so it reads as a sentence rather
    # than naming Errno::ENOENT at someone who mistyped a filename.
    it "does not name the error class for a missing file" do
      stream = StringIO.new
      described_class.run(["inspect", "no/such.png"], output: stream)

      expect(stream.string).to start_with("claricle: No such file or directory")
    end

    it "exits 3 for bytes it cannot identify" do
      Tempfile.create(["junk", ".bin"]) do |file|
        file.write("not an image at all")
        file.flush

        expect(described_class.run(["inspect", file.path], output: StringIO.new)).to eq(3)
      end
    end

    # Detected but unhandled is a different answer from unrecognised, and
    # both are exit 3 -- so assert the message, not just the code.
    it "exits 3 for a detected format with no handler" do
      stream = StringIO.new
      wmf = File.join(__dir__, "..", "fixtures", "detector", "std.wmf")

      expect(described_class.run(["inspect", wmf], output: stream)).to eq(3)
      expect(stream.string).to match(/not supported/)
    end
  end

  describe "formats" do
    it "prints what png can actually do" do
      expect { expect(described_class.run(["formats"])).to eq(0) }
        .to output(/png\tinspect/).to_stdout
    end

    # The command must not advertise an operation that is still a stub.
    # Asserting the whole line, because "prints no conform" would also
    # pass if the command printed nothing at all.
    it "does not claim conform or convert yet" do
      expect { described_class.run(["formats"]) }
        .to output("png\tinspect\nsvg\tinspect\n").to_stdout
    end

    it "emits a fixed row shape under --json" do
      expect { described_class.run(["formats", "--json"]) }
        .to output(
          %([{"format":"png","inspect":true,"conform":false,"convert":false,"convert_to":[]},) +
          %({"format":"svg","inspect":true,"conform":false,"convert":false,"convert_to":[]}]\n)
        )
        .to_stdout
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
  end

  describe "the exit map" do
    before { stub_const("Claricle::Cli", probe) }

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

    # thor converts EPIPE to SystemExit(0) before the map sees it, and
    # that is right: a closed pipe is not a failure. Pinned so it is not
    # later "corrected" to 4.
    it "returns 0 for a closed pipe" do
      expect(run.call(%w[boom epipe])).to eq(0)
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
  end
end
