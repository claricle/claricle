# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in claricle.gemspec
gemspec

# TEMPORARY, and it belongs in the Gemfile rather than the gemspec on purpose:
# a gemspec constraint ships to everyone who installs claricle, this one binds
# development and CI only.
#
# json 3.0.0 (2026-09-07) removed the tolerance json 2.x had for unknown
# options. Released lutaml-model passes two it no longer accepts -- `register:`
# into `JSON.generate` and `create_additions:` into `JSON.parse` -- so every
# lutaml-backed `to_json` and `from_json` raises `ArgumentError`. Measured on
# bare main: 77 failures under json 3.0.0, 0 under 2.21.2.
#
# lutaml/lutaml-model#770 fixes it. Verified against this repo before pointing
# here: main 946/0, and the three PRs that were red come back 1034/0, 1099/0
# and 1049/0.
#
# Tracks the BRANCH rather than a SHA so fixes pushed to #770 arrive without an
# edit here. The cost is that a force-push or a rename breaks CI, which is the
# right trade while that PR is actively worked on.
#
# REMOVE THIS once lutaml-model ships a release carrying the fix, and let the
# gemspec's `~> 0.8.19` resolve normally again.
gem "lutaml-model", git: "https://github.com/lutaml/lutaml-model.git",
                    branch: "fix/json-3-compatibility"

gem "rake"
gem "rspec"
gem "rubocop"
gem "rubocop-performance"
gem "rubocop-rake"
gem "rubocop-rspec"
