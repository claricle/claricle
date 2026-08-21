# frozen_string_literal: true

RSpec.describe "Claricle::Handlers::Base" do
  base = Claricle.const_get(:Handlers).const_get(:Base)
  image = Struct.new(:format)

  describe "the formats declaration" do
    it "reads back what a subclass declared" do
      subclass = Class.new(base) { formats :png, :svg }
      expect(subclass.supported_formats).to eq(%i[png svg])
    end

    # The registry derives a frozen map at load, so a redeclaration would
    # leave handler and registry disagreeing about who owns a format.
    it "refuses a second declaration" do
      subclass = Class.new(base) { formats :png }

      expect { subclass.formats(:svg) }
        .to raise_error(Claricle::Error, /already declared formats \[:png\]/)
    end

    it "keeps the original declaration after a refused one" do
      subclass = Class.new(base) { formats :png }
      begin
        subclass.formats(:svg)
      rescue Claricle::Error
        nil
      end

      expect(subclass.supported_formats).to eq([:png])
    end

    it "does not leak to a sibling or to Base" do
      Class.new(base) { formats :png }
      sibling = Class.new(base)
      expect(sibling.supported_formats).to be_empty
      expect(base.supported_formats).to be_empty
    end

    it "freezes the declaration" do
      subclass = Class.new(base) { formats :png }
      expect(subclass.supported_formats).to be_frozen
    end

    # The registry keys its map on these and sorts the keys, so a String
    # among them is not a near miss: `Registry.formats` raises
    # `comparison of String with :svg failed`, and the Symbol the
    # detector produces misses the map entirely.
    it "refuses a non-Symbol declaration, naming the offender" do
      expect { Class.new(base) { formats "png", :svg } }
        .to raise_error(Claricle::Error, /non-Symbol formats \["png"\]/)
    end

    # Refused, not half-applied: the author fixes the typo and declares
    # again in the same class.
    it "declares nothing when the declaration is refused" do
      subclass = Class.new(base)
      begin
        subclass.formats("png")
      rescue Claricle::Error
        nil
      end

      expect(subclass.supported_formats).to be_empty
      expect { subclass.formats(:png) }.not_to raise_error
      expect(subclass.supported_formats).to eq([:png])
    end
  end

  # A handler that has not implemented an operation says which one, rather
  # than returning nil and failing somewhere else.
  describe "unimplemented operations" do
    subject(:handler) { Class.new(base) { formats :wmf }.new }

    it "names inspect" do
      expect { handler.inspection(image.new(:wmf)) }
        .to raise_error(Claricle::UnsupportedFormat, "format :wmf is not supported for inspect")
    end

    it "names conform" do
      expect { handler.conformance_report(image.new(:wmf)) }
        .to raise_error(Claricle::UnsupportedFormat, "format :wmf is not supported for conform")
    end

    it "names convert and its target" do
      expect { handler.convert(image.new(:wmf), to: :svg) }
        .to raise_error(Claricle::UnsupportedFormat,
                        "format :wmf is not supported for convert to :svg")
    end

    # The format asked about, not the first one declared: a handler owning
    # two formats would otherwise name the wrong one whichever way it came.
    it "names the format it was actually asked about" do
      multi = Class.new(base) { formats :svg, :svgz }.new
      expect { multi.inspection(image.new(:svgz)) }
        .to raise_error(Claricle::UnsupportedFormat, /:svgz is not supported/)
    end
  end
end
