# frozen_string_literal: true

# Resolves a name under spec/fixtures/inspect/ to its full path. A module
# method rather than a `let` (this takes an argument and `let` has no
# arity) or an in-block `def` inside a describe block (which would define
# an instance method on that one anonymous example group class instead of
# living somewhere another spec file could reuse it).
module InspectFixture
  module_function

  def path(name)
    File.join(__dir__, "..", "fixtures", "inspect", name)
  end
end
