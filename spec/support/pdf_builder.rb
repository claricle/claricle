# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Builds classic-xref PDF fixtures from named parts, so the CORRUPTION
# corpus needs no committed bytes. Two static fixtures are committed --
# spec/fixtures/inspect/valid.pdf and no_trailer.pdf, both produced by this
# builder -- because the table in never_calls_image_content_spec.rb sources
# every other format from a static file and one row built at spec time
# would be the odd one out. Every part is a keyword defaulting to the valid
# one, and a fixture is named by which parts it overrides -- there is no
# list of override points to keep in step with the corpus.
#
# Two constraints, both load-bearing:
#
# Overrides are applied BEFORE offsets are computed. Corrupting finished
# bytes shifts every xref offset, which collapses every variant to one
# failure class -- measured, and it is how an earlier probe of these
# classes went wrong.
#
# The valid defaults compose. A fixture that overrides one part is a
# working document in every other respect, which is what lets the
# version-gate fixtures prove the gate refused them rather than the
# structure gate.
#
# `PAGE` carries a MediaBox: the conform handler's `Validator.validate`
# has an opinion about a page missing one, and the "reports a conformant
# PDF" example needs a baseline document `Validator.validate` finds
# nothing wrong with. The inspect handler never reads it (dimensions are
# deliberately absent from its output -- see handlers/pdf.rb), so the
# extra key changes nothing for those examples.
module PdfBuilder
  CATALOG = "<< /Type /Catalog /Pages 2 0 R >>"
  PAGES = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
  PAGE = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"

  # oid, generation, body. Generation travels with the object because the
  # xref row and the `N G obj` line have to agree, and the generation
  # fixtures move both together.
  OBJECTS = [[1, 0, CATALOG], [2, 0, PAGES], [3, 0, PAGE]].freeze

  TRAILER = "<< /Size 4 /Root 1 0 R >>"

  # One hash rather than seven keywords, so a fixture names only what it
  # overrides and the parameter list stays inside the cop's bound.
  #
  # `first_line` is the WHOLE first line, not just the version: the read
  # extent turns on where the first terminator sits, and both version
  # components are unbounded in length, so a fixture has to be able to
  # push that terminator anywhere.
  #
  # `phantom_oids` marks additional oids "in use" at offset 0 (inside the
  # header, not a real object) with no matching "oid gen obj" anywhere in
  # the file -- for a reference pdfrb's own xref says exists but cannot
  # actually find, anywhere.
  DEFAULTS = {
    first_line: "%PDF-1.4", eol: "\n", objects: OBJECTS,
    trailer: TRAILER, entries: {}, phantom_oids: [], startxref: nil, suffix: ""
  }.freeze

  module_function

  # A keyword that is not a part is a typo, not an override. Merging it
  # blindly built the valid baseline instead, so the example passed while
  # checking nothing it meant to check. Raising names the bad key.
  def merged(parts)
    unknown = parts.keys - DEFAULTS.keys
    raise ArgumentError, "unknown PDF fixture part: #{unknown.join(", ")}" if unknown.any?

    DEFAULTS.merge(parts)
  end

  def document(**parts)
    part = merged(parts)
    head = "#{part[:first_line]}#{part[:eol]}"
    body, offsets = serialise(part[:objects], head.bytesize)
    "#{head}#{body}#{tail(part, offsets, head.bytesize + body.bytesize)}".b
  end

  def tail(part, offsets, xref_at)
    "#{xref(part[:objects], offsets, part[:entries], part[:phantom_oids])}" \
      "trailer\n#{part[:trailer]}\nstartxref\n" \
      "#{part[:startxref] || xref_at}\n%%EOF\n#{part[:suffix]}"
  end

  def serialise(objects, base)
    offsets = {}
    body = +""
    objects.each do |oid, gen, dict|
      offsets[oid] = base + body.bytesize
      body << "#{oid} #{gen} obj\n#{dict}\nendobj\n"
    end
    [body, offsets]
  end

  # One row per oid from 1 up to the highest named -- by a real object,
  # an `entries` override, or a phantom -- so a phantom oid can sit past
  # the real objects without leaving a gap the xref subsection header
  # disagrees with. `entries` overrides a row's offset, generation or
  # type without touching the object it points at, which is what the
  # dangling and free-entry fixtures need. A phantom row reads "in use at
  # offset 0" (offset 0 sits inside the header, never a valid object
  # start, and no such object is ever written -- so pdfrb's own recovery
  # scan cannot find it either).
  def xref(objects, offsets, entries, phantom_oids)
    real = objects.to_h { |oid, gen, _| [oid, gen] }
    highest = (real.keys + phantom_oids + [0]).max
    rows = (1..highest).map { |oid| xref_row(oid, real, offsets, entries, phantom_oids) }
    "xref\n0 #{highest + 1}\n0000000000 65535 f \n#{rows.join}"
  end

  def xref_row(oid, real, offsets, entries, phantom_oids)
    if real.key?(oid)
      over = entries[oid] || {}
      format("%<offset>010d %<gen>05d %<type>s \n",
             offset: over.fetch(:offset, offsets[oid]),
             gen: over.fetch(:gen, real[oid]), type: over.fetch(:type, "n"))
    elsif phantom_oids.include?(oid)
      "0000000000 00000 n \n"
    else
      "0000000000 65535 f \n"
    end
  end

  # A fresh path per call, so one example can never see another's file.
  #
  # NOT because a typed read would spoil the bytes for the next reader:
  # measured, pdfrb's typed subscript mutates the in-memory Document
  # only, the file on disk is byte-identical afterwards, and a fresh
  # `Document.open` re-reads the raw `5.0`. Sharing one path would still
  # couple examples through mtime, cleanup order and debuggability, and
  # a fixture named after the case that built it is worth more when a
  # failure has to be traced.
  def write(bytes, name: "fixture")
    path = File.join(directory, "#{name}-#{@seq = @seq.to_i + 1}.pdf")
    File.binwrite(path, bytes)
    path
  end

  # For a fixture `document`'s own part-based construction cannot reach
  # -- corruption in the raw trailer text itself, for instance -- so a
  # caller can hand over bytes it built by hand and still get the same
  # fresh-path-per-call, removed-at-exit guarantees `path` gives. An
  # alias rather than a second implementation: it is exactly `write`,
  # named for the conform handler's own callers.
  class << self
    alias path_for write
  end

  # One directory for the whole run, removed when the process ends --
  # which for the suite is when the suite ends. `Dir.mktmpdir` in its
  # non-block form leaves the directory behind forever: measured, 226
  # `claricle-pdf*` directories in TMPDIR, one more every `rspec` run.
  #
  # `at_exit` rather than an RSpec `after(:suite)` hook, because this
  # file is also required directly by scripts that never load RSpec and
  # the directory has to go away for those too. It is registered once,
  # on first use, so a run that builds no fixture creates nothing to
  # remove.
  def directory
    @directory ||= Dir.mktmpdir("claricle-pdf").tap do |dir|
      at_exit { FileUtils.remove_entry(dir) }
    end
  end

  def path(name: "fixture", **parts)
    write(document(**parts), name: name)
  end

  # A version number long enough to put the first terminator at `bytes`.
  # `%PDF-` is five bytes and `1.` two, so the rest is digits.
  def padded_version_line(bytes)
    "%PDF-1.#{"0" * (bytes - 7)}"
  end
end
