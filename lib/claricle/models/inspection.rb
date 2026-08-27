# frozen_string_literal: true

require "json"

require_relative "base"
require_relative "free_form_hash"
require_relative "issue"

module Claricle
  module Models
    # Owns Inspection's free-form metadata boundary. Keeping the grammar
    # and canonical copy together makes the graph accepted during
    # validation exactly the frozen graph stored by the model.
    module Metadata
      DUPLICATE = ::Object.instance_method(:dup)
      HASH_BY_IDENTITY = ::Hash.instance_method(:compare_by_identity?)
      HASH_EMPTY = ::Hash.instance_method(:empty?)
      HASH_SHIFT = ::Hash.instance_method(:shift)
      HASH_SIZE = ::Hash.instance_method(:size)
      STRING_ENCODE = ::String.instance_method(:encode)
      META_MAX_DEPTH = ::JSON::State.new.max_nesting - 1
      META_SCALARS = [::Integer, ::Float, ::TrueClass, ::FalseClass, ::NilClass].freeze
      private_constant :DUPLICATE, :HASH_BY_IDENTITY, :HASH_EMPTY,
                       :HASH_SHIFT, :HASH_SIZE, :STRING_ENCODE,
                       :META_MAX_DEPTH, :META_SCALARS

      private

      def unwrap_meta(value)
        core_instance?(value, FreeFormHash) ? value.value : value
      end

      # Copies iteratively so cycles terminate and over-deep graphs stop
      # at JSON's own nesting boundary. The canonical copy is also the
      # graph later stored, so validation and storage cannot observe
      # different virtual views.
      def canonical_meta(value)
        return if value.nil?

        copy = copy_meta_graph(value)
        JSON.generate({ "meta" => copy })
        copy
      rescue JSON::JSONError => e
        refuse("meta", "values JSON can render", e.message)
      end

      def copy_meta_graph(root)
        refuse_meta(root) unless core_instance?(root, ::Hash)

        copies = {}.compare_by_identity
        copy = new_container(root)
        copies[root] = copy
        pending = [[root, copy, 1]]
        populate_meta_copy(pending, copies) until pending.empty?
        copies.each_value(&:freeze)
        copy
      end

      def populate_meta_copy(pending, copies)
        source, target, depth = pending.pop
        return populate_hash(source, target, pending, copies, depth) if core_instance?(source, ::Hash)

        each_array(source) do |item|
          target << copy_meta_value(item, pending, copies, depth + 1)
        end
      end

      def populate_hash(source, target, pending, copies, depth)
        work = DUPLICATE.bind_call(source)
        until HASH_EMPTY.bind_call(work)
          key, item = HASH_SHIFT.bind_call(work)
          refuse_meta(key) unless core_instance?(key, ::String)

          target[canonical_meta_key(key)] = copy_meta_value(item, pending, copies, depth + 1)
        end
        refuse_meta(source) unless HASH_SIZE.bind_call(source) == HASH_SIZE.bind_call(target)
      end

      def canonical_meta_key(key)
        STRING_ENCODE.bind_call(key, Encoding::UTF_8).freeze
      rescue EncodingError => e
        refuse("meta", "UTF-8 String keys", e.message)
      end

      def copy_meta_value(value, pending, copies, depth)
        return ::String.new(value).freeze if core_instance?(value, ::String)
        return value if META_SCALARS.include?(class_of(value))
        return refuse_meta(value) unless core_instance?(value, ::Hash) || core_instance?(value, ::Array)

        refuse_meta_depth if depth > META_MAX_DEPTH
        return copies[value] if copies.key?(value)

        new_container(value).tap do |copy|
          copies[value] = copy
          pending << [value, copy, depth]
        end
      end

      def new_container(source)
        return [] if core_instance?(source, ::Array)

        refuse_meta(source) if HASH_BY_IDENTITY.bind_call(source)
        {}
      end

      def refuse_meta(value)
        got = class_of(value)
        refuse("meta", "core JSON values under String keys", got)
      end

      def refuse_meta_depth
        refuse("meta", "values JSON can render", "nesting exceeds #{META_MAX_DEPTH}")
      end
    end

    # Inspection reports whether metadata parsed, and makes no validity
    # claim -- that belongs to conform alone (D17).
    class Inspection < Base
      include Metadata

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

        unwrap_meta(@meta)
      end

      private

      def normalize
        self.issues = [] if issues.nil?
      end

      def validate_types
        super
        canonical = canonical_meta(meta)
        @meta = canonical unless object_frozen?(self)
      end

      def nested_models
        issues
      end
    end

    private_constant :Metadata
  end
end
