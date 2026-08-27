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

    # The example above only reaches lutaml's own required-attribute
    # error, so it says nothing about the errors this library raises
    # itself. Every one of those goes through `Base#refuse`, and handing
    # that a bare String would leave the whole suite green while
    # `error_messages` blew up with NoMethodError.
    it "raises its own errors so they survive error_messages too" do
      [-> { models::Issue.new(severity: %w[info error], message: "m") },
       -> { models::Location.new(byte_offset: -1) },
       -> { models::Inspection.new(parse_status: "ok", width: Float::NAN) },
       -> { models::Inspection.new(parse_status: "ok", meta: { "r" => Float::INFINITY }) },
       -> { models::Inspection.new(parse_status: "ok", meta: { "r" => "\xFF".b }) },
       -> { models::Report.new(issues: [42]) },
       -> { models::Report.new(issues: models::Issue.new(severity: "info", message: "m")) }]
        .each do |build|
          raised = begin
            build.call
            nil
          rescue Lutaml::Model::ValidationError => e
            e
          end
          expect(raised).to be_a(Lutaml::Model::ValidationError)
          expect(raised.error_messages).to all(be_a(String))
        end
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
    # The thread-local itself, not a follow-up construction: a model built
    # with real attributes finalizes whether the marker leaked or not, so
    # it cannot tell the two apart. Only the blank signature can, and that
    # is what the ensure protects.
    it "is cleared after a successful deserialization" do
      models::Report.from_json(%({"source_path":"a"}))

      expect(Thread.current[:claricle_models_deserializing]).to be_nil
      expect { models::Issue.new(lutaml_register: :default) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # Malformed input fails inside the adapter, before `Base.of` sets the
    # marker at all -- so this covers the path that never reaches the
    # ensure. The example below covers the one that does.
    it "leaves no marker behind when parsing fails" do
      expect { models::Report.from_json("{not json") }
        .to raise_error(Lutaml::Model::InvalidFormatError)

      expect(Thread.current[:claricle_models_deserializing]).to be_nil
      expect { models::Issue.new(lutaml_register: :default) }
        .to raise_error(Lutaml::Model::ValidationError)
    end

    # Neither the key nor the stored value is secret -- it is literally
    # `true`. The protection is that deferral needs the marker AND
    # lutaml's blank signature together, so parking a value under the key
    # does nothing to ordinary construction.
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
      json = %([{"severity":"info","message":"a"},{"severity":"warning","message":"b"},) +
             %({"severity":"error","message":"c"}])
      parsed = models::Issue.from_json(json)
      expect(parsed.map(&:severity)).to eq(%w[info warning error])
      expect(parsed).to all(be_frozen)
      bad = %([{"severity":"info","message":"a"},{"severity":"warning","message":"b"},) +
            %({"severity":"nope","message":"c"}])
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

    # Ruby's default Marshal writes the ivars into a fresh object and runs
    # neither the constructor nor the lifecycle -- measured: the copy came
    # back unfrozen, took `severity = "bogus"` past the enum, and rendered
    # it. Nothing in this gem crosses a process boundary, so the dump is
    # refused rather than reimplemented.
    describe "marshalling" do
      # One valid instance of each model, so the loop below asserts the
      # refusal rather than a constructor that never ran.
      built = {
        Issue: -> { issue.call("info") },
        Report: -> { models::Report.new(format: "png") },
        Location: -> { models::Location.new },
        Inspection: -> { models::Inspection.new(format: "png", parse_status: "ok") }
      }.freeze

      # Every class, not just the one Base is written on: the refusal is
      # inherited, and a subclass that quietly regained a dump would be
      # the whole hole back.
      %i[Issue Report Location Inspection].each do |name|
        it "refuses to dump #{name}" do
          expect { Marshal.dump(built.fetch(name).call) }
            .to raise_error(TypeError, /cannot marshal Claricle::Models::#{name}/)
        end
      end

      # A model reached indirectly is written by Ruby rather than by any
      # code of ours, so the refusal has to be on the hook Ruby itself
      # calls. Measured: it is.
      it "refuses a model nested inside a plain container" do
        expect { Marshal.dump({ "a" => [issue.call("info")] }) }
          .to raise_error(TypeError, /Claricle models are not marshalable/)
      end

      # The one place a model can reach Marshal without a caller naming
      # it: `meta` holds whatever a handler attached, and `meta` is
      # public. Dumped through the Inspection this passes on the OUTER
      # refusal and says nothing about the Issue inside, so it goes
      # through the Hash the reader hands back and names the class the
      # refusal has to come from.
      it "refuses a model a caller reaches through meta" do
        held = models::Inspection.new(format: "svg", parse_status: "ok",
                                      meta: { "held" => issue.call("info") })

        expect { Marshal.dump(held.meta) }
          .to raise_error(TypeError, /cannot marshal Claricle::Models::Issue/)
      end

      # Ruby prefers `marshal_dump` over `_dump` where both exist, so a
      # `marshal_dump` added later would silently displace the refusal.
      # Neither hook may exist, public or private.
      it "defines neither marshal hook that would displace the refusal" do
        %i[marshal_dump marshal_load].each do |hook|
          expect(models::Issue.method_defined?(hook)).to be(false)
          expect(models::Issue.private_method_defined?(hook)).to be(false)
        end
      end

      # `_dump` is Ruby's hook, not the model's API. Marshal reaches it
      # privately -- measured -- so publishing it buys nothing.
      it "keeps _dump off the public surface" do
        expect(original).not_to respond_to(:_dump)
        expect(models::Issue.private_method_defined?(:_dump)).to be(true)
      end
    end

    it "re-freezes a dup" do
      expect(original.dup).to be_frozen
      expect { original.dup.severity = "bogus" }.to raise_error(FrozenError)
    end

    # `be_frozen` on the clone itself, because the assignment alone proves
    # less than it looks: it raises on the shallow-copied and already
    # frozen @using_default before it ever reaches the object.
    it "re-freezes an explicitly unfrozen clone" do
      copy = original.clone(freeze: false)

      expect(copy).to be_frozen
      expect { copy.severity = "bogus" }.to raise_error(FrozenError)
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

    # using_default_for is public on lutaml. Flipping an entry drops that
    # attribute from the document -- measured: mark every one of an
    # issue's fields and a warning report serializes "issues":null and
    # reloads valid.
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

    # A fully populated Issue that someone else froze without ever calling
    # finalize. A bare `allocate.freeze` will not do: validation rejects an
    # empty model long before seal is reached.
    let(:externally_frozen) do
      template = models::Issue.new(severity: "info", message: "m")
      copy = models::Issue.allocate
      template.instance_variables.each do |name|
        next if name == :@claricle_sealed

        copy.instance_variable_set(name, template.instance_variable_get(name))
      end
      copy.freeze
    end

    # Sealing tracks its own bookkeeping rather than trusting frozen?, so a
    # model frozen by someone else is not mistaken for a sealed one: seal
    # is reached and dies partway through, where a `frozen?` check would
    # have waved it past as already sealed.
    it "does not treat an externally frozen model as sealed" do
      expect { models::Report.new(issues: [externally_frozen]) }
        .to raise_error(FrozenError)
    end

    # The block form of `new` hands the caller the model before finalize
    # runs, so a failed seal leaves a real object in their hands. It must
    # not claim to be sealed: with the marker set before the children, that
    # Report stayed mutable, kept taking issues, and `seal` returned at the
    # marker forever after instead of trying again.
    it "does not call itself sealed when a child refuses" do
      retained = nil
      expect { models::Report.new(issues: [externally_frozen]) { |r| retained = r } }
        .to raise_error(FrozenError)

      expect(retained.instance_variable_get(:@claricle_sealed)).to be_falsey
      expect { retained.send(:seal) }.to raise_error(FrozenError)
    end

    # `seal` freezes without revalidating -- that is what recursion needs
    # it to do, since a child's own `finalize` already validated it. Public,
    # a caller holding a model retained from a failed construction could
    # mutate it into any shape and freeze it straight past validation:
    # measured, a retained Issue set to `severity: "bogus"` sealed cleanly
    # and serialized. Protected closes that without touching recursion,
    # which calls `seal` on a sibling instance from inside `seal` itself.
    it "refuses to freeze a poisoned, retained model through the public surface" do
      retained = nil
      expect { models::Report.new(issues: [externally_frozen]) { |r| retained = r } }
        .to raise_error(FrozenError)

      # Fix up what made construction fail, then poison a real attribute --
      # a caller doing this and calling the old public `seal` used to freeze
      # the object with no revalidation in between.
      retained.issues = []
      retained.instance_variable_set(:@source_path, 42)
      expect { retained.seal }.to raise_error(NoMethodError, /protected method/)
      expect(retained).not_to be_frozen
    end

    # `using_default_for` is public lutaml plumbing, meant for its own
    # deserializer. Called by a caller instead -- reachable through the
    # block form of `new`, before finalize runs -- it flips a REQUIRED
    # attribute to "using its default" while the attribute still holds
    # the value it was given. Rendering skips whatever is marked default,
    # so the value survives the reader and vanishes from the document:
    # measured, `to_json` rendered `{"message":"m"}` for an Issue whose
    # `severity` still read back "info", and reloading that JSON raised
    # `ValidationError: Missing required attribute: severity`.
    it "refuses to seal a required attribute flagged as using its default" do
      expect do
        models::Issue.new(severity: "info", message: "m") { |i| i.using_default_for(:severity) }
      end.to raise_error(Lutaml::Model::ValidationError, /severity expects recorded as explicitly set/)
    end

    # The same flip on an OPTIONAL attribute is not a schema violation --
    # `validate!` has nothing required to reject -- so it sealed and
    # rendered silently before this check covered every attribute, not
    # only required ones. Measured: `Report#source_path`, `#format`, and
    # `Issue#code` all round-tripped to nil having read back their real
    # value right up to the freeze.
    it "refuses to seal an optional attribute flagged as using its default" do
      expect do
        models::Report.new(source_path: "x") { |r| r.using_default_for(:source_path) }
      end.to raise_error(Lutaml::Model::ValidationError, /source_path expects recorded as explicitly set/)
    end

    it "still accepts an optional attribute legitimately left at its default" do
      expect(models::Issue.new(severity: "info", message: "m").code).to be_nil
    end

    it "still accepts an optional collection attribute legitimately left empty" do
      expect(models::Report.new(source_path: "x").issues).to eq([])
    end

    # `init_deserialization_state`/`finalize_deserialization` are public
    # lutaml plumbing for its own XML allocation path -- unused here,
    # since no model declares an `xml` block -- that resets every
    # attribute to a shared sentinel. Reachable from the block form of
    # `new`, they wiped a Report's `source_path` and its whole `issues`
    # collection down to an empty Array with no error, and the model
    # sealed reporting `valid: :yes` over an issue the caller had
    # actually supplied. No value-based check can tell that apart from a
    # Report the caller genuinely built empty, so both methods are
    # private instead.
    %i[init_deserialization_state finalize_deserialization].each do |method_name|
      it "keeps #{method_name} off the public surface" do
        report = models::Report.new(source_path: "x", issues: [issue["error"]])

        expect(report).not_to respond_to(method_name)
        expect { report.public_send(method_name, :default) }
          .to raise_error(NoMethodError, /private method/)
      end
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

    # lutaml copies a declared attribute but shares what is nested inside
    # a free-form Hash, so the model seals a copy of that graph rather
    # than the graph itself. Both halves, because either one alone is a
    # defect: the handler keeps its own objects writable, and the write
    # does not reach the inspection.
    it "seals its own copy of free-form metadata, not the caller's" do
      inner = +"v"
      nested = [inner]
      inspection = models::Inspection.new(format: "png", parse_status: "ok",
                                          meta: { "a" => nested })

      expect { nested << "x" }.not_to raise_error
      expect { inner << "x" }.not_to raise_error
      expect(inspection.meta).to eq({ "a" => ["v"] })
    end

    it "leaves dpi nullable" do
      expect(models::Inspection.new(format: "png", parse_status: "ok").dpi).to be_nil
    end

    # JSON has neither Infinity nor NaN. lutaml took both, the lifecycle
    # froze the model around them, and the to_json that followed raised
    # JSON::GeneratorError -- so a document that parsed could not be
    # written back out. All three dimensions, and both doors.
    it "refuses a dimension JSON could not write back out" do
      expect { models::Inspection.from_json(%({"parse_status":"ok","width":1e400})) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /width expects a finite number, got Infinity/)
      expect { models::Inspection.new(parse_status: "ok", height: Float::NAN) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /height expects a finite number, got NaN/)
      expect { models::Inspection.new(parse_status: "ok", dpi: -Float::INFINITY) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /dpi expects a finite number, got -Infinity/)
    end

    # The guard keys on finiteness, not on the value being unusual: 0.0
    # and a huge-but-finite dimension both stay legal and both serialize.
    it "still accepts every finite dimension" do
      wide = models::Inspection.new(parse_status: "ok", width: 0.0, height: 1e308)

      expect([wide.width, wide.height]).to eql([0.0, 1e308])
      expect(models::Inspection.from_json(wide.to_json).height).to eql(1e308)
    end
  end

  describe "Location" do
    # lutaml coerces the type and never looks at the value, so both ends
    # of a zero-based half-open range came back negative from a document.
    it "refuses a negative byte range at both doors" do
      expect { models::Location.new(byte_offset: -1) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /byte_offset expects a non-negative integer, got -1/)
      expect { models::Location.from_json(%({"byte_length":-4})) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /byte_length expects a non-negative integer, got -4/)
    end

    # A line and a column are counts into a document, so they are no more
    # negative than the byte range is. Checking only the two the comment
    # names would have left the other half of the model open.
    it "refuses a negative line or column too" do
      expect { models::Location.new(line: -5) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /line expects a non-negative integer, got -5/)
      expect { models::Location.from_json(%({"column":-2})) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /column expects a non-negative integer, got -2/)
    end

    # lutaml casts an integer attribute before anything can look at the
    # value, and the cast is lossy in five measured directions. The
    # non-negative check used to run on the RESULT, so each of these
    # sealed and rendered a position the caller never gave.
    {
      "-0.5" => -0.5, "1.5" => 1.5, "true" => true, "false" => false,
      %("3") => "3"
    }.each do |shown, value|
      it "refuses #{shown}, which lutaml would have made a legal position" do
        expect { models::Location.new(byte_offset: value) }
          .to raise_error(Lutaml::Model::ValidationError,
                          /byte_offset expects a non-negative integer, got #{Regexp.escape(shown)}/)
      end
    end

    # The same five from a document, because deserialization runs its own
    # cast and that is where `{"byte_offset":-0.5}` was measured
    # rendering back out as 0.
    it "refuses the same coercions arriving from a document" do
      ["-0.5", "1.5", "true", "false", %("3")].each do |literal|
        expect { models::Location.from_json(%({"byte_offset":#{literal}})) }
          .to raise_error(Lutaml::Model::ValidationError,
                          /byte_offset expects a non-negative integer/)
      end
    end

    # Nested, because that is the shape the corrupted position survived
    # in: the aggregate validated, sealed, and rendered it.
    it "refuses a coerced position nested in a report" do
      json = %({"issues":[{"severity":"error","message":"m",) +
             %("location":{"byte_offset":-0.5}}]})
      expect { models::Report.from_json(json) }
        .to raise_error(Lutaml::Model::ValidationError,
                        /byte_offset expects a non-negative integer, got -0.5/)
    end

    # The declared type exists to stop the cast, so it must still let a
    # legal position through untouched at both doors.
    it "still round-trips a legal position as an Integer" do
      built = models::Location.new(byte_offset: 33, byte_length: 4, line: 2, column: 9)

      expect(built.byte_offset).to eql(33)
      expect(models::Location.from_json(built.to_json).to_json).to eq(built.to_json)
    end

    # Only the private validation reads it, and it is not vocabulary a
    # caller ever names -- unlike SEVERITIES and PARSE_STATUSES, which
    # say what a field may hold.
    it "keeps POSITIONS off the public surface" do
      expect { models::Location::POSITIONS }.to raise_error(NameError, /private constant/)
    end

    # Zero is a legal offset and a legal length, so the guard has to key
    # on the sign rather than on the value being falsy or blank.
    it "still accepts a zero-length range at offset zero" do
      empty = models::Location.new(byte_offset: 0, byte_length: 0, line: 0, column: 0)

      expect([empty.byte_offset, empty.byte_length, empty.line]).to eq([0, 0, 0])
    end

    # Nested, because Location is reached through an Issue in practice
    # and the aggregate walks its own children.
    it "refuses a negative range nested in a report" do
      json = %({"issues":[{"severity":"error","message":"m",) +
             %("location":{"byte_offset":-1}}]})
      expect { models::Report.from_json(json) }
        .to raise_error(Lutaml::Model::ValidationError, /byte_offset expects a non-negative/)
    end

    # lutaml has a sentinel object standing for "never set", and the
    # block form of `new` is the one door a caller can store it through.
    # It made that door disagree with the rest in two directions at once
    # -- measured, a position raised `byte_offset expects a non-negative
    # integer, got uninitialized`, while `chunk` sealed and handed the
    # sentinel itself back where a caller expects a String or nil.
    #
    # Normalised rather than refused, because refusing is only reachable
    # from that one door: through the other five lutaml erases the
    # sentinel before our lifecycle runs and the ivar holds a plain nil,
    # so there is nothing left to refuse and nil is what they all report.
    it "reads nil through every door when handed lutaml's unset sentinel" do
      unset = Lutaml::Model::UninitializedClass.instance
      nested = lambda do
        models::Issue.new(severity: "error", message: "m",
                          location: models::Location.new(byte_offset: unset)).location
      end
      doors = [
        -> { models::Location.new(byte_offset: unset) },
        -> { models::Location.new({ byte_offset: unset }) },
        -> { models::Location.new { |l| l.byte_offset = unset } },
        -> { models::Location.new { |l| l.byte_offset(unset) } },
        -> { models::Location.from_hash({ "byte_offset" => unset }) },
        -> { models::Location.from_json(%({"byte_offset":null})) },
        nested
      ]

      expect(doors.map { |door| door.call.byte_offset }).to all(be_nil)
      expect(doors.map { |door| door.call.to_json }).to all(eq("{}"))
    end

    # The strongest thing clearing the sentinel buys, and the reason it
    # belongs to the lifecycle rather than to Location. Measured before
    # the fix: `Issue.new(severity: "error") { |i| i.message(sentinel) }`
    # sealed, `message` read back as `UninitializedClass`, and `to_json`
    # rendered `{"severity":"error"}` -- a required field gone from the
    # document, which then reloaded as `Missing required attribute:
    # message`. Cleared to nil, the required check sees it and refuses at
    # construction instead.
    it "refuses a required attribute handed the unset sentinel" do
      unset = Lutaml::Model::UninitializedClass.instance

      expect { models::Issue.new(severity: "error") { |i| i.message(unset) } }
        .to raise_error(Lutaml::Model::ValidationError, /Missing required attribute: message/)
    end

    # lutaml wraps a singular enum's value in an Array, so the sentinel
    # hides inside `[sentinel]` where identity against the singleton
    # cannot see it. Measured before that wrapper was read through:
    # `Inspection.new { |x| x.parse_status = sentinel }` sealed and
    # rendered `{"issues":[]}` -- a required attribute simply absent --
    # and reloading that document raised `Missing required attribute:
    # parse_status`. Both enums in the vocabulary, because one of them
    # passing proves nothing about the other.
    it "refuses a required enum handed the unset sentinel" do
      unset = Lutaml::Model::UninitializedClass.instance

      expect { models::Inspection.new { |i| i.parse_status = unset } }
        .to raise_error(Lutaml::Model::ValidationError,
                        /Missing required attribute: parse_status/)
      expect { models::Issue.new(message: "m") { |i| i.severity = unset } }
        .to raise_error(Lutaml::Model::ValidationError,
                        /Missing required attribute: severity/)
    end

    # The other side of that guard: reading through the enum wrapper must
    # not disturb a legitimate enum, which is stored in the very same
    # shape.
    it "still carries every legal enum value through the wrapper" do
      expect(models::Inspection.new(parse_status: "failed").to_json)
        .to eq(%({"parse_status":"failed","issues":[]}))
      expect(%w[error warning info].map { |s| issue[s].severity })
        .to eq(%w[error warning info])
    end

    # The boundary of that rule, so it is a decision rather than an
    # assumption. lutaml wraps whatever a collection setter is handed, so
    # the ivar holds `[sentinel]` and never the sentinel itself -- the
    # clearing pass cannot see it, and the collection's own member check
    # is what refuses it.
    it "refuses the unset sentinel handed to a collection" do
      unset = Lutaml::Model::UninitializedClass.instance

      expect { models::Report.new { |r| r.issues(unset) } }
        .to raise_error(Lutaml::Model::ValidationError,
                        /issues expects Claricle::Models::Issue, got Lutaml::Model::UninitializedClass/)
    end

    # The rule is the lifecycle's, not the byte range's. Pinned on an
    # attribute POSITIONS does not cover and on a second model, because
    # a fix that only knew about positions would leave `chunk` reporting
    # the sentinel one field away from where it was found.
    it "clears the sentinel from any attribute, on any model" do
      unset = Lutaml::Model::UninitializedClass.instance
      located = models::Location.new { |l| l.chunk(unset) }
      report = models::Report.new { |r| r.source_path(unset) }

      expect(located.chunk).to be_nil
      expect(located.to_json).to eq("{}")
      expect(report.source_path).to be_nil
      expect(report.to_json).not_to include("source_path")
    end

    it "round-trips a chunk and both ends of the byte range" do
      located = issue["error", location: models::Location.new(byte_offset: 33, byte_length: 4,
                                                              chunk: "IDAT")]
      reloaded = models::Issue.from_json(located.to_json).location
      expect([reloaded.byte_offset, reloaded.byte_length, reloaded.chunk])
        .to eq([33, 4, "IDAT"])
    end
  end

  # lutaml-model 0.8.19's `:hash` type is shaped for XML and treats two
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

    # An empty meta is a report -- "I looked and there was nothing" --
    # and must survive the round trip as {}. Without render_empty the key
    # is omitted from JSON and reloads as nil, which says "I did not
    # look". Absent meta must still reload as nil, so the two stay
    # distinguishable.
    it "keeps an empty hash distinct from an absent one" do
      empty = described_class.const_get(:Inspection)
                             .new(format: "png", parse_status: "ok", meta: {})
      absent = described_class.const_get(:Inspection)
                              .new(format: "png", parse_status: "ok")

      expect(described_class.const_get(:Inspection).from_json(empty.to_json).meta)
        .to eq({})
      expect(described_class.const_get(:Inspection).from_json(absent.to_json).meta)
        .to be_nil
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

    # Measured on 0.8.19: `Hash#to_h` returns SELF, so the cast handed the
    # model the caller's own object. A handler that kept its reference
    # could then rewrite what an inspection had already reported. Both
    # halves: the model must not see the later write, and the caller must
    # keep a usable Hash rather than a frozen one.
    it "stores its own copy of the hash the caller supplied" do
      supplied = { "a" => 1 }
      inspection = described_class.const_get(:Inspection)
                                  .new(format: "svg", parse_status: "ok", meta: supplied)

      expect { supplied["b"] = 2 }.not_to raise_error
      expect(inspection.meta).to eq({ "a" => 1 })
    end

    # Owning the container is only half of it. Left writable, a sealed
    # Inspection could still have `meta["x"] = 1` written through it and
    # its JSON changed afterwards, which is exactly what deep freeze is
    # there to stop. Both doors, because deserialization stores the value
    # wrapped rather than bare.
    it "seals the metadata container at both doors" do
      built = described_class.const_get(:Inspection)
                             .new(format: "svg", parse_status: "ok", meta: { "a" => 1 })
      loaded = described_class.const_get(:Inspection).from_json(built.to_json)

      expect { built.meta["x"] = 1 }.to raise_error(FrozenError)
      expect { loaded.meta["x"] = 1 }.to raise_error(FrozenError)
      expect(built.to_json).to eq(loaded.to_json)
    end

    # Sealing the container is only its top level. Real metadata is not
    # flat -- an SVG root gives Strings and an EMF header gives a nested
    # `frame` Hash -- and every one of those arrived as the handler's own
    # object, which the container copy never touched.
    it "seals free-form metadata all the way down, at both doors" do
      built = described_class.const_get(:Inspection)
                             .new(format: "svg", parse_status: "ok",
                                  meta: { "title" => +"t", "frame" => { "x" => 1 },
                                          "l" => [+"a"] })
      loaded = described_class.const_get(:Inspection).from_json(built.to_json)

      [built, loaded].each do |inspection|
        expect { inspection.meta["frame"]["x"] = 2 }.to raise_error(FrozenError)
        expect { inspection.meta["title"] << "!" }.to raise_error(FrozenError)
        expect { inspection.meta["l"] << "b" }.to raise_error(FrozenError)
        expect { inspection.meta["l"][0] << "!" }.to raise_error(FrozenError)
      end
    end

    # The point of sealing it. A frozen Inspection whose nested values
    # were still the handler's reported whatever the handler wrote next,
    # without anything ever touching a frozen object.
    it "keeps its document when a handler writes to metadata it still holds" do
      title = +"hello"
      frame = { "x" => 1 }
      inspection = described_class.const_get(:Inspection)
                                  .new(format: "svg", parse_status: "ok",
                                       meta: { "title" => title, "frame" => frame })
      before = inspection.to_json

      title << " world"
      frame["x"] = 999

      expect(inspection.to_json).to eq(before)
      expect(inspection.meta).to eq({ "title" => "hello", "frame" => { "x" => 1 } })
    end

    # `refuse_unrenderable` passes on the graph it was handed, so a
    # nested value rewritten afterwards used to reach `to_json`
    # unchecked. Measured, both ways it can go wrong: invalid binary
    # raised JSON::GeneratorError and a container closed into a cycle
    # raised JSON::NestingError, each from a model that had already
    # validated and sealed.
    it "still renders after a handler makes its old metadata unrenderable" do
      text = +"ok"
      nested = { "a" => 1 }
      inspection = described_class.const_get(:Inspection)
                                  .new(parse_status: "ok",
                                       meta: { "t" => text, "n" => nested })

      text.replace("\xFF".b)
      nested["self"] = nested

      expect { inspection.to_json }.not_to raise_error
      expect(inspection.meta).to eq({ "t" => "ok", "n" => { "a" => 1 } })
    end

    # Sealing the Hash the reader unwraps used to be only half of it.
    # Deserialization stored a FreeFormHash around that Hash, and the
    # wrapper was a separate object -- left writable, it could be pointed
    # at another Hash without ever touching a frozen one, and the frozen
    # Inspection's own JSON changed with it. Sealing now replaces the
    # ivar, so both doors end on one bare frozen Hash and the second
    # object is gone rather than guarded.
    #
    # `be_an_instance_of`, not `be_a`: FreeFormHash is a Hash subclass, so
    # `be_a` would pass on the very wrapper this says is no longer
    # there.
    it "leaves one bare sealed hash in the ivar, whichever door built it" do
      built = described_class.const_get(:Inspection)
                             .new(format: "svg", parse_status: "ok", meta: { "a" => 1 })
      loaded = described_class.const_get(:Inspection).from_json(built.to_json)

      [built, loaded].each do |inspection|
        stored = inspection.instance_variable_get(:@meta)

        expect(stored).to be_an_instance_of(Hash)
        expect(stored).to be_frozen
      end
      expect(loaded.meta).to eq({ "a" => 1 })
    end

    # Sealing the model must not follow the CONTAINER out into a
    # document. Every other key `to_hash` renders comes back writable,
    # and meta is not special to whoever asked for the Hash -- the cast
    # dups it on the way out for exactly that reason. What is inside it
    # is the inspection's own sealed data, shared rather than copied
    # again because nothing can change it.
    it "renders a document whose meta container the caller can still edit" do
      inspection = described_class.const_get(:Inspection)
                                  .new(format: "svg", parse_status: "ok",
                                       meta: { "a" => 1, "n" => { "b" => 2 } })
      doc = inspection.to_hash

      expect { doc["meta"]["c"] = 3 }.not_to raise_error
      expect { doc["meta"]["n"]["d"] = 4 }.to raise_error(FrozenError)
      expect(inspection.meta).to eq({ "a" => 1, "n" => { "b" => 2 } })
    end

    # meta is verbatim and JSON is what the CLI reports, so a value JSON
    # will not write leaves an Inspection nothing can report. Both kinds
    # it refuses, at every depth, and as a key as well as a value.
    {
      "a number at the top level" => { "width" => Float::INFINITY },
      "a number nested in a hash" => { "box" => { "dpi" => -Float::INFINITY } },
      "a number inside an array" => { "sizes" => [1.0, Float::NAN] },
      "bytes that are not UTF-8" => { "raw" => "\xFF\xFE".b },
      "invalid UTF-8" => { "name" => (+"bad \xFF byte").force_encoding(Encoding::UTF_8) },
      "bytes nested in an array" => { "chunks" => [{ "data" => "\xC3".b }] },
      "a container that leads back to itself" => {}.tap { |h| h["self"] = h }
    }.each do |label, meta|
      it "refuses #{label} in meta, which JSON could not write" do
        expect { models::Inspection.new(parse_status: "ok", meta: meta) }
          .to raise_error(Lutaml::Model::ValidationError, /meta expects values JSON can render/)
      end
    end

    it "refuses an unrenderable value arriving from a document too" do
      expect { models::Inspection.from_json(%({"parse_status":"ok","meta":{"v":1e400}})) }
        .to raise_error(Lutaml::Model::ValidationError, /meta expects values JSON can render/)
    end

    # It refuses what JSON refuses and nothing more, which is why it asks
    # JSON instead of listing rules. Every one of these tempts a
    # hand-written check into a wrong answer: `"\xFF".b` is valid
    # ASCII-8BIT and still unwritable while Latin-1 and UTF-16 are both
    # fine; the same container held twice side by side is not a cycle;
    # and an Infinity used as a KEY renders happily as "Infinity" even
    # though the same value refuses to render as a value.
    it "still stores everything JSON can write" do
      shared = { "n" => 1.0 }
      kept = models::Inspection.new(
        parse_status: "ok",
        meta: { "s" => :sym, "r" => (1..5), "ascii" => "plain".b,
                "latin" => (+"caf\xE9").force_encoding(Encoding::ISO_8859_1),
                "wide" => "x".encode(Encoding::UTF_16),
                Float::INFINITY => "as a key", "a" => shared, "b" => shared }
      )

      expect(kept.meta["s"]).to eq(:sym)
      expect(kept.meta["r"]).to eq(1..5)
      # The Infinity key by lookup, not just by the model constructing:
      # stringifying every key on the way in would otherwise pass here
      # while quietly breaking the verbatim contract.
      expect(kept.meta[Float::INFINITY]).to eq("as a key")
      expect(kept.meta.keys).to include(Float::INFINITY)
      expect { kept.to_json }.not_to raise_error
    end

    # The whole point of rendering rather than listing rules: a handler
    # that nests deeply enough trips JSON's depth limit, which no
    # hand-written check for Infinity or encodings would ever have seen.
    #
    # On the exact boundary, because the limit is counted from the
    # outside and meta sits one level inside the document. Checked bare,
    # 100 passed validation and `to_json` still raised; a spec at 200
    # would never have seen that. Both sides here: 99 must survive the
    # round trip, 100 must be refused.
    nest = ->(depth) { (1..depth).reduce("leaf") { |inner, _| { "n" => inner } } }

    it "refuses meta one level deeper than the document can carry" do
      expect { models::Inspection.new(parse_status: "ok", meta: nest[100]) }
        .to raise_error(Lutaml::Model::ValidationError, /meta expects values JSON can render/)
    end

    it "still writes meta at the deepest level the document can carry" do
      deepest = models::Inspection.new(parse_status: "ok", meta: nest[99])

      expect { deepest.to_json }.not_to raise_error
      expect(models::Inspection.from_json(deepest.to_json).meta).to eq(nest[99])
    end

    # JSON never descends into a Hash key -- it renders one through
    # `to_s` -- so neither its depth limit nor its cycle detection ever
    # sees a key graph, and `refuse_unrenderable` cannot bound one.
    # Sealing used to walk keys anyway, so a meta that JSON writes
    # perfectly well took `Inspection.new` down with SystemStackError:
    # the model refused, by crashing, a document it had just proved it
    # could render.
    {
      "leads back to itself" => [].tap { |a| a << a },
      "nests 5,000 deep" => (1..5_000).reduce([]) { |inner, _| [inner] }
    }.each do |label, key|
      it "seals a meta whose key #{label}, which JSON renders fine" do
        expect(JSON.generate({ "meta" => { key => 1 } })).to be_a(String)

        inspection = models::Inspection.new(parse_status: "ok", meta: { key => 1 })

        expect { inspection.to_json }.not_to raise_error
      end
    end

    # The other half of that: bounding the keys must not have loosened
    # the values, where JSON does look and where the guard belongs.
    it "still refuses a value that leads back to itself" do
      cycle = {}
      cycle["self"] = cycle

      expect { models::Inspection.new(parse_status: "ok", meta: { "v" => cycle }) }
        .to raise_error(Lutaml::Model::ValidationError, /meta expects values JSON can render/)
    end

    # A Hash comparing by identity keeps keys that are `==` but not the
    # same object. Rebuilt as an ordinary Hash they merge, and measured,
    # a handler's two-entry meta sealed as one -- an entry gone with
    # nothing raised.
    it "keeps every entry of a meta that compares its keys by identity" do
      supplied = {}.compare_by_identity
      supplied[+"a"] = 1
      supplied[+"a"] = 2

      sealed = models::Inspection.new(parse_status: "ok", meta: supplied).meta

      expect(sealed.size).to eq(2)
      expect(sealed.values).to contain_exactly(1, 2)
      expect(sealed).to be_compare_by_identity
    end

    # meta holds whatever a handler put there, so the copy must not ask
    # that object how to traverse itself. Measured on an Array whose
    # `map` returns `self`: the caller's own Array came back frozen AND
    # still shared, so its mutable String went on changing a sealed
    # Inspection's JSON -- one override defeating both halves of the
    # copy.
    it "copies a metadata container that lies about how to traverse it" do
      sneaky = Class.new(Array) do
        def map(&) = self
        def each(&) = ["substituted"].each(&)
      end
      leaf = +"real"
      supplied = sneaky.new([leaf])

      inspection = models::Inspection.new(parse_status: "ok", meta: { "k" => supplied })
      before = inspection.to_json
      leaf << "!"

      expect(supplied).not_to be_frozen
      expect(inspection.meta["k"]).to be_an_instance_of(Array)
      expect(inspection.meta["k"]).to eq(["real"])
      expect(inspection.to_json).to eq(before)
    end

    # The same for a String, which can lie about being frozen as easily
    # as an Array can lie about `map`. Asking `frozen?` is why the copy
    # is unconditional.
    it "copies a metadata string that lies about being frozen" do
      sneaky = Class.new(String) do
        def dup = self
        def frozen? = true
      end
      supplied = sneaky.new("real")

      inspection = models::Inspection.new(parse_status: "ok", meta: { "s" => supplied })
      before = inspection.to_json
      supplied.replace("substituted")

      expect(inspection.meta["s"]).to be_an_instance_of(String)
      expect(inspection.to_json).to eq(before)
    end

    # What carrying keys across gives up, pinned so it is a decision
    # rather than a gap. JSON reduces every non-String key to text
    # through `to_s`, which is exactly the case the copy already leaves
    # to the handler for a value -- so a container key and an arbitrary
    # object key behave the same, and neither is pinned. A String key
    # needs no help: Ruby froze and copied it on insert.
    it "leaves a non-String meta key to the handler, whatever shape it is" do
      container = [+"a"]
      object = Object.new
      object.instance_variable_set(:@shown, +"one")
      def object.to_s = @shown
      text = +"key"

      inspection = models::Inspection.new(parse_status: "ok",
                                          meta: { container => 1, object => 2, text => 3 })
      container << "b"
      object.instance_variable_set(:@shown, "two")
      text << "!"

      rendered = JSON.parse(inspection.to_json)["meta"]

      expect(rendered.keys).to contain_exactly("[\"a\", \"b\"]", "two", "key")
    end

    # lutaml generates `meta(*args)` and the block form of `new` uses the
    # argument branch to assign. Overriding it with a zero-arity reader
    # made meta the one attribute that form could not set.
    it "still sets through the builder form of new" do
      inspection = described_class.const_get(:Inspection).new do |i|
        i.parse_status = "ok"
        i.meta("a" => 1)
      end

      expect(inspection.meta).to eq({ "a" => 1 })
    end
  end

  # lutaml accepts a list for a non-collection enum, stores it whole, and
  # returns only the first element -- so the extra values vanish between
  # construction and JSON with nothing to show for it.
  describe "enum cardinality" do
    it "refuses two values for Issue#severity" do
      expect do
        described_class.const_get(:Issue)
                       .new(severity: %w[info error], code: "c", message: "m")
      end.to raise_error(Lutaml::Model::ValidationError, /single value/)
    end

    it "refuses two values for Inspection#parse_status" do
      expect do
        described_class.const_get(:Inspection)
                       .new(format: "svg", parse_status: %w[ok failed])
      end.to raise_error(Lutaml::Model::ValidationError, /single value/)
    end

    # lutaml stores every enum value as an array internally, so the check
    # cannot key on shape alone -- these must still be accepted.
    #
    # Not named `issue`, for the third time in this file: that is a lambda
    # local at describe scope, and assigning it inside an example rebinds
    # it for every example that runs afterwards. Under `--order random`
    # these two took 23 others down with them.
    it "still accepts a single value" do
      single = described_class.const_get(:Issue)
                              .new(severity: "error", code: "c", message: "m")

      expect(single.severity).to eq("error")
    end

    # Cardinality only. By the time this runs lutaml has already turned a
    # bare "error" into ["error"], so a one-element list is indistinguish-
    # able from the value it wraps and nothing is lost by taking it. A
    # document is stricter: lutaml rejects any list there itself.
    it "accepts a one-element list but refuses one from a document" do
      wrapped = described_class.const_get(:Issue).new(severity: ["error"], message: "m")

      expect(wrapped.severity).to eq("error")
      expect { described_class.const_get(:Issue).from_json(%({"severity":["error"],"message":"m"})) }
        .to raise_error(Lutaml::Model::CollectionTrueMissingError)
    end
  end

  describe "public surface" do
    # Written out rather than looped, because `const_get` walks straight
    # past private_constant and only a literal reference raises.
    it "keeps Base private" do
      expect { Claricle::Models::Base }.to raise_error(NameError, /private constant/)
    end

    # A workaround for one measured lutaml behaviour, not a type a caller
    # ever names: `meta` is declared with it, and what comes back out of a
    # model is a plain Hash either way.
    it "keeps FreeFormHash private" do
      expect { Claricle::Models::FreeFormHash }.to raise_error(NameError, /private constant/)
    end

    # A mixin only Base uses, and Base is private, so it has no caller.
    it "keeps Validation private" do
      expect { Claricle::Models::Validation }.to raise_error(NameError, /private constant/)
    end

    it "lists none of them among its constants" do
      expect(described_class.constants).to contain_exactly(:Location, :Issue, :Report, :Inspection)
    end

    # `meta` still hands back a plain Hash, so hiding the type takes
    # nothing away from a caller.
    it "still gives a caller a plain Hash for meta" do
      inspection = described_class.const_get(:Inspection)
                                  .new(format: "svg", parse_status: "ok", meta: { "a" => 1 })

      expect(inspection.meta).to be_an_instance_of(Hash)
      expect(described_class.const_get(:Inspection)
                            .from_json(inspection.to_json).meta).to be_an_instance_of(Hash)
    end
  end
end
