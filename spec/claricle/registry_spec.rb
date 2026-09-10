# frozen_string_literal: true

require "English"

require_relative "../support/pdf_builder"

RSpec.describe "Claricle::Registry" do
  registry = Claricle.const_get(:Registry)
  base = Claricle.const_get(:Handlers).const_get(:Base)

  # Real subclasses, never doubles: the map derives from supported_formats,
  # so a double would prove nothing about the derivation.
  handler = lambda do |*formats|
    Class.new(base) { formats(*formats) }
  end

  # Item 01 asserted the registry shipped empty. Item 02 fills it, so the
  # replacement pins the exact set and its owning classes -- "every listed
  # class appears" would pass for any incomplete list, which is the one
  # failure mode that requiring from registry.rb cannot catch.
  describe "what ships registered" do
    it "lists exactly the handler classes it names" do
      handlers = Claricle.const_get(:Handlers)

      expect(registry.const_get(:HANDLER_CLASSES))
        .to eq([handlers.const_get(:Metafile), handlers.const_get(:Pdf),
                handlers.const_get(:Png), handlers.const_get(:Postscript),
                handlers.const_get(:Svg)])
    end

    it "exposes exactly the formats those handlers declare" do
      expect(registry.formats).to eq(%i[emf eps pdf png ps svg])
    end

    # Ownership, not membership: a format list alone would pass a handler
    # registered against the wrong class.
    it "maps each format to its owning handler" do
      handlers = Claricle.const_get(:Handlers)

      expect(registry.handler_for(:emf)).to be(handlers.const_get(:Metafile))
      expect(registry.handler_for(:eps)).to be(handlers.const_get(:Postscript))
      expect(registry.handler_for(:pdf)).to be(handlers.const_get(:Pdf))
      expect(registry.handler_for(:png)).to be(handlers.const_get(:Png))
      expect(registry.handler_for(:ps)).to be(handlers.const_get(:Postscript))
      expect(registry.handler_for(:svg)).to be(handlers.const_get(:Svg))
    end

    # Derived, so it cannot advertise an operation still on Base.
    it "reports only the capabilities each handler has implemented" do
      expect(registry.capabilities_for(:emf)).to eq([:inspect])
      expect(registry.capabilities_for(:eps)).to eq([:inspect])
      expect(registry.capabilities_for(:pdf)).to eq([:inspect])
      expect(registry.capabilities_for(:png)).to eq([:inspect])
      expect(registry.capabilities_for(:ps)).to eq([:inspect])
      expect(registry.capabilities_for(:svg)).to eq([:inspect])
    end
  end

  # stub_const restores a constant with const_set, which makes it public
  # again. Without this the privacy examples below would fail depending on
  # execution order rather than on the code.
  around do |example|
    example.run
  ensure
    registry.send(:private_constant, :HANDLERS)
  end

  describe "the derived map" do
    it "is frozen" do
      expect(registry.const_get(:HANDLERS)).to be_frozen
    end

    # On a locally built map: if the freeze regressed, mutating the real
    # one would contaminate every later example.
    it "refuses mutation" do
      map = registry.send(:build, [handler.call(:png)])
      expect { map[:svg] = base }.to raise_error(FrozenError)
    end

    # Through Registry.formats, not the raw hash: asserting map.keys.sort
    # would pass even if formats stopped sorting. Declared in reverse so
    # sorted output cannot pass by accident either.
    it "reports every declared format, sorted" do
      stub_const("#{registry}::HANDLERS", registry.send(:build, [handler.call(:svg, :png)]))
      expect(registry.formats).to eq(%i[png svg])
    end

    # Each key's exact owner: asserting only that the two differ would pass
    # with the owners swapped.
    it "routes each format to the class that declared it" do
      png = handler.call(:png)
      svg = handler.call(:svg, :svgz)
      stub_const("#{registry}::HANDLERS", registry.send(:build, [png, svg]))
      expect(registry.handler_for(:png)).to eq(png)
      expect(registry.handler_for(:svg)).to eq(svg)
      expect(registry.handler_for(:svgz)).to eq(svg)
      expect(registry.formats).to eq(%i[png svg svgz])
    end

    # One immutable owner per format, so a second claim is a defect rather
    # than a last-one-wins.
    it "refuses two handlers claiming the same format, naming both" do
      first = handler.call(:png)
      second = handler.call(:png)
      raised = nil
      begin
        registry.send(:build, [first, second])
      rescue Claricle::Error => e
        raised = e
      end
      expect(raised).to be_a(Claricle::Error)
      expect(raised.message).to include("duplicate handler for :png")
      expect(raised.message).to include(first.to_s).and include(second.to_s)
    end
  end

  describe "handler_for" do
    it "raises UnsupportedFormat naming the format" do
      expect { registry.handler_for(:wmf) }
        .to raise_error(Claricle::UnsupportedFormat, /format :wmf is not supported/)
    end

    it "raises something callers can rescue as Claricle::Error" do
      expect { registry.handler_for(:wmf) }.to raise_error(Claricle::Error)
    end
  end

  describe "UnsupportedFormat's message" do
    # Positional operation, per 01-core.md:21. Keyword-only would make a
    # caller following the settled contract raise ArgumentError, which the
    # runner maps to 4 instead of 3.
    it "builds each form exactly" do
      expect(Claricle::UnsupportedFormat.new(:wmf).message)
        .to eq("format :wmf is not supported")
      expect(Claricle::UnsupportedFormat.new(:wmf, :convert).message)
        .to eq("format :wmf is not supported for convert")
      expect(Claricle::UnsupportedFormat.new(:wmf, :convert, target: :svg).message)
        .to eq("format :wmf is not supported for convert to :svg")
    end

    # A target alone reads as nonsense -- "not supported to :svg" -- so it
    # is dropped rather than rendered.
    it "ignores a target given without an operation" do
      expect(Claricle::UnsupportedFormat.new(:wmf, target: :svg).message)
        .to eq("format :wmf is not supported")
    end

    # Supplied and absent are different things, and both falsey values
    # are supplied. Truthiness hid `false`; checking for nil then hid
    # `nil`, which is what a caller who forgot `--to` actually sends.
    it "names every supplied target and omits only an absent one" do
      expect(Claricle::UnsupportedFormat.new(:wmf, :convert, target: false).message)
        .to eq("format :wmf is not supported for convert to false")
      expect(Claricle::UnsupportedFormat.new(:wmf, :convert, target: nil).message)
        .to eq("format :wmf is not supported for convert to nil")
      expect(Claricle::UnsupportedFormat.new(:wmf, :convert).message)
        .to eq("format :wmf is not supported for convert")
    end
  end

  # The plan's claim is that registry.rb owns its dependencies, so there is
  # no require order for the entry point to get wrong. The suite cannot
  # check that -- spec_helper loads claricle, which pulls in errors first --
  # so these load each file alone in a fresh process.
  describe "loading a file on its own" do
    lib = File.expand_path("../../lib", __dir__)

    run = lambda do |script|
      output = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", script], err: %i[child out], &:read)
      [$CHILD_STATUS.success?, output]
    end

    it "loads registry.rb without the entry point" do
      ok, output = run.call('require "claricle/registry"; ' \
                            "print Claricle.const_get(:Registry).formats.inspect")
      expect(ok).to be(true), "subprocess failed: #{output}"
      expect(output).to eq("[:emf, :eps, :pdf, :png, :ps, :svg]")
    end

    it "loads the PostScript delegate only when an inspection needs it" do
      ok, output = run.call(<<~RUBY)
        require "claricle"
        before = Object.const_defined?(:Postscript, false)
        source = ["%!PS-Adobe-3.0", "%%BoundingBox: 0 0 100 50",
                  "%%EndComments"].join("\\n") + "\\n"
        image = Claricle::Image.from_content(source, format: :ps)
        after_image = Object.const_defined?(:Postscript, false)
        width = image.inspection.width
        after_inspection = Object.const_defined?(:Postscript, false)
        print [before, after_image, after_inspection, width].inspect
      RUBY

      expect(ok).to be(true), "subprocess failed: #{output}"
      expect(output).to eq("[false, false, true, 100.0]")
    end

    # The same shape for pdfrb. `require "pdfrb"` sits inside the
    # inspection path rather than at the top of the handler file, because
    # registry.rb requires every handler eagerly -- measured, best of 9
    # on a monotonic clock, a top-level require costs ~43 ms on every
    # `claricle version` and every `--help`, for a delegate most
    # invocations never touch.
    #
    # A constant probe rather than $LOADED_FEATURES: a constant cannot be
    # defined by a require that did not happen.
    it "loads the pdfrb delegate only when an inspection needs it" do
      pdf = PdfBuilder.path(name: "lazy")
      ok, output = run.call(<<~RUBY)
        require "claricle"
        before = Object.const_defined?(:Pdfrb, false)
        image = Claricle::Image.from_path(#{pdf.inspect})
        after_image = Object.const_defined?(:Pdfrb, false)
        pages = image.inspection.meta["pages"]
        print [before, after_image, Object.const_defined?(:Pdfrb, false), pages].inspect
      RUBY

      expect(ok).to be(true), "subprocess failed: #{output}"
      expect(output).to eq("[false, false, true, 1]")
    end

    it "loads handlers/base.rb without the entry point" do
      ok, output = run.call(<<~RUBY)
        require "claricle/handlers/base"
        base = Claricle.const_get(:Handlers).const_get(:Base)
        image = Struct.new(:format).new(:png)
        begin
          Class.new(base).new.inspection(image)
        rescue Claricle::UnsupportedFormat => e
          print e.message
        end
      RUBY
      expect(ok).to be(true), "subprocess failed: #{output}"
      expect(output).to eq("format :png is not supported for inspect")
    end

    # Privacy declared where each constant is defined, not only in the
    # entry point: this require path is supported, and it used to leave
    # these internals public until claricle.rb happened to run.
    it "ships them private when loaded on their own too" do
      ok, output = run.call(<<~RUBY)
        require "claricle/registry"
        require "claricle/handlers/base"
        probes = [
          -> { Claricle::Registry }, -> { Claricle::Handlers },
          -> { Claricle::Detector }, -> { Claricle::EpsHeader },
          -> { Claricle::ReservedNamespace }, -> { Claricle::AttributeDefaults },
          -> { Claricle::AttributeReferences }
        ]
        print(probes.map do |probe|
          probe.call
          "public"
        rescue NameError => e
          e.message.include?("private constant") ? "private" : "missing"
        end.join(","))
      RUBY
      expect(ok).to be(true), "subprocess failed: #{output}"
      expect(output).to eq((["private"] * 7).join(","))
    end

    # The privacy examples below cannot prove privacy on their own: the
    # around hook re-privatises HANDLERS after every example, so once one
    # example has run the suite has established what the code is supposed
    # to. A process that only requires the gem has no such help.
    it "ships every one of them private" do
      ok, output = run.call(<<~RUBY)
        require "claricle"
        probes = [
          -> { Claricle::Registry }, -> { Claricle::Handlers },
          -> { Claricle.const_get(:Registry)::HANDLERS },
          -> { Claricle.const_get(:Registry)::HANDLER_CLASSES },
          -> { Claricle.const_get(:Handlers)::Base }
        ]
        print(probes.map do |probe|
          probe.call
          "public"
        rescue NameError => e
          e.message.include?("private constant") ? "private" : "missing"
        end.join(","))
      RUBY
      expect(ok).to be(true), "subprocess failed: #{output}"
      expect(output).to eq((["private"] * 5).join(","))
    end
  end

  describe "visibility" do
    # Privacy is not transitive in Ruby: reaching the outer module must not
    # hand over what is nested inside it.
    it "keeps Registry and Handlers private" do
      expect { Claricle::Registry }.to raise_error(NameError, /private constant/)
      expect { Claricle::Handlers }.to raise_error(NameError, /private constant/)
    end

    it "keeps their nested constants private too" do
      expect { registry::HANDLERS }.to raise_error(NameError, /private constant/)
      expect { registry::HANDLER_CLASSES }.to raise_error(NameError, /private constant/)
      expect { Claricle.const_get(:Handlers)::Base }
        .to raise_error(NameError, /private constant/)
    end
  end
end
