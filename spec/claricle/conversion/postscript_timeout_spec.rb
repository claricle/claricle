# frozen_string_literal: true

RSpec.describe "PostScript conversion deadline" do
  handlers = Claricle.const_get(:Handlers, false)
  postscript_convert = handlers.const_get(:PostscriptConvert, false)

  around do |example|
    example.run
  ensure
    if postscript_convert.const_defined?(:DEADLINE_SECONDS)
      postscript_convert.send(:private_constant, :DEADLINE_SECONDS)
    end
  end

  it "turns a malformed-input parser hang into a conversion error" do
    stub_const("#{postscript_convert}::DEADLINE_SECONDS", 0.05)
    path = File.expand_path("../../fixtures/convert/rect_and_line.ps", __dir__)
    content = File.binread(path).sub("grestore\nshowpage", "grestor)\nshowpage")
    image = Claricle::Image.from_content(content, format: :ps)

    expect { Timeout.timeout(1) { image.convert(to: :svg) } }
      .to raise_error(Claricle::ConversionError, /within 0\.05 seconds/)
  end

  it "still converts a valid PostScript program" do
    path = File.expand_path("../../fixtures/convert/rect_and_line.ps", __dir__)

    conversion = Claricle::Image.from_path(path).convert(to: :svg)

    expect(conversion.target_format).to eq("svg")
    expect(conversion.content).to include("<svg")
  end
end
