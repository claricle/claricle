# frozen_string_literal: true

require "tempfile"

require_relative "detector"
require_relative "registry"

module Claricle
  # What every operation takes and the registry dispatches on. Built from a
  # path or from content; either way it knows its format.
  class Image
    attr_reader :format, :path

    def self.from_path(path)
      new(format: Detector.detect_path(path), path: path)
    end

    def self.from_content(content, format: nil)
      # nil means "detect"; anything else is the caller's answer, including
      # a false one, which the Symbol guard then rejects.
      new(format: format.nil? ? Detector.detect(content) : format, content: content)
    end

    def initialize(format:, path: nil, content: nil)
      raise ArgumentError, "format must be a Symbol, got #{format.class}" unless format.is_a?(Symbol)
      # Exactly one source. Neither leaves #content reading from a nil
      # path; both is contradictory and would silently prefer one.
      raise ArgumentError, "give exactly one of path: or content:" unless path.nil? ^ content.nil?

      @format = format
      @path = path
      @content = content && binary(content)
    end

    # Read on demand, once. Detection already streamed the file; slurping it
    # at construction would waste that.
    def content
      @content ||= File.binread(path)
    end

    # Most delegates want a path. A content-born image gets a temporary one
    # that exists only for the block -- Tempfile.create's block form removes
    # it on exit, where Tempfile.new would leave it behind.
    def with_path
      raise ArgumentError, "with_path requires a block" unless block_given?
      return yield(path) if path

      Tempfile.create(["claricle", ".#{format}"]) do |file|
        file.binmode
        file.write(content)
        file.flush
        yield(file.path)
      end
    end

    def inspection
      handler.inspection(self)
    end

    def conformance_report
      handler.conformance_report(self)
    end

    def convert(to:)
      handler.convert(self, to: to)
    end

    private

    # Bytes, whatever the caller tagged them. `File.binread` already gives
    # that; detection binary-copies its own view (detector.rb:137) and
    # never the String we keep, so a content-born image was the one place
    # `content` depended on how the caller happened to read the file.
    # Measured: the same 70-byte PNG through `File.read` arrives UTF-8,
    # where `length` is 69 and `valid_encoding?` is false -- a handler
    # indexing or scanning it would disagree with the path-born image.
    # Re-tagged on a copy, so the caller keeps their String as it was, and
    # only when it has to be: `.b` allocates a second whole image.
    def binary(bytes)
      bytes.encoding == Encoding::BINARY ? bytes : bytes.b
    end

    # Per call: handlers are stateless, and a cache would buy nothing.
    def handler
      Registry.handler_for(format).new
    end
  end
end
