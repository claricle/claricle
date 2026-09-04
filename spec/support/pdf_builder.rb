# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Builds minimal classic-xref PDFs for the conform handler's specs, so no
# PDF byte is committed to this repo -- the same approach 00-overview.md's
# "Measured delegate contracts" section describes: a `Pdfrb::Composer`-built
# PDF for the valid case, and hand-built ones for the broken cases
# `Composer` has no DSL for (a missing Catalog, a dangling reference).
#
# Three objects -- Catalog, Pages, Page -- compose a structurally valid
# document. A fixture overrides only the parts it needs broken; offsets are
# computed from the OBJECTS actually given, so overriding just the trailer
# (the catalog-less case) still produces a correct xref for the objects
# that are there.
module PdfBuilder
  CATALOG = "<< /Type /Catalog /Pages 2 0 R >>"
  PAGES = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
  PAGE = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"

  # oid, generation, dictionary body -- the valid three-object document
  # every fixture starts from.
  DEFAULT_OBJECTS = [[1, 0, CATALOG], [2, 0, PAGES], [3, 0, PAGE]].freeze
  DEFAULT_TRAILER = "<< /Size 4 /Root 1 0 R >>"

  HEAD = "%PDF-1.4\n"

  module_function

  # A classic-xref PDF built from `objects` (an Array of
  # [oid, gen, dict-body] triples) and `trailer` (the trailer dictionary's
  # own text), as bytes. `phantom_oids` marks additional oids "in use" at
  # offset 0 (inside the header, not a real object) with no matching
  # "oid gen obj" anywhere in the file -- for a reference pdfrb's own
  # xref says exists but cannot actually find, anywhere.
  def document(objects: DEFAULT_OBJECTS, trailer: DEFAULT_TRAILER, phantom_oids: [])
    body, offsets = serialise(objects)
    xref_at = HEAD.bytesize + body.bytesize
    "#{HEAD}#{body}#{xref(objects, offsets, phantom_oids)}" \
    "trailer\n#{trailer}\nstartxref\n#{xref_at}\n%%EOF\n".b
  end

  # The objects' own bytes, and where each one starts -- the xref needs
  # both, and computing offsets from the objects actually given (rather
  # than from `DEFAULT_OBJECTS`) is what lets a fixture override only the
  # trailer and still get a correct xref for the objects that are there.
  def serialise(objects)
    offsets = {}
    body = +""
    objects.each do |oid, gen, dict|
      offsets[oid] = HEAD.bytesize + body.bytesize
      body << "#{oid} #{gen} obj\n#{dict}\nendobj\n"
    end
    [body, offsets]
  end

  # One row per oid from 1 up to the highest named (by an object or a
  # phantom), so a phantom oid can sit past the real objects without
  # leaving a gap the xref subsection header disagrees with.
  def xref(objects, offsets, phantom_oids = [])
    real = objects.to_h { |oid, gen, _| [oid, gen] }
    highest = (real.keys + phantom_oids + [0]).max
    rows = (1..highest).map { |oid| xref_row(oid, real, offsets, phantom_oids) }
    "xref\n0 #{highest + 1}\n0000000000 65535 f \n#{rows.join}"
  end

  # A real object's own row, a phantom's "in use at offset 0" row (offset
  # 0 sits inside "%PDF-1.4\n", never a valid object start, and no such
  # object is ever written -- so pdfrb's own recovery scan cannot find it
  # either), or a plain free slot for any oid neither names.
  def xref_row(oid, real, offsets, phantom_oids)
    if real.key?(oid)
      format("%<offset>010d %<gen>05d n \n", offset: offsets[oid], gen: real[oid])
    elsif phantom_oids.include?(oid)
      "0000000000 00000 n \n"
    else
      "0000000000 65535 f \n"
    end
  end

  # A fresh path per call, named after the case that built it, so a
  # failure is traceable back to its fixture. One directory for the whole
  # run, removed at exit -- `Dir.mktmpdir`'s non-block form otherwise
  # leaves the directory behind forever.
  def path(name: "fixture", **parts)
    path_for(document(**parts), name: name)
  end

  # For a fixture `document`'s own part-based construction cannot reach
  # -- corruption in the raw trailer text itself, for instance -- so a
  # caller can hand over bytes it built by hand and still get the same
  # fresh-path-per-call, removed-at-exit guarantees `path` gives.
  def path_for(bytes, name: "fixture")
    @seq = @seq.to_i + 1
    file = File.join(directory, "#{name}-#{@seq}.pdf")
    File.binwrite(file, bytes)
    file
  end

  def directory
    @directory ||= Dir.mktmpdir("claricle-pdf").tap do |dir|
      at_exit { FileUtils.remove_entry(dir) }
    end
  end
end
