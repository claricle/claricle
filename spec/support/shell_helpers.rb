# frozen_string_literal: true

# Building the Thor shell shapes the CLI specs drive. In `spec/support` and
# included through `RSpec.configure` rather than defined in a spec file: a
# `def` at the top level of a spec file becomes a private method on Object and
# is reachable from every other file in the suite, which is a surprise nobody
# asked for. Two files need these, so they stop being local helpers.
module ShellHelpers
  # Thor asks the settable `Thor::Base.shell` factory for a shell per
  # invocation. Handing back one prepared instance is what lets an example
  # drive the real Runner path while still owning the shell it uses.
  def shell_factory(shell)
    Class.new do
      define_singleton_method(:new) { shell }
    end
  end

  # A real `Thor::Shell::Basic` -- real padding, real muting, real everything
  # -- writing into `sink` instead of `$stdout`. Thor reads `stdout` on every
  # write, so a singleton is enough and nothing else about the shell changes.
  def shell_writing_to(sink)
    shell = Thor::Base.shell.new
    shell.define_singleton_method(:stdout) { sink }
    shell
  end
end

RSpec.configure do |config|
  config.include ShellHelpers
end
