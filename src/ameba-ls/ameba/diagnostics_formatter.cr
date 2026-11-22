class AmebaLS::IssueDiagnostic
  getter issue : Ameba::Issue
  getter diagnostic : LSProtocol::Diagnostic

  def initialize(@issue, @diagnostic)
  end

  # Returns `true` if *other* (sent back by the client) describes the same issue.
  def matches?(other : LSProtocol::Diagnostic) : Bool
    diagnostic.code == other.code &&
      diagnostic.range == other.range &&
      diagnostic.message == other.message
  end
end

class AmebaLS::DiagnosticsFormatter < Ameba::Formatter::BaseFormatter
  private UNNECESSARY_TAG_KEYWORDS =
    %w[duplicate unneeded unreachable unused useless redundant]

  private UNNECESSARY_TAG_PATTERN =
    %r{^(\w+)/(#{UNNECESSARY_TAG_KEYWORDS.join('|')})}i

  getter diagnostics = Array(IssueDiagnostic).new

  # The encoding of the character offsets in the ranges of the diagnostics
  getter position_encoding : LSProtocol::PositionEncodingKind

  @mutex = Mutex.new

  def initialize(@position_encoding = :utf8)
    super()
  end

  def source_finished(source : Ameba::Source) : Nil
    diagnostics = [] of IssueDiagnostic

    source.issues.each do |issue|
      next if issue.disabled?

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
          range: issue.lsp_location_range(source.lines, position_encoding),
          severity: convert_severity(issue.rule.severity),
          tags: tags,
          source: "ameba",
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
