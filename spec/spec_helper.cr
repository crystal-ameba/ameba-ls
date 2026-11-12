require "spec"
require "../src/ameba-ls"

# Keeps `Larimar::Server#send_msg` logging out of the spec output.
Log.setup(:none)

SPEC_URI = URI.parse("file:///nonexistent/spec_subject.cr")

def lsp_position(line, character)
  LSProtocol::Position.new(line: line.to_u32, character: character.to_u32)
end

def lsp_range(start_line, start_character, end_line, end_character)
  LSProtocol::Range.new(
    start: lsp_position(start_line, start_character),
    end: lsp_position(end_line, end_character),
  )
end

# A range that doesn't overlap any diagnostic in the documents used by specs.
def far_away_range
  lsp_range(1000, 0, 1000, 0)
end

# Wires a provider to a controller and a server writing to an in-memory output.
class ProviderHarness
  getter provider = AmebaLS::Provider.new
  getter controller = Larimar::ProviderController.new
  getter output = IO::Memory.new

  def initialize
    controller.server = Larimar::Server.new(IO::Memory.new, output)
    controller.register_provider(provider)
  end

  def document(code, uri = SPEC_URI)
    Larimar::TextDocument.new(code, uri).tap do |document|
      controller.@documents[uri] = document
    end
  end

  def open(code, uri = SPEC_URI)
    document(code, uri).tap { |document| provider.on_open(document) }
  end

  def stub_diagnostics(uri, diagnostics : Array(AmebaLS::IssueDiagnostic))
    provider.@diagnostics[uri] = diagnostics
  end

  def actions(document, range = far_away_range)
    provider
      .provide_code_actions(document, range, code_action_context, nil)
      .should_not(be_nil)
      .map(&.as(LSProtocol::CodeAction))
  end

  def fix_all_action(document, range = far_away_range)
    actions(document, range).find!(&.kind.==(LSProtocol::CodeActionKind::SourceFixAll))
  end

  def resolve(action)
    provider.resolve_code_action(action, nil).should_not(be_nil)
  end

  def rule_names(uri = SPEC_URI)
    provider.@diagnostics[uri].map(&.issue.rule.name)
  end

  # Returns the bodies of all messages sent by the server so far.
  def published : Array(JSON::Any)
    output.to_s
      .split("Content-Length: ", remove_empty: true)
      .map { |frame| JSON.parse(frame.split("\r\n\r\n", 2).last) }
  end
end

def code_action_context
  LSProtocol::CodeActionContext.new(diagnostics: [] of LSProtocol::Diagnostic)
end

def stub_issue(code = "",
               rule = Ameba::Rule::Layout::TrailingWhitespace.new,
               location : Crystal::Location? = Crystal::Location.new(nil, 1, 1),
               end_location : Crystal::Location? = location,
               correction : (Ameba::Source::Corrector ->)? = nil)
  Ameba::Issue.new(
    code: code,
    rule: rule,
    location: location,
    end_location: end_location,
    message: "stubbed issue",
    block: correction,
  )
end

def stub_diagnostic(code = "",
                    rule = Ameba::Rule::Layout::TrailingWhitespace.new,
                    line = 1,
                    correction : (Ameba::Source::Corrector ->)? = nil,
                    location : Crystal::Location? = Crystal::Location.new(nil, line, 1))
  issue = stub_issue(code, rule, location, location, correction)

  AmebaLS::IssueDiagnostic.new(
    issue: issue,
    diagnostic: LSProtocol::Diagnostic.new(
      message: issue.message,
      range: issue.lsp_location_range,
    ),
  )
end

# A correction that doesn't change anything, for specs that only care about correctability.
def noop_correction : Ameba::Source::Corrector ->
  ->(_corrector : Ameba::Source::Corrector) { }
end

# Applies edits the way LSP clients do: same-position edits keep their array order.
def apply_edits(document, action) : String
  edits = action.edit.should_not(be_nil).changes.should_not(be_nil)[document.uri]
  code = document.to_s

  ordered = edits
    .each_with_index
    .to_a
    .sort_by! { |(edit, idx)| {document.position_to_index(edit.range.start), idx} }

  String.build do |io|
    last_end = 0
    ordered.each do |(edit, _)|
      io << code[last_end...document.position_to_index(edit.range.start)] << edit.new_text
      last_end = document.position_to_index(edit.range.end)
    end
    io << code[last_end..]
  end
end
