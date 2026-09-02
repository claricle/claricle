# frozen_string_literal: true

require "stringio"
require "tempfile"

# Two subjects, one file: the model that carries a conversion result, and the
# classifier that decides its `lossiness`. They ship together because the
# vocabulary is shared -- `Conversion::LOSSINESS_LEVELS` is `Lossiness::LEVELS`.
RSpec.describe "conversion lossiness" do
  root = File.expand_path("../../..", __dir__)
  # `const_get`, because Lossiness is a private constant -- the same door
  # spec/claricle/registry_spec.rb:6 uses for Registry.
  lossiness = Claricle.const_get(:Lossiness)
  model = Claricle::Models::Conversion

  let(:fixtures) { File.join(root, "spec/fixtures/convert") }
  let(:emf_bytes) { File.binread(File.join(root, "spec/fixtures/detector/valid.emf")) }
  let(:eps_bytes) { File.binread(File.join(root, "spec/fixtures/inspect/basic.eps")) }

  # A `def`, not a `let`: it takes arguments, and `let` has no arity -- a block
  # parameter there receives the RSpec Example, not the argument.
  def path_for(name)
    File.join(File.expand_path("../../..", __dir__), "spec/fixtures/convert", "#{name}.svg")
  end

  def classify(name, to: :eps, from: :svg)
    Claricle.const_get(:Lossiness).classify(source_format: from, target_format: to,
                                            source: File.binread(path_for(name)))
  end

  def classify_io(name, to: :eps, from: :svg)
    File.open(path_for(name), "rb") do |io|
      Claricle.const_get(:Lossiness).classify(source_format: from, target_format: to, source: io)
    end
  end

  # `Claricle::Models::Conversion` spelled out, not the `model` local above: a
  # `def` body cannot see a describe-scope local, which is the same arity/scope
  # reason a helper taking arguments cannot be a `let`.
  def conversion(**attrs)
    defaults = { source_format: "svg", target_format: "eps", lossiness: "lossless" }
    Claricle::Models::Conversion.new(defaults.merge(attrs))
  end

  describe "the model" do
    it "keeps the output bytes out of every serialized representation" do
      subject = conversion(source_path: "a.svg", output_path: "a.eps", content: emf_bytes)
      keys = %w[source_path source_format target_format lossiness output_path]

      expect(JSON.parse(subject.to_json).keys).to match_array(keys)
      expect(YAML.safe_load(subject.to_yaml).keys).to match_array(keys)
      expect(subject.to_hash.keys).to match_array(keys)
    end

    it "carries binary target bytes back out unchanged" do
      subject = conversion(content: emf_bytes)

      expect(subject.content).to eq(emf_bytes)
      expect(subject.content.encoding).to eq(Encoding::BINARY)
      expect(subject.content.bytesize).to eq(364)
      expect { subject.to_json }.not_to raise_error
    end

    it "neither forces BINARY nor corrupts UTF-8 text content" do
      subject = conversion(content: "<svg/>")

      expect(subject.content).to eq("<svg/>")
      expect(subject.content.encoding).to eq(Encoding::UTF_8)
    end

    it "hands back frozen content and does not freeze or alias the caller's String" do
      caller_bytes = +"<svg/>"
      subject = conversion(content: caller_bytes)

      expect(subject.content).to be_frozen
      expect(caller_bytes).not_to be_frozen
      expect(subject.content).not_to equal(caller_bytes)
      caller_bytes << "mutated"
      expect(subject.content).to eq("<svg/>")
    end

    it "reads back the document it writes, and cannot be handed content through one" do
      subject = conversion(source_path: "a.svg", output_path: "a.eps", content: emf_bytes)
      reloaded = model.from_json(subject.to_json)

      expect(reloaded.source_path).to eq("a.svg")
      expect(reloaded.output_path).to eq("a.eps")
      expect(reloaded.lossiness).to eq("lossless")
      expect(reloaded.content).to be_nil

      injected = model.from_json(%({"source_format":"svg","target_format":"eps",
                                    "lossiness":"lossy","content":"zz"}))
      expect(injected.content).to be_nil
      expect(injected.target_format).to eq("eps")
    end

    it "refuses a lossiness outside the vocabulary at both doors" do
      expect { conversion(lossiness: "maybe") }
        .to raise_error(Lutaml::Model::ValidationError, /maybe/)
      expect { model.from_json(%({"source_format":"svg","target_format":"eps","lossiness":"maybe"})) }
        .to raise_error(Lutaml::Model::ValidationError, /maybe/)
    end

    it "represents a content-born, stdout-bound conversion" do
      subject = conversion(source_path: nil, output_path: nil)

      expect(JSON.parse(subject.to_json).keys)
        .to match_array(%w[source_format target_format lossiness])
    end

    it "refuses to omit what makes a conversion traceable" do
      %i[source_format target_format lossiness].each do |name|
        attrs = { source_format: "svg", target_format: "eps", lossiness: "lossless" }
        attrs.delete(name)

        expect { model.new(attrs) }
          .to raise_error(Lutaml::Model::ValidationError, /#{name}/),
              "expected a missing #{name} to be refused by name"
      end
    end

    it "publishes exactly the documented vocabulary, frozen" do
      expect(model::LOSSINESS_LEVELS).to eq(%w[lossless lossy unknown])
      expect(model::LOSSINESS_LEVELS).to be_frozen
    end
  end

  describe "the classifier" do
    it "never calls a target with no measured rule set lossless" do
      expect(classify("rect_and_line", to: :ps)).to eq("unknown")
    end

    it "never calls a source format it cannot inspect lossless" do
      # SVG bytes under a non-SVG declared format: the only shape that reaches
      # the source guard, since :svg is absent from RULES and the target branch
      # would otherwise answer first.
      svg = File.binread(path_for("rect_and_line"))
      %i[emf png].each do |declared|
        verdict = lossiness.classify(source_format: declared, target_format: :eps, source: svg)
        expect(verdict).to eq("unknown"), "expected #{declared} source to be unknown"
      end
    end

    it "reads an IO exactly as it reads a String" do
      %w[rect_and_line gradient_linear large_trailing_gradient].each do |name|
        expect(classify_io(name)).to eq(classify(name)), "String and IO disagreed on #{name}"
      end
    end

    it "calls a document lossless only when every feature present is proven kept" do
      expect(classify("rect_and_line")).to eq("lossless")
      expect(classify("rect_and_line", to: :emf)).to eq("lossless")
    end

    it "classifies each measured loss against its measured target" do
      table = {
        %w[gradient_linear] => { eps: "lossy", emf: "lossy" },
        %w[gradient_radial] => { eps: "lossy", emf: "lossy" },
        %w[clip_path_element] => { eps: "lossy", emf: "lossy" },
        %w[clip_path_attribute] => { eps: "lossy", emf: "lossy" },
        %w[embedded_raster] => { eps: "lossy", emf: "unknown" }
      }
      table.each do |(name), targets|
        targets.each do |target, want|
          expect(classify(name, to: target)).to eq(want), "#{name} -> #{target}"
        end
      end
    end

    it "never waves through an element nobody has measured" do
      expect(classify("text_rect_line")).to eq("unknown")
      expect(classify("text_rect_line", to: :emf)).to eq("unknown")
    end

    it "cannot have its ignored-element list grow silently" do
      expect(classify("path_and_rect")).to eq("unknown")
      expect(classify("path_and_rect", to: :emf)).to eq("unknown")
    end

    it "pins the two elements that are deliberately ignored" do
      expect(classify("defs_container")).to eq("lossless")
    end

    it "returns a verdict for an unreadable document rather than raising" do
      expect(classify("malformed")).to eq("unknown")
    end

    it "returns a verdict for an unusable declared encoding rather than raising" do
      expect(classify("bad_encoding")).to eq("unknown")
    end

    it "does not let a namespace prefix hide a loss" do
      expect(classify("prefixed_gradient")).to eq("lossy")
    end

    it "always returns a member of the documented vocabulary" do
      %w[rect_and_line gradient_linear text malformed empty_svg].each do |name|
        expect(model::LOSSINESS_LEVELS).to include(classify(name))
      end
    end

    it "pins every rule table against silent growth" do
      expect(lossiness::RULES).to eq(
        eps: { lost: %i[gradient clip_path embedded_raster], kept: %i[basic_shape] },
        emf: { lost: %i[gradient clip_path], kept: %i[basic_shape] }
      )
      expect(lossiness::ELEMENTS).to eq(
        "linearGradient" => :gradient, "radialGradient" => :gradient,
        "clipPath" => :clip_path, "image" => :embedded_raster,
        "rect" => :basic_shape, "line" => :basic_shape
      )
      expect(lossiness::IGNORED).to eq(%w[svg defs])
      expect(lossiness::ATTR_FEATURES).to eq("clip-path" => :clip_path)
      expect(lossiness::KEPT_FEATURES).to eq(lossiness::RULES.values.flat_map { _1[:kept] }.uniq)
    end

    it "reads the whole document rather than a bounded prefix" do
      expect(File.size(path_for("large_trailing_gradient"))).to be > 8192
      expect(classify("large_trailing_gradient")).to eq("lossy")
    end

    it "never calls a document with nothing in it lossless" do
      %w[empty_svg empty_defs].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end
      ["", "   \n  ", "<!-- hi -->"].each do |raw|
        verdict = lossiness.classify(source_format: :svg, target_format: :eps, source: raw)
        expect(verdict).to eq("unknown"), "#{raw.inspect} should be unknown"
      end
    end

    it "never calls a non-SVG root lossless, even carrying real shapes" do
      expect(classify("defs_root_svg_ns")).to eq("unknown")
    end

    it "never waves through an attribute nobody has proven harmless" do
      expect(classify("opacity_rect")).to eq("unknown")
      expect(classify("opacity_rect", to: :emf)).to eq("unknown")
    end

    it "reads attributes on elements whose own contribution is ignored" do
      expect(classify("root_style_rect")).to eq("unknown")
    end

    it "never mistakes a foreign-namespace element for a proven-kept shape" do
      expect(classify("foreign_namespace_rect")).to eq("unknown")
      expect(classify("foreign_default_ns_rect")).to eq("unknown")
      expect(classify("no_namespace_rect")).to eq("unknown")
      expect(classify("nested_foreign_ns_rect")).to eq("unknown")
      expect(classify("redundant_svg_ns_rect")).to eq("lossless")
    end

    it "runs the prefix test before the ignored-element skip" do
      expect(classify("foreign_prefixed_defs")).to eq("unknown")
    end

    it "never calls a document whose DTD can hide markup lossless" do
      %w[entity_gradient attlist_default_opacity public_doctype_attlist
         public_doctype_rect system_dtd_rect external_entity_ref].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end
      expect(classify("bare_doctype_rect")).to eq("lossless")
    end

    it "never waves through a processing instruction" do
      expect(classify("stylesheet_pi_rect")).to eq("unknown")
      expect(classify("other_pi_rect")).to eq("unknown")
      expect(classify("xmldecl_rect")).to eq("lossless")
    end

    it "allows xml:space only because a text-bearing element is separately unclassified" do
      expect(classify("xml_space_rect")).to eq("lossless")
      expect(classify("xml_space_text")).to eq("unknown")
    end

    it "does not let a non-xml prefixed attribute through the xml: allowance" do
      expect(classify("foreign_prefixed_attr")).to eq("unknown")
    end

    it "never calls a source it cannot decode lossless" do
      expect(classify("utf16_gradient")).to eq("unknown")
    end

    it "permits an absent paint attribute and refuses an unproven one" do
      expect(classify("no_paint_rect")).to eq("lossless")
      expect(classify("paint_none_rect")).to eq("unknown")
    end

    it "proves paint by value, on both paint attributes" do
      expect(classify("paint_rgb_rect")).to eq("lossless")
      %w[paint_url_rect paint_transparent_rect paint_named_rect
         paint_stroke_url_rect].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end
    end

    it "proves geometry by value, across the whole geometry-name set" do
      expect(classify("geom_px_rect")).to eq("lossless")
      expect(classify("geom_viewbox_rect")).to eq("lossless")
      %w[geom_percent_rect geom_em_rect geom_mm_rect geom_calc_rect
         geom_height_percent geom_y1_percent].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} should be unknown"
      end
    end

    it "never waves through an event type it does not recognise" do
      expect(classify("external_entity_ref")).to eq("unknown")
      # the union basis: 14 predicates + 3 emitted types that have none
      predicates = REXML::Parsers::PullEvent.instance_methods(false).grep(/\?\z/)
      expect(predicates.size).to eq(14)
      expect(lossiness::KNOWN_EVENTS.size).to eq(14)
    end

    it "never calls a second root or epilog content lossless" do
      expect(classify("second_root")).to eq("unknown")
      expect(classify("epilog_content")).to eq("unknown")
    end

    it "treats absent root dimensions as it treats a relative one" do
      expect(classify("no_root_dimensions")).to eq("unknown")
      expect(classify("rect_and_line")).to eq("lossless")
    end

    it "refuses a source whose position cannot be observed" do
      reader, writer = IO.pipe
      writer.write(File.binread(path_for("rect_and_line")))
      writer.close
      expect { lossiness.classify(source_format: :svg, target_format: :eps, source: reader) }
        .to raise_error(Claricle::InvocationError, /position/)
    ensure
      reader&.close
    end

    it "refuses a source that has already been partly consumed" do
      File.open(path_for("attlist_default_opacity"), "rb") do |io|
        io.seek(io.read.index("<svg"))
        expect { lossiness.classify(source_format: :svg, target_format: :eps, source: io) }
          .to raise_error(Claricle::InvocationError, /byte 0/)
      end
    end

    # Interface restriction, not a mutation: a mutant explores the neighbourhood
    # of the code we wrote and cannot express "reads the whole thing by another
    # route", because that is a different implementation rather than a mutation
    # of ours. So the seam is handed an object that answers ONLY what the design
    # is permitted to call, and anything else raises.
    #
    # The permitted set is measured, not guessed. REXML::SourceFactory.create_from
    # (rexml-3.4.4/lib/rexml/source.rb:42-53) dispatches on read, readline, nil?
    # and eof?, and IOSource then uses external_encoding; `pos` is ours, for the
    # byte-0 guard. Reproduce the parser's own calls with:
    #   ruby -rrexml/parsers/pullparser -e 'wrap an IO in a method_missing spy,
    #     parse, print the calls'  # => eof?, external_encoding, read(Integer),
    #                              #    readline(String)
    #
    # `to_str` is deliberately ABSENT: SourceFactory would use it to slurp the
    # whole source into a StringIO, which is exactly the access pattern the
    # `source:` seam exists to avoid.
    it "never slurps or repositions the IO it is given" do
      permitted = %i[eof? external_encoding read readline nil? pos]
      restricted = Class.new do
        define_method(:initialize) { |io| @io = io }
        define_method(:respond_to?) { |m, p = false| permitted.include?(m) && @io.respond_to?(m, p) }
        define_method(:method_missing) do |name, *args, &blk|
          unless permitted.include?(name)
            raise "forbidden IO call: #{name}"
          end
          raise "unbounded read" if name == :read && args.empty?

          @io.public_send(name, *args, &blk)
        end
        define_method(:respond_to_missing?) { |m, p = false| permitted.include?(m) && @io.respond_to?(m, p) }
      end

      File.open(path_for("gradient_linear"), "rb") do |io|
        verdict = lossiness.classify(source_format: :svg, target_format: :eps,
                                     source: restricted.new(io))
        expect(verdict).to eq("lossy")
      end
    end
  end
end
