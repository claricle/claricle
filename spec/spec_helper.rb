# frozen_string_literal: true

require "tempfile"
require "timeout"
require "claricle"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Without this, a partial double may stub a method the real object does
  # not have, and the example still passes. A pin naming a misremembered or
  # renamed method then asserts nothing, forever, while reading as a precise
  # assertion -- worse than a vacuous matcher, because it looks specific.
  # `spec/claricle/mock_verification_spec.rb` pins that this stays on.
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
