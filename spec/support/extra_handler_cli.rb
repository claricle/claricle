# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# Runs the real `exe/claricle` in a fresh process against a scratch copy of
# lib/ with ONE handler file dropped in, the same way
# spec/claricle/one_class_per_format_spec.rb adds a format. The registry is
# frozen at load, so a handler cannot be added in-process; a subprocess also
# keeps the throwaway class out of every other example.
# Not self-installing: the file that wants this includes the module.
module ExtraHandlerCli
  ROOT = File.expand_path("../..", __dir__)

  # `files` maps a file name to its content. Returns [stdout, stderr, exit
  # status] for `claricle *argv` run inside the directory holding them.
  # Under bundler stderr can lead with load warnings: match its tail.
  def claricle_with_handler(handler_fixture, argv, files: {})
    Dir.mktmpdir("claricle-extra-handler") do |dir|
      lib = scratch_lib_with(dir, handler_fixture)
      work = File.join(dir, "work")
      FileUtils.mkdir(work)
      files.each { |name, content| File.binwrite(File.join(work, name), content) }
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{lib}", File.join(ROOT, "exe", "claricle"),
                                              *argv, chdir: work)
      [stdout, stderr, status.exitstatus]
    end
  end

  private

  def scratch_lib_with(dir, handler_fixture)
    FileUtils.cp_r(File.join(ROOT, "lib"), dir)
    handlers = File.join(dir, "lib", "claricle", "handlers")
    FileUtils.cp(handler_fixture, File.join(handlers, File.basename(handler_fixture)))
    File.join(dir, "lib")
  end
end
