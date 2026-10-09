# frozen_string_literal: true

require "svg_conform"

# Real svg_conform objects for the mapper specs. Measured over every svg
# fixture under every profile (svg_conform 0.2.2), real input only ever
# produces `errors` issues with (severity, type) of (:error, :error),
# (nil, :error) and (:info, :error): nothing fills `warnings` or
# `validity_errors`, no issue carries a position, and no type is new. The
# rows real input cannot reach are built from the gem's own classes here.
# Not self-installing: the file that wants these includes the module.
module SvgConformResults
  Position = Struct.new(:line, :column)
  Context = Struct.new(:errors, :warnings, :validity_errors, :reference_manifest)

  def svg_issue(type, id, severity: nil, line: nil, column: nil)
    SvgConform::Errors::ValidationIssue.new(
      type: type, rule: nil, node: Position.new(line, column),
      message: "#{id} said so", requirement_id: id, severity: severity
    )
  end

  def svg_result(errors: [], warnings: [], validity_errors: [])
    SvgConform::ValidationResult.new(nil, nil, Context.new(errors, warnings, validity_errors, nil))
  end

  # A real Validator whose only difference is the canned result.
  def svg_validator_returning(result)
    Class.new(SvgConform::Validator) do
      define_method(:validate_file) { |_path, **_options| result }
    end.new
  end
end
