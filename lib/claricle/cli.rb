# frozen_string_literal: true

module Claricle
  # Command-line interface for Claricle
  class Cli < Thor
    def self.exit_on_failure?
      true
    end

    desc "version", "Display Claricle version"
    def version
      puts "Claricle version #{Claricle::VERSION}"
    end

    desc "validate FILE_PATTERN", "Validate image files (placeholder)"
    long_desc <<~LONGDESC
      Validate image files against their respective standards.

      This command will validate PNG, SVG, and other image formats
      for conformance and correctness.

      Note: This is a placeholder command. Functionality will be
      implemented in future versions.

      Examples:
        claricle validate image.png
        claricle validate *.svg
        claricle validate "images/*.png"
    LONGDESC
    def validate(_pattern)
      puts "Image validation functionality coming soon!"
      puts "This gem is currently a placeholder to reserve the name."
    end

    desc "convert SOURCE DEST", "Convert image formats (placeholder)"
    long_desc <<~LONGDESC
      Convert images between different formats.

      Note: This is a placeholder command. Functionality will be
      implemented in future versions.

      Examples:
        claricle convert image.png image.svg
        claricle convert logo.svg logo.png
    LONGDESC
    def convert(_source, _dest)
      puts "Image conversion functionality coming soon!"
      puts "This gem is currently a placeholder to reserve the name."
    end

    desc "compress FILE_PATTERN", "Compress image files (placeholder)"
    long_desc <<~LONGDESC
      Compress image files while maintaining quality.

      Note: This is a placeholder command. Functionality will be
      implemented in future versions.

      Examples:
        claricle compress image.png
        claricle compress *.jpg
    LONGDESC
    def compress(_pattern)
      puts "Image compression functionality coming soon!"
      puts "This gem is currently a placeholder to reserve the name."
    end
  end
end
