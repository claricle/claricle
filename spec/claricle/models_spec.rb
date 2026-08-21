# frozen_string_literal: true

require "json"

RSpec.describe Claricle::Models do
  models = Claricle::Models
  issue = ->(severity, **rest) { models::Issue.new(severity: severity, message: "m", **rest) }

  describe "invariants at both doors" do
    it "rejects an invalid severity on construction" do
      expect { models::Issue.new(severity: "bogus", message: "m") }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    it "rejects an invalid severity on deserialization" do
      expect { models::Issue.from_json(%({"severity":"bogus","message":"m"})) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # severity was optional until a review caught it: an Issue with no
    # severity made a Report report itself valid, which is the worst
    # possible direction for that bug.
    it "rejects a missing severity at both doors" do
      expect { models::Issue.new(message: "corrupt") }
        .to raise_error(Lutaml::Model::ValidationError)
      expect { models::Issue.from_json(%({"message":"corrupt"})) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # Raising with bare strings makes lutaml's own error_messages blow up.
    it "raises errors that survive lutaml's error_messages" do
      raised = nil
      begin
        models::Issue.new(message: "m")
      rescue Lutaml::Model::ValidationError => e
        raised = e
      end
      expect(raised).to be_a(Lutaml::Model::ValidationError)
      expect(raised.error_messages).to all(be_a(String))
    end

    it "rejects a missing message at both doors" do
      expect { models::Issue.new(severity: "error") }
        .to raise_error(Lutaml::Model::ValidationError)
      expect { models::Issue.from_json(%({"severity":"error"})) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # Deserialization builds a blank instance first; the marker that defers
    # finalization is this library's own dynamic extent, so passing
    # lutaml-model's reserved keyword directly must not reach that path.
    it "still validates when handed lutaml-model's reserved keyword" do
      expect { models::Issue.new(lutaml_register: :default) }
        .to raise_error(Lutaml::Model::ValidationError)
    end
  end

  describe "nested validation" do
    # Report#validate! does not recurse, so the aggregate walks its own
    # children. Without that, this deserializes happily.
    it "rejects an invalid issue nested in a Report" do
      expect { models::Report.from_json(%({"issues":[{"severity":"nope","message":"m"}]})) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    it "rejects an invalid issue nested in an Inspection" do
      json = %({"format":"png","parse_status":"ok","issues":[{"severity":"nope","message":"m"}]})
      expect { models::Inspection.from_json(json) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # An invalid Issue cannot reach an aggregate's constructor, because it
    # cannot be built in the first place. That is the construction-side
    # guarantee; the deserialization cases above cover the other door.
    it "cannot build an invalid issue to nest in the first place" do
      expect { models::Issue.new(severity: "nope", message: "m") }
        .to raise_error(Lutaml::Model::ValidationError)
      expect(models::Report.new(issues: [issue["info"]]).issues.size).to eq(1)
    end
  end

  describe "the deferral marker" do
    it "is cleared after a successful deserialization" do
      models::Report.from_json(%({"source_path":"a"}))
      expect { models::Issue.new(severity: "bogus", message: "m") }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # Malformed input raises inside the deserialization call itself, so
    # this exercises the ensure. A validation failure would not -- that
    # happens after the marker is already restored.
    it "is restored when deserialization raises part-way through" do
      begin
        models::Report.from_json("{not json")
      rescue StandardError
        nil
      end
      expect { models::Issue.new(severity: "bogus", message: "m") }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # The thread-local key is guessable; the identity of the value is not.
    [true, [], "x"].each do |forged|
      it "cannot be deferred by parking #{forged.inspect} under the key" do
        Thread.current[:claricle_models_deserializing] = forged
        expect { models::Issue.new(severity: "bogus", message: "m") }
          .to raise_error(Lutaml::Model::ValidationError)
      ensure
        Thread.current[:claricle_models_deserializing] = nil
      end
    end

    # Deferral needs BOTH the extent and lutaml's blank-construction
    # signature. A caller building a model inside the extent passes real
    # attributes, so it validates immediately rather than slipping through.
    it "validates a model a caller builds during deserialization" do
      outcome = nil
      trigger = Class.new do
        define_method(:to_s) do
          outcome = begin
            Claricle::Models::Issue.new(severity: "bogus", message: "sneaky")
          rescue Lutaml::Model::ValidationError => e
            e
          end
          "info"
        end
      end
      models::Issue.from_hash({ "severity" => trigger.new, "message" => "m" })
      expect(outcome).to be_a(Lutaml::Model::ValidationError)
    end

    it "is cleaned up when deserialization raises part-way through" do
      boom = Class.new { def to_s = raise("boom") }
      expect { models::Issue.from_hash({ "severity" => boom.new, "message" => "m" }) }
        .to raise_error(RuntimeError)
      expect(Thread.current[:claricle_models_deserializing]).to be_nil
      expect { models::Issue.new(severity: "bogus", message: "m") }
        .to raise_error(Lutaml::Model::ValidationError)
    end
  end

  # A model attribute is only cast when it arrives as a hash from a
  # document. Handed a wrong-typed object directly, lutaml stores it and
  # the failure surfaces much later somewhere unrelated.
  describe "declared nested types" do
    it "rejects a wrong-typed member of a collection" do
      expect { models::Report.new(issues: [models::Location.new(byte_offset: 1)]) }
        .to raise_error(Lutaml::Model::ValidationError, /issues expects/)
    end

    it "rejects a wrong-typed single model attribute" do
      expect do
        models::Issue.new(severity: "info", message: "m",
                          location: models::Issue.new(severity: "info", message: "x"))
      end.to raise_error(Lutaml::Model::ValidationError, /location expects/)
    end

    # A nil collection member reaches recursion and dies as a NoMethodError
    # without an attribute name; a nil singular attribute is legitimate.
    it "rejects a nil collection member but allows a nil model attribute" do
      expect { models::Report.new(issues: [nil]) }
        .to raise_error(Lutaml::Model::ValidationError, /issues expects/)
      expect(models::Issue.new(severity: "info", message: "m").location).to be_nil
    end

    # A bare model where a collection is declared has the right type but
    # the wrong shape; without this it dies inside lutaml's method_missing
    # as "undefined method [] for nil".
    it "rejects a bare model where a collection is declared" do
      lone = models::Issue.new(severity: "info", message: "m")
      expect { models::Report.new(issues: lone) }
        .to raise_error(Lutaml::Model::ValidationError, /issues expects a collection/)
      expect { models::Report.from_json(%({"issues":{"severity":"info","message":"m"}})) }
        .to raise_error(Lutaml::Model::ValidationError, /issues expects a collection/)
    end

    it "still composes correctly typed models" do
      report = models::Report.new(
        issues: [models::Issue.new(severity: "info", message: "m",
                                   location: models::Location.new(chunk: "IDAT"))]
      )
      expect(report.issues.first.location.chunk).to eq("IDAT")
    end
  end

  # from_json parses and then delegates to `of`, so guarding `of` is what
  # covers every entry point rather than just the one.
  describe "the JSON and hash deserialization entry points" do
    it "validates through of_json as well as from_json" do
      expect(models::Issue.of_json({ "severity" => "info", "message" => "m" }).severity)
        .to eq("info")
      expect { models::Issue.of_json({ "severity" => "nope", "message" => "m" }) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # Three members, and the invalid one last: a single-element array
    # cannot catch finalization being applied to only the first.
    it "validates and freezes every member of a top-level array" do
      json = %([{"severity":"info","message":"a"},{"severity":"warning","message":"b"}])
      parsed = models::Issue.from_json(json)
      expect(parsed.map(&:severity)).to eq(%w[info warning])
      expect(parsed).to all(be_frozen)
      bad = %([{"severity":"info","message":"a"},{"severity":"nope","message":"b"}])
      expect { models::Issue.from_json(bad) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # Lutaml accepts a positional attributes Hash; narrowing initialize to
    # keywords alone would break that without any error at load time.
    it "accepts a positional attributes hash" do
      expect(models::Issue.new({ severity: "info", message: "m" }).severity).to eq("info")
      expect { models::Issue.new({ severity: "nope", message: "m" }) }
        .to raise_error(Lutaml::Model::ValidationError)
    end
  end

  # dup and clone(freeze: false) would otherwise hand back an unfrozen copy
  # that accepts an invalid reassignment.
  describe "copies" do
    subject(:original) { models::Issue.new(severity: "info", message: "m") }

    it "does not freeze the caller's issues array" do
      supplied = [models::Issue.new(severity: "info", message: "m")]
      report = models::Report.new(issues: supplied)
      expect { supplied << models::Issue.new(severity: "info", message: "m") }
        .not_to raise_error
      expect(report.issues).to be_frozen
    end

    # lutaml threads cyclic parent/root back-references through every
    # nested model. Dumping them made marshal_load finalize against a
    # half-restored graph, so an Issue lifted out of a deserialized Report
    # raised ValidationError -- while a directly-built Issue round-tripped
    # fine, which is why the example below never caught it.
    describe "a model nested inside a deserialized parent" do
      let(:parent) do
        models::Report.from_json(
          {
            format: "png", valid: false,
            issues: [{ severity: "error", message: "m",
                       location: { chunk: "IDAT", byte_offset: 33 } }]
          }.to_json
        )
      end

      it "round-trips once lifted out of its parent" do
        # Not named `issue`: that is a lambda local at describe scope, and
        # assigning it here would rebind it for every later example.
        nested = parent.issues.first
        restored = Marshal.load(Marshal.dump(nested))

        expect(restored.to_json).to eq(nested.to_json)
        expect(restored).to be_frozen
      end

      it "round-trips at the second level of nesting" do
        location = parent.issues.first.location
        restored = Marshal.load(Marshal.dump(location))

        expect(restored.to_json).to eq(location.to_json)
      end

      it "still round-trips the parent itself" do
        expect(Marshal.load(Marshal.dump(parent)).to_json).to eq(parent.to_json)
      end

      # The hierarchy is asserted positively, both links on both levels.
      # An earlier fix dropped lutaml's back-references from the dump: the
      # lifted case worked and every copied graph came back detached, and
      # the spec that replaced this one asserted only the lost parents --
      # an honest record of the wrong behaviour is still the wrong
      # behaviour. `_dump`/`_load` keep both.
      it "keeps every parent and root link through a whole-graph copy" do
        copy = Marshal.load(Marshal.dump(parent))
        nested = copy.issues.first

        expect(nested.lutaml_parent).to be(copy)
        expect(nested.lutaml_root).to be(copy)
        expect(nested.location.lutaml_parent).to be(nested)
        expect(nested.location.lutaml_root).to be(copy)
      end

      it "makes a lifted model the root of its own copy" do
        lifted = Marshal.load(Marshal.dump(parent.issues.first))

        expect(lifted.location.lutaml_parent).to be(lifted)
        expect(lifted.location.lutaml_root).to be(lifted)
      end

      # meta is free-form, so the payload nests Marshal rather than JSON.
      it "preserves Ruby values inside meta that JSON would flatten" do
        inspection = models::Inspection.new(
          format: "png", parse_status: "ok",
          meta: { "sym" => :a_symbol, "range" => (1..5) }
        )
        restored = Marshal.load(Marshal.dump(inspection))

        expect(restored.meta["sym"]).to eq(:a_symbol)
        expect(restored.meta["range"]).to eq(1..5)
      end

      # `1.0` and `Rational(1,1)` are both `== 1`, and a longer envelope
      # would be a different format wearing the right version number, so
      # the guard checks exact type and exact shape.
      [99, 1.0, Rational(1, 1)].each do |version|
        it "refuses a payload versioned #{version.inspect}" do
          payload = Marshal.dump([version, parent.to_hash])

          expect { models::Report._load(payload) }
            .to raise_error(TypeError, /unsupported Claricle marshal payload/)
        end
      end

      it "refuses an envelope carrying extra fields" do
        payload = Marshal.dump([1, parent.to_hash, "extra"])

        expect { models::Report._load(payload) }
          .to raise_error(TypeError, /unsupported Claricle marshal payload/)
      end

      # The payload carries attributes, not classes, so a subclass would
      # come back as its parent with its own attributes gone. Refused at
      # dump time rather than silently erased -- validation accepts
      # subclasses, so nothing else catches this.
      it "refuses to marshal a nested subclass rather than erasing it" do
        subclass = Class.new(models::Issue) { attribute :vendor_code, :string }
        nested = subclass.new(severity: "error", message: "m", vendor_code: "X1")
        report = models::Report.new(format: "png", issues: [nested])

        expect { Marshal.dump(report) }
          .to raise_error(TypeError, /was declared/)
      end

      # lutaml omits explicitly-empty values from `to_hash`, so a payload
      # built from it lost the difference between "absent" and "empty".
      it "keeps an explicitly empty hash rather than reloading it as nil" do
        inspection = models::Inspection.new(format: "png", parse_status: "ok", meta: {})

        expect(Marshal.load(Marshal.dump(inspection)).meta).to eq({})
      end

      it "keeps a present but empty nested model" do
        # Not named `issue`: that is a lambda local at describe scope and
        # assigning it here rebinds it for every later example. This file
        # has now caught me twice, which is the argument for `let`.
        with_location = models::Issue.new(severity: "info", message: "m",
                                          location: models::Location.new)

        expect(Marshal.load(Marshal.dump(with_location)).location).not_to be_nil
      end
    end

    # Marshal skips initialize, and @claricle_sealed survives the dump, so
    # a restored model would be mutable while claiming to be sealed.
    it "re-runs the lifecycle on an unmarshalled model" do
      restored = Marshal.load(Marshal.dump(original))
      expect(restored).to be_frozen
      expect { restored.severity = "bogus" }.to raise_error(FrozenError)
      expect(restored.severity).to eq(original.severity)
    end

    it "re-freezes a dup" do
      expect(original.dup).to be_frozen
      expect { original.dup.severity = "bogus" }.to raise_error(FrozenError)
    end

    it "re-freezes an explicitly unfrozen clone" do
      expect { original.clone(freeze: false).severity = "bogus" }
        .to raise_error(FrozenError)
    end
  end

  describe "empty collections" do
    # lutaml-model drops an empty collection from the document, and returns
    # nil rather than [] for an absent key. Both ends are forced.
    it "serializes Report and Inspection with an explicit empty issues array" do
      expect(models::Report.new(source_path: "a.png").to_json).to include(%("issues":[]))
      expect(models::Inspection.new(format: "png", parse_status: "ok").to_json)
        .to include(%("issues":[]))
    end

    it "normalizes an absent issues key to an empty array" do
      expect(models::Report.from_json(%({"source_path":"a"})).issues).to eq([])
      expect(models::Inspection.from_json(%({"format":"png","parse_status":"ok"})).issues)
        .to eq([])
    end

    it "normalizes a null issues key to an empty array" do
      expect(models::Report.from_json(%({"source_path":"a","issues":null})).issues).to eq([])
      null_inspection = %({"format":"png","parse_status":"ok","issues":null})
      expect(models::Inspection.from_json(null_inspection).issues).to eq([])
    end

    it "keeps a clean report valid after a round trip" do
      report = models::Report.new(source_path: "a.png")
      expect(models::Report.from_json(report.to_json).valid).to eq(:yes)
    end
  end

  describe "Report#valid" do
    it "is yes for no issues at all" do
      expect(models::Report.new.valid).to eq(:yes)
    end

    # Every permutation, not a chosen ordering. Pinning the decisive
    # severity to any one index -- first, last or middle -- leaves a
    # positional shortcut that passes the whole table.
    {
      yes: %w[info info],
      suspicious: %w[info warning info],
      no: %w[info error warning]
    }.each do |verdict, severities|
      severities.permutation.to_a.uniq.each do |ordering|
        it "is #{verdict} for #{ordering.join(" + ")}" do
          report = models::Report.new(issues: ordering.map { |s| issue[s] })
          expect(report.valid).to eq(verdict)
          # Parsed, not matched: a round trip alone proves nothing, since
          # the verdict is recomputed from issues on the way back in.
          expect(JSON.parse(report.to_json)["valid"]).to eq(verdict.to_s)
          expect(models::Report.from_json(report.to_json).valid).to eq(verdict)
        end
      end
    end

    # Permutations kill single-position shortcuts but not a bounded scan of
    # the first few entries. The decisive severity sits past that here.
    {
      suspicious: %w[info info info info warning],
      no: %w[info info info warning error]
    }.each do |verdict, severities|
      it "is #{verdict} when the decisive issue is the #{severities.size}th" do
        report = models::Report.new(issues: severities.map { |sev| issue[sev] })
        expect(report.valid).to eq(verdict)
        expect(JSON.parse(report.to_json)["valid"]).to eq(verdict.to_s)
      end
    end

    it "never downgrades on info alone" do
      expect(models::Report.new(issues: [issue["info"]]).valid).to eq(:yes)
    end

    it "is serialized, because batch consumers read result.valid" do
      expect(models::Report.new(issues: [issue["error"]]).to_json).to include(%("valid":"no"))
    end

    it "recomputes rather than trusting an incoming verdict" do
      lying = %({"source_path":"a","issues":[],"valid":"no"})
      reloaded = models::Report.from_json(lying)
      expect(reloaded.valid).to eq(:yes)
      # Serialized too: the getter alone would miss a retained value being
      # emitted again.
      expect(JSON.parse(reloaded.to_json)["valid"]).to eq("yes")
    end
  end

  describe "deep freeze" do
    subject(:report) do
      models::Report.new(
        issues: [issue["info", location: models::Location.new(byte_offset: 1, chunk: +"IDAT")]]
      )
    end

    it "refuses to grow the issues collection" do
      expect { report.issues << issue["info"] }.to raise_error(FrozenError)
    end

    it "refuses to reassign an issue attribute" do
      expect { report.issues.first.message = "x" }.to raise_error(FrozenError)
    end

    it "refuses to reassign a nested location attribute" do
      expect { report.issues.first.location.byte_offset = 9 }.to raise_error(FrozenError)
    end

    # Freezing a model leaves its Strings mutable, so the leaves are frozen
    # too -- otherwise the collection only looks immutable.
    it "refuses to mutate a message or a chunk in place" do
      expect { report.issues.first.message << "x" }.to raise_error(FrozenError)
      expect { report.issues.first.location.chunk << "x" }.to raise_error(FrozenError)
    end

    # using_default_for is public on lutaml. Flipping an entry on a frozen
    # model drops the attribute from the document, so a warning report
    # serializes "issues":null and reloads as clean.
    it "refuses to have its default bookkeeping flipped" do
      expect { report.issues.first.using_default_for(:severity) }
        .to raise_error(FrozenError)
      expect(report.to_json).to include(%("severity":"info"))
    end

    # An enum declared with values: is stored as a mutable Array behind a
    # String getter. Freezing what the getter returns leaves that array
    # writable, and a frozen report's verdict can still be changed.
    it "seals the array backing an enum attribute" do
      backing = report.issues.first.instance_variable_get(:@severity)
      expect(backing).to be_an(Array)
      expect { backing[0] = "error" }.to raise_error(FrozenError)
      expect { backing[0] << "x" }.to raise_error(FrozenError)
    end

    # Sealing tracks its own bookkeeping rather than trusting frozen?, so a
    # model frozen by someone else is not mistaken for a sealed one.
    it "does not treat an externally frozen model as sealed" do
      unsealed = models::Issue.allocate.freeze
      expect { models::Report.new(issues: [unsealed]) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    it "is idempotent, so an aggregate can seal members twice" do
      inner = models::Issue.new(severity: "info", message: "m")
      expect { models::Report.new(issues: [inner]) }.not_to raise_error
      expect { models::Inspection.new(format: "png", parse_status: "ok", issues: [inner]) }
        .not_to raise_error
    end

    # `new` copies a String attribute but from_hash aliases the caller's.
    it "does not freeze a string handed in through from_hash" do
      severity = +"info"
      loaded = models::Issue.from_hash({ "severity" => severity, "message" => +"m" })
      expect { severity << "x" }.not_to raise_error
      expect(loaded.severity).not_to equal(severity)
      expect(loaded.severity).to be_frozen
    end

    it "applies the same freeze after a round trip" do
      reloaded = models::Report.from_json(report.to_json)
      expect { reloaded.issues.first.message << "x" }.to raise_error(FrozenError)
      expect { reloaded.issues << issue["info"] }.to raise_error(FrozenError)
    end
  end

  describe "Inspection" do
    it "makes no validity claim" do
      inspection = models::Inspection.new(format: "png", parse_status: "ok")
      expect(inspection).not_to respond_to(:valid)
      expect(inspection.to_json).not_to include("valid")
    end

    it "rejects a missing parse_status at both doors" do
      expect { models::Inspection.new(format: "png") }
        .to raise_error(Lutaml::Model::ValidationError)
      expect { models::Inspection.from_json(%({"format":"png"})) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    it "rejects an invalid parse_status at both doors" do
      expect { models::Inspection.new(format: "png", parse_status: "maybe") }
        .to raise_error(Lutaml::Model::ValidationError)
      expect { models::Inspection.from_json(%({"format":"png","parse_status":"maybe"})) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    %w[ok failed].each do |status|
      it "accepts #{status} and round-trips it" do
        inspection = models::Inspection.new(format: "png", parse_status: status)
        expect(models::Inspection.from_json(inspection.to_json).parse_status).to eq(status)
      end
    end

    # vectory returns Integer for SVG and Float for EPS; D15 wants one type.
    it "normalizes dimensions to one numeric type" do
      from_integers = models::Inspection.new(format: "svg", parse_status: "ok",
                                             width: 800, height: 600, dpi: 96)
      from_floats = models::Inspection.new(format: "eps", parse_status: "ok",
                                           width: 800.0, height: 600.0, dpi: 96.0)
      # eql, not eq: eq considers 800 and 800.0 equal, so it would pass
      # against an implementation that kept the Integer.
      expect([from_integers.width, from_integers.height, from_integers.dpi])
        .to eql([800.0, 600.0, 96.0])
      expect(from_floats.width).to eql(from_integers.width)
    end

    # lutaml copies a declared attribute but shares what is nested inside a
    # free-form Hash. Descending into meta would freeze containers the
    # caller still holds, and 01-core.md:47 never asked us to.
    it "leaves free-form metadata alone" do
      inner = +"v"
      nested = [inner]
      models::Inspection.new(format: "png", parse_status: "ok", meta: { "a" => nested })
      expect { nested << "x" }.not_to raise_error
      expect { inner << "x" }.not_to raise_error
    end

    it "leaves dpi nullable" do
      expect(models::Inspection.new(format: "png", parse_status: "ok").dpi).to be_nil
    end
  end

  describe "Location" do
    it "round-trips a chunk and both ends of the byte range" do
      located = issue["error", location: models::Location.new(byte_offset: 33, byte_length: 4,
                                                              chunk: "IDAT")]
      reloaded = models::Issue.from_json(located.to_json).location
      expect([reloaded.byte_offset, reloaded.byte_length, reloaded.chunk])
        .to eq([33, 4, "IDAT"])
    end
  end

  # lutaml-model 0.8.19's `:hash` type is shaped for XML and treats three
  # key names as structure rather than data. `meta` is whatever a handler
  # read out of a file, and an SVG root legitimately carries `elements`
  # or `text` as an attribute name -- inspecting one crashed the CLI.
  describe "free-form meta" do
    {
      "a nested text key" => { "node" => { "text" => "hello", "lang" => "en" } },
      "an elements key" => { "elements" => { "width" => 1 } },
      "text as the only key" => { "text" => "hello" },
      "all three at once" => { "text" => "t", "elements" => { "w" => 1 },
                               "node" => { "text" => "x", "lang" => "en" } }
    }.each do |label, meta|
      it "stores #{label} exactly as given" do
        inspection = described_class.const_get(:Inspection)
                                    .new(format: "svg", parse_status: "ok", meta: meta)

        expect(inspection.meta).to eq(meta)
      end

      it "round-trips #{label} through JSON" do
        inspection = described_class.const_get(:Inspection)
                                    .new(format: "svg", parse_status: "ok", meta: meta)
        back = described_class.const_get(:Inspection).from_json(inspection.to_json)

        expect(back.meta).to eq(meta)
        expect(back.meta).to be_a(Hash)
      end
    end

    # The lutaml type wraps any Hash whose attribute type is not exactly
    # Type::Hash, so the reader has to unwrap. A caller asked for a Hash.
    it "hands back a Hash however the model was built" do
      built = described_class.const_get(:Inspection)
                             .new(format: "svg", parse_status: "ok", meta: { "a" => 1 })
      loaded = described_class.const_get(:Inspection).from_json(built.to_json)

      expect(built.meta).to be_a(Hash)
      expect(loaded.meta).to be_a(Hash)
    end
  end

  # lutaml accepts a list for a non-collection enum, stores it whole, and
  # returns only the first element -- so the extra values vanish between
  # construction and JSON with nothing to show for it.
  describe "enum cardinality" do
    it "refuses a list for Issue#severity" do
      expect do
        described_class.const_get(:Issue)
                       .new(severity: %w[info error], code: "c", message: "m")
      end.to raise_error(Lutaml::Model::ValidationError, /single value/)
    end

    it "refuses a list for Inspection#parse_status" do
      expect do
        described_class.const_get(:Inspection)
                       .new(format: "svg", parse_status: %w[ok failed])
      end.to raise_error(Lutaml::Model::ValidationError, /single value/)
    end

    # lutaml stores every enum value as an array internally, so the check
    # cannot key on shape alone -- these must still be accepted.
    it "still accepts a single value" do
      issue = described_class.const_get(:Issue)
                             .new(severity: "error", code: "c", message: "m")

      expect(issue.severity).to eq("error")
    end
  end
end
