# frozen_string_literal: true

require "open3"
require "tmpdir"

# Every convert edge runs in its own cold Ruby process. A constant that only
# resolves after some other conversion loaded it (the Postsvg UnknownOperator
# load-order bug) passes inside one warm suite process and fails here. Do not
# fold these into in-process examples.
RSpec.describe "Convert edges in a fresh process" do
  root = File.expand_path("../../..", __dir__)
  fixtures = File.join(root, "spec", "fixtures", "convert")

  it "does not load conversion delegates when claricle is required" do
    output, status = Open3.capture2(
      RbConfig.ruby, "-I#{File.join(root, "lib")}", "-e",
      'require "claricle"; puts [defined?(Vectory), defined?(Postsvg)].inspect'
    )

    expect(status).to be_success
    expect(output).to eq("[nil, nil]\n")
  end

  # What each target's output must start with (EMF: record type 1, then the
  # " EMF" signature at offset 40).
  signatures = {
    svg: ->(bytes) { bytes.lstrip.start_with?("<svg", "<?xml") },
    emf: ->(bytes) { bytes.byteslice(0, 4) == "\x01\x00\x00\x00".b && bytes.byteslice(40, 4) == " EMF" },
    eps: ->(bytes) { bytes.start_with?("%!PS-Adobe") && bytes.include?("EPSF") },
    ps: ->(bytes) { bytes.start_with?("%!PS-Adobe") }
  }

  # Read in a separate process so this spec process never loads the converters.
  edges, = Open3.capture2(RbConfig.ruby, "-I#{File.join(root, "lib")}", "-e", <<~RUBY)
    require "claricle"
    registry = Claricle.const_get(:Registry)
    registry.formats.each do |from|
      registry.convert_targets_for(from).each { |to| puts "\#{from} \#{to}" }
    end
  RUBY
  edges = edges.lines.map { |line| line.split.map(&:to_sym) }
  edges.select! { |from, _| File.exist?(File.join(fixtures, "rect_and_line.#{from}")) }

  it "finds the edges and a signature check for every target" do
    expect(edges.size).to eq(12)
    expect(edges.map(&:last).uniq - signatures.keys).to be_empty
  end

  # One cold `claricle convert`; returns the output bytes after asserting exit 0.
  convert_cold = lambda do |source, to|
    Dir.mktmpdir("claricle-fresh") do |dir|
      out = File.join(dir, "out.#{to}")
      _, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I#{File.join(root, "lib")}", File.join(root, "exe", "claricle"),
        "convert", source, "--to", to.to_s, "--output", out
      )
      raise "exit #{status.exitstatus}: #{stderr}" unless status.exitstatus.zero?

      File.binread(out)
    end
  end

  edges.each do |from, to|
    it "converts #{from} to #{to}" do
      bytes = convert_cold.call(File.join(fixtures, "rect_and_line.#{from}"), to)

      expect(signatures.fetch(to).call(bytes)).to be(true), "unexpected #{to} output: #{bytes[0, 60].inspect}"
    end
  end

  # rect_and_line never touches Postsvg's UnknownOperator; an embedded raster
  # does. Keep these two: they are the only examples that fail on that bug.
  %i[eps ps].each do |to|
    it "converts an embedded raster svg to #{to}" do
      bytes = convert_cold.call(File.join(fixtures, "embedded_raster.svg"), to)

      expect(signatures.fetch(to).call(bytes)).to be(true), "unexpected #{to} output: #{bytes[0, 60].inspect}"
    end
  end
end
