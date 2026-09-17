# frozen_string_literal: true

# Every model here reaches JSON through lutaml-model's own adapter, never
# through the json gem directly. lutaml-model 0.8.19 through 0.8.22 pass an
# unrecognised keyword into that adapter and json 3.x raises on it, where
# json 2.x silently ignored it; lutaml-model 0.8.23 fixed the adapter call.
# Pairing 0.8.22 with json 3.x makes every lutaml-backed to_json/from_json
# raise `ArgumentError: unknown keyword: register`; pairing 0.8.23 with the
# same json does not.
#
# The floor moved again, past 0.8.23, for an unrelated second reason:
# Claricle::Models::Validation stopped refusing a multi-value enum and a
# bare model handed to a `collection: true` attribute itself once lutaml-
# model 0.8.32 (lutaml/lutaml-model#185, PR #720) started doing both
# itself -- see lib/claricle/models/base.rb. Below 0.8.32, neither guard
# exists anywhere: reproduced directly against 0.8.31, `Issue.new(severity:
# %w[info error], message: "m")` silently keeps "info" and drops "error"
# with no error raised, and `Report.new(issues: a_bare_issue)` crashes with
# a raw `NoMethodError` instead of the clean `ValidationError` the removed
# code used to produce. So the floor on lutaml-model, not a ceiling on
# json, is what keeps a resolved bundle safe.
RSpec.describe "the lutaml-model floor claricle's models depend on" do
  root = File.expand_path("../..", __dir__)

  # The gemspec as it ships, not the resolved bundle: the floor is what
  # keeps a fresh `bundle install` away from the broken 0.8.19-0.8.31
  # range, so the file is the thing under test.
  let(:lutaml_model_requirement) do
    gemspec = Gem::Specification.load(File.join(root, "claricle.gemspec"))
    gemspec.dependencies.find { |dependency| dependency.name == "lutaml-model" }
           .requirement
  end

  # `~> 0.8.23` already admitted 0.8.31 (it meant `>= 0.8.23, < 0.9`) -- the
  # defect is that it ALSO admitted every version still missing the
  # cardinality enforcement this library now depends on. So the assertion
  # that catches the bug is the refusal at the old floor, not the
  # admission of the new one.
  it "refuses every broken lutaml-model version and admits the fixed one" do
    expect(lutaml_model_requirement.satisfied_by?(Gem::Version.new("0.8.22")))
      .to be(false)
    expect(lutaml_model_requirement.satisfied_by?(Gem::Version.new("0.8.31")))
      .to be(false)
    expect(lutaml_model_requirement.satisfied_by?(Gem::Version.new("0.8.32")))
      .to be(true)
  end

  # The pessimistic operator's ceiling is unchanged by the fix -- still a
  # patch-level float, not an open floor to the next minor.
  it "still refuses a jump to the next minor version" do
    expect(lutaml_model_requirement.satisfied_by?(Gem::Version.new("0.9.0")))
      .to be(false)
  end
end
