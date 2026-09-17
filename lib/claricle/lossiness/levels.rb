# frozen_string_literal: true

module Claricle
  module Lossiness
    # Split out of `lossiness.rb` so a caller that only wants the three-string
    # vocabulary (`Models::Conversion` reads `LEVELS` for one attribute's
    # `values:` list) does not also load the classifier and, through it,
    # `detector.rb` and REXML. Measured: requiring `lossiness.rb` alone pulled
    # in `REXML` and `Emf` as a side effect of a single 3-element Array
    # constant. This file requires nothing and defines nothing but `LEVELS`.
    LEVELS = %w[lossless lossy unknown].freeze
  end
end
