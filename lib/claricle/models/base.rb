# frozen_string_literal: true

require "lutaml/model"

module Claricle
  module Models
    # The per-attribute checks `validate_deeply` runs beyond what lutaml
    # validates on its own. Its own module because Base crosses RuboCop's
    # class-length limit with this much of it inline -- measured, not
    # assumed: folded back in, RuboCop reports Base at 111 lines against
    # a limit of 100. Dropping the Marshal protocol did not change that.
    module Validation
      private

      # One sentence for every one of these checks, and one place that
      # knows lutaml's ValidationError carries exceptions rather than
      # Strings -- handed bare Strings, its own `error_messages` blows
      # up. Subclasses raise through here too.
      def refuse(name, expectation, got)
        raise Lutaml::Model::ValidationError,
              [TypeError.new("#{name} expects #{expectation}, got #{got}")]
      end

      # A declared model attribute is only cast when it arrives as a hash
      # from a document. Handed a wrong-typed object directly, lutaml stores
      # it as-is and the failure surfaces much later as a NoMethodError.
      def validate_types
        self.class.attributes.each do |name, attribute|
          validate_cardinality(name, attribute)
          validate_finite(name)
          validate_default_bookkeeping(name, attribute)

          type = attribute.type
          next unless type.is_a?(Class) && type < Base

          validate_attribute(name, attribute, type)
        end
      end

      # `using_default_for` is public on lutaml, for its own deserializer
      # to mark an attribute absent from the document. A caller can reach
      # it too -- through the block form of `new`, before this runs -- and
      # flip ANY attribute to "using its default" while it still holds
      # the value it was actually given. Rendering skips whatever is
      # marked default, so the value survives the reader and vanishes
      # from the document -- measured on a required attribute (`to_json`
      # rendered `{"message":"m"}` for an Issue whose `severity` still
      # read back "info", and reloading that JSON raised
      # `ValidationError: Missing required attribute: severity`) and
      # separately on optional, unguarded ones (`source_path`, `format`,
      # `Issue#code` all round-tripped to nil having read back their real
      # value right up to the freeze).
      #
      # None of these models declares `default:`, so a genuine default is
      # always blank -- nil for a scalar, empty for a collection, once
      # `normalize` has run (which it has by here). A NON-blank value
      # under a true `using_default?` is therefore always the bookkeeping
      # lying about a value that IS present, never a legitimate default,
      # whether or not the attribute is required.
      def validate_default_bookkeeping(name, attribute)
        return unless using_default?(name)

        value = public_send(name)
        blank = attribute.collection? ? value.empty? : value.nil?
        return if blank

        refuse(name, "recorded as explicitly set", "flagged as using its default")
      end

      # JSON has neither Infinity nor NaN. lutaml coerces both without
      # complaint -- measured: `{"width":1e400}` deserialized to
      # Float::INFINITY, the lifecycle froze the model around it, and the
      # `to_json` that followed raised `JSON::GeneratorError`, so a
      # document that parsed could not be written back out. Refused here,
      # where the attribute name is still in hand.
      def validate_finite(name)
        value = public_send(name)
        return unless value.is_a?(Numeric) && !value.finite?

        refuse(name, "a finite number", value)
      end

      # An enum that is not a collection must be given one value, never
      # two. lutaml 0.8.19 accepts a list, stores it whole, and its getter
      # returns only the first element -- so
      # `Issue.new(severity: ["info", "error"])` validates, reports
      # `"info"`, and drops `"error"` on the way to JSON. Nothing about
      # that is visible to a caller.
      #
      # Cardinality only, and deliberately so: `severity: ["error"]`
      # is accepted, because lutaml has already normalised a bare
      # `"error"` to the same `["error"]` by the time this runs and the
      # two are no longer distinguishable. Nothing is lost either way.
      # Deserialization is stricter -- lutaml's own
      # `CollectionTrueMissingError` rejects any list from a document
      # before this runs.
      #
      # The raw ivar, because the getter is the thing that hides it.
      def validate_cardinality(name, attribute)
        return if attribute.collection?
        return unless attribute.enum?

        # lutaml stores EVERY enum value as an array, so a valid
        # `severity: "error"` is `["error"]` here and the shape alone
        # proves nothing. Only a second element is evidence that a list
        # was passed, and only that loses data.
        raw = instance_variable_get(:"@#{name}")
        return unless raw.is_a?(Array) && raw.length > 1

        refuse(name, "a single value", raw.inspect)
      end

      def validate_attribute(name, attribute, type)
        value = public_send(name)
        return validate_type(name, type, value, nullable: true) unless attribute.collection?

        refuse(name, "a collection", value.class) unless value.is_a?(Array)

        value.each { |element| validate_type(name, type, element, nullable: false) }
      end

      # A singular model attribute may be absent; a collection member may
      # not -- a nil there reaches recursion and dies as a NoMethodError.
      def validate_type(name, type, element, nullable:)
        return if nullable && element.nil?
        return if element.is_a?(type)

        refuse(name, type, element.class)
      end
    end

    # lutaml-model 0.8.19 validates nothing on its own: a bogus enum
    # constructs and serializes, a missing attribute becomes nil, and
    # `validate!` does not reach nested models. Every model therefore runs
    # one lifecycle -- normalize, validate, freeze -- at both doors.
    class Base < Lutaml::Model::Serializable
      include Validation

      DESERIALIZING = :claricle_models_deserializing
      # Lutaml builds every model -- parent and nested alike -- by calling
      # `new` with exactly this and populating it afterwards. Direct
      # construction always carries real attributes.
      BLANK_CONSTRUCTION = [:lutaml_register].freeze
      private_constant :DESERIALIZING, :BLANK_CONSTRUCTION

      # Public on lutaml, for its own XML allocation path
      # (`allocate_for_deserialization`, reached only through an `xml`
      # mapping block) to reset every attribute to a shared empty-
      # collection sentinel or `UninitializedClass.instance` before
      # filling it in field by field. None of these models declares an
      # `xml` block, so lutaml never calls either method on one -- but a
      # caller reached them too, through the block form of `new`, before
      # this runs. Measured: `init_deserialization_state(:default)` wiped
      # a Report's `source_path` to the sentinel and its whole `issues`
      # collection to `[]`, and the model sealed reporting `valid: :yes`
      # over an issue the caller had actually supplied -- no schema
      # violation to catch, since the wiped shape is indistinguishable
      # from a Report the caller genuinely built empty. Hidden rather
      # than checked for, because the collection wipe leaves no value
      # anywhere in the object for `validate_types` to catch.
      private :init_deserialization_state, :finalize_deserialization

      # Deserialization builds a blank instance and populates it afterwards,
      # so `initialize` must not finalize during that window. Neither the
      # key nor the value is secret; the protection is that BOTH the extent
      # and lutaml's blank signature must hold, so ordinary construction
      # validates however the thread-local was set. Forging both yields an
      # empty model, which `allocate` already gives anyone who wants one.
      # `Thread.current[]` is fiber-local, so a boundary it does not cross
      # makes construction validate rather than skip.
      #
      # `of` rather than `from`: every `from_*` parses and then delegates
      # here, so this one override also covers `of_json` and friends. A
      # top-level array arrives already finalized, because `of` maps it back
      # through itself one item at a time.
      def self.of(format, doc, options = {})
        outer = Thread.current[DESERIALIZING]
        Thread.current[DESERIALIZING] = true
        begin
          result = super
        ensure
          Thread.current[DESERIALIZING] = outer
        end
        result.is_a?(Array) ? result : result.finalize
      end

      # Lutaml also accepts a positional attributes Hash, so take whatever
      # the superclass takes.
      # Both conditions are required. Inside a deserialization but with
      # real attributes means a caller built this themselves -- through a
      # coercion callback, say -- so it validates now. Outside one, the
      # thread-local is meaningless however it was set.
      def initialize(*args, **kwargs)
        super
        finalize unless args.empty? &&
                        kwargs.keys == BLANK_CONSTRUCTION &&
                        Thread.current[DESERIALIZING]
      end

      def initialize_copy(other)
        super
        @claricle_sealed = false
        finalize
      end

      def finalize
        validate_deeply
        seal
        self
      end

      def validate_deeply
        normalize
        validate!
        validate_types
        nested_models.each(&:validate_deeply)
      end

      protected

      # Idempotent on our own bookkeeping rather than on `frozen?`, so a
      # model frozen by other code is not mistaken for a sealed one. An
      # empty model with a required attribute never reaches here --
      # validation rejects it first; Report and Location have none, so an
      # empty instance of either is valid and does reach this point. A
      # populated one that dies does so partway through, which is the
      # externally-frozen case tested below.
      #
      # The marker goes on last, beside the freeze it stands for. Set
      # first, a child that refused to seal left the parent marked sealed
      # and still mutable, and every later `seal` returned at the guard --
      # measured: the block form of `new` handed back a Report that called
      # itself sealed, took another issue, and changed its own verdict.
      # There is no cycle for an early marker to break: nesting runs
      # Report -> Issue -> Location and stops.
      #
      # Protected, not public: it freezes without revalidating, so a
      # caller holding a model that failed to finalize (the block form of
      # `new` hands one over before the exception) could mutate it into
      # any shape and freeze it straight past `validate_deeply` -- measured,
      # a poisoned Issue sealed with `severity: "bogus"` and serialized.
      # `finalize` is the only public door, and it always validates first.
      # Explicit block form for the recursive call below: `Symbol#to_proc`
      # calls `public_send`, which a protected method refuses.
      def seal
        return self if @claricle_sealed

        # rubocop:disable Style/SymbolProc -- &:seal calls public_send,
        # which a protected method refuses; the block calls it directly.
        nested_models.each { |model| model.seal }
        # rubocop:enable Style/SymbolProc
        freeze_attributes
        # Lutaml tracks which attributes still hold defaults in a mutable
        # hash, and `using_default_for` is public. Flipping an entry on a
        # frozen model drops that attribute from the document -- measured:
        # marking every one of an issue's fields turns "issues":[...] into
        # "issues":null, and a warning report then reloads valid. Freezing
        # it here, after the attribute pass, leaves composition intact.
        instance_variable_get(:@using_default)&.freeze
        @claricle_sealed = true
        freeze
      end

      private

      # Refused, rather than supported. Ruby's default Marshal writes the
      # ivars into a fresh object and runs neither the constructor nor the
      # lifecycle -- measured: the copy came back unfrozen, took
      # `severity = "bogus"` past the enum, and rendered it. Nothing in
      # this gem forks, caches or crosses a process boundary, so no model
      # is dumped at all rather than dumped through a protocol of its own.
      # A real one can be written the day something actually needs it.
      #
      # This closes the dump side only, and does not pretend otherwise.
      # `Marshal.load` of bytes a caller got from somewhere else still
      # builds whatever those bytes describe -- measured, a hand-built
      # ordinary-object payload naming this class loaded unfrozen with
      # `severity: "bogus"`. That was equally true before this refusal
      # existed: `_load` was only ever reached for payloads our own
      # `_dump` had written, never for a payload someone else shaped.
      # Nothing in this gem calls `Marshal.load`.
      #
      # `_dump` and not `marshal_dump`: Ruby prefers `marshal_dump` where
      # both exist, so the refusal sits on the hook a later `marshal_dump`
      # would have to displace deliberately. Private, because Marshal
      # reaches a private `_dump` on the class and on every subclass --
      # measured -- so nothing is gained by publishing it. It covers a
      # model nested inside a plain Hash or Array too, also measured.
      def _dump(_depth)
        raise TypeError, "cannot marshal #{self.class}: Claricle models are not marshalable"
      end

      # Freeze declared attributes only, and freeze them where they lie.
      # lutaml hands us its own copy of a String or a collection, so that
      # cannot reach the caller. It does NOT copy what is nested inside a
      # free-form Hash, so Inspection cannot seal `meta` this way and
      # overrides it to copy the graph first -- see `Inspection#sealed_copy`.
      # Works on the backing storage, not the getters. An enum declared with
      # `values:` is stored as a mutable Array behind a String getter, so
      # freezing what the getter returns leaves that array writable and a
      # frozen report can still have its verdict changed. Writing the ivar
      # rather than calling the setter also leaves lutaml's `using_default`
      # bookkeeping alone.
      #
      # Strings are duplicated first: `new` hands us its own copy, but
      # `from_hash` aliases the caller's, and freezing that would take their
      # String away from them.
      def freeze_attributes
        self.class.attributes.each_key do |name|
          slot = :"@#{name}"
          case (raw = instance_variable_get(slot))
          when String then instance_variable_set(slot, own_string(raw))
          when Array then instance_variable_set(slot, raw.map { |e| own_string(e) }.freeze)
          end
        end
      end

      def own_string(value)
        return value unless value.is_a?(String)

        value.frozen? ? value : value.dup.freeze
      end

      def normalize; end

      def nested_models
        []
      end
    end

    # Validation is an implementation detail of Base, not an extension
    # point -- Base is private, so a mixin only Base uses has no caller
    # left to serve.
    private_constant :Base, :Validation
  end
end
