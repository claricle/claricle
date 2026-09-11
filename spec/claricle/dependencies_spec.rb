# frozen_string_literal: true

# Every model here reaches JSON through lutaml-model's own adapter, never
# through the json gem directly. lutaml-model 0.8.19 through 0.8.22 pass an
# unrecognised keyword into that adapter and json 3.x raises on it, where
# json 2.x silently ignored it; lutaml-model 0.8.23 fixed the adapter call.
# Pairing 0.8.22 with json 3.x makes every lutaml-backed to_json/from_json
# raise `ArgumentError: unknown keyword: register`; pairing 0.8.23 with the
# same json does not. So the floor on lutaml-model, not a ceiling on json,
# is what keeps a resolved bundle safe.
RSpec.describe "the lutaml-model floor claricle's models depend on" do
  root = File.expand_path("../..", __dir__)

  # The gemspec as it ships, not the resolved bundle: the floor is what
  # keeps a fresh `bundle install` away from the broken 0.8.19-0.8.22
  # range, so the file is the thing under test.
  let(:lutaml_model_requirement) do
    gemspec = Gem::Specification.load(File.join(root, "claricle.gemspec"))
    gemspec.dependencies.find { |dependency| dependency.name == "lutaml-model" }
           .requirement
  end

  # `~> 0.8.19` already admits 0.8.23 (it means `>= 0.8.19, < 0.9`) -- the
  # defect is that it ALSO admits every broken version below 0.8.23. So the
  # assertion that catches the bug is the refusal, not the admission.
  it "refuses every broken lutaml-model version and admits the fixed one" do
    expect(lutaml_model_requirement.satisfied_by?(Gem::Version.new("0.8.22")))
      .to be(false)
    expect(lutaml_model_requirement.satisfied_by?(Gem::Version.new("0.8.23")))
      .to be(true)
  end

  # The pessimistic operator's ceiling is unchanged by the fix -- still a
  # patch-level float, not an open floor to the next minor.
  it "still refuses a jump to the next minor version" do
    expect(lutaml_model_requirement.satisfied_by?(Gem::Version.new("0.9.0")))
      .to be(false)
  end
end
