# frozen_string_literal: true

require "tempfile"

require_relative "detector"
require_relative "registry"

module Claricle
  # What every operation takes and the registry dispatches on. Built from a
  # path or from content; either way it knows its format.
  #
  # A path-born image is a handle to a file, not a snapshot of it.
  # `format` is the verdict `from_path` reached from the bytes that were
  # there at construction, and `content` and `with_path` go back to that
  # name afterwards. So the file must not change while an image is in
  # use -- measured: a detected PNG overwritten with a valid SVG kept
  # reporting :png, and every later read saw the SVG.
  #
  # Stated rather than enforced, deliberately. Binding the format to one
  # generation of bytes means holding that generation, which costs a
  # file-sized allocation retained for the image's whole lifetime -- the
  # reason `content` is lazy here at all, and the reason a handler that
  # only needs a header should never reach for it. A `stat` taken at
  # construction and rechecked on every read would not close the race
  # either: `with_path` hands out a name, and whatever opens that name
  # does so after the check. It would narrow the window in exchange for
  # a guarantee this cannot keep.
  #
  # What a file replaced mid-flight costs is a wrong label on an honest
  # failure -- the handler for the format detected first reports that it
  # could not parse the bytes that are there now. A content-born image
  # has no such window: its bytes and its format are settled together
  # and it owns both.
  class Image
    attr_reader :format, :path

    KIND_OF = ::Object.instance_method(:is_a?)
    CLASS_OF = ::Object.instance_method(:class)
    private_constant :KIND_OF, :CLASS_OF

    class << self
      def from_path(path)
        # Checked before anything opens it, for the same reason `binary`
        # runs first in `from_content`. `Detector.detect_path` opens
        # whatever it is handed and `File.open` takes a descriptor as
        # happily as a name -- measured: `Image.from_path(io.fileno)`
        # detected :png, and by the time `initialize` refused the Integer
        # the caller's IO read `Errno::EBADF` while `io.closed?` still
        # said false.
        name = checked_path(path)
        new(format: Detector.detect_path(name), path: name)
      end

      def from_content(content, format: nil)
        # Bytes settled first: detection reads them, so a non-String would
        # die inside the detector with a NoMethodError before the
        # constructor could name what was actually wrong.
        content = binary(content)
        # nil means "detect"; anything else is the caller's answer,
        # including a false one, which the Symbol guard then rejects.
        new(format: format.nil? ? Detector.detect(content) : format, content: content)
      end

      private

      def checked_format(format)
        return format if KIND_OF.bind_call(format, ::Symbol)

        raise ArgumentError, "format must be a Symbol, got #{CLASS_OF.bind_call(format)}"
      end

      def checked_source(path, content)
        return if path.nil? ^ content.nil?

        raise ArgumentError, "give exactly one of path: or content:"
      end

      # A path is read and joined, so it has to be a name -- and one this
      # image owns, for the same reason it owns its bytes. Measured:
      # `path.replace(other_file)` after `from_path(path)` left the image
      # reading the other file while still reporting the format detected
      # from the first, and `image.path << "x"` rewrote it through the
      # reader. A fresh core String makes that ownership independent of
      # a subclass's virtual `frozen?` and `dup`.
      #
      # Refused rather than assumed, because `false` would clear the
      # exactly-one check in `initialize` and then read as "no path" in
      # `with_path`, so the image took the temporary-file branch and died
      # on `File.binread(false)`.
      def checked_path(path)
        unless KIND_OF.bind_call(path, ::String)
          raise ArgumentError, "path must be a String, got #{CLASS_OF.bind_call(path)}"
        end

        ::String.new(path).freeze
      end

      # Bytes this image owns, whatever the caller tagged them.
      # `File.binread` already gives binary; detection binary-copies its
      # own view (`Detector.detect`) and never the String we keep, so a
      # content-born image was the one place `content` depended on how the
      # caller happened to read the file. Measured: the same 70-byte PNG
      # through `File.read` arrives UTF-8, where `length` is 69 and
      # `valid_encoding?` is false -- a handler indexing or scanning it
      # would disagree with the path-born image.
      #
      # Copied and frozen, not merely re-tagged. An Image is a value, and
      # a caller who kept their String could otherwise rewrite the bytes
      # out from under the format we detected -- measured:
      # `bytes.replace("not a PNG")` after `from_content(bytes)` left the
      # image reporting :png over nine bytes of text. Every input is
      # normalized through a fresh core String: a subclass can lie about
      # `b`, `dup`, `frozen?` or `encoding`, and even an exact frozen
      # String can give `b` singleton behavior that makes detection see
      # different bytes from the ones the image stores.
      #
      # Refused rather than assumed, because `false` clears the
      # exactly-one check in `initialize` and is still falsy -- measured:
      # `Image.new(format: :png, content: false)` built an image, and its
      # `content` then read the nil path and raised "no implicit
      # conversion of nil into String".
      def binary(bytes)
        unless KIND_OF.bind_call(bytes, ::String)
          raise ArgumentError, "content must be a String, got #{CLASS_OF.bind_call(bytes)}"
        end

        ::String.new(bytes).force_encoding(Encoding::BINARY).freeze
      end
    end

    def initialize(format:, path: nil, content: nil)
      self.class.send(:checked_format, format)

      path = self.class.send(:checked_path, path) unless path.nil?
      # Exactly one source. Neither leaves #content reading from a nil
      # path; both is contradictory and would silently prefer one.
      self.class.send(:checked_source, path, content)
      content = self.class.send(:binary, content) unless content.nil?

      @format = format
      @path = path
      @content = content
    end

    # Read lazily and then remembered. Detection already streamed the file;
    # slurping it at construction would waste that. Frozen for the same
    # reason a content-born image keeps a copy: a handler that mutated
    # these bytes in place would change what every later handler sees.
    #
    # Remembered, so this and `with_path` can disagree: whichever ran
    # first fixes what it saw, and the other reads the file again. They
    # agree exactly as long as the file does not change, which is the
    # contract stated on the class.
    def content
      @content ||= File.binread(path).freeze
    end

    # Most delegates want a path. A content-born image gets a temporary one
    # that exists only for the block -- Tempfile.create's block form removes
    # it on exit, where Tempfile.new would leave it behind.
    def with_path
      raise ArgumentError, "with_path requires a block" unless block_given?
      return yield(path) if path

      Tempfile.create(["claricle", ".#{format}"]) do |file|
        file.binmode
        file.write(content)
        file.flush
        yield(file.path)
      end
    end

    def inspection
      handler.inspection(self)
    end

    def conformance_report
      handler.conformance_report(self)
    end

    def convert(to:)
      handler.convert(self, to: to)
    end

    private

    # Per call: handlers are stateless, and a cache would buy nothing.
    def handler
      Registry.handler_for(format).new
    end

    # Refused, rather than supported. Ruby's default Marshal writes the
    # ivars into a fresh object and runs neither the constructor nor any
    # of its guards -- and it does not carry a String's freeze, so the
    # copy is writable through its own readers. Measured:
    # `copy.content.replace("NOT A PNG AT ALL")` left the copy reporting
    # :png over sixteen bytes of text, and `copy.path.replace("/etc/passwd")`
    # pointed a path-born image at another file while it still reported
    # the format detected from the first.
    #
    # Nothing in this gem forks, caches or crosses a process boundary, so
    # an image is not dumped at all rather than dumped through hooks of
    # its own. The dump side only: `Marshal.load` of bytes from elsewhere
    # is as unsafe here as it is anywhere. Private, because Marshal
    # reaches a private `_dump` -- measured -- and `_dump` rather than
    # `marshal_dump` because Ruby prefers `marshal_dump` where both exist.
    def _dump(_depth)
      raise TypeError, "cannot marshal #{self.class}: a Claricle image is not marshalable"
    end
  end
end
