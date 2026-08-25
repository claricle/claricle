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

    # `to:` is required, so a nil there is a caller who forgot their
    # target rather than one who has none. Hiding it left the error
    # naming the operation without saying what it was refused for.
    it "names a nil target rather than hiding it" do
      expect { handler.convert(image.new(:wmf), to: nil) }
        .to raise_error(Claricle::UnsupportedFormat,
                        "format :wmf is not supported for convert to nil")
    end

    # The format asked about, not the first one declared: a handler owning
    # two formats would otherwise name the wrong one whichever way it came.
    it "names the format it was actually asked about" do
      multi = Class.new(base) { formats :svg, :svgz }.new
      expect { multi.inspection(image.new(:svgz)) }
        .to raise_error(Claricle::UnsupportedFormat, /:svgz is not supported/)
    end
  end

  # The shape every handler needs when a parse did not get far enough to
  # report anything. Each of them was writing it out again.
  describe "#failed_inspection" do
    subject(:handler) do
      Class.new(base) do
        formats :wmf

        def inspection(image)
          failed_inspection(image, code: "wmf.header_unreadable",
                                   message: "WMF header could not be read")
        end
      end.new
    end

    it "reports the parse as failed, carrying the single error" do
      result = handler.inspection(image.new(:wmf))

      expect(result.parse_status).to eq("failed")
      expect(result.issues.map { |i| [i.severity, i.code, i.message] })
        .to eq([["error", "wmf.header_unreadable", "WMF header could not be read"]])
    end

    # The image's own format, not the first one the handler declared: a
    # handler owning :svg and :svgz must not report :svg for both.
    it "names the format of the image it was given" do
      multi = Class.new(base) do
        formats :svg, :svgz

        def inspection(image)
          failed_inspection(image, code: "c", message: "m")
        end
      end.new

      expect(multi.inspection(image.new(:svgz)).format).to eq("svgz")
    end

    # A failed parse claims nothing about the file's validity -- that is
    # conform's answer alone (D17) -- and it reports no dimensions it
    # never read.
    it "claims nothing it did not measure" do
      result = handler.inspection(image.new(:wmf))

      expect([result.width, result.height, result.dpi, result.color_space, result.meta])
        .to eq([nil, nil, nil, nil, nil])
    end

    it "returns a sealed inspection" do
      expect(handler.inspection(image.new(:wmf))).to be_frozen
    end

    # A helper for subclasses, not an operation a caller invokes.
    it "stays off the public surface" do
      expect(handler).not_to respond_to(:failed_inspection)
    end
  end
end
