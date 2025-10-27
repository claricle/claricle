# frozen_string_literal: true

require_relative "lib/claricle/version"

Gem::Specification.new do |spec|
  spec.name = "claricle"
  spec.version = Claricle::VERSION
  spec.authors = ["Ribose Inc."]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "Claricle is a comprehensive image utility gem for validation, conversion, and compression."
  spec.description = <<~HEREDOC
    Claricle provides a Ruby library for working with images, offering tools for
    image validation (PNG, SVG), format conversion, compression, and vector
    graphics processing. The name combines "clarity" and "particle", representing
    the clear validation of every pixel. It is built to integrate functionality
    from pngconform, svgconform, vectory, and other image processing tools into
    a unified interface.
  HEREDOC

  spec.homepage = "https://github.com/ribose/claricle"
  spec.license = "BSD-2-Clause"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ribose/claricle"
  spec.metadata["changelog_uri"] = "https://github.com/ribose/claricle"
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

  spec.add_dependency "thor", "~> 1.0"
end
