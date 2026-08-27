# frozen_string_literal: true

require "json"

require_relative "base"
require_relative "free_form_hash"
require_relative "issue"

module Claricle
  module Models
    # Inspection reports whether metadata parsed, and makes no validity
    # claim -- that belongs to conform alone (D17).
    class Inspection < Base
      PARSE_STATUSES = %w[ok failed].freeze

      attribute :format, :string
      attribute :width, :float
      attribute :height, :float
      attribute :dpi, :float
      attribute :color_space, :string
      attribute :meta, FreeFormHash
      attribute :parse_status, :string, values: PARSE_STATUSES, required: true
      attribute :issues, Issue, collection: true

      key_value do
        map "format", to: :format
        map "width", to: :width
        map "height", to: :height
        map "dpi", to: :dpi
        map "color_space", to: :color_space
        # render_empty, so a handler that deliberately reported an empty
        # `meta` gets `{}` back rather than nil. Without it the key is
        # omitted from JSON and reloads as nil, turning "I looked and
        # there was nothing" into "I did not look".
        map "meta", to: :meta, render_empty: true
        map "parse_status", to: :parse_status
        map "issues", to: :issues, render_empty: true
      end

      # Deserialization wraps the value in the type instance rather than
      # casting it back: lutaml wraps any Hash whose attribute type is
      # not EXACTLY `Type::Hash`, and `FreeFormHash` is a subclass. A
      # caller asked for a Hash and gets one whichever way the model was
      # built.
      #
      # The ivar directly, not `super`: 0.8.19 defines attribute readers
      # with `define_method` on this very class, so writing one here
      # replaces it and there is no superclass method to reach.
      #
      # `*args` because the generated reader doubles as the builder-form
      # setter -- `Inspection.new { |i| i.meta("a" => 1) }`. A zero-arity
      # reader made `meta` the one attribute that form could not set.
      def meta(*args)
        unless args.empty?
          self.meta = args.first
          return args.first
        end

        raw = @meta
        raw.is_a?(Lutaml::Model::Type::Value) ? raw.value : raw
      end

      private

      def normalize
        self.issues = [] if issues.nil?
      end

      def validate_types
        super
        refuse_unrenderable
      end

      # `meta` is stored verbatim, and JSON is what the CLI reports, so a
      # meta JSON will not write leaves an Inspection nothing can report:
      # the model took the value, froze around it, and the
      # `JSON::GeneratorError` surfaced later, nowhere near the handler
      # that supplied it.
      #
      # Rendered rather than inspected, because the list of what JSON
      # refuses is longer than it looks and every item of it would be a
      # guess at another library's rules. Measured: Infinity and NaN, a
      # String that will not become UTF-8 (`"\xFF".b` is valid
      # ASCII-8BIT and still unwritable, while Latin-1 and UTF-16 are
      # both fine, so `valid_encoding?` is not the rule), a container
      # that leads back to itself, and anything nested past the depth
      # limit. Everything else survives as a String -- a Symbol, a Range
      # and a bare Object all render.
      #
      # `JSON.generate` with its defaults, because that is exactly what
      # lutaml renders with (json/standard_adapter.rb:34), so this asks
      # the same question the same way.
      #
      # Under the same key it will occupy in the document, because the
      # depth limit is counted from the outside: rendered bare, a meta
      # nested 100 deep passes here and the `to_json` that follows still
      # raises, since the document puts one more level above it.
      # Measured, the two agree at every depth from 96 to 103 -- both
      # refuse 100 and both take 99.
      #
      # Only `meta` needs it: lutaml scrubs a declared `:string`
      # attribute to valid UTF-8 on the way in, and `validate_finite`
      # covers the declared numbers.
      def refuse_unrenderable
        raw = meta
        return if raw.nil?

        JSON.generate({ "meta" => raw })
      rescue JSON::JSONError => e
        refuse("meta", "values JSON can render", e.message)
      end

      # Base freezes Strings and collections, so `meta` has to be sealed
      # here -- and sealed all the way down, because the container is the
      # only part of it the model owned. Measured on a sealed Inspection,
      # against the shapes real handlers produce: SVG root attributes
      # arrive as mutable Strings and an EMF `frame` arrives as a nested
      # Hash, and writing through the caller's own reference to either
      # changed a frozen Inspection's JSON. Two of those writes went
      # further and left it with no JSON at all -- replacing a nested
      # String with invalid binary raised `JSON::GeneratorError`, and
      # closing a nested Hash into a cycle raised `JSON::NestingError`,
      # both from a `to_json` long after `refuse_unrenderable` had passed
      # the value it was given.
      #
      # A copy first and a freeze second, never a freeze in place:
      # `FreeFormHash.cast` copies the container and nothing below it, so
      # every Hash, Array and String nested inside `meta` is still the
      # caller's object. Sealing those where they lie would take a
      # handler's own data away from it, which is a defect of its own.
      #
      # Read through the reader and written straight back to the ivar,
      # which collapses the two shapes `meta` is stored in. Construction
      # keeps a bare Hash and deserialization keeps one inside a
      # FreeFormHash, and the wrapper was a second object to seal -- one
      # that got missed, measured: after `from_json`,
      # `@meta.instance_variable_set(:@value, {"changed" => true})` gave
      # a frozen Inspection a different `meta` and different JSON without
      # ever touching a frozen object. Sealing replaces the ivar outright
      # rather than reaching into the wrapper, so after this both doors
      # hold the same bare frozen Hash and there is no second object left
      # to repoint. The reader keeps its unwrap because it also runs
      # during deserialization, before this does.
      def freeze_attributes
        super
        @meta = sealed_copy(meta)
      end

      # Read the graph through core Hash, Array and String, never
      # through the methods on the object in hand. `meta` is whatever a
      # handler put there, and a subclass gets to redefine what a
      # traversal returns -- measured, an Array whose `map` returns
      # `self` left the caller's own Array frozen AND still shared, so a
      # mutable String nested in it went on changing a sealed
      # Inspection's JSON. One override, both halves of the copy
      # defeated. Copies come back as plain core objects, which is what
      # the JSON graph `meta` describes was made of anyway.
      HASH_PAIRS = ::Hash.instance_method(:each_pair)
      HASH_BY_IDENTITY = ::Hash.instance_method(:compare_by_identity?)
      ARRAY_ELEMENTS = ::Array.instance_method(:each)
      private_constant :HASH_PAIRS, :HASH_BY_IDENTITY, :ARRAY_ELEMENTS

      # The model's own copy of the JSON graph `meta` describes, frozen
      # at every level.
      #
      # Values only. A Hash key is carried across exactly as it arrived,
      # because JSON never descends into one: a String key renders as
      # itself, and every other key renders through `to_s`. That is
      # precisely the case the `else` branch below already declines to
      # pin, so keys are not a second rule -- they are the same one.
      #
      # Walking them was also the only part of this recursion nothing
      # bounded. `refuse_unrenderable` bounds the values, because
      # `JSON.generate` has already walked them and refused a cycle or a
      # graph too deep to write. It never looks inside a key, so both
      # shapes sail through it -- measured, `{[[...self...]] => 1}` and a
      # key nested 5,000 deep each render fine and each then took
      # `Inspection.new` down with `SystemStackError`. A model JSON can
      # render must not be refused by our own sealing, least of all by
      # crashing.
      #
      # Ruby freezes and copies an unfrozen String key on insert into an
      # ordinary Hash (measured across every insertion path: literal,
      # `[]=`, `store`, `merge`, `to_h`, `Hash[]` and `JSON.parse`), so
      # those keys are already pinned and already ours. The one Hash that
      # does not do this is one comparing by identity, and its keys stay
      # the handler's along with every other key.
      #
      # Identity comparison is carried across with them. Rebuilt as an
      # ordinary Hash, keys that are `==` but not the same object merge
      # -- measured, a two-entry Hash sealed as one entry, silently
      # dropping what a handler had reported.
      #
      # Everything that is not a Hash, an Array or a String is left
      # exactly as it arrived. Numbers, Symbols, `true`, `false` and
      # `nil` cannot change, and an arbitrary object a handler chose to
      # attach is the handler's, not ours -- JSON renders it through
      # `to_s`, and freezing someone else's object to pin that would be
      # the very thing the copy above exists to avoid.
      #
      # `Ractor.make_shareable(value, copy: true)` does all of this in C
      # and was measured rather than assumed: it refuses values this
      # model accepts. A Proc or a lambda in `meta` renders through
      # `to_s` and passes `refuse_unrenderable`, and `make_shareable`
      # then raises `TypeError: allocator undefined for Proc` from inside
      # `seal` -- trading a stored value for a crash, in a gem that
      # starts no Ractors.
      def sealed_copy(value)
        case value
        when ::Hash then sealed_hash(value)
        when ::Array then sealed_array(value)
        # Copied even when it is already frozen, because asking would
        # mean trusting `frozen?` on an object whose class a handler
        # wrote. A `meta` graph is small and the answer costs one String.
        when ::String then ::String.new(value).freeze
        else value
        end
      end

      def sealed_hash(hash)
        copy = {}
        copy.compare_by_identity if HASH_BY_IDENTITY.bind_call(hash)
        HASH_PAIRS.bind_call(hash) { |key, value| copy[key] = sealed_copy(value) }
        copy.freeze
      end

      def sealed_array(array)
        copy = []
        ARRAY_ELEMENTS.bind_call(array) { |element| copy << sealed_copy(element) }
        copy.freeze
      end

      def nested_models
        issues
      end
    end
  end
end
