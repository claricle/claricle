# frozen_string_literal: true

module Claricle
  # Loads the render stack only when a conversion has passed its local
  # target and input-size checks. Inspection and conformance do not need it.
  module ConversionEngine
    module_function

    def load!
      require "vectory"
      require "postsvg"

      # postsvg 0.3.0 declares UnknownOperator through the wrong autoload
      # path. Loading every operator category once prevents a cold process
      # from failing only when a rendered SVG contains an embedded raster.
      ::Postsvg::Model::Operators.load_all!
    end
  end

  private_constant :ConversionEngine
end
