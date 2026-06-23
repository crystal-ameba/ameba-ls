class AmebaLS::DiagnosticsFormatter < Ameba::Formatter::BaseFormatter
  property cancellation_token : CancellationToken?
  getter diagnostics = Array(LSProtocol::Diagnostic).new

  @mutex = Mutex.new

  def source_finished(source : Ameba::Source) : Nil
    diagnostics = [] of LSProtocol::Diagnostic

    source.issues.each do |issue|
      next if issue.disabled?

      cancellation_token.try(&.cancelled!)

      start_location = LSProtocol::Position.new(
        line: (issue.location.try(&.line_number.to_u32) || 1_u32) - 1,
        character: (issue.location.try(&.column_number.to_u32) || 1_u32) - 1,
      )
      end_location = LSProtocol::Position.new(
        line: (issue.end_location.try(&.line_number.to_u32) || issue.location.try(&.line_number.to_u32) || 1_u32) - 1,
        character: (issue.end_location.try(&.column_number.to_u32) || issue.location.try(&.column_number.to_u32) || 1_u32),
      )

      diagnostics << LSProtocol::Diagnostic.new(
        message: "[#{issue.rule.name}] #{issue.message}",
        range: LSProtocol::Range.new(
          start: start_location,
          end: end_location,
        ),
        severity: convert_severity(issue.rule.severity),
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
