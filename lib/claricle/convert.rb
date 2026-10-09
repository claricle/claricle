# frozen_string_literal: true

module Claricle
  # One file in, the one `Models::Conversion` out. The same code path as
  # `convert_batch`, so the write lifecycle, collision and overwrite rules
  # cannot differ; the only change is the failure shape. A batch collects
  # a per-file failure into its result, but with one file there is nothing
  # to carry it past, so the real exception is raised, as `conform?` does.
  #
  # `path` is one file, never a pattern: a name that matches several files
  # is refused before anything is converted.
  def self.convert(path, to: nil, output: nil, force: false)
    files = Batch.expand([path], nil)
    raise InvocationError, "convert takes a single source; #{files.length} files matched" if files.length > 1

    result = convert_batch(files.first, to: to, output: output, force: force)
    raise result.highest_error if result.highest_error

    result.items.first.result
  end
end
