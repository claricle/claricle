# frozen_string_literal: true

# Watches ONE call to `Claricle::Cli.class_options_help` made while
# `probe` runs, and hands back what `probe` saw -- WHEN a write reached
# the shell, not merely that it did. Refuses a second `help` call inside
# one block instead of silently answering about the first. An instance
# method, not a module function: it calls `allow`, which only resolves on
# a running example. Stays on `and_wrap_original`, not `prepend`: RSpec
# tears its own stub down at the end of the example, so a leaked hook
# can't outlive it (same pattern at
# `spec/claricle/handlers/postscript_spec.rb:964`).
module GenerationObserver
  def observing_generation(probe)
    seen = []
    allow(Claricle::Cli).to receive(:class_options_help).and_wrap_original do |original, *args|
      seen << probe.call
      original.call(*args)
    end
    yield
    raise "observing_generation saw #{seen.length} generations, expected 1" unless seen.one?

    seen.first
  end
end
