# frozen_string_literal: true

require "timeout"

require_relative "base"
require_relative "../models/inspection"
require_relative "../models/issue"

module Claricle
  module Handlers
    # Reports a PDF's version and, when it can be read honestly, its
    # DECLARED page count. Dimensions are deliberately absent: reaching
    # the first page's box safely needs a cycle-guarded page-tree walk in
    # both directions, per-element dereferencing and corner
    # normalisation, none of which pdfrb offers -- measured on 0.7.23 and
    # re-verified on 0.7.49, which is what resolves here,
    # `page.media_box` hangs forever on a self-referential `/Parent`, and
    # `[0 0]` reads back as a 0x0 page invented whole.
    class Pdf < Base
      formats :pdf

      # A PDF header line longer than a kilobyte is not a header. The
      # read is HEADER_SCAN_BYTES + 1 so "the first line is exactly 1024
      # bytes and ends" is distinguishable from "the first line is at
      # least 1025 bytes" -- measured: `read(1025)` returns 1024 bytes at
      # a 1024-byte EOF and 1025 otherwise.
      HEADER_SCAN_BYTES = 1024

      # An interactive budget, NOT a safe upper bound, and the difference
      # is the whole of the tradeoff.
      #
      # It bounds TIME, not memory. Measured: a 190 KB file whose object
      # stream decodes to 200 MB allocated +190.8 MB *inside* a
      # five-second window and then timed out, so the deadline fired and
      # the memory was spent anyway.
      #
      # It is justified by the inputs that are actually slow rather than
      # by any claim about all of them. Measured: a `/Prev` pointing at
      # its own xref offset never returns at all; resolving one Catalog
      # from that 190 KB file took 29.61 s. A legitimately slow document
      # -- a large file on slow storage -- is reported "failed" when it
      # was merely slow, and that is the accepted cost. The alternative
      # is a CLI that never returns.
      DEADLINE_SECONDS = 5

      HEADER_CODE = "pdf.header_unreadable"
      OPEN_CODE = "pdf.unreadable"
      STRUCTURE_CODE = "pdf.structure_unreadable"
      TIMEOUT_CODE = "pdf.timeout"

      # One code per cause. The four sibling handlers each ship exactly
      # one, because each has exactly one failure event. This handler has
      # four a consumer can tell apart: the header never parsed, the file
      # would not open, the structure would not resolve, and the clock
      # ran out. Collapsing them reported "PDF structure could not be
      # read" for files whose structure was never reached.
      # All FOUR, so a reader scanning this sees every failure mode. The
      # timeout message interpolates `DEADLINE_SECONDS`, which is defined
      # above, so the number can never drift from the value that produced
      # it -- and there is only ever one deadline, so building the string
      # per call bought nothing but a method and a branch.
      MESSAGES = {
        HEADER_CODE => "PDF header is not a valid version declaration",
        OPEN_CODE => "PDF could not be opened",
        STRUCTURE_CODE => "PDF structure could not be read",
        TIMEOUT_CODE => "PDF could not be read within #{DEADLINE_SECONDS} seconds"
      }.freeze

      private_constant :HEADER_SCAN_BYTES, :DEADLINE_SECONDS, :HEADER_CODE,
                       :OPEN_CODE, :STRUCTURE_CODE, :TIMEOUT_CODE, :MESSAGES

      # The file's own bytes decide the version, never the delegate.
      # `Document.open` succeeds on an empty file and the document it
      # returns still REPORTS a version -- measured, `"1.4"` for empty,
      # for garbage and for a `%PDF-x.y` header alike. A fabricated
      # default is worse than no answer, so the gate reads the
      # declaration itself and reports the token it captured.
      module VersionGate
        # A COMPLETE declaration, terminated. `\A%PDF-(\d+\.\d+)` alone
        # validates a numeric PREFIX: measured, it captures "1.7" for
        # both `%PDF-1.7junk` and `%PDF-1.7.2`, neither of which is
        # version 1.7. The lookahead is what refuses them.
        GATE = /\A%PDF-(\d+\.\d+)(?=[\r\n]|\z)/
        TERMINATOR = /[\r\n]/
        private_constant :GATE, :TERMINATOR

        module_function

        # The capture holds digits and a dot only, so re-tagging it UTF-8
        # is always valid -- confirmed against content carrying 0xFF 0xFE
        # 0x80 right behind the header.
        def version(path)
          prefix = read(path)
          return unless terminated?(prefix)

          match = GATE.match(prefix)
          match && match[1].force_encoding(Encoding::UTF_8)
        end

        # The YIELDED path, not `image.content` and not `with_source`.
        # For a content-born image `with_source` hands over the bytes in
        # memory while pdfrb reads the tempfile `with_path` wrote, so the
        # gate and the delegate would be reading two different objects.
        # Opening the yielded path keeps every read on the same bytes.
        def read(path)
          File.open(path, "rb") { |file| file.read(HEADER_SCAN_BYTES + 1) } || "".b
        end

        # `\z` anchors to the end of the STRING SUPPLIED, not to physical
        # EOF, so without this a bounded read would let the anchor pass
        # on a line it only saw part of. Measured, and the third row is
        # the dangerous one: nine bytes of `%PDF-12.345` capture "12.3"
        # -- not a refusal, a plausible WRONG version reported silently.
        #
        # A short read is a real end of file, so `\z` means what it says
        # there. A full read with no terminator in it is a first line of
        # at least HEADER_SCAN_BYTES + 1 bytes, and that is refused.
        def terminated?(prefix)
          prefix.bytesize <= HEADER_SCAN_BYTES || prefix.match?(TERMINATOR)
        end
      end
      private_constant :VersionGate

      # pdfrb resolves by object NUMBER alone -- measured, `/MediaBox 4 9 R`
      # returns object `4 0`, and a compressed object addressed `1 1 R`
      # resolves happily because `add_compressed` never records a
      # generation for the reader to compare. So every reference this
      # handler follows is checked against the xref before resolution,
      # and that check is the entire generation guarantee.
      module Resolver
        RESOLVABLE = %i[in_use compressed].freeze
        private_constant :RESOLVABLE

        module_function

        # Anything that is not a Reference is refused DETERMINISTICALLY
        # rather than left to raise downstream. `Document#object` returns
        # a non-Reference unchanged -- measured, `object(nil)` is nil,
        # `object(7)` is 7 -- so an absent, dangling or scalar `/Pages`
        # used to reach a `NoMethodError` on the `.value` after it and be
        # right by accident.
        #
        # A `/Pages` written as a DIRECT dictionary is refused too. PDF
        # requires it to be indirect and every file measured here writes
        # it that way, but a producer that inlined it would be reported
        # "failed". Accepted, and recorded rather than hidden.
        #
        # For a COMPRESSED reference this cannot prove the object it
        # received is the object the file recorded at that index: pdfrb's
        # object-stream reader discards the number stored there and wraps
        # the value with the number that was asked for. That is a
        # limitation of object numbers, not of generations.
        def resolve(document, value)
          return unless value.is_a?(::Pdfrb::Model::Reference)

          entry = document.xref&.[](value.oid)
          return unless entry && RESOLVABLE.include?(entry.type)
          return unless entry.gen.to_i == value.gen

          document.object(value)
        end
      end
      private_constant :Resolver

      # What the timeout block managed to establish. A local carrier and
      # never an ivar: `image.rb:231` builds a handler per call precisely
      # so it holds no per-call state, and the outer rescue has to tell
      # an expiry BEFORE the structure gate from one after it.
      Progress = Struct.new(:version, :node, :page_count, :code)
      private_constant :Progress

      # One deadline over the whole operation, never one per stage: five
      # stages each granted five seconds is a twenty-five second worst
      # case wearing a five-second label.
      #
      # The expiry is caught OUTSIDE the block, and the default form is
      # not a style choice. Measured on Ruby 3.4.8: `Timeout.timeout(n)`
      # raises an internal `Timeout::ExitException` inside the block --
      # not a `StandardError` -- and translates it to `Timeout::Error`
      # only outside, so a stage-local rescue catches nothing. The
      # explicit `Timeout.timeout(n, Timeout::Error)` form is worse: it
      # makes a real `Timeout::Error` fly inside the block, where the
      # inner rescue swallows it and the outer one sees nothing.
      #
      # `require "pdfrb"` sits in this method rather than at the top of
      # the file because `registry.rb` requires every handler eagerly.
      # Measured, best of 9 on a monotonic clock: bare `ruby -e ""` is
      # 33.1 ms and `ruby -e 'require "pdfrb"'` is 76.8 ms, so a
      # top-level require would put ~43 ms on every `claricle version`
      # and every `--help`, for a delegate most invocations never touch.
      #
      # It sits OUTSIDE the Timeout block, and that is not cosmetic.
      # Measured: with the require inside, a deadline expiring during it
      # left `Pdfrb` undefined and the next line raised a bare
      # `NameError` -- which is not on any rescue list here, so it
      # escaped `inspection` instead of reporting `"failed"`. The
      # deadline exists to bound reading an untrusted FILE; loading our
      # own dependency is fixed work that no input controls.
      #
      # The node is the flag. Nil means the deadline expired before the
      # structure gate passed, which is "failed"; non-nil means it
      # expired reading an optional field, which is "ok" with the count
      # omitted. A separate boolean would shadow a value that already
      # carries the same information.
      def inspection(image)
        progress = Progress.new
        require "pdfrb"
        begin
          Timeout.timeout(DEADLINE_SECONDS) { run_stages(image, progress) }
        rescue Timeout::Error
          # `||=`, because a code already set names a cause the run
          # actually reached. A structure gate that refused sets
          # STRUCTURE_CODE with the node still nil, and a deadline
          # expiring during the unwind after it would otherwise relabel
          # that refusal `pdf.timeout` -- one code per cause, reporting
          # the wrong one.
          progress.code ||= TIMEOUT_CODE unless progress.node
        end
        return failure(image, progress.code) if progress.code

        readable(image, progress)
      end

      private

      # Every read happens inside `with_path`. The handler never calls
      # `image.content` itself: `with_path` calls it once for a
      # content-born image, to write the tempfile pdfrb needs, and that
      # returns the string the image already retains rather than making a
      # second copy. A path-born inspection materialises nothing.
      def run_stages(image, progress)
        image.with_path do |path|
          progress.version = VersionGate.version(path)
          next progress.code = HEADER_CODE unless progress.version

          open_document(path, progress)
        end
      end

      # The BLOCK form, always. Measured on a 1 MB file: the non-block
      # branch is `File.binread(path)` into a `StringIO` held for the
      # document's life, whose `string` is exactly the file; the block
      # form's `doc.io` is a `File` handle that does not respond to
      # `string` at all.
      #
      # `Errno::ENOENT` is deliberately NOT rescued. pdfrb opens the file
      # itself and `with_path` re-yields a path-born image's path without
      # holding the handle, so a file deleted between the header read and
      # this call raises it -- and reporting "failed" would claim the PDF
      # is unreadable when it is simply gone.
      def open_document(path, progress)
        ::Pdfrb::Document.open(path) do |document|
          progress.node = guarded { structure_gate(document) }
          next progress.code = STRUCTURE_CODE unless progress.node

          progress.page_count = guarded { count_read(document, progress.node) }
        end
      rescue *parse_failures, Errno::EINVAL
        progress.code = OPEN_CODE
      end

      # One list, named once, because it is one policy. NOT a hoisted
      # constant: `::Pdfrb::Error` cannot be resolved at class-definition
      # time while the require is lazy -- measured, a
      # `PARSE_FAILURES = [::Pdfrb::Error, ...]` constant makes
      # `require "claricle"` itself die with
      # `uninitialized constant Pdfrb (NameError)`. The sibling
      # `metafile.rb:239` can hold its equivalent as a constant only
      # because `metafile.rb:3` requires `emf` at the top of the file.
      # A method defers the lookup to call time, when pdfrb is loaded.
      #
      # `Errno::EINVAL` is deliberately NOT in the list. It is reachable
      # only from a negative `/Prev` consumed during `open`, so it
      # belongs to that rescue alone; adding it to `guarded` would widen
      # the gates for a class they cannot see.
      def parse_failures
        [::Pdfrb::Error, NoMethodError, TypeError, RangeError,
         ArgumentError, SystemStackError]
      end

      # Returns nil when the DELEGATE could not read what was asked for.
      #
      # This wraps a whole method, not one delegate expression, so the
      # allowlist also catches classes this handler's own logic could
      # raise and a bug here would be reported as a corrupt PDF. That is
      # a known cost, not a closed hole. The `&.` on every value the
      # resolver may refuse does NOT move that handling outside this
      # region -- it is inside it. What it does is stop those values
      # raising here at all, so the classes below stay reachable only
      # from the delegate.
      #
      # `NoMethodError` on the list is the real cost. Everywhere else it
      # signals a broken delegate; here pdfrb raises it for ordinary
      # corrupt files -- a free object-stream xref entry, a trailing
      # backslash in a compressed body -- and nothing at the call site
      # distinguishes the two. Crashing on a corrupt PDF is worse.
      def guarded
        yield
      rescue *parse_failures
        nil
      end

      # What proves a document exists at all. A header-only `%PDF-1.4\n`
      # passes the version gate -- the version is genuinely readable --
      # and opens without complaint; only this refuses it.
      #
      # The trailer nil check is part of the gate, not a rescue.
      # Measured: `document.trailer` is nil on a header-only file, on an
      # empty one, on garbage and on one truncated mid-body, so
      # `trailer[:Root]` raises `NoMethodError` before any check runs.
      # Resting the refusal on that would rest it on this handler's own
      # missing nil check rather than on pdfrb's error handling.
      def structure_gate(document)
        return unless document.trailer

        catalog = typed(Resolver.resolve(document, document.trailer[:Root]), :Catalog)
        return unless catalog

        typed(Resolver.resolve(document, catalog.value[:Pages]), :Pages)
      end

      # The `&.` is load-bearing, not defensive noise: `Resolver.resolve`
      # returns nil on every refusal, and a bare `.value` would raise
      # `NoMethodError` to be caught by `guarded` and reported as a
      # rescued delegate failure -- right by accident.
      def typed(object, name)
        object if object&.value&.[](:Type) == name
      end

      # `pages.count` is never called. Measured, it is not a declaration:
      # sometimes the declared `/Count`, sometimes computed by walking
      # `/Kids`, sometimes fabricated -- and on a self-cycling `/Kids`
      # tree with `/Count` missing it raises `SystemStackError`.
      # `Catalog#page_count` is forbidden too, because calling it MUTATES
      # the Catalog: measured, `catalog.value[:Pages]` is a `Reference`
      # before and a resolved `PageTreeNode` after, which leaves the
      # generation guard with nothing to check.
      #
      # THE DECLARED COUNT, which can disagree with the real one without
      # bound: a document with one leaf page declaring `/Count 999`
      # reports 999. Nothing traverses the page tree to check it.
      #
      # `Integer` is a correctness requirement, not taste. Measured,
      # `Models::Inspection` refuses a non-core leaf in `meta` with
      # `Lutaml::Model::ValidationError`, and a Name arrives as a Symbol
      # -- so putting a raw `:Bad` in `meta["pages"]` would not report a
      # bad count, it would raise out of the model.
      def count_read(document, node)
        raw = node.value[:Count]
        raw = Resolver.resolve(document, raw)&.value if raw.is_a?(::Pdfrb::Model::Reference)
        raw if raw.is_a?(::Integer) && !raw.negative?
      end

      def failure(image, code)
        failed_inspection(image, code: code, message: MESSAGES.fetch(code))
      end

      # `width`, `height`, `dpi` and `color_space` stay nil, and a nil
      # attribute is simply absent from the serialised output.
      def readable(image, progress)
        Models::Inspection.new(
          format: image.format.to_s, parse_status: "ok", meta: metadata(progress)
        )
      end

      # `count_read` has already validated it down to a non-negative
      # Integer or nil, so this is a page count and not a raw value. Zero
      # is truthy in Ruby, so a document declaring `/Count 0` reports its
      # zero rather than dropping the key.
      def metadata(progress)
        meta = { "version" => progress.version }
        meta["pages"] = progress.page_count if progress.page_count
        meta
      end
    end
  end
end
