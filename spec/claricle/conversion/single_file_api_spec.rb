# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# `Claricle.convert` is the issue's primary Ruby example. It must answer to
# the same write lifecycle as `convert_batch` -- these specs drive real
# conversions, so a divergence shows as a different file on disk.
RSpec.describe "Claricle.convert" do
  fixtures = File.expand_path("../../fixtures", __dir__)
  emf = File.join(fixtures, "convert/rect_and_line.emf")
  png = File.join(fixtures, "inspect/valid.png")
  eps = File.join(fixtures, "inspect/basic.eps")

  def workspace(*sources)
    Dir.mktmpdir do |dir|
      sources.each { |name, source| FileUtils.cp(source, File.join(dir, name)) }
      Dir.chdir(dir) { yield dir }
    end
  end

  it "writes the target beside the source and returns the one Conversion" do
    workspace(["diagram.emf", emf]) do
      conversion = Claricle.convert("diagram.emf", to: :svg)

      expect(conversion).to be_a(Claricle::Models::Conversion)
      expect(File.expand_path(conversion.output_path)).to eq(File.expand_path("diagram.svg"))
      expect(File.read("diagram.svg")).to start_with("<svg")
      expect(conversion.target_format).to eq("svg")
    end
  end

  it "writes to an explicit output, creating nothing beside the source" do
    workspace(["diagram.emf", emf]) do |dir|
      conversion = Claricle.convert("diagram.emf", output: "copy.svg")

      expect(conversion.output_path).to eq("copy.svg")
      expect(Dir.children(dir).sort).to eq(%w[copy.svg diagram.emf])
    end
  end

  it "writes the bytes to stdout for output: \"-\" and creates no file" do
    workspace(["diagram.emf", emf]) do |dir|
      conversion = nil
      expect { conversion = Claricle.convert("diagram.emf", to: :svg, output: "-") }
        .to output(/\A<svg/).to_stdout
      expect(conversion).to be_a(Claricle::Models::Conversion)
      expect(Dir.children(dir)).to eq(%w[diagram.emf])
    end
  end

  it "refuses to overwrite without force: and replaces with it" do
    workspace(["diagram.emf", emf]) do
      File.write("diagram.svg", "already here")

      expect { Claricle.convert("diagram.emf", to: :svg) }
        .to raise_error(Claricle::InvocationError, /output file exists/)
      expect(File.read("diagram.svg")).to eq("already here")

      Claricle.convert("diagram.emf", to: :svg, force: true)
      expect(File.read("diagram.svg")).to start_with("<svg")
    end
  end

  # A single file has no batch to carry a failure in, so the real exception
  # is raised -- the way `conform?` does -- rather than returned in an envelope.
  {
    "an unsupported target" => [{ png: "a.png" }, { to: :svg }, Claricle::UnsupportedFormat,
                                /:png is not supported for convert to :svg/],
    "its own format" => [{ eps: "a.eps" }, { to: :eps, output: "copy.eps" }, Claricle::InvocationError,
                         /already eps/],
    "no target at all" => [{ png: "a.png" }, {}, Claricle::InvocationError, /give --to, or an --output/]
  }.each do |label, (source, args, error, message)|
    it "raises the underlying #{error.name.split("::").last} for #{label}" do
      kind, name = source.first
      workspace([name, { png: png, eps: eps }.fetch(kind)]) do
        expect { Claricle.convert(name, **args) }.to raise_error(error, message)
      end
    end
  end

  it "refuses a pattern that names more than one file, before converting any" do
    workspace(["a.emf", emf], ["b.emf", emf]) do |dir|
      expect { Claricle.convert("*.emf", to: :svg) }
        .to raise_error(Claricle::InvocationError, /takes a single source; 2 files matched/)
      expect(Dir.children(dir).sort).to eq(%w[a.emf b.emf])
    end
  end

  it "raises when the source does not exist" do
    workspace do
      expect { Claricle.convert("missing.emf", to: :svg) }
        .to raise_error(Claricle::InvocationError, /no files matched/)
    end
  end
end
