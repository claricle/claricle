# frozen_string_literal: true

require_relative "lib/claricle/version"

Gem::Specification.new do |spec|
  spec.name = "claricle"
  spec.version = Claricle::VERSION
  spec.authors = ["Ribose Inc."]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "Format detection and a unified image model for Ruby."
  spec.description = <<~HEREDOC
    Claricle detects an image's format from its bytes -- PNG, SVG, EMF, WMF,
    EPS, PS and PDF -- and gives one object and one set of models to work with.
    The name combines "clarity" and "particle". Inspection, conformance
    checking and conversion are being built on this foundation, wrapping
    png_conform, svg_conform, vectory and pdfrb behind a single interface.
  HEREDOC

  spec.homepage = "https://github.com/claricle/claricle"
  spec.license = "BSD-2-Clause"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/claricle/claricle"
  spec.metadata["changelog_uri"] = "https://github.com/claricle/claricle"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "emf", "~> 0.1.0"
  # Constrained to json 2.x. Every lutaml-model this gemspec admits passes a
  # `register:` keyword down to `JSON.generate` (it enters at
  # format_conversion.rb:207, reaches JSON at
  # key_value/adapter/json/standard_adapter.rb:34, and 0.8.19 and 0.8.22 are
  # identical there). json 2.x ignores unknown keywords; 3.0.0 raises
  # `ArgumentError: unknown keyword: register`, killing every lutaml-backed
  # `to_json` -- `claricle inspect --json` included, so this is a shipped
  # runtime path and not only the suite.
  # `~> 2.7` and not a bare `< 3.0`: Ruby 3.3 already bundles 2.7.x and 3.4
  # bundles 2.9.1, so on those the constraint asks for nothing new; the Ruby
  # 4.0 leg CI runs is untested against it. Widen the constraint -- do not
  # delete the line, three files require json directly -- once lutaml-model
  # stops passing `register:`.
  spec.add_dependency "json", "~> 2.7"
  spec.add_dependency "lutaml-model", "~> 0.8.19"
  spec.add_dependency "png_conform", "~> 0.1.4"
  spec.add_dependency "postscript", "~> 0.2.0"
  spec.add_dependency "rexml", "~> 3.4.4"
  spec.add_dependency "thor", "~> 1.2"
end
