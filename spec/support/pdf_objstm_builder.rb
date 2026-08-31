# frozen_string_literal: true

require "zlib"

require_relative "pdf_builder"

# Builds PDF 1.5 fixtures whose Catalog, page tree and page all live in a
# compressed object stream reached through an xref stream -- what modern
# producers emit by default.
#
# Split from `PdfBuilder` along a real seam rather than to dodge a cop:
# a classic document has an xref TABLE of ASCII rows and no streams at
# all, while this one has two Flate streams whose lengths and offsets
# depend on each other. Sharing one module meant every classic fixture
# carrying parameters only a stream fixture could use.
#
# The same two constraints hold as in `PdfBuilder`: overrides are applied
# before offsets are computed, and the defaults compose into a working
# document.
module PdfObjstmBuilder
  # oid 4 is the object stream, oid 5 the xref stream. Objects 1..3 are
  # the compressed ones, so `xref[1]` reads `type: :compressed` -- which
  # is the proof these fixtures are genuinely compressed rather than
  # recovered, since recovery only ever produces `:in_use` entries.
  OBJSTM_OID = 4
  XREF_OID = 5

  # PDF 1.5 is the floor for object and xref streams and no fixture has a
  # reason to move off it, so it is fixed rather than a knob. Every key
  # below IS overridden by some example; a parameter nothing drives is a
  # claim about flexibility nothing checks.
  HEADER = "%PDF-1.5\n"

  DEFAULTS = {
    bodies: [PdfBuilder::CATALOG, PdfBuilder::PAGES, PdfBuilder::PAGE],
    stream_dict: nil, omit_stream: false,
    entries: {}, widths: [1, 4, 2], root: "1 0 R", xref_extra: "", xref_data: nil
  }.freeze

  module_function

  def document(**parts)
    part = DEFAULTS.merge(parts)
    stream = objstm(part)
    objstm_at = HEADER.bytesize
    xref_at = objstm_at + stream.bytesize
    "#{HEADER}#{stream}#{xref(part, objstm_at, xref_at)}" \
    "startxref\n#{xref_at}\n%%EOF\n".b
  end

  def path(name: "objstm", **parts)
    PdfBuilder.write(document(**parts), name: name)
  end

  # `LENGTH` is a placeholder rather than a computed number so an
  # overriding fixture can supply its own dictionary without having to
  # know how long the deflated payload came out.
  def objstm(part)
    return "" if part[:omit_stream]

    pairs, values = payload(part[:bodies])
    data = Zlib::Deflate.deflate("#{pairs}#{values}")
    dict = (part[:stream_dict] || default_dict(part[:bodies].size, pairs.bytesize))
           .sub("LENGTH", data.bytesize.to_s)
    "#{OBJSTM_OID} 0 obj\n#{dict}\nstream\n#{data}\nendstream\nendobj\n"
  end

  def default_dict(count, first)
    "<< /Type /ObjStm /N #{count} /First #{first} /Length LENGTH /Filter /FlateDecode >>"
  end

  # The header is `oid offset` pairs; `/First` is where the pairs stop
  # and the values start. pdfrb parses every declared value eagerly the
  # first time ANY compressed object is resolved, so a malformed value
  # anywhere in here poisons the Catalog resolve whatever index it sits
  # at.
  # Values are SEPARATED by a space, never terminated by one. The
  # difference decides a fixture: pdfrb's escape reader tests
  # `esc >= 0` on whatever `advance_byte` returned, and that is nil only
  # when the backslash is the buffer's LAST byte -- measured, a trailing
  # space after it turns a `NoMethodError` into a `Pdfrb::LexError`.
  def payload(bodies)
    values = +""
    pairs = bodies.each_with_index.map do |body, index|
      values << " " unless values.empty?
      offset = values.bytesize
      values << body
      "#{index + 1} #{offset}"
    end
    ["#{pairs.join(" ")} ", values]
  end

  def xref(part, objstm_at, xref_at)
    data = part[:xref_data] || Zlib::Deflate.deflate(rows(part, objstm_at, xref_at))
    size = ([XREF_OID] + part[:entries].keys).max + 1
    dict = "<< /Type /XRef /Size #{size} /W [#{part[:widths].join(" ")}] " \
           "/Root #{part[:root]} /Filter /FlateDecode " \
           "/Length #{data.bytesize}#{part[:xref_extra]} >>"
    "#{XREF_OID} 0 obj\n#{dict}\nstream\n#{data}\nendstream\nendobj\n"
  end

  # Type 0 is free, 1 is an offset, 2 is `[objstm oid, index]`. A
  # compressed entry carries no generation at all -- pdfrb's
  # `add_compressed` never writes one -- which is why the handler's
  # generation guard is the entire guarantee on this path.
  def rows(part, objstm_at, xref_at)
    default = { 0 => [0, 0, 65_535], 1 => [2, OBJSTM_OID, 0], 2 => [2, OBJSTM_OID, 1],
                3 => [2, OBJSTM_OID, 2], OBJSTM_OID => [1, objstm_at, 0],
                XREF_OID => [1, xref_at, 0] }
    default.merge(part[:entries]).sort.map { |_, entry| pack(entry, part[:widths]) }.join
  end

  def pack(entry, widths)
    entry.zip(widths).map do |value, width|
      width.to_i.zero? ? "" : [value].pack("Q>").byteslice(-width, width)
    end.join
  end
end
