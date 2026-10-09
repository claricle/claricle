# frozen_string_literal: true

module Claricle
  # emfsvg's writer leaves EMR_HEADER.nBytes (u32 at offset 48) at 0, so
  # its output declares a size the file does not have. `seal` writes the
  # real length; bytes that are not an EMF header, or that already declare
  # a size, pass through untouched, as does any target other than :emf.
  # nRecords and nHandles are written correctly by the delegate and are
  # not touched.
  module EmfHeader
    HEADER_TYPE = 1
    N_BYTES_OFFSET = 48
    MIN_HEADER_BYTES = 52

    module_function

    def seal(target, bytes)
      return bytes unless target == :emf && unsealed?(bytes)

      sealed = bytes.b
      sealed[N_BYTES_OFFSET, 4] = [sealed.bytesize].pack("V")
      sealed
    end

    def unsealed?(bytes)
      bytes.bytesize >= MIN_HEADER_BYTES &&
        bytes.byteslice(0, 4).unpack1("V") == HEADER_TYPE &&
        bytes.byteslice(N_BYTES_OFFSET, 4).unpack1("V").zero?
    end
  end

  private_constant :EmfHeader
end
