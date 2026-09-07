# frozen_string_literal: true

require "English"
require "fileutils"
require "stringio"
require "tmpdir"

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
      # The command inventory is pinned by its own example. This one is
      # about `--` reaching general help at all, so it asserts the SHAPE
      # -- a well-formed Commands block -- and lets the inventory grow as
      # handlers land. Pinning both here made adding a command look like
      # a terminator regression.
      ["--"] => /\ACommands:\n(?:\s+\S+ .+\n)+\n\z/,
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

    {
      "help" => ["help"],
      "version" => ["version"],
      "formats" => ["formats"],
      "inspect" => [
        "inspect", File.join(__dir__, "..", "fixtures", "inspect", "valid.png")
      ]
    }.each do |command, arguments|
      it "returns 0 when #{command} output is closed" do
        result = with_closed_stdout do
          described_class.run(arguments, output: StringIO.new)
        end

        expect(result).to eq(0)
      end
    end

    it "maps an inspect operation's broken pipe to 4" do
      allow(Claricle::Image).to receive(:from_path).and_raise(Errno::EPIPE)

      expect(described_class.run(%w[inspect image.png], output: StringIO.new)).to eq(4)
    end

    it "maps inspection generation's broken pipe to 4" do
      image = instance_double(Claricle::Image)
      allow(Claricle::Image).to receive(:from_path).and_return(image)
      allow(image).to receive(:inspection).and_raise(Errno::EPIPE)

      expect(described_class.run(%w[inspect image.png], output: StringIO.new)).to eq(4)
    end

    it "maps inspection rendering's broken pipe to 4" do
      inspection = instance_double(Claricle::Models::Inspection)
      image = instance_double(Claricle::Image, inspection: inspection)
      presenter = Claricle.const_get(:Cli).const_get(:Presenter)
      allow(Claricle::Image).to receive(:from_path).and_return(image)
      allow(presenter).to receive(:inspection).with(inspection).and_raise(Errno::EPIPE)

      expect(described_class.run(%w[inspect image.png], output: StringIO.new)).to eq(4)
    end

    it "maps inspection JSON generation's broken pipe to 4" do
      inspection = instance_double(Claricle::Models::Inspection)
      image = instance_double(Claricle::Image, inspection: inspection)
      allow(Claricle::Image).to receive(:from_path).and_return(image)
      allow(inspection).to receive(:to_json).and_raise(Errno::EPIPE)

      arguments = %w[inspect image.png --json]
      expect(described_class.run(arguments, output: StringIO.new)).to eq(4)
    end

    it "maps a formats operation's broken pipe to 4" do
      allow(Claricle.const_get(:Registry)).to receive(:formats).and_raise(Errno::EPIPE)

      expect(described_class.run(["formats"], output: StringIO.new)).to eq(4)
    end

    it "maps capability lookup's broken pipe to 4" do
      registry = Claricle.const_get(:Registry)
      allow(registry).to receive(:formats).and_return([:png])
      allow(registry).to receive(:capabilities_for).and_raise(Errno::EPIPE)

      expect(described_class.run(["formats"], output: StringIO.new)).to eq(4)
    end

    it "maps formats rendering's broken pipe to 4" do
      registry = Claricle.const_get(:Registry)
      presenter = Claricle.const_get(:Cli).const_get(:Presenter)
      allow(registry).to receive(:formats).and_return([])
      allow(presenter).to receive(:format_table).with([]).and_raise(Errno::EPIPE)

      expect(described_class.run(["formats"], output: StringIO.new)).to eq(4)
    end

    it "maps formats JSON generation's broken pipe to 4" do
      registry = Claricle.const_get(:Registry)
      allow(registry).to receive(:formats).and_return([])
      allow(JSON).to receive(:generate).with([]).and_raise(Errno::EPIPE)

      expect(described_class.run(%w[formats --json], output: StringIO.new)).to eq(4)
    end

    it "does not hide a non-output error from help" do
      expect(described_class.run(%w[help nope], output: StringIO.new)).to eq(2)
    end

    it "does not consume the caller's argv array" do
      arguments = ["nope"]

      described_class.run(arguments, output: StringIO.new)

      expect(arguments).to eq(["nope"])
    end

    # Pin Thor-contributed commands alongside Claricle's own, so a new
    # inherited command cannot slip into the public inventory.
    it "exposes exactly the intended commands" do
      expect(Claricle::Cli.all_commands.keys)
        .to contain_exactly("conform", "formats", "help", "inspect", "version")
    end
  end

  # Thor registers a command under its METHOD name, and `map` only adds
  # an alias -- so `inspect_file` stayed callable, and Thor translates
  # dashes to underscores, so `inspect-file` did too. Three spellings for
  # one documented command.
  describe "the inspect command's spelling" do
    it "answers to the documented name" do
      expect { described_class.run(["inspect", File.join(__dir__, "..", "fixtures", "inspect", "valid.png")]) }
        .to output(/format: png/).to_stdout
    end

    %w[inspect_file inspect-file].each do |spelling|
      it "does not answer to #{spelling}" do
        expect { expect(described_class.run([spelling, "x.png"])).to eq(2) }
          .to output(/Could not find command/).to_stderr
      end
    end

    # described_class here is the Runner, not the Thor class.
    it "lists only the documented command" do
      names = Claricle.const_get(:Cli).all_commands.keys

      expect(names).to include("inspect")
      expect(names).not_to include("inspect_file")
    end

    # The reason the method is not simply `def inspect(file)`. Every
    # example above would pass a CLI that shadowed Object#inspect; only
    # this one would go red, and it goes red loudly -- `p cli` raises
    # ArgumentError.
    it "leaves Object#inspect alone" do
      expect(Claricle.const_get(:Cli).new.inspect).to start_with("#<Claricle::Cli")
    end

    # Thor names a command by its METHOD name in an arity error, so this
    # answered `"claricle inspect_file" was called with no arguments` --
    # the one spelling the examples above prove the CLI rejects. Thor
    # builds the prefix from $0, which is `rspec` here, so the assertion
    # is on the command name rather than the whole line.
    it "names the documented command when no file is given" do
      stream = StringIO.new
      expect(described_class.run(["inspect"], output: stream)).to eq(2)

      expect(stream.string).to match(/ inspect" was called with no arguments/)
      expect(stream.string).not_to include("inspect_file")
    end

    # The rename is keyed off Claricle's own command registry, so Thor's
    # built-ins have to fall through it untouched. `help` is the one that
    # would notice, since it is the only built-in taking an argument.
    it "leaves a Thor built-in's arity error alone" do
      stream = StringIO.new
      described_class.run(%w[help a b c], output: stream)

      expect(stream.string).to match(/ help" was called with arguments/)
    end

    # The copy is what gets renamed. Renaming the registered command
    # instead would break dispatch on the very next call.
    it "does not rename the registered command" do
      described_class.run(["inspect"], output: StringIO.new)

      expect(Claricle.const_get(:Cli).all_commands["inspect"].name).to eq("inspect_file")
    end
  end

  describe "inspect" do
    let(:png) { File.join(__dir__, "..", "fixtures", "inspect", "valid.png") }

    it "prints the metadata and returns 0" do
      expect { expect(described_class.run(["inspect", png])).to eq(0) }
        .to output(/format: png.*dimensions: 4\.0x3\.0.*parse status: ok/m).to_stdout
    end

    # End to end through detection, since an EPS is detected rather than
    # declared here -- the handler specs all pass the format explicitly.
    it "inspects an EPS through the real detector" do
      eps = File.join(__dir__, "..", "fixtures", "inspect", "basic.eps")

      expect { expect(described_class.run(["inspect", eps])).to eq(0) }
        .to output(/format: eps.*dimensions: 100\.0x50\.0.*parse status: ok/m)
        .to_stdout
    end

    # The fields a PNG inspection can fill, or dropping one from the
    # renderer leaves the assertions above green. The single-axis rows
    # are the presenter's other branch and no PNG reaches them, so both
    # of them -- width-only AND height-only -- are covered against the
    # presenter directly, further down.
    it "prints dpi, colour space and the meta fields" do
      phys = File.join(__dir__, "..", "fixtures", "inspect", "phys.png")

      expect { described_class.run(["inspect", phys]) }
        .to output(/dpi: 72\.009/).to_stdout
      expect { described_class.run(["inspect", phys]) }
        .to output(/color space: truecolor\+alpha/).to_stdout
      expect { described_class.run(["inspect", phys]) }
        .to output(/meta\.bit_depth: 8.*meta\.compression: 0.*meta\.filter: 0.*meta\.interlace: 0/m)
        .to_stdout
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

    # The plan requires an SVG example end to end, not just PNG. One
    # example, not two: an exit code on its own says nothing about what
    # was printed, and a separate status-only example passed with the
    # unit conversion forced to nil.
    it "prints SVG dimensions and the declared units, and exits 0" do
      Tempfile.create(["logo", ".svg"]) do |file|
        file.write(%(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="5mm"/>))
        file.flush

        # Both axes, and enough digits that a wrong conversion cannot
        # hide behind a truncated match.
        expect { expect(described_class.run(["inspect", file.path])).to eq(0) }
          .to output(/format: svg/).to_stdout
        expect { described_class.run(["inspect", file.path]) }
          .to output(/dimensions: 37\.79527559055118\d*x18\.89763779527559\d*/).to_stdout
        expect { described_class.run(["inspect", file.path]) }
          .to output(/^meta\.height: 5mm$/).to_stdout
        expect { described_class.run(["inspect", file.path]) }
          .to output(/^meta\.width: 10mm$/).to_stdout
      end
    end

    # SVG is the first format whose metadata is free text out of the
    # file, and `&#xA;` is a character reference, so XML keeps it as a
    # real newline. Printed raw it made a line of Claricle's own shape.
    #
    # Six characters, because C0 is not the whole set and each forges
    # differently: LF adds a line, CR overwrites the one already there,
    # NEL is C1's own next-line, CSI introduces control sequences, and
    # U+2028/U+2029 are Unicode's line and paragraph separators. All six
    # measured arriving intact before this.
    { "a newline" => ["&#xA;", '\x0A'],
      "a carriage return" => ["&#xD;", '\x0D'],
      "a next-line control" => ["&#x85;", '\x85'],
      "a control sequence introducer" => ["&#x9B;", '\x9B'],
      "a line separator" => ["&#x2028;", '\u{2028}'],
      "a paragraph separator" => ["&#x2029;", '\u{2029}'] }
      .each do |label, (reference, escaped)|
      it "refuses to print #{label} out of a file's metadata" do
        Tempfile.create(["forge", ".svg"]) do |file|
          file.write(%(<svg xmlns="http://www.w3.org/2000/svg" id="a#{reference}error: forged"/>))
          file.flush

          expect { described_class.run(["inspect", file.path]) }
            .to output(/^meta\.id: a#{Regexp.escape(escaped)}error: forged$/).to_stdout
        end
      end
    end

    # Escaping the characters is not enough on its own: a root attribute
    # can simply be NAMED like one of Claricle's own rows. Unprefixed,
    # `error="forged"` printed a line shaped exactly like an issue and
    # `format="png"` printed a second format line contradicting the
    # first.
    it "keeps a file's metadata keys out of its own row labels" do
      Tempfile.create(["forge", ".svg"]) do |file|
        file.write(%(<svg xmlns="http://www.w3.org/2000/svg" error="forged" format="png"/>))
        file.flush

        expect { described_class.run(["inspect", file.path]) }
          .to output(/^meta\.error: forged$/).to_stdout
        expect { described_class.run(["inspect", file.path]) }
          .not_to output(/^error: forged$/).to_stdout
        expect { described_class.run(["inspect", file.path]) }
          .not_to output(/^format: png$/).to_stdout
      end
    end

    # The escaping is presentation, not a change to what was read: the
    # JSON carries the real character, escaped by JSON itself.
    it "keeps the real character under --json" do
      Tempfile.create(["forge", ".svg"]) do |file|
        file.write(%(<svg xmlns="http://www.w3.org/2000/svg" id="a&#xA;b"/>))
        file.flush

        expect { described_class.run(["inspect", file.path, "--json"]) }
          .to output(/"id":"a\\nb"/).to_stdout
      end
    end

    it "exits 2 for a missing file" do
      expect(described_class.run(["inspect", "no/such.png"], output: StringIO.new)).to eq(2)
    end

    # A typo is an ordinary user error, so it reads as a sentence rather
    # than naming Errno::ENOENT at someone who mistyped a filename. Both
    # halves are asserted: `start_with` alone would still pass if the
    # class name were appended rather than prefixed.
    it "does not name the error class for a missing file" do
      stream = StringIO.new
      described_class.run(["inspect", "no/such.png"], output: stream)

      expect(stream.string).to start_with("claricle: No such file or directory")
      expect(stream.string).not_to include("Errno")
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

  # PNG fills both dimensions or neither, so the presenter's one-axis
  # branch is unreachable through any command today. It is written for
  # SVG, which can declare a width and no height, and it is asserted
  # here rather than left to item 03 -- otherwise "7.0x" would be the
  # first anyone hears of it.
  describe "the presenter's dimension rows" do
    let(:presenter) { Claricle.const_get(:Cli).const_get(:Presenter) }

    it "puts both on one line when both are known" do
      inspection = Claricle::Models::Inspection.new(
        format: "svg", width: 7.0, height: 3.0, parse_status: "ok"
      )

      expect(presenter.inspection(inspection)).to include("dimensions: 7.0x3.0")
    end

    it "names the axis it has when only width is known" do
      inspection = Claricle::Models::Inspection.new(
        format: "svg", width: 7.0, parse_status: "ok"
      )
      rendered = presenter.inspection(inspection)

      expect(rendered).to include("width: 7.0")
      expect(rendered).not_to include("height")
      expect(rendered).not_to include("7.0x")
    end

    # The mirror case. Without it, a renderer that drops a known height
    # whenever width is nil stays green, and the comment further up
    # claimed this row was covered when it was not.
    it "names the axis it has when only height is known" do
      inspection = Claricle::Models::Inspection.new(
        format: "svg", height: 3.0, parse_status: "ok"
      )
      rendered = presenter.inspection(inspection)

      expect(rendered).to include("height: 3.0")
      expect(rendered).not_to include("width")
      expect(rendered).not_to include("x3.0")
    end
  end

  describe "formats" do
    it "prints what png can actually do" do
      expect { expect(described_class.run(["formats"])).to eq(0) }
        .to output(/png\tinspect/).to_stdout
    end

    # The command must not advertise an operation that is still a stub.
    # Asserting the whole line, because "prints no conform" would also
    # pass if the command printed nothing at all. png is the first (and
    # so far only) format that claims conform; nothing claims convert yet.
    it "claims conform only for png, and convert for nothing yet" do
      expect { described_class.run(["formats"]) }
        .to output("emf\tinspect\neps\tinspect\npng\tinspect, conform\n" \
                   "ps\tinspect\nsvg\tinspect\n").to_stdout
    end

    it "emits a fixed row shape under --json" do
      conform = { "emf" => false, "eps" => false, "png" => true, "ps" => false, "svg" => false }
      rows = %w[emf eps png ps svg].map do |format|
        %({"format":"#{format}","inspect":true,"conform":#{conform.fetch(format)},"convert":false,"convert_to":[]})
      end
      expected = "[#{rows.join(",")}]\n"

      expect { described_class.run(["formats", "--json"]) }.to output(expected).to_stdout
    end
  end

  # png implements conformance_report now; eps and ps never will (D22), so
  # they carry the exit-3 UnsupportedFormat story on. Exit 0 and 1 arrive
  # end to end through png, the first handler.
  describe "conform" do
    fixtures = File.join(__dir__, "..", "fixtures", "inspect")

    workspace = lambda do |*names, &block|
      Dir.mktmpdir do |dir|
        names.each { |name, source| FileUtils.cp(File.join(fixtures, source), File.join(dir, name)) }
        Dir.chdir(dir, &block)
      end
    end

    def capture_stdout
      previous = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = previous
    end

    def closed_stdout
      reader, writer = IO.pipe
      reader.close
      previous = $stdout
      $stdout = writer
      yield
    ensure
      $stdout = previous
      writer&.close
    end

    # The failure is collected into an envelope rather than raised, so it
    # reaches the user through the command's own stderr line, not the
    # runner's exception reporting. Both halves: the code AND what it said.
    it "exits 3 for a format nothing conforms, and says which" do
      workspace.call(["a.eps", "basic.eps"]) do
        expect(described_class.run(%w[conform a.eps], output: StringIO.new)).to eq(3)
        expect { described_class.run(%w[conform a.eps], output: StringIO.new) }
          .to output(/:eps is not supported for conform/).to_stderr
      end
    end

    # The first real conformance verdicts to reach the CLI end to end:
    # png implements conformance_report now, so 0 and 1 are reachable
    # without a stub.
    it "exits 0 for a conformant PNG, and prints its verdict" do
      workspace.call(["a.png", "valid.png"]) do
        expect(described_class.run(%w[conform a.png], output: StringIO.new)).to eq(0)
        expect { described_class.run(%w[conform a.png], output: StringIO.new) }
          .to output("a.png: yes\n").to_stdout
      end
    end

    # The specific mapped issue (severity, code, message, location) is
    # pinned in png_spec.rb; this end-to-end check is only that a
    # png.-coded error line reaches stdout for a real nonconformant file.
    it "exits 1 for a nonconformant PNG, with an error line on stdout" do
      workspace.call(["a.png", "short_ihdr.png"]) do
        expect(described_class.run(%w[conform a.png], output: StringIO.new)).to eq(1)
        expect { described_class.run(%w[conform a.png], output: StringIO.new) }
          .to output(/\Aa\.png: no\n {2}error \[png\./).to_stdout
      end
    end

    it "exits 2 for a pattern that matched nothing" do
      workspace.call do
        expect(described_class.run(["conform", "--pattern", "none-*.png"], output: StringIO.new))
          .to eq(2)
      end
    end

    # Thor accepts the command with no arguments at all, so the command has
    # to refuse it rather than treating an empty batch as success -- and say
    # what was wrong, rather than reporting an empty list of things that
    # matched nothing.
    it "exits 2 when given neither a file nor a pattern" do
      workspace.call do
        expect(described_class.run(["conform"], output: StringIO.new)).to eq(2)
        expect { described_class.run(["conform"], output: $stderr) }
          .to output("claricle: no files given\n").to_stderr
      end
    end

    # No handler answers a verdict yet, so `--strict` has nowhere to change
    # anything -- every real call raises UnsupportedFormat before a verdict
    # exists to be strict about. This proves the wiring instead: the flag
    # the user typed is the flag the module API receives, not a default that
    # silently won.
    it "forwards strict: only when --strict was given" do
      result = instance_double(Claricle::BatchResult, exit_code: 0, items: [])

      expect(Claricle).to receive(:conformance_batch)
        .with("a.png", pattern: nil, strict: true, profile: nil).and_return(result)
      described_class.run(%w[conform a.png --strict], output: StringIO.new)

      expect(Claricle).to receive(:conformance_batch)
        .with("a.png", pattern: nil, strict: false, profile: nil).and_return(result)
      described_class.run(%w[conform a.png], output: StringIO.new)
    end

    # Real behavior, not a forwarding mock: no handler defines a profile
    # yet, so any --profile is a bad invocation checked before the batch
    # runs -- proven the same way the module API's own spec proves it,
    # through the command's real exit code and message.
    it "exits 2 for --profile, since no format defines one yet" do
      workspace.call(["a.png", "valid.png"]) do
        expect(described_class.run(%w[conform a.png --profile base], output: StringIO.new))
          .to eq(2)
        expect { described_class.run(%w[conform a.png --profile base], output: $stderr) }
          .to output(/no format defines a profile yet: "base"/).to_stderr
      end
    end

    # A closed consumer must not turn a failure into a success. Every other
    # command can only succeed, so the shared closed-output table asserts 0
    # for them; here 0 would be the bug.
    #
    # `--json`, deliberately. Without it a batch whose every file failed
    # writes nothing at all to stdout -- the verdict lines are empty and the
    # failures go to stderr -- so nothing raises EPIPE and the example would
    # pass whether the status were settled before the write or after it.
    # Measured: the plain form leaves a mutant that returns
    # `tolerate_closed_output`'s own 0 alive. `--json` always writes, so it
    # reaches the arm where the ordering can actually break.
    it "keeps its status when the output is closed" do
      workspace.call(["a.eps", "basic.eps"]) do
        json = closed_stdout do
          described_class.run(%w[conform a.eps --json], output: StringIO.new)
        end
        plain = closed_stdout { described_class.run(%w[conform a.eps], output: StringIO.new) }

        expect([json, plain]).to eq([3, 3])
      end
    end

    describe "--json" do
      # Shape cannot follow invocation syntax: a filename may legally
      # contain glob characters and a shell expands an unquoted glob before
      # Claricle sees it, so "which form did the user type" is not knowable.
      # One file gets the same array a batch gets.
      it "emits an array for a single file, not a bare object" do
        workspace.call(["a.eps", "basic.eps"]) do
          json = nil
          expect { json = described_class.run(%w[conform a.eps --json], output: StringIO.new) }
            .to output(/\A\[\{/).to_stdout
          expect(json).to eq(3)
        end
      end

      it "carries the whole envelope for a single failure" do
        workspace.call(["a.eps", "basic.eps"]) do
          rendered = capture_stdout { described_class.run(%w[conform a.eps --json]) }
          rows = JSON.parse(rendered)

          expect(rows.length).to eq(1)
          expect(rows.first["path"]).to eq("a.eps")
          expect(rows.first["status"]).to eq("error")
          expect(rows.first["exit_code"]).to eq(3)
          expect(rows.first["error"]["code"]).to eq("Claricle::UnsupportedFormat")
        end
      end

      # A conformant file's real envelope, contrasted with the failure
      # shape above: `result` carries the Report, `error` stays nil.
      it "carries the whole envelope for a conformant file" do
        workspace.call(["a.png", "valid.png"]) do
          rendered = capture_stdout { described_class.run(%w[conform a.png --json]) }
          rows = JSON.parse(rendered)

          expect(rows.length).to eq(1)
          expect(rows.first["status"]).to eq("ok")
          expect(rows.first["exit_code"]).to eq(0)
          expect(rows.first["error"]).to be_nil
          expect(rows.first["result"]["valid"]).to eq("yes")
        end
      end

      it "emits one element per file, in path order" do
        workspace.call(["a.png", "valid.png"], ["b.eps", "basic.eps"]) do
          rendered = capture_stdout { described_class.run(%w[conform --pattern * --json]) }

          expect(JSON.parse(rendered).map { |row| row["path"] }).to eq(%w[a.png b.eps])
        end
      end
    end

    # One stderr line per failed file, and nothing on stdout for it: stdout
    # carries verdicts, and a file with no verdict has nothing to say there.
    it "reports a failed file on stderr and not on stdout" do
      workspace.call(["a.eps", "basic.eps"], ["b.eps", "basic.eps"]) do
        expect { described_class.run(%w[conform --pattern *.eps], output: StringIO.new) }
          .to output("").to_stdout
        expect { described_class.run(%w[conform --pattern *.eps], output: StringIO.new) }
          .to output(/claricle: a\.eps: .*\nclaricle: b\.eps: /).to_stderr
      end
    end

    it "stays silent on stderr under --json" do
      workspace.call(["a.png", "valid.png"]) do
        expect { described_class.run(%w[conform a.png --json], output: StringIO.new) }
          .not_to output.to_stderr
      end
    end
  end

  # Driven against envelopes built here rather than a real handler's
  # output -- the same way the dimension rows above are -- so the
  # presenter's own rendering rules stay pinned independently of what any
  # one handler happens to report.
  describe "the presenter's conformance rows" do
    let(:presenter) { Claricle.const_get(:Cli).const_get(:Presenter) }

    def item(path, valid_issues, exit_code: 0)
      Claricle::Models::BatchItem.new(
        path: path, exit_code: exit_code,
        result: Claricle::Models::Report.new(source_path: path, issues: valid_issues)
      )
    end

    it "prints the path and the verdict, and nothing else, for a clean file" do
      expect(presenter.conformance([item("a.png", [])])).to eq("a.png: yes")
    end

    it "prints the tri-state verdict it was given" do
      warned = item("a.png", [Claricle::Models::Issue.new(severity: "warning", message: "m")],
                    exit_code: 0)

      expect(presenter.conformance([warned])).to start_with("a.png: suspicious")
    end

    it "prints severity, code and message on an issue's line" do
      issue = Claricle::Models::Issue.new(severity: "error", code: "png.crc",
                                          message: "CRC error in IDAT chunk")

      expect(presenter.conformance([item("a.png", [issue], exit_code: 1)]))
        .to eq("a.png: no\n  error [png.crc] CRC error in IDAT chunk")
    end

    # Only the fields that are populated: printing all six would spell out
    # four nils, and printing none would lose the two that were measured.
    it "prints only the location fields that are populated" do
      located = Claricle::Models::Issue.new(
        severity: "error", code: "png.crc", message: "bad",
        location: Claricle::Models::Location.new(chunk: "IDAT", byte_offset: 33)
      )
      rendered = presenter.conformance([item("a.png", [located], exit_code: 1)])

      expect(rendered).to include("(chunk: IDAT, byte_offset: 33)")
      expect(rendered).not_to include("line")
      expect(rendered).not_to include("node_path")
    end

    it "prints no parentheses for an issue with no location at all" do
      bare = Claricle::Models::Issue.new(severity: "info", code: "c", message: "m")

      expect(presenter.conformance([item("a.png", [bare])])).to eq("a.png: yes\n  info [c] m")
    end

    # Issue#code is optional. Printing `[]` for an absent one would read
    # as a code nobody chose rather than one the delegate never reported
    # -- the same rule `location` already follows for its own six fields.
    it "prints no brackets for an issue with no code at all" do
      codeless = Claricle::Models::Issue.new(severity: "info", message: "m")

      expect(presenter.conformance([item("a.png", [codeless])])).to eq("a.png: yes\n  info m")
    end

    # An issue's message reaches here from a file by way of a delegate, and
    # a control character in it can forge a line of Claricle's own shape --
    # the same hazard the metadata rows above escape.
    it "escapes a control character out of an issue's message" do
      forged = Claricle::Models::Issue.new(severity: "error", code: "c",
                                           message: "a\nerror: forged")

      expect(presenter.conformance([item("a.png", [forged], exit_code: 1)]))
        .to eq("a.png: no\n  error [c] a\\x0Aerror: forged")
    end

    it "renders one stderr line per failed file and none for a clean one" do
      failed = Claricle::Models::BatchItem.new(
        path: "b.eps", exit_code: 3,
        error: Claricle::Models::BatchError.new(code: "Claricle::UnsupportedFormat",
                                                message: "format :eps is not supported")
      )

      expect(presenter.conformance_failures([item("a.png", []), failed]))
        .to eq(["claricle: b.eps: format :eps is not supported"])
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
