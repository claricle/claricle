# frozen_string_literal: true

# Calls `Claricle::Batch.run` with `pattern:`/`classify:` keywords already
# named, so every example in batch_spec.rb reads the argument it is
# actually varying instead of repeating the two defaults each time. In
# `spec/support` rather than a `def` in the describe body: it takes
# arguments, so a `let` (no arity) can't stand in for it, and a top-level
# `def` would leak onto Object.
#
# `include`, not `module_function` like `PdfBuilder`/`InspectFixture`: it
# closes over no host state and could be either, but batch_spec.rb calls
# it bare at dozens of sites, and `module_function` would mean rewriting
# every one to `BatchRunner.run(...)`.
module BatchRunner
  def run(batch, arguments, pattern: nil, classify: nil, &operation)
    batch.run(arguments, pattern: pattern, classify: classify, &operation)
  end
end
