# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Issue #1: "Adding a new format = adding a new handler class, not editing
# switch statements across N files." Proven the only way that counts: copy
# lib/ to a scratch directory, add ONE file to its handlers/ directory, and
# run a fresh process against the copy. A separate process also means the
# throwaway class cannot leak into any other example.
RSpec.describe "Adding a format" do
  lib = File.expand_path("../../lib", __dir__)
  fixture = File.expand_path("../fixtures/extra_handler/qoi.rb", __dir__)
  plain_svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>'
  gradient_svg = '<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g"/></defs></svg>'

  # Runs `script` in a fresh process whose load path holds a copy of lib/,
  # with the fixture dropped in as the only addition when `with_handler`.
  run = lambda do |script, with_handler:|
    Dir.mktmpdir("claricle-one-class") do |dir|
      FileUtils.cp_r(lib, dir)
      handlers = File.join(dir, "lib", "claricle", "handlers")
      FileUtils.cp(fixture, File.join(handlers, "qoi.rb")) if with_handler
      File.write(File.join(dir, "plain.svg"), plain_svg)
      File.write(File.join(dir, "gradient.svg"), gradient_svg)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{File.join(dir, "lib")}", "-e",
                                              "Dir.chdir(#{dir.inspect}); #{script}")
      raise "subprocess failed: #{stderr}" unless status.success?

      JSON.parse(stdout)
    end
  end

  probe = <<~RUBY
    require "claricle"
    require "json"
    registry = Claricle.const_get(:Registry)
    image = Claricle::Image.from_path("plain.svg")
    print JSON.generate(
      formats: registry.formats,
      detected: (Claricle.detect("qoifxxxx") rescue "unknown"),
      owner: (registry.handler_for(:qoi).name rescue nil),
      svg_targets: registry.convert_targets_for(:svg),
      converted: (image.convert(to: :qoi).content rescue "refused"),
      lossless: (image.convert(to: :qoi).lossiness rescue "refused"),
      lossy: (Claricle::Image.from_path("gradient.svg").convert(to: :qoi).lossiness rescue "refused")
    )
  RUBY

  it "picks up a dropped-in handler class for detect, dispatch, formats and convert" do
    result = run.call(probe, with_handler: true)

    expect(result).to include(
      "detected" => "qoi", "owner" => "Claricle::Handlers::Qoi",
      "converted" => "qoif#{plain_svg.bytesize}",
      "lossless" => "lossless", "lossy" => "lossy"
    )
    expect(result["formats"]).to include("qoi")
    expect(result["svg_targets"]).to include("qoi")
  end

  it "lists the new format in `claricle formats` with no other edit" do
    script = 'require "claricle"; Claricle::Cli.start(%w[formats --json])'
    rows = run.call(script, with_handler: true)
    row = rows.find { |r| r["format"] == "qoi" }
    svg = rows.find { |r| r["format"] == "svg" }

    expect(row).not_to be_nil
    expect(svg["convert_to"]).to include("qoi")
  end

  it "converts through the CLI to the new format" do
    script = <<~RUBY
      require "claricle"
      require "json"
      require "stringio"
      real = $stdout
      $stdout = StringIO.new
      Claricle::Cli.start(%w[convert plain.svg --to qoi])
      $stdout = real
      print JSON.generate(File.binread("plain.qoi"))
    RUBY

    expect(run.call(script, with_handler: true)).to eq("qoif#{plain_svg.bytesize}")
  end

  # The control: the same probe without the file. If this did not differ,
  # the examples above would pass for any reason at all.
  it "knows nothing of the format without the file" do
    result = run.call(probe, with_handler: false)

    expect(result).to include("detected" => "unknown", "owner" => nil, "converted" => "refused")
    expect(result["formats"]).not_to include("qoi")
    expect(result["svg_targets"]).not_to include("qoi")
  end

  it "does not leak into this process" do
    registry = Claricle.const_get(:Registry)

    expect(registry.formats).not_to include(:qoi)
    expect(Claricle.const_get(:Handlers).constants).not_to include(:Qoi)
  end

  describe "the declarations" do
    base = Claricle.const_get(:Handlers).const_get(:Base)

    it "refuses a detector that answers a format it did not declare" do
      handler = Class.new(base) do
        formats :qoi
        detect { :gif }
      end

      expect { handler.detect_format("x") }.to raise_error(Claricle::Error, /did not declare/)
    end

    it "answers nil when no detector was declared or it declines" do
      declared = Class.new(base) do
        formats :qoi
        detect { |header| :qoi if header.start_with?("qoif") }
      end

      expect(Class.new(base).detect_format("qoif")).to be_nil
      expect(declared.detect_format("nope")).to be_nil
      expect(declared.detect_format("qoif")).to eq(:qoi)
    end

    it "refuses a second converter from the same source" do
      handler = Class.new(base) do
        formats :qoi
        convert_from(:svg) { "" }
      end

      expect { handler.convert_from(:svg) { "" } }.to raise_error(Claricle::Error, /already declared a converter/)
    end

    it "refuses a second loss_rules declaration" do
      handler = Class.new(base) { loss_rules lost: [], kept: [] }

      expect { handler.loss_rules(lost: [], kept: []) }.to raise_error(Claricle::Error, /already declared loss rules/)
    end
  end
end
