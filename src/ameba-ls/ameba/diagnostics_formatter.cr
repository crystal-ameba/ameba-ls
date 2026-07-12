class AmebaLS::IssueDiagnostic
  getter issue : Ameba::Issue
  getter diagnostic : LSProtocol::Diagnostic

  def initialize(@issue, @diagnostic)
  end
end

class AmebaLS::DiagnosticsFormatter < Ameba::Formatter::BaseFormatter
  private UNNECESSARY_TAG_KEYWORDS =
    %w[unneeded unreachable unused useless redundant]

  private UNNECESSARY_TAG_PATTERN =
    %r{^(\w+)/(#{UNNECESSARY_TAG_KEYWORDS.join('|')})}i

  property cancellation_token : CancellationToken?
  getter diagnostics = Array(IssueDiagnostic).new

  @mutex = Mutex.new

  def source_finished(source : Ameba::Source) : Nil
    diagnostics = [] of IssueDiagnostic

    source.issues.each do |issue|
      next if issue.disabled?

      cancellation_token.try(&.cancelled!)

      if issue.rule.name.matches?(UNNECESSARY_TAG_PATTERN)
        tags = [:unnecessary] of LSProtocol::DiagnosticTag
      end

      diagnostics << IssueDiagnostic.new(
        issue: issue,
        diagnostic: LSProtocol::Diagnostic.new(
          code: issue.rule.name,
          code_description: LSProtocol::CodeDescription.new(
            href: URI.parse(issue.rule.class.documentation_url),
          ),
          message: issue.message,
          range: issue.lsp_location_range,
          severity: convert_severity(issue.rule.severity),
          tags: tags,
        )
      )
    end

    @mutex.synchronize do
      self.diagnostics.concat(diagnostics)
    end
  end

  private def convert_severity(severity : Ameba::Severity) : LSProtocol::DiagnosticSeverity
    case severity
    in .error?
      LSProtocol::DiagnosticSeverity::Error
    in .warning?
      LSProtocol::DiagnosticSeverity::Warning
    in .convention?
      LSProtocol::DiagnosticSeverity::Information
    end
  end
end
