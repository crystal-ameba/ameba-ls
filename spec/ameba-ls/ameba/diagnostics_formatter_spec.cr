require "../../spec_helper"

private def source_with_issue(rule = Ameba::Rule::Layout::TrailingWhitespace.new, status = nil)
  location = Crystal::Location.new(nil, 1, 2)
  end_location = Crystal::Location.new(nil, 1, 4)

  Ameba::Source.new("foo bar\n", "subject.cr").tap do |source|
    source.add_issue(rule, location, end_location, "stubbed message", status)
  end
end

private def format(source)
  AmebaLS::DiagnosticsFormatter.new.tap(&.source_finished(source)).diagnostics
end

describe AmebaLS::DiagnosticsFormatter do
  describe "#source_finished" do
    it "converts issues to diagnostics" do
      rule = Ameba::Rule::Layout::TrailingWhitespace.new
      source = source_with_issue(rule)

      entry = format(source).first
      entry.issue.should eq(source.issues.first)

      diagnostic = entry.diagnostic
      diagnostic.code.should eq("Layout/TrailingWhitespace")
      diagnostic.message.should eq("stubbed message")
      diagnostic.source.should eq("ameba")
      diagnostic.range.to_json.should eq(lsp_range(0, 1, 0, 4).to_json)
      diagnostic.code_description.should_not(be_nil).href
        .should eq(URI.parse(rule.class.documentation_url))
    end

    it "skips disabled issues" do
      format(source_with_issue(status: Ameba::Issue::Status::Disabled)).should be_empty
    end

    it "accumulates diagnostics of multiple sources" do
      formatter = AmebaLS::DiagnosticsFormatter.new

      formatter.source_finished(source_with_issue)
      formatter.source_finished(source_with_issue)

      formatter.diagnostics.size.should eq(2)
    end

    {
      Ameba::Severity::Error      => LSProtocol::DiagnosticSeverity::Error,
      Ameba::Severity::Warning    => LSProtocol::DiagnosticSeverity::Warning,
      Ameba::Severity::Convention => LSProtocol::DiagnosticSeverity::Information,
    }.each do |severity, expected|
      it "maps the #{severity} severity to #{expected}" do
        rule = Ameba::Rule::Layout::TrailingWhitespace.new
        rule.severity = severity

        format(source_with_issue(rule)).first.diagnostic.severity.should eq(expected)
      end
    end

    describe "unnecessary tag" do
      it "marks rules about unnecessary code" do
        {
          Ameba::Rule::Lint::UnusedArgument.new,
          Ameba::Rule::Lint::UselessAssign.new,
          Ameba::Rule::Lint::UnreachableCode.new,
          Ameba::Rule::Style::RedundantBegin.new,
          Ameba::Rule::Lint::UnneededDisableDirective.new,
        }.each do |rule|
          format(source_with_issue(rule)).first.diagnostic.tags
            .should eq([LSProtocol::DiagnosticTag::Unnecessary])
        end
      end

      it "doesn't mark other rules" do
        format(source_with_issue).first.diagnostic.tags.should be_nil
      end
    end
  end
end
