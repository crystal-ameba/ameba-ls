class AmebaLS::Provider < Larimar::Provider
  include Larimar::CodeActionProvider

  Log = ::Larimar::Log.for(self)

  RULES_DISABLED = %w[
    Layout/TrailingBlankLines
    Layout/TrailingWhitespace
    Lint/Formatting
  ]

  @diagnostics = Hash(URI, Array(IssueDiagnostic)).new

  def on_open(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_change(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_save(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_close(document : Larimar::TextDocument) : Nil
    @diagnostics.delete(document.uri)

    publish_diagnostics(document, [] of LSProtocol::Diagnostic)
  end

  private def handle_ameba(document : Larimar::TextDocument) : Nil
    source = Ameba::Source.new(document.to_s, document.uri.path)
    formatter = DiagnosticsFormatter.new

    workspace_folder = Larimar::Workspace
      .find_closest_shard_yml(document.uri)
      .try(&.path)

    if workspace_folder
      config_path = Path[workspace_folder, Ameba::Config::Loader::FILENAME].to_s
      config_path = nil unless File.exists?(config_path)
    end

    Log.debug(&.emit("Running ameba",
      source: source.path,
      config: config_path,
    ))

    config = Config.load(path: config_path)
    config.sources = [source]
    config.formatter = formatter

    # Disabling these as they're common when typing
    config.update_rules(RULES_DISABLED, enabled: false)

    begin
      Ameba::Runner.new(config).run
    rescue CancellationException
    end

    @diagnostics[document.uri] =
      diagnostics = formatter.diagnostics

    publish_diagnostics(document, diagnostics)
  end

  private def publish_diagnostics(document, diagnostics : Array(LSProtocol::Diagnostic)) : Nil
    controller.server.send_msg(
      LSProtocol::PublishDiagnosticsNotification.new(
        params: LSProtocol::PublishDiagnosticsParams.new(
          diagnostics: diagnostics,
          uri: document.uri,
        ),
      )
    )
  end

  private def publish_diagnostics(document, diagnostics : Array(IssueDiagnostic)) : Nil
    publish_diagnostics(document, diagnostics.map(&.diagnostic))
  end

  def provide_code_actions(
    document : Larimar::TextDocument,
    range : LSProtocol::Range | LSProtocol::SelectionRange,
    context : LSProtocol::CodeActionContext,
    token : CancellationToken?,
  ) : Array(LSProtocol::CodeAction | LSProtocol::Command)?
    return unless (diagnostics = @diagnostics[document.uri]?)

    result = [] of LSProtocol::CodeAction | LSProtocol::Command

    diagnostics.each_with_index do |diagnostic, idx|
      issue, diagnostic =
        diagnostic.issue, diagnostic.diagnostic

      next unless diagnostic.range.overlaps?(range)

      if issue.correctable?
        result << LSProtocol::CodeAction.new(
          title: "Fix #{issue.rule.name}",
          diagnostics: [diagnostic],
          kind: :quick_fix,
          is_preferred: true,
          data: JSON::Any.new({
            "uri" => JSON::Any.new(document.uri.to_s),
            "idx" => JSON::Any.new(idx),
          } of String => JSON::Any),
        )
      end

      result << LSProtocol::CodeAction.new(
        title: "Ignore #{issue.rule.name}",
        diagnostics: [diagnostic],
        kind: :quick_fix,
        data: JSON::Any.new({
          "uri"    => JSON::Any.new(document.uri.to_s),
          "idx"    => JSON::Any.new(idx),
          "ignore" => JSON::Any.new(true),
        } of String => JSON::Any),
      )
    end

    result.sort_by! do |action|
      action.as(LSProtocol::CodeAction).is_preferred ? 0 : 1
    end
    result
  end

  def resolve_code_action(
    code_action : LSProtocol::CodeAction,
    token : CancellationToken?,
  ) : LSProtocol::CodeAction?
    return unless (data = code_action.data.try(&.as_h?)) &&
                  (document_uri_string = data["uri"]?.try(&.as_s?)) &&
                  (document_uri = URI.parse(document_uri_string)) &&
                  (document = controller.@documents[document_uri]?) &&
                  (diagnostic = code_action.diagnostics.try(&.first?)) &&
                  (diagnostic_idx = data["idx"]?.try(&.as_i?)) &&
                  (diagnostics = @diagnostics[document_uri]?) &&
                  (issue = diagnostics[diagnostic_idx]?.try(&.issue))

    document.mutex.synchronize do
      if data["ignore"]?.try(&.as_bool?)
        resolve_ignore_code_action(document, diagnostic, issue)
      else
        resolve_fix_code_action(document, diagnostic, issue)
      end
    end
  end

  private def resolve_ignore_code_action(document, diagnostic, issue)
    return unless (location = issue.location)
    line_number = location.line_number - 1

    text_edits = [] of LSProtocol::TextEdit
    lines = document.to_s.lines

    if line_number.positive?
      prev_line = lines[line_number - 1]

      if prev_line.lstrip.starts_with?("# ameba:disable")
        position = LSProtocol::Position.new(
          line: line_number.to_u - 1,
          character: prev_line.size.to_u,
        )
        text_edits << LSProtocol::TextEdit.new(
          new_text: ", #{issue.rule.name}",
          range: LSProtocol::Range.new(
            start: position,
            end: position,
          ),
        )
      end
    end

    if text_edits.empty?
      curr_line = lines[line_number]

      if curr_line.ends_with?(/# ameba:disable (.+?)/)
        position = LSProtocol::Position.new(
          line: line_number.to_u,
          character: curr_line.size.to_u,
        )
        text_edits << LSProtocol::TextEdit.new(
          new_text: ", #{issue.rule.name}",
          range: LSProtocol::Range.new(
            start: position,
            end: position,
          ),
        )
      end
    end

    if text_edits.empty?
      indent = lines[line_number].match!(/^\s*/)[0]

      position = LSProtocol::Position.new(
        line: line_number.to_u,
        character: 0_u32,
      )
      text_edits << LSProtocol::TextEdit.new(
        new_text: "#{indent}# ameba:disable #{issue.rule.name}\n",
        range: LSProtocol::Range.new(
          start: position,
          end: position,
        ),
      )
    end

    workspace_edit = LSProtocol::WorkspaceEdit.new(
      changes: {document.uri => text_edits},
    )

    LSProtocol::CodeAction.new(
      title: "Ignore #{issue.rule.name}",
      diagnostics: [diagnostic],
      edit: workspace_edit,
      kind: :quick_fix,
    )
  end

  private def resolve_fix_code_action(document, diagnostic, issue)
    corrector = Ameba::Source::Corrector.new(document.to_s)
    issue.correct(corrector)

    text_edits = [] of LSProtocol::TextEdit
    get_text_edits(document, text_edits, corrector.@rewriter.@action_root)

    workspace_edit = LSProtocol::WorkspaceEdit.new(
      changes: {document.uri => text_edits},
    )

    LSProtocol::CodeAction.new(
      title: "Fix #{issue.rule.name}",
      diagnostics: [diagnostic],
      edit: workspace_edit,
      kind: :quick_fix,
      is_preferred: true,
    )
  end

  private def get_text_edits(document, edits : Array(LSProtocol::TextEdit), action : Ameba::Source::Rewriter::Action) : Nil
    begin_pos = document.index_to_position(action.begin_pos)
    end_pos = document.index_to_position(action.end_pos)

    if (insert_before = action.insert_before) && !insert_before.empty?
      edits << LSProtocol::TextEdit.new(
        new_text: insert_before,
        range: LSProtocol::Range.new(
          start: begin_pos,
          end: begin_pos,
        ),
      )
    end

    if (insert_after = action.insert_after) && !insert_after.empty?
      edits << LSProtocol::TextEdit.new(
        new_text: insert_after,
        range: LSProtocol::Range.new(
          start: end_pos,
          end: end_pos,
        ),
      )
    end

    if (replacement = action.replacement)
      edits << LSProtocol::TextEdit.new(
        new_text: replacement,
        range: LSProtocol::Range.new(
          start: begin_pos,
          end: end_pos,
        ),
      )
    else
      action.@children.each do |child|
        get_text_edits(document, edits, child)
      end
    end
  end
end
