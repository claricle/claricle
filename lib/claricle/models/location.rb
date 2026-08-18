# frozen_string_literal: true

require_relative "base"

module Claricle
  module Models
    # Where an issue sits in its source. Every field is nullable, because
    # what a delegate can report varies by format. `byte_offset` and
    # `byte_length` are a zero-based half-open range -- issue #1 asks for a
    # byte range, which a bare offset cannot express.
    class Location < Base
      attribute :byte_offset, :integer
      attribute :byte_length, :integer
      attribute :line, :integer
      attribute :column, :integer
      attribute :chunk, :string
      attribute :node_path, :string
    end
  end
end
