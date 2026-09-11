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

      # Body-derived values get the same order-of-magnitude publication
      # bound as the header read. The page-count comparison is numeric so
      # refusing an attacker-sized Integer never converts it back to an
      # attacker-sized String.
      #
      # This bounds publication, not parsing. pdfrb has already
      # materialised the Integer or Symbol before this handler sees it;
      # bounding those source tokens would require replacing its tokenizer
      # and compressed-object-stream path rather than enforcing our output
      # contract here.
      MAX_PAGE_COUNT = (10**HEADER_SCAN_BYTES) - 1

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
      #
      # All FOUR are listed here, so a reader scanning this sees every
      # failure mode. The
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

      # What a `/Version` Name must look like to be believed. Measured,
      # `catalog.value[:Version]` comes back as a Symbol for a Name, but
      # also as a String, a Float, an Array, a Reference or nil depending
      # on what the file wrote -- and as `:"1.7.2"`, `:X` or `:""` for a
      # Name that is not a version. Only a Symbol within the publication
      # bound and matching this is taken, so both readings of the version
      # refuse `%PDF-1.7.2` for the same reason.
      VERSION_TOKEN = /\A\d+\.\d+\z/

      private_constant :HEADER_SCAN_BYTES, :MAX_PAGE_COUNT, :DEADLINE_SECONDS,
                       :HEADER_CODE, :OPEN_CODE, :STRUCTURE_CODE, :TIMEOUT_CODE,
                       :MESSAGES, :VERSION_TOKEN

      # The file's own bytes decide the version, never the delegate.
      # `Document.open` succeeds on an empty file and the document it
      # returns still REPORTS a version -- measured, `"1.4"` for empty,
      # for garbage and for a `%PDF-x.y` header alike. A fabricated
      # default is worse than no answer, so the gate reads the
      # declaration itself and reports the token it captured.
      #
      # The header is only HALF the answer. A PDF may raise its version
      # in the Catalog's `/Version`, and the reported version is the
      # NUMERIC MAXIMUM of the two -- see `highest_version`.
      module VersionGate
        # A COMPLETE declaration: the first line carries the version and
        # nothing after it but optional spaces or tabs.
        #
        # WHAT IT REFUSES. `\A%PDF-(\d+\.\d+)` alone validates a numeric
        # PREFIX -- measured, it captures "1.7" for both `%PDF-1.7junk`
        # and `%PDF-1.7.2`, neither of which is version 1.7.
        #
        # WHAT IT TOLERATES, and this is a MEASURED CONCESSION rather
        # than a loosened guard. A real file on this machine --
        # `duck-small.pdf`, written by ImageMagick 4.2.8 in 2001 --
        # begins `%PDF-1.1` then a SPACE then LF. pdfrb reads it, poppler
        # reads it and calls it version 1.1, and this handler used to
        # report `pdf.header_unreadable` for it: a false refusal of a
        # perfectly readable document. Trailing horizontal whitespace is
        # therefore accepted.
        #
        # `[ \t]*(?:[\r\n]|\z)` and NOT the one-character class
        # `[ \t\r\n]`, because the shorter form only has to match the
        # single byte after the digits. Measured, it accepts BOTH
        # `%PDF-1.4 junk` and `%PDF-1.4\tjunk` and reports "1.4" -- the
        # general junk relaxation this gate exists to prevent. Requiring
        # the LINE to end is what keeps the two apart.
        #
        # Space and tab only. PDF's whitespace table also lists NUL and
        # FF; no measured real file needs them here, and generalising
        # past the evidence is the defect this handler keeps paying for.
        GATE = /\A%PDF-(\d+\.\d+)(?=[ \t]*(?:[\r\n]|\z))/
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

      # THE DELEGATE BOUNDARY: every call that crosses into pdfrb, and the
      # single rescue that covers them.
      #
      # Grouped here so the rescue can sit around ONE delegate expression
      # at a time. While `guarded` wrapped whole handler methods, the
      # allowlist also covered Claricle's own code, and a bug in this file
      # was reported as a corrupt PDF instead of crashing.
      #
      # Included rather than `module_function`, so `guarded` is one
      # instance method every read here and in `MetadataGate` shares.
      #
      # pdfrb resolves by object NUMBER alone -- measured, `/MediaBox 4 9 R`
      # returns object `4 0`, and a compressed object addressed `1 1 R`
      # resolves happily because `add_compressed` never records a
      # generation for the reader to compare. So every reference this
      # handler follows is checked against the xref before resolution,
      # and that check is the entire generation guarantee.
      module Resolver
        RESOLVABLE = %i[in_use compressed].freeze
        private_constant :RESOLVABLE

        private

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
        # Every call wraps ONE pdfrb expression. The shape checks are what
        # make that possible: `typed` refuses anything whose `.value` is
        # not a Hash rather than letting `7[](:Type)` raise, and the `&.`
        # on every value `resolve` may refuse stops those raising at all.
        #
        # `NoMethodError` stays on the list for pdfrb itself. Everywhere
        # else it signals a broken delegate; here pdfrb raises it for
        # ordinary corrupt files -- a free object-stream xref entry, a
        # trailing backslash in a compressed body -- and nothing at the
        # call site distinguishes the two. Crashing on a corrupt PDF is
        # worse.
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
        #
        # Returns BOTH checked objects, so the Catalog survives to be
        # asked for its `/Version` instead of being resolved a second
        # time.
        #
        # The node stays the flag, and the DESTRUCTURE at the call site is
        # what keeps it so: `catalog, progress.node =` reads nil out of a
        # nil return and out of `[catalog, nil]` alike, so a Catalog that
        # resolves while its `/Pages` does not still leaves `progress.node`
        # nil and reports "failed".
        def structure_gate(document)
          trailer = guarded { document.trailer }
          return unless trailer

          catalog = typed(resolve(document, guarded { trailer[:Root] }), :Catalog)
          return unless catalog

          [catalog, typed(resolve(document, catalog.value[:Pages]), :Pages)]
        end

        # The `&.` is load-bearing, not defensive noise: `resolve` returns
        # nil on every refusal, and a bare `.value` would raise
        # `NoMethodError`.
        #
        # The Hash check is what keeps this handler's own logic out of
        # `guarded`. A dictionary's `.value` is a plain Hash, but an
        # indirect `/Root` resolving to a scalar used to make this
        # `7[](:Type)` -- measured, a `TypeError` raised by THIS handler
        # and swallowed as if pdfrb had refused the file. The outcome is
        # the same `structure_unreadable` either way; the difference is
        # that a real bug here now escapes instead of hiding behind it.
        def typed(object, name)
          value = object&.value
          return unless value.is_a?(::Hash)

          object if value[:Type] == name
        end

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
        # For a COMPRESSED reference `document.object` alone cannot prove
        # the object it received is the object the file recorded at that
        # index: pdfrb's object-stream reader discards the number stored
        # there and wraps the value with the number that was asked for.
        # `compressed_oid_matches?` below is what closes that gap by
        # reading the ObjStm's own header directly.
        def resolve(document, value)
          guarded { checked(document, value) }
        end

        def checked(document, value)
          return unless value.is_a?(::Pdfrb::Model::Reference)

          entry = document.xref&.[](value.oid)
          return unless entry && RESOLVABLE.include?(entry.type)
          return unless entry.gen.to_i == value.gen
          return unless resolvable_compressed?(document, entry, value.oid)

          document.object(value)
        end

        # A no-op for every non-compressed entry, so `checked` pays this
        # branch's cost without paying `compressed_oid_matches?`'s.
        def resolvable_compressed?(document, entry, oid)
          entry.type != :compressed || compressed_oid_matches?(document, entry, oid)
        end

        # ISO 32000-1 7.5.7: the xref's declared object number for a
        # compressed object and the number the object stream's OWN header
        # records at that index shall agree. pdfrb's
        # `ObjectReader#load_from_objstm` (measured against pdfrb-0.7.49
        # lib/pdfrb/source/object_reader.rb:119-129) discards the stored
        # number and relabels whatever value it finds at the index with
        # the oid the caller asked for -- so an xref entry whose `index`
        # disagrees with what the stream itself declares silently returns
        # a different object's value under the right object's number.
        # Measured: an otherwise well-formed compressed Pages node with
        # `/Count 1` swapped for one at another index declaring `/Count
        # 999` resolves and publishes 999 with no error anywhere.
        #
        # `container&.type == :in_use` is checked FIRST and separately
        # from the oid comparison below. An object stream is never itself
        # stored inside another object stream, so if the xref claims the
        # CONTAINING stream is itself `:compressed`, the `document.object`
        # call a few lines down would recurse into pdfrb's own
        # compressed-resolution path a second time with none of this
        # method's guards applied to that inner hop -- measured, without
        # this check that recursion runs until `SystemStackError`, which
        # `guarded` happens to catch but only after paying for the whole
        # stack. Refusing immediately is cheaper and does not depend on a
        # rescue two frames away.
        #
        # Re-parses only the ObjStm's HEADER (the `oid offset` pairs
        # before `/First`), not the values: `ObjectStreamReader.read`
        # (pdfrb-0.7.49 lib/pdfrb/source/object_stream_reader.rb:18-21)
        # parses the header exactly this way, but it also eagerly parses
        # every declared VALUE, which pdfrb already does once per ObjStm
        # and caches privately (`@objstm_cache`, unreachable from here).
        # Calling that method a second time here would double the
        # value-parsing cost of every compressed resolution; this reads
        # only the bytes needed to answer the oid question.
        def compressed_oid_matches?(document, entry, expected_oid)
          pairs = objstm_header_pairs(document, entry.obj_stm_oid)
          return false unless pairs

          slot = entry.index.to_i * 2
          return false unless slot >= 0 && slot < pairs.length

          pairs[slot].to_i == expected_oid
        end

        # Memoised per `obj_stm_oid`, on the handler instance. `Image#handler`
        # (image.rb) builds a fresh handler per call and this method's own
        # instance runs exactly one `Pdfrb::Document.open` (`open_document`
        # above), so the cache cannot outlive, or leak across, the one
        # document it was built for.
        #
        # Without this, a shared object stream pays `objstm_header_tokens`'s
        # decode once per COMPRESSED OBJECT the handler resolves out of it,
        # not once per stream. Measured: instrumenting
        # `Pdfrb::Model::Cos::Stream#decoded_stream` (which pdfrb does not
        # memoise -- confirmed against pdfrb-0.7.49
        # lib/pdfrb/model/cos/stream.rb, every call re-runs
        # `Pdfrb::Filter.apply`) on the default 3-object fixture, where the
        # handler resolves 2 distinct compressed oids (Catalog, Pages) from
        # one ObjStm, gave 4 decodes -- 1 for the xref stream, 2 for this
        # method (one per resolve), 1 more inside pdfrb's own
        # `ObjectReader#load_from_objstm`. The comment on
        # `compressed_oid_matches?` above already accounts for paying that
        # last one twice (ours plus pdfrb's, once); it did not account for
        # multiplying by every compressed object touched, and the file's own
        # `DEADLINE_SECONDS` comment treats decode cost as a resource this
        # handler cannot let scale with attacker-controlled shape.
        def objstm_header_pairs(document, obj_stm_oid)
          cache = (@objstm_header_pairs ||= {})
          return cache[obj_stm_oid] if cache.key?(obj_stm_oid)

          cache[obj_stm_oid] = uncached_objstm_header_pairs(document, obj_stm_oid)
        end

        # Returns nil for anything that keeps the header from being read
        # safely: the declared container is not a genuine in-use stream
        # (see `compressed_oid_matches?`'s comment on why that is checked
        # before touching the delegate at all), or `/First` does not
        # describe a real prefix of the decoded bytes.
        def uncached_objstm_header_pairs(document, obj_stm_oid)
          container = document.xref&.[](obj_stm_oid)
          return unless container&.type == :in_use

          objstm = document.object(::Pdfrb::Model::Reference.new(obj_stm_oid, 0))
          return unless objstm.is_a?(::Pdfrb::Model::Cos::Stream)

          objstm_header_tokens(objstm)
        end

        def objstm_header_tokens(objstm)
          first = objstm.value[:First]
          decoded = objstm.decoded_stream
          return unless first.is_a?(::Integer) && !first.negative?
          return unless decoded && first <= decoded.bytesize

          decoded.byteslice(0, first).split(/\s+/)
        end
      end
      include Resolver

      private_constant :Resolver

      # The publication boundary for both body-derived metadata values.
      # Kept as private instance methods, so each read reaches the
      # handler's own guarded `resolve` and can still fail independently.
      #
      # A module rather than two more methods in the class body: this
      # file's other two helper groups are modules for the same reason,
      # and folding these back into `Pdf` puts it over the project's
      # RuboCop class-length budget.
      module MetadataGate
        private

        # The Catalog's own claim, believed only when it is a well-formed
        # Name. Read RAW through `.value`, like every other key here: the
        # typed `Dictionary#[]` coerces and mutates the node in place.
        #
        # A Reference goes through the guarded `resolve`, never
        # `document.object`, or the generation guard is bypassed for this
        # key alone -- pdfrb resolves by object number and would hand back
        # an object the file never authorised.
        #
        # `Document#version` and `Catalog#version_override` are both
        # refused: the first fabricates "1.4" for an unreadable header,
        # which is the whole reason this handler reads the bytes itself.
        def catalog_version(document, catalog)
          raw = catalog.value[:Version]
          raw = resolve(document, raw)&.value if raw.is_a?(::Pdfrb::Model::Reference)
          return unless raw.is_a?(::Symbol)

          token = raw.name
          token if token.bytesize <= HEADER_SCAN_BYTES && token.match?(VERSION_TOKEN)
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
        # bad count, it would raise out of the model. The magnitude check is
        # the publication bound: at most HEADER_SCAN_BYTES decimal digits.
        def count_read(document, node)
          raw = node.value[:Count]
          raw = resolve(document, raw)&.value if raw.is_a?(::Pdfrb::Model::Reference)
          raw if raw.is_a?(::Integer) && !raw.negative? && raw <= MAX_PAGE_COUNT
        end
      end
      include MetadataGate

      private_constant :MetadataGate

      # What the timeout block managed to establish. A local carrier and
      # never an ivar: `image.rb:233` builds a handler per call precisely
      # so it holds no per-call state, and the outer rescue has to tell
      # an expiry BEFORE the structure gate from one after it.
      Progress = Struct.new(:version, :node, :page_count, :code, :version_settled)
      private_constant :Progress

      # One deadline over every potentially unbounded step in the normal
      # operation, including construction of its successful result, never
      # one per stage: five stages each granted five seconds is a
      # twenty-five second worst case wearing a five-second label.
      #
      # An expiry after the VERSION IS SETTLED still returns `ok`. That
      # recovery result is necessarily built after the clock has fired, but
      # only after its page count is cleared; the remaining published
      # strings are capped at HEADER_SCAN_BYTES, so the recovery has
      # bounded input size.
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
      # `version_settled` is the flag, and it is the VERSION rather than
      # the structure gate's node. The reported version is the numeric
      # maximum of the header and the Catalog's `/Version`, so a clock
      # that fires while the Catalog is being read leaves only half the
      # answer. The node was true by then, so the old flag reported "ok"
      # and published the header version -- measured, "1.4" for a file
      # whose Catalog says 1.7. A wrong version called a good read is
      # worse than a "failed", so anything before the version is settled
      # is now `pdf.timeout`.
      #
      # Only the count read and the result construction happen after the
      # flag is set, and both are recoverable: the count is simply
      # omitted.
      def inspection(image)
        progress = Progress.new
        require "pdfrb"
        result = bounded(progress) { run_stages(image, progress) }
        if progress.code
          return failed_inspection(image, code: progress.code,
                                          message: MESSAGES.fetch(progress.code))
        end

        result || readable(image, progress)
      end

      private

      # The clock, and what an expiry is allowed to conclude. Returns nil
      # on an expiry, so the caller falls back to the recovery result.
      #
      # `||=`, because a code already set names a cause the run actually
      # reached. A structure gate that refused sets STRUCTURE_CODE with
      # the version still unsettled, and a deadline expiring during the
      # unwind after it would otherwise relabel that refusal
      # `pdf.timeout` -- one code per cause, reporting the wrong one.
      def bounded(progress, &)
        Timeout.timeout(DEADLINE_SECONDS, &)
      rescue Timeout::Error
        progress.code ||= TIMEOUT_CODE unless progress.version_settled
        progress.page_count = nil
      end

      # Every read happens inside `with_path`. The handler never calls
      # `image.content` itself: `with_path` calls it once for a
      # content-born image, to write the tempfile pdfrb needs, and that
      # returns the string the image already retains rather than making a
      # second copy. A path-born inspection materialises nothing.
      def run_stages(image, progress)
        image.with_path do |path|
          progress.version = VersionGate.version(path)
          unless progress.version
            progress.code = HEADER_CODE
            next
          end

          open_document(path, progress)
        end
        readable(image, progress) unless progress.code
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
      #
      # `opened` narrows this rescue to the OPEN itself. The block form is
      # required (see above), so the rescue would otherwise also cover the
      # stages inside the block, where this handler's own code runs: a bug
      # there was reported as `pdf.unreadable` instead of crashing. Once
      # pdfrb has yielded, every delegate call inside is guarded on its
      # own, so anything still escaping is ours and is re-raised.
      def open_document(path, progress)
        opened = false
        ::Pdfrb::Document.open(path) do |document|
          opened = true
          read_document(document, progress)
        end
      rescue *parse_failures, Errno::EINVAL
        raise if opened

        progress.code = OPEN_CODE
      end

      # The stages that run once pdfrb has handed the document over. A
      # method of its own so the rescue above covers the open and nothing
      # else.
      def read_document(document, progress)
        catalog, progress.node = structure_gate(document)
        unless progress.node
          progress.code = STRUCTURE_CODE
          return
        end

        read_optional_fields(document, catalog, progress)
      end

      # Everything the gate did NOT have to prove. Each delegate read is
      # guarded on its own, so a Catalog that will not give up its
      # `/Version` still reports the header's, and a `/Count` that raises
      # still leaves the version intact.
      #
      # The flag is set BETWEEN the two reads. Everything above it decides
      # the published version, so a deadline there must report "failed";
      # everything below it only adds the count, which the recovery drops.
      def read_optional_fields(document, catalog, progress)
        progress.version = highest_version(progress.version,
                                           catalog_version(document, catalog))
        progress.version_settled = true
        progress.page_count = count_read(document, progress.node)
      end

      # The NUMERIC MAXIMUM, and every word of that is load-bearing.
      #
      # Not "prefer the Catalog": a real file can declare a LOWER
      # `/Version` than its header, and 1.7 is then the true version --
      # poppler agrees. Not a string compare: `"1.10" > "1.9"` is FALSE.
      # Not a float: `1.10 == 1.1`, so 1.10 and 1.1 collide. Comparing
      # integer pairs split on the dot is the only one of the three that
      # gets both directions right.
      def highest_version(header, catalog)
        return header unless catalog

        [header, catalog].max_by { |version| version.split(".").map(&:to_i) }
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
