# frozen_string_literal: true

# Asserts that a snippet or claim is still IN the README, so renaming
# `image.format` to `image.formatt` in the docs turns these red instead of
# leaving replica examples green. Instance methods, not module functions:
# both read `readme`, the `let` documentation_spec.rb defines alongside
# `include DocumentationExamples`, and `expect` is only available inside a
# running example. In `spec/support` rather than a `def` in the describe
# body because both take an argument -- a `let` has no arity, and a
# top-level `def` would leak onto Object.
module DocumentationExamples
  # Whole lines, not substrings: asserting "image.format" would still pass
  # if the doc said "image.formatt".
  def shows(snippet)
    lines = readme.lines.map(&:strip)
    expect(lines).to include(snippet), "README no longer shows the line: #{snippet}"
  end

  # `shows` is for a code line, which the README never wraps. Prose is
  # hard wrapped, so a sentence is matched with its wrap points left free.
  # Each word is escaped, so backticks and punctuation inside the claim
  # stay literal.
  def claims(sentence)
    pattern = /#{sentence.split.map { |word| Regexp.escape(word) }.join('\s+')}/
    expect(readme).to match(pattern), "README no longer claims: #{sentence}"
  end
end
