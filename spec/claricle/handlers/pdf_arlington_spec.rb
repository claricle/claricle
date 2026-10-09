# frozen_string_literal: true

require "timeout"
require "pdfrb"

require_relative "../../support/pdf_builder"

RSpec.describe "Claricle PDF handler Arlington conformance" do
  let(:arlington) { Claricle.const_get(:Handlers).const_get(:PdfArlington) }

  let(:catalog) { "<< /Type /Catalog /Pages 2 0 R >>" }
  let(:pages) { "<< /Type /Pages /Kids [3 0 R] /Count 1 >>" }
  let(:page) { "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>" }

  def report_for(name, *bodies)
    objects = bodies.each_with_index.map { |body, index| [index + 1, 0, body] }
    path = PdfBuilder.path(name: "arlington-#{name}", objects: objects,
                           trailer: "<< /Size #{objects.size + 1} /Root 1 0 R >>")
    Claricle::Image.from_path(path).conformance_report
  end

  def arlington_issues(report)
    report.issues.select { |issue| issue.code.start_with?("PDF_ARLINGTON") }
  end

  def summary(issues)
    issues.map { |issue| [issue.code, issue.location.node_path] }
  end

  it "finds nothing in a document that satisfies the Arlington model" do
    report = report_for("valid", catalog, pages, page)

    expect(report.issues).to eq([])
    expect(report.valid).to eq(:yes)
  end

  it "reports a Catalog without /Pages at the Catalog" do
    report = report_for("no-pages", "<< /Type /Catalog >>", pages, page)

    expect(arlington_issues(report)).to contain_exactly(
      have_attributes(severity: "error", code: "PDF_ARLINGTON_REQUIRED_KEY",
                      message: "Catalog is missing required key /Pages",
                      location: have_attributes(node_path: "Catalog"))
    )
  end

  it "reports a Page without /MediaBox at its place in the page tree" do
    bare_page = "<< /Type /Page /Parent 2 0 R /Resources << >> >>"
    issues = arlington_issues(report_for("no-mediabox", catalog, pages, bare_page))

    expect(summary(issues)).to eq([["PDF_ARLINGTON_REQUIRED_KEY", "Catalog/Pages/Kids[0]"]])
    expect(issues.first.message).to eq("PageObject is missing required key /MediaBox")
  end

  it "accepts a /MediaBox and /Resources inherited from the page tree" do
    inheriting_pages = "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 1 1] /Resources << >> >>"
    inheriting_page = "<< /Type /Page /Parent 2 0 R >>"

    expect(arlington_issues(report_for("inherit", catalog, inheriting_pages, inheriting_page))).to eq([])
  end

  it "does not accept an inherited key through a /Parent that loops" do
    bare_page = "<< /Type /Page /Parent 4 0 R /Resources << >> >>"
    loop_a = "<< /Type /Pages /Kids [3 0 R] /Count 1 /Parent 5 0 R >>"
    loop_b = "<< /Type /Pages /Kids [] /Count 0 /Parent 4 0 R >>"
    report = Timeout.timeout(10) { report_for("parent-loop", catalog, pages, bare_page, loop_a, loop_b) }

    expect(summary(arlington_issues(report))).to include(["PDF_ARLINGTON_REQUIRED_KEY", "Catalog/Pages/Kids[0]"])
  end

  it "reports a value of the wrong type at its own path" do
    wrong_count = "<< /Type /Pages /Kids [3 0 R] /Count (one) >>"
    issues = arlington_issues(report_for("count-string", catalog, wrong_count, page))

    expect(summary(issues)).to eq([["PDF_ARLINGTON_TYPE", "Catalog/Pages/Count"]])
    expect(issues.first.message).to eq("Catalog/Pages/Count is a string; Arlington allows integer")
  end

  it "reports a name outside the values Arlington lists" do
    issues = arlington_issues(report_for("bad-name", "<< /Type /Cat /Pages 2 0 R >>", pages, page))

    expect(summary(issues)).to eq([["PDF_ARLINGTON_VALUE", "Catalog/Type"]])
    expect(issues.first.message).to eq("Catalog/Type is /Cat; Arlington allows Catalog")
  end

  it "reports a key a Required predicate makes mandatory" do
    with_piece_info = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /PieceInfo << >> >>"
    issues = arlington_issues(report_for("predicate", catalog, pages, with_piece_info))

    expect(issues.map(&:message)).to eq(["PageObject is missing required key /LastModified"])
  end

  it "does not report a Required predicate that does not hold" do
    expect(arlington_issues(report_for("predicate-false", catalog, pages, page))).to eq([])
  end

  it "terminates on a page tree whose node lists itself as a kid" do
    self_kid = "<< /Type /Pages /Kids [2 0 R 3 0 R] /Count 1 >>"
    report = Timeout.timeout(10) { report_for("self-kid", catalog, self_kid, page) }

    expect(report.issues.select { |issue| issue.code == "PDF_ARLINGTON_LIMIT" }).to eq([])
  end

  it "stops at the node cap and says so" do
    stub_const("#{arlington}::Walker::MAX_NODES", 3)
    issues = arlington_issues(report_for("cap", catalog, pages, page))

    expect(issues).to contain_exactly(have_attributes(severity: "warning", code: "PDF_ARLINGTON_LIMIT"))
  end

  it "keeps going past a reference to an object that does not exist" do
    dangling = "<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 1 >>"

    expect { report_for("dangling", catalog, dangling, page) }.not_to raise_error
  end

  it "makes no claim about a value whose table is ambiguous" do
    unknown_kid = "<< /Type /Pages /Kids [4 0 R] /Count 1 >>"
    report = report_for("unknown-kid", catalog, unknown_kid, page, "<< /Type /Mystery >>")

    expect(arlington_issues(report)).to eq([])
  end

  it "reports nothing for a document with no Catalog" do
    path = PdfBuilder.path(name: "arlington-no-catalog", trailer: "<< /Size 4 >>")

    expect(arlington.issues(Pdfrb::Document.open(path))).to eq([])
  end
end
