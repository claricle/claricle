# frozen_string_literal: true

require "lutaml/model"

module Claricle
  module Models
    # Ruby's replacement-object Marshal protocol. Its own module because
    # it is one concern with its own version contract, and because Base
    # crossed the class-length limit once it moved in.
    #
    # The per-object hooks (`marshal_dump`/`marshal_load`) cannot be used:
    # Ruby restores depth-first, so Location then Issue are already frozen
    # before Report#marshal_load runs, and relinking from the parent
    # raises FrozenError. An earlier fix dodged that by dropping lutaml's
    # back-references from the dump -- it fixed a lifted model and
    # silently detached every copied graph, which was a bad trade.
    #
    # `_dump`/`_load` make the boundary atomic instead. `_load` runs on
    # the subclass and returns a whole object, so lutaml assigns every
    # link while building it and the lifecycle then validates and freezes
    # the finished subtree. A lifted model round-trips as its own root,
    # and a whole graph keeps its hierarchy.
    #
    # `marshal_dump` must stay absent: Ruby prefers it over `_dump`.
    #
    # Three consequences, all deliberate. The payload is a nested Marshal
    # stream, so it does not inherit the outer load's `freeze:` or load
    # proc -- that is inherent to `_dump` returning a String. It is a
    # semantic snapshot, so aliasing inside the subtree is normalized:
    # the same Issue given twice reloads as two equal Issues. And the
    # nested stream has a cycle table of its own, so a model that leads
    # back to itself through `meta` is refused by name rather than
    # followed -- see `guarding` below.
    module Marshalling
      VERSION = 1
      DUMPING = :claricle_models_dumping

      def _dump(depth)
        Marshalling.guarding(self) do
          Marshal.dump([VERSION, marshal_attributes], depth)
        end
      end

      # A model reached through `meta` is written by Ruby rather than by
      # `plain`, so it re-enters `_dump` and opens a stream of its own.
      # Ruby's cycle table belongs to the outer stream and cannot see into
      # this one, so a `meta` that leads back to its own model recursed
      # until the stack gave out -- measured: `meta["box"]["self"]`
      # pointing at the Inspection whose `box` that is, `SystemStackError`
      # rather than any message a caller could act on. Named instead, the
      # same trade `plain` makes for a nested subclass.
      #
      # Only what is open right now, so the same model written twice side
      # by side is fine -- and Ruby links the second occurrence anyway.
      # `compare_by_identity`, because two equal models are two models,
      # and because hashing a lutaml model walks the parent links this is
      # here to keep out of.
      def self.guarding(model)
        active = (Thread.current[DUMPING] ||= {}.compare_by_identity)
        raise TypeError, "cannot marshal #{model.class}: its meta leads back to it" if active[model]

        active[model] = true
        begin
          yield
        ensure
          active.delete(model)
          Thread.current[DUMPING] = nil if active.empty?
        end
      end

      # Not `to_hash`: lutaml omits explicitly-empty values from it, so a
      # `meta: {}` came back nil and so did a present-but-empty nested
      # model. Every declared attribute is written, empty or not, so the
      # payload says what the object holds rather than what is worth
      # rendering.
      def marshal_attributes
        self.class.attributes.to_h do |name, attribute|
          [name.to_s, Marshalling.plain(public_send(name), attribute.type)]
        end
      end

      # The payload carries attributes, not classes, so a nested model is
      # rebuilt as whatever the attribute declares. A subclass would come
      # back as its parent with its own attributes silently gone, so it is
      # refused instead. Validation accepts subclasses, which is why this
      # has to be checked rather than assumed: `Base` is a private
      # constant and subclassing is not a supported extension point, so
      # failing loudly is better than inventing a class discriminator no
      # caller needs.
      def self.plain(value, type = nil)
        case value
        when Array then value.map { |element| plain(element, type) }
        when Base
          unless type.nil? || value.instance_of?(type)
            raise TypeError, "cannot marshal #{value.class}: #{type} was declared"
          end

          value.marshal_attributes
        else value
        end
      end

      # `_load` has to live on the class, so it arrives by `extend`.
      module ClassMethods
        def _load(payload)
          # rubocop:disable Security/MarshalLoad -- this IS the Marshal
          # hook. Ruby calls it with what our own `_dump` wrote, and it is
          # only reached because the caller already chose to Marshal.load
          # the outer payload. Unnesting would not make that choice safer.
          envelope = Marshal.load(payload)
          # rubocop:enable Security/MarshalLoad
          version, attributes = envelope
          # Exact type and exact shape: `1.0` and `Rational(1,1)` are both
          # `== 1`, and a longer envelope would be a different format
          # wearing the right version number.
          valid = envelope.is_a?(Array) && envelope.size == 2 &&
                  version.instance_of?(Integer) && version == VERSION
          raise TypeError, "unsupported Claricle marshal payload #{version.inspect}" unless valid

          from_hash(attributes)
        end
      end
    end

    # lutaml-model 0.8.19 validates nothing on its own: a bogus enum
    # constructs and serializes, a missing attribute becomes nil, and
    # `validate!` does not reach nested models. Every model therefore runs
    # one lifecycle -- normalize, validate, freeze -- at both doors.
    class Base < Lutaml::Model::Serializable
      include Marshalling
      extend Marshalling::ClassMethods

      DESERIALIZING = :claricle_models_deserializing
      # Lutaml builds every model -- parent and nested alike -- by calling
      # `new` with exactly this and populating it afterwards. Direct
      # construction always carries real attributes.
      BLANK_CONSTRUCTION = [:lutaml_register].freeze
      private_constant :DESERIALIZING, :BLANK_CONSTRUCTION

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

      # Idempotent on our own bookkeeping rather than on `frozen?`, so a
      # model frozen by other code is not mistaken for a sealed one. An
      # empty one never reaches here -- validation rejects it first -- and
      # a populated one dies partway through, which is the point.
      #
      # The marker goes on last, beside the freeze it stands for. Set
      # first, a child that refused to seal left the parent marked sealed
      # and still mutable, and every later `seal` returned at the guard --
      # measured: the block form of `new` handed back a Report that called
      # itself sealed, took another issue, and changed its own verdict.
      # There is no cycle for an early marker to break: nesting runs
      # Report -> Issue -> Location and stops.
      def seal
        return self if @claricle_sealed

        nested_models.each(&:seal)
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

      # Freeze declared attributes only. lutaml hands us its own copy of a
      # String or a collection, so freezing those in place cannot reach the
      # caller. It does NOT copy what is nested inside a free-form Hash, so
      # descending into `meta` would freeze containers the caller still
      # holds -- and 01-core.md:47 asks for the issue collection, not for
      # every value a handler chose to attach. Inspection overrides this
      # to seal `meta`'s own container, which the model does own.
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

      # A declared model attribute is only cast when it arrives as a hash
      # from a document. Handed a wrong-typed object directly, lutaml stores
      # it as-is and the failure surfaces much later as a NoMethodError.
      def validate_types
        self.class.attributes.each do |name, attribute|
          validate_cardinality(name, attribute)
          validate_finite(name)

          type = attribute.type
          next unless type.is_a?(Class) && type < Base

          validate_attribute(name, attribute, type)
        end
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

      # One sentence for every one of these checks, and one place that
      # knows lutaml's ValidationError carries exceptions rather than
      # Strings -- handed bare Strings, its own `error_messages` blows
      # up. Subclasses raise through here too.
      def refuse(name, expectation, got)
        raise Lutaml::Model::ValidationError,
              [TypeError.new("#{name} expects #{expectation}, got #{got}")]
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

      def nested_models
        []
      end
    end

    private_constant :Base
  end
end
