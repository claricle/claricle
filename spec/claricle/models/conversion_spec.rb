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

    # Both fixtures carry an unmeasured element BESIDE proven ones, so the
    # empty-feature step cannot answer first and the element catch-all is the
    # guard under test. `path_and_rect` uses a bare `<path/>`: a `d=` attribute
    # would trip the attribute rule instead.
    #
    # Renamed from "cannot have its ignored-element list grow silently", which
    # this cannot show -- adding "path" to IGNORED reddens the constant pin
    # below, not this example.
    it "never waves through an element nobody has measured" do
      %w[text_rect_line path_and_rect].each do |name|
        expect(classify(name)).to eq("unknown"), "#{name} -> eps"
        expect(classify(name, to: :emf)).to eq("unknown"), "#{name} -> emf"
      end
    end

    it "pins the two elements that are deliberately ignored" do
      expect(classify("defs_container")).to eq("lossless")
    end

    # These three shipped with a README entry and no example. Measured: making
    # `content_feature` return nil for "style" -- the exact wrong behaviour the
    # README names -- left the whole suite green at 991/0 while
    # style_element_rect classified `lossless`.
    it "treats a style element as unmeasured, and comments and CDATA as marks-free" do
      expect(classify("style_element_rect")).to eq("unknown")
      expect(classify("comment_rect")).to eq("lossless")
      expect(classify("cdata_rect")).to eq("lossless")
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

    # text.svg is the one fixture shaped "an unmeasured element and NO proven
    # shape at all" -- text_rect_line carries a rect and a line -- so it is
    # exactly the document that must never come back lossless. It used to be
    # covered only by an `include` matcher over the vocabulary, which
    # "lossless" satisfies.
    it "never calls a document of only unmeasured elements lossless" do
      expect(classify("text")).to eq("unknown")
      expect(classify("text", to: :emf)).to eq("unknown")
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

      # The SETS, never their sizes: both happen to hold 14 and they overlap in
      # only 10, so `eq(14)` on each pins a coincidence -- swapping one member
      # of KNOWN_EVENTS for a non-event keeps the size and silently flips
      # comment_rect. Asserted against REXML's own predicate list so a grammar
      # change in the dependency reddens here.
      predicates = REXML::Parsers::PullEvent.instance_methods(false)
                                            .grep(/\?\z/)
                                            .map { |m| m.to_s.chomp("?").to_sym }
      expect(predicates - lossiness::KNOWN_EVENTS)
        .to contain_exactly(:doctype, :entity, :error, :instruction)
      expect(lossiness::KNOWN_EVENTS - predicates)
        .to contain_exactly(:start_doctype, :end_doctype,
                            :processing_instruction, :end_document)
    end

    # PullParser does not report an unclosed stack at EOF, so "REXML raised"
    # was not the whole of malformedness. Measured before the depth guard:
    # cutting 30 bytes off large_trailing_gradient.svg turned `lossy` into
    # `lossless` -- losing evidence made the verdict more confident.
    it "never grows more confident when the document is truncated" do
      expect(classify("large_trailing_gradient")).to eq("lossy")
      expect(classify("truncated_gradient")).to eq("unknown")
    end

    it "treats a nested svg viewport as a new, unmeasured context" do
      expect(classify("nested_svg_rect")).to eq("unknown")
    end

    # Named for the guard that actually answers. `second_root` trips the epilog
    # check before `visit_root` ever reaches its `@roots > 1` branch, so this
    # cannot isolate the second-root count -- that branch is deliberate
    # redundancy in the safe direction, not something this example pins.
    it "never calls content after the root closes lossless" do
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

    it "refuses a closed source the same way it refuses an unpositionable one" do
      # The block form closes the file and hands back the closed IO, which is
      # the object under test here.
      closed = File.open(path_for("rect_and_line"), "rb") { |io| io }
      expect { lossiness.classify(source_format: :svg, target_format: :eps, source: closed) }
        .to raise_error(Claricle::InvocationError, /not readable/)
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
    #
    # BasicObject, not Object, and that is the difference between watching a
    # route and closing it. Measured: an Object-based double still answers 52
    # methods without ever reaching method_missing, and
    # `instance_variable_get(:@io).read` hands back the real IO and reads all
    # 17,986 bytes. BasicObject removes 43 of those, so the permitted list
    # below is what the object answers rather than only what it intercepts.
    it "never repositions the IO it is given, and never reads it in one call" do
      permitted = %i[eof? external_encoding read readline nil? pos]
      restricted = Class.new(BasicObject) do
        attr_reader :largest_read

        define_method(:initialize) do |io|
          @io = io
          @largest_read = 0
        end
        define_method(:respond_to?) { |m, p = false| permitted.include?(m) && @io.respond_to?(m, p) }
        define_method(:method_missing) do |name, *args, &blk|
          # Bare `Kernel`/`String`, no `::` prefix: a `Class.new(BasicObject)
          # do ... end` body and its `define_method` blocks capture the
          # ENCLOSING lexical scope, so top-level constants resolve normally.
          # The `::` form is only needed under `class Foo < BasicObject`, which
          # opens a fresh constant scope. Measured both ways before deciding.
          Kernel.raise "forbidden IO call: #{name}" unless permitted.include?(name)
          Kernel.raise "unbounded read" if name == :read && args.empty?

          result = @io.public_send(name, *args, &blk)
          @largest_read = [@largest_read, result.bytesize].max if result.is_a?(String)
          result
        end
        define_method(:respond_to_missing?) { |*| false }
      end

      File.open(path_for("large_trailing_gradient"), "rb") do |io|
        wrapper = restricted.new(io)
        verdict = lossiness.classify(source_format: :svg, target_format: :eps,
                                     source: wrapper)
        expect(verdict).to eq("lossy")
        # The repositioning half is pinned by `permitted` above (seek, rewind
        # and pos= all raise, and to_str is absent so SourceFactory cannot
        # wrap the source in a StringIO). This pins the realistic slurp shape
        # -- one call returning the whole document -- rather than cumulative
        # bytes, which a streaming parse legitimately reads in full.
        expect(wrapper.largest_read).to be < File.size(path_for("large_trailing_gradient"))
      end
    end
  end
end
