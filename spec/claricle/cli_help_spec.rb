# frozen_string_literal: true

# What `Cli#help` promises a caller's SHELL, kept apart from cli_spec.rb
# because it is a different subject -- it shares no fixture or helper with the
# exit-code, inspect, formats or presenter groups there -- and because
# cli_spec.rb had grown past 1000 lines.
#
# Every example here is a caller shape that a BUFFERED help was measured
# getting wrong. `Cli#help` deliberately does not buffer: it wraps Thor's own
# help in one wide closed-output rescue, and the comment on that method
# records the seven ways buffering failed and why it was abandoned. These pin
# the shapes, so a future attempt at it fails loudly rather than regressing
# them silently.
RSpec.describe Claricle::Cli::Runner do
  describe "help's shell contract" do
    # `help`'s rescue deliberately covers generation as well as the write,
    # unlike every other command below. These two pin that, so narrowing it
    # cannot happen by accident -- the comment on `Cli#help` records the
    # three rounds of measurement that settled it. `printable_commands`
    # builds the general help page; `banner` builds one command's.
    it "returns 0 when help generation hits a broken pipe" do
      allow(Claricle::Cli).to receive(:printable_commands).and_raise(Errno::EPIPE)

      expect(described_class.run(["help"], output: StringIO.new)).to eq(0)
    end

    it "returns 0 when command help generation hits a broken pipe" do
      allow(Claricle::Cli).to receive(:banner).and_raise(Errno::EPIPE)

      expect(described_class.run(%w[help version], output: StringIO.new)).to eq(0)
    end

    # The stored writer stays OPEN; it is the pipe's READER that is gone,
    # so the first write raises EPIPE. Closing the writer itself would
    # raise IOError instead and exit 4, which is a different contract and
    # deliberately not what this pins.
    it "returns 0 when a custom shell's stored output has lost its reader" do
      reader, writer = IO.pipe
      reader.close
      custom_shell = Class.new(Thor::Shell::Basic) do
        attr_reader :calls

        def initialize(output)
          super()
          @output = output
          @pending = []
          @calls = []
        end

        def say(message = "", *)
          @calls << :say
          @pending << message
        end

        def print_table(*)
          @calls << :print_table
          @output.puts(*@pending)
        end
      end.new(writer)
      allow(Thor::Base).to receive(:shell).and_return(shell_factory(custom_shell))

      expect(described_class.run(["help"], output: StringIO.new)).to eq(0)
      expect(custom_shell.calls).to eq(%i[say print_table])
    ensure
      writer&.close
    end

    # Runner asks the settable `Thor::Base.shell` factory for each
    # invocation's shell. Returning this exact instance exercises the real
    # Runner path while proving its singleton output behaviour is preserved.
    it "preserves a caller-supplied shell's singleton help behaviour" do
      sink = StringIO.new
      injected = Thor::Base.shell.new
      injected.define_singleton_method(:say) do |message = "", *|
        sink.puts("custom:#{message}")
      end
      injected.define_singleton_method(:print_table) do |rows, **|
        sink.puts("custom-table:#{rows.length}")
      end
      allow(Thor::Base).to receive(:shell).and_return(shell_factory(injected))

      expect do
        expect(described_class.run(["help"], output: StringIO.new)).to eq(0)
      end.to output("").to_stdout

      # Deliberately NOT an equality check on the row count. The command
      # inventory is pinned once, on its own example further down; matching
      # it here as well would make adding a command look like a regression
      # in whose shell got used -- the same trap the terminator example's
      # comment warns about.
      expect(sink.string).to match(/\Acustom:Commands:\ncustom-table:\d+\ncustom:\n\z/)
    end

    # Thor drives a shell that answers `say`, `print_table`,
    # `print_wrapped` and `respond_to?` -- FOUR, not the three it calls.
    # Measured: a `BasicObject` shell without `respond_to?` never reaches
    # help at all, dying in Thor's own construction with
    # `NoMethodError: respond_to?`, which is why this one defines it.
    #
    # What `BasicObject` still withholds is everything else Object
    # supplies, `public_send` included, so any future indirection through
    # `help` has to reach this shell the way Thor does rather than
    # narrowing the shells this CLI accepts below Thor's own set.
    it "writes onto a shell that does not inherit Object's methods" do
      reached = []
      bare = Class.new(BasicObject) do
        define_method(:respond_to?) { |*| false }
        define_method(:say) { |*, **, &_block| reached << :say }
        define_method(:print_table) { |*, **, &_block| reached << :print_table }
        define_method(:print_wrapped) { |*, **, &_block| reached << :print_wrapped }
      end.new
      allow(Thor::Base).to receive(:shell).and_return(shell_factory(bare))

      expect(described_class.run(["help"], output: StringIO.new)).to eq(0)
      expect(reached).to eq(%i[say print_table say])
    end

    # Thor hands the shell to `Cli.help` and `Cli.command_help`, so a
    # subclass overriding either one can call ANY shell method on it, not
    # just the writing ones. `set_color` is a query: it has to return the
    # real shell's real answer, in the middle of building the page.
    it "forwards a non-writing shell method that a subclass asks for" do
      sink = StringIO.new
      subclass = Class.new(Claricle::Cli) do
        def self.help(shell, *)
          shell.say(shell.set_color("Coloured heading", :green))
          super
        end
      end
      coloured = []
      shell = shell_writing_to(sink)
      shell.define_singleton_method(:set_color) do |text, *colors|
        next text unless colors.include?(:green)

        coloured << text
        "REAL(#{text})"
      end

      subclass.new([], {}, shell: shell).help

      # The marker is what makes this a query rather than an echo. A
      # proxy that returned `set_color`'s ARGUMENT without ever asking the
      # real shell would still print "Coloured heading", so asserting that
      # alone passes on a shell whose answer was thrown away.
      expect(sink.string).to include("REAL(Coloured heading)")
      expect(coloured).to eq(["Coloured heading"])
      expect(sink.string).to include("Commands:")
    end

    # `help` is public, so a library caller can hold one Cli instance and
    # call it twice and get the page twice. Anything `help` installs on the
    # instance for the duration of a call has to come back off it.
    it "restores the caller's shell so a second help still reaches it" do
      sink = StringIO.new
      shell = shell_writing_to(sink)
      cli = Claricle::Cli.new([], {}, shell: shell)

      cli.help("version")
      first = sink.string.dup
      cli.help("version")

      # The CONTENT twice, not twice the byte count. A second call that
      # wrote the same number of junk bytes satisfies a length check --
      # measured, it stayed green -- so the length says nothing about
      # whether the page was printed.
      expect(first).to include("Display Claricle version")
      expect(cli.shell).to be(shell)
      expect(sink.string).to eq(first * 2)
    end

    # The examples from here down all pin ONE property: `help` writes
    # through the caller's shell as it goes, so every state that shell is
    # holding at the moment of a write still applies to it. Each is a shape
    # that a buffered `help` was measured getting wrong, and together they
    # are what a future attempt at buffering has to keep working. The
    # comment on `Cli#help` records why that attempt was abandoned.
    #
    # Thor's `indent` raises the padding, yields, and lowers it again, so a
    # write held past the block prints flush left.
    it "writes at the padding in force when the write is made" do
      sink = StringIO.new
      subclass = Class.new(Claricle::Cli) do
        def self.help(shell, *)
          shell.indent(2) { shell.say("Indented heading") }
          super
        end
      end
      shell = shell_writing_to(sink)

      subclass.new([], {}, shell: shell).help

      expect(sink.string).to start_with("    Indented heading\n")
      expect(sink.string).to include("\nCommands:\n")
    end

    # Thor assigns `@shell` during construction (thor's shell.rb, in
    # `initialize`), so a frozen Cli is frozen WITH a shell in it and
    # prints from one happily. Any scheme that swaps `self.shell` loses
    # this caller entirely.
    it "prints help on a frozen instance" do
      sink = StringIO.new
      shell = shell_writing_to(sink)
      cli = Claricle::Cli.new([], {}, shell: shell).freeze

      expect { cli.help("version") }.not_to raise_error
      expect(sink.string).to include("Display Claricle version")
    end

    # A real pipe, not a stub: the errno has to come from the OS write,
    # which is the only thing that proves the rescue actually covers it.
    it "tolerates a closed pipe on a frozen instance" do
      reader, writer = IO.pipe
      reader.close
      shell = Thor::Base.shell.new
      shell.define_singleton_method(:stdout) { writer }

      expect(Claricle::Cli.new([], {}, shell: shell).freeze.help("version").code).to eq(0)
    ensure
      writer&.close
    end

    # `mute` yields with writes suppressed and clears the flag afterwards,
    # so a write held past the block prints exactly what the caller
    # silenced.
    it "does not print a write the caller muted" do
      sink = StringIO.new
      subclass = Class.new(Claricle::Cli) do
        def self.help(shell, *)
          shell.mute { shell.say("suppressed") }
        end
      end
      shell = shell_writing_to(sink)

      subclass.new([], {}, shell: shell).help

      expect(sink.string).to eq("")
    end

    # A SECOND suppression switch, and it is not `mute?`. Thor's `say`
    # also returns early when `base.options[:quiet]` is set, so a shell
    # that is not muted can still be silent. The two are separate: a
    # buffered `help` that consulted only `mute?` printed "suppressed"
    # here while every mute example above stayed green.
    #
    # "visible" is written after quiet is cleared, so a run that printed
    # nothing at all would fail too -- the assertion is which of the two
    # lines survives, not that the page is empty.
    it "does not print a write the caller silenced with the quiet option" do
      sink = StringIO.new
      subclass = Class.new(Claricle::Cli) do
        def self.help(shell, *)
          original = shell.base.options
          shell.base.options = original.merge(quiet: true)
          shell.say("suppressed")
          shell.base.options = original
          shell.say("visible")
        end
      end
      shell = shell_writing_to(sink)

      subclass.new([], {}, shell: shell).help

      expect(sink.string).to eq("visible\n")
    end

    # Thor prints from a frozen shell happily. Reproducing shell state for
    # a held write means assigning to it, which raises FrozenError here
    # before any output reaches the sink.
    it "prints through a shell frozen after construction" do
      sink = StringIO.new
      shell = shell_writing_to(sink)
      cli = Claricle::Cli.new([], {}, shell: shell)
      shell.freeze

      expect { cli.help("version") }.not_to raise_error
      expect(sink.string).to include("Display Claricle version")
    end

    # A shell may report its padding and refuse to have it set, driving
    # its own `indent` internally. Thor prints such a shell indented; a
    # held write has no way to put that padding back, so it flattens.
    it "keeps indentation on a shell whose padding cannot be set" do
      sink = StringIO.new
      read_only = Class.new(Thor::Shell::Basic) do
        attr_reader :padding

        undef_method :padding=

        def indent(count = 1)
          original = @padding
          @padding = original + count
          yield
        ensure
          @padding = original
        end
      end.new
      read_only.define_singleton_method(:stdout) { sink }
      subclass = Class.new(Claricle::Cli) do
        def self.help(shell, *)
          shell.indent(2) { shell.say("indented") }
        end
      end

      subclass.new([], {}, shell: read_only).help

      expect(sink.string).to eq("    indented\n")
    end

    it "writes help through a print/puts/flush-only stream" do
      contents = +""
      sink = Object.new
      sink.define_singleton_method(:print) { |text| contents << text }
      sink.define_singleton_method(:puts) { |text = ""| contents << text << "\n" }
      sink.define_singleton_method(:flush) { nil }
      injected = shell_writing_to(sink)
      allow(Thor::Base).to receive(:shell).and_return(shell_factory(injected))

      expect(sink).not_to respond_to(:write)
      expect(described_class.run(["help"], output: StringIO.new)).to eq(0)
      expect(contents).to match(/\ACommands:\n(?:\s+\S+ .+\n)+\n\z/)
    end
  end
end
