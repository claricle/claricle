# frozen_string_literal: true

# Two floors are pinned here, not one: below 0.8.23, lutaml-model's JSON
# adapter raises `ArgumentError: unknown keyword: register` against json
# 3.x. Below 0.8.32, Claricle::Models::Validation's own cardinality/shape
# guards were removed (lib/claricle/models/base.rb) in favor of lutaml-
# model doing that itself -- so below 0.8.32 nothing does it at all.
# Don't lower this without re-adding whichever guard the floor was
# covering for.
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
