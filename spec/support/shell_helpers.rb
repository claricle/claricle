# frozen_string_literal: true

# Building the Thor shell shapes `cli_help_spec.rb` drives. In `spec/support`
# and NOT self-installing: the file that wants these includes the module into
# its own group.
#
# An earlier version ended with `RSpec.configure { config.include ShellHelpers }`,
# which put both helpers on every example group in the suite -- but only when
# the one file requiring this one happened to be in the run. Measured:
# `rspec spec/claricle/registry_spec.rb` alone answered false to
# `respond_to?(:shell_factory)`, and a full `rspec` answered true. A helper
# whose presence depends on which files were selected is the same surprise a
# top-level `def` in a spec file causes, wearing better clothes.
module ShellHelpers
  # Thor asks the settable `Thor::Base.shell` factory for a shell per
  # invocation. Handing back one prepared instance is what lets an example
  # drive the real Runner path while still owning the shell it uses.
  def shell_factory(shell)
    Class.new do
      define_singleton_method(:new) { shell }
    end
  end

  # A real shell of whatever class `Thor::Base.shell` hands back -- measured
  # as `Thor::Shell::Color` here, a `Basic` subclass, so the write path is
  # inherited and unchanged. Real padding, real muting, real everything,
  # writing into `sink` instead of `$stdout`. Thor reads `stdout` on every
  # write, so a singleton is enough and nothing else about the shell changes.
  def shell_writing_to(sink)
    shell = Thor::Base.shell.new
    shell.define_singleton_method(:stdout) { sink }
    shell
  end
end
