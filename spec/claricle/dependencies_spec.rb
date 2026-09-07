# frozen_string_literal: true

require "json"

# Every model here reaches JSON through lutaml-model's standard adapter,
# never through the json gem directly, and that adapter forwards its own
# options into json's keyword arguments. json 2.x ignores a keyword it
# does not recognise; json 3.0.0 raises `ArgumentError: unknown keyword`.
# Measured 2026-09-07 against the CI failure on run 34109645693: with
# json 3.0.0 resolved, `bundle exec rspec` went from 0 failures to 77,
# and `claricle inspect --json` on a real PNG printed
# `claricle: ArgumentError: unknown keyword: register` in place of a
# document. lutaml-model 0.8.19 and 0.8.22 both fail this way -- their
# json adapters are byte-identical -- so the json release is the whole
# cause and the gemspec ceiling is the whole fix.
RSpec.describe "the json gem claricle's models serialise through" do
  root = File.expand_path("../..", __dir__)

  # The gemspec as it ships, not the resolved bundle: the ceiling is what
  # keeps a fresh `bundle install` away from json 3, so the file is the
  # thing under test.
  let(:json_requirement) do
    gemspec = Gem::Specification.load(File.join(root, "claricle.gemspec"))
    gemspec.dependencies.find { |dependency| dependency.name == "json" }
           .requirement
  end

  # Both halves are load-bearing in opposite directions. Without the
  # first, dropping the ceiling passes. Without the second, raising the
  # floor above the json that Ruby 3.3 -- this gem's own floor -- ships as
  # a default gem passes, and every supported Ruby then needs a network
  # install to run the suite.
  #
  # The version named is 2.7.1, not the loaded `JSON::VERSION`. Bundler
  # guarantees the loaded json satisfies the gemspec, so an assertion
  # against it is true by construction under `bundle exec` and cannot
  # fail: measured with the constraint mutated to `= 2.7.1`, which simply
  # installed 2.7.1 and left the example green.
  it "declares a constraint that refuses 3.0.0 and admits Ruby 3.3's json" do
    expect(json_requirement.satisfied_by?(Gem::Version.new("3.0.0")))
      .to be(false)
    expect(json_requirement.satisfied_by?(Gem::Version.new("2.7.1")))
      .to be(true)
  end

  # Driven through lutaml-model's own adapter rather than a hand-written
  # `JSON.generate(value, register: :default)`, so the example follows
  # lutaml if it changes which options it forwards. A replica of the two
  # calls would keep passing after lutaml started forwarding a third.
  it "accepts the options lutaml-model's adapter forwards on both doors" do
    adapter = Lutaml::KeyValue::Adapter::Json::StandardAdapter

    expect(adapter.new({ "a" => 1 }, register: :default)
                  .to_json(register: :default)).to eq('{"a":1}')
    expect(adapter.parse('{"a":1}')).to eq("a" => 1)
  end

  # The property the two examples above exist to protect, asserted end to
  # end on a real model: a value out, and the same value back in.
  it "round-trips a model whose register lutaml fills in by default" do
    issue = Claricle::Models::Issue.new(severity: "error", message: "m")

    expect(issue.lutaml_register).to eq(:default)
    expect(issue.to_json).to eq('{"severity":"error","message":"m"}')
    expect(Claricle::Models::Issue.from_json(issue.to_json).message).to eq("m")
  end
end
