# frozen_string_literal: true

require_relative "../errors"
require_relative "../lossiness"
require_relative "../models/conversion"

module Claricle
  module Handlers
    # What a handler declares so that adding its format is that one class and
    # no edit elsewhere: how the format is recognised, what it can be
    # converted from, and what that conversion loses. Included by Base.
    module ExtensionPoints
      # Bounds the READ of a source being converted INTO a handler's format,
      # the same limit every outbound converter applies.
      MAX_CONVERT_BYTES = 200 * 1024 * 1024
      private_constant :MAX_CONVERT_BYTES

      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        # How this format is recognised: a block handed the first bytes of
        # the input (a binary String, at most `Detector::HEADER_BYTES`),
        # answering one of this handler's own formats as a Symbol, or nil.
        # The built-in probes run first and this runs only for input none
        # of them claimed, so a new format cannot change what an existing
        # one detects. A Symbol outside `formats` is a defect in the
        # handler and raises where it happens, not later as a routing miss.
        def detect(&probe)
          raise ArgumentError, "detect needs a block" unless probe
          raise Error, "#{self} already declared a detector" if @detector

          @detector = probe
        end

        def detect_format(header)
          format = @detector&.call(header)
          return format if format.nil? || supported_formats.include?(format)

          raise Error, "#{self} detected #{format.inspect}, which it did not declare in formats"
        end

        # Declares that this handler can PRODUCE its formats from the given
        # source formats. The block receives the source bytes and the
        # target format and returns the converted bytes. Declared on the
        # target's handler, so adding a format never edits the source's.
        # A source handler that already lists the target in `convert_to`
        # keeps its own path.
        def convert_from(*sources, &producer)
          raise ArgumentError, "convert_from needs a block" unless producer

          bad = sources.grep_v(Symbol)
          raise Error, "#{self} declared non-Symbol convert sources #{bad.inspect}" if bad.any?

          sources.each do |source|
            raise Error, "#{self} already declared a converter from #{source.inspect}" if converters.key?(source)

            converters[source] = producer
          end
        end

        def converters
          @converters ||= {}
        end

        def convert_sources
          converters.keys
        end

        # The SVG features converting INTO this format loses and keeps, in
        # the vocabulary of `Lossiness`. Optional: without it a conversion
        # into this format is reported `unknown`, never `lossless`.
        def loss_rules(lost:, kept:)
          raise Error, "#{self} already declared loss rules" if @loss_rule

          @loss_rule = { lost: lost.freeze, kept: kept.freeze }.freeze
        end

        attr_reader :loss_rule
      end

      # Converts `image` INTO one of this handler's formats, through the
      # producer declared with `convert_from` for the image's format.
      # Reached from `Image#convert` only when the source's own handler
      # does not list the target.
      def convert_inbound(image, to:)
        producer = self.class.converters.fetch(image.format) do
          raise UnsupportedFormat.new(image.format, :convert, target: to)
        end
        content = bounded_content(image)
        conversion(image, to, content, produce(producer, content, to))
      end

      private

      def conversion(image, to, content, converted)
        loss = Lossiness.classify(source_format: image.format, target_format: to,
                                  source: content, rule: self.class.loss_rule)
        Models::Conversion.new(source_path: image.path, source_format: image.format.to_s,
                               target_format: to.to_s, lossiness: loss, content: converted)
      end

      def bounded_content(image)
        content = image.with_source { |source| bounded_read(source) }
        return content if content.bytesize <= MAX_CONVERT_BYTES

        raise ConversionError, "#{image.format} image exceeds the #{MAX_CONVERT_BYTES}-byte convert limit"
      end

      def bounded_read(source)
        return source.read(MAX_CONVERT_BYTES + 1) || "".b if source.respond_to?(:read)

        source.byteslice(0, MAX_CONVERT_BYTES + 1)
      end

      # Scoped to the producer alone: what the producer raises is not ours
      # to enumerate, and the rest of `convert_inbound` is.
      def produce(producer, content, to)
        producer.call(content, to)
      rescue StandardError => e
        raise ConversionError, "#{e.class}: #{e.message}"
      end
    end
  end
end
