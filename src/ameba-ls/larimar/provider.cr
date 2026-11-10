class AmebaLS::Provider < Larimar::Provider
  include Larimar::CodeActionProvider

  Log = ::Larimar::Log.for(self)

  # Rules that are disabled on change to avoid unnecessary diagnostics while typing.
  RULES_DISABLED = %w[
    Layout/TrailingBlankLines
    Layout/TrailingWhitespace
    Lint/Formatting
  ]

  # Documents are handled in parallel, while this hash is shared between all of them.
  @diagnostics = Hash(URI, Array(IssueDiagnostic)).new
  @diagnostics_mutex = Mutex.new

  # The errors users were already notified about, by the project root.
  @config_errors = Hash(Path, String).new
  @config_errors_mutex = Mutex.new

  def on_open(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_change(document : Larimar::TextDocument) : Nil
    handle_ameba(document, RULES_DISABLED)
  end

  def on_save(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_close(document : Larimar::TextDocument) : Nil
    @diagnostics_mutex.synchronize { @diagnostics.delete(document.uri) }

    publish_diagnostics(document, [] of LSProtocol::Diagnostic)
  end

  private def handle_ameba(document : Larimar::TextDocument, disabled_rules = nil) : Nil
    # Other schemes (`untitled:`, `git:`) have no meaningful path on disk.
    # For a relative one, `Larimar::Workspace.find_closest_shard_yml` never returns.
    return unless document.uri.scheme == "file"

    # Whatever happens below, the previous issues no longer match the document.
    @diagnostics_mutex.synchronize { @diagnostics.delete(document.uri) }

    source = Ameba::Source.new(document.to_s, document.uri.path)
    formatter = DiagnosticsFormatter.new

    root = project_root(document)

    Log.debug(&.emit("Running ameba",
      source: source.path.to_s,
      root: root.to_s,
    ))

    config = load_config(root)
    config.sources = [source]
    config.formatter = formatter

    if disabled_rules
      # Excluding instead of disabling, since `Lint/UnneededDisableDirective`
      # would otherwise report inline directives for these rules as unneeded.
      config.rules.each do |rule|
        rule.excluded = Set{source.path.to_s} if rule.name.in?(disabled_rules)
      end
    end

    Ameba::Runner.new(config).run

    diagnostics = formatter.diagnostics
    @diagnostics_mutex.synchronize { @diagnostics[document.uri] = diagnostics }

    publish_diagnostics(document, diagnostics)
  end

  # Returns the directory of the closest `shard.yml`, or of the file itself if there's none.
  private def project_root(document : Larimar::TextDocument) : Path
    shard_uri = Larimar::Workspace.find_closest_shard_yml(document.uri)
    shard_uri ? Path[shard_uri.path] : Path[document.uri.path].parent
  end

  # An invalid config shouldn't leave the document without diagnostics, so
  # it falls back to the defaults, after letting the user know about the error.
  private def load_config(root : Path)
    Config.load(root: root).tap do
      @config_errors_mutex.synchronize { @config_errors.delete(root) }
    end
  rescue ex
    report_config_error(root, ex.message || ex.class.name)
    Config.load(root: root, skip_reading_config: true)
  end

  # Called on every change, so the same error is reported only once.
  private def report_config_error(root : Path, message : String) : Nil
    already_reported = @config_errors_mutex.synchronize do
      prev_message = @config_errors[root]?.tap { @config_errors[root] = message }
      prev_message == message
    end
    return if already_reported

    controller.server.send_msg(
      LSProtocol::ShowMessageNotification.new(
        params: LSProtocol::ShowMessageParams.new(
          message: "#{root / Ameba::Config::Loader::FILENAME}: #{message}",
          type: :error,
        ),
      )
    )
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
    raise_if_cancelled(token)

    return unless (diagnostics = @diagnostics_mutex.synchronize { @diagnostics[document.uri]? })

    result = [] of LSProtocol::CodeAction | LSProtocol::Command

    diagnostics.each do |diagnostic|
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
            "uri"     => JSON::Any.new(document.uri.to_s),
            "version" => JSON::Any.new(document.version),
          } of String => JSON::Any),
        )
      end

      unless issue.rule.special?
        result << LSProtocol::CodeAction.new(
          title: "Ignore #{issue.rule.name}",
          diagnostics: [diagnostic],
          kind: :quick_fix,
          data: JSON::Any.new({
            "uri"     => JSON::Any.new(document.uri.to_s),
            "version" => JSON::Any.new(document.version),
            "ignore"  => JSON::Any.new(true),
          } of String => JSON::Any),
        )
      end
    end

    result.sort_by! do |action|
      action.as(LSProtocol::CodeAction).is_preferred ? 0 : 1
    end
    result
  end

  # `CancellationToken#cancelled!` raises unconditionally.
  private def raise_if_cancelled(token : CancellationToken?) : Nil
    raise CancellationException.new if token.try(&.cancelled?)
  end

  def resolve_code_action(
    code_action : LSProtocol::CodeAction,
    token : CancellationToken?,
  ) : LSProtocol::CodeAction?
    raise_if_cancelled(token)

    return unless (data = code_action.data.try(&.as_h?)) &&
                  (document_uri_string = data["uri"]?.try(&.as_s?)) &&
                  (document_uri = URI.parse(document_uri_string)) &&
                  (document = controller.@documents[document_uri]?) &&
                  (diagnostic = code_action.diagnostics.try(&.first?)) &&
                  (version = data["version"]?.try(&.as_i?))

    document.mutex.synchronize do
      # The document has changed since the action was offered,
      # hence the issue it was offered for might not be there anymore.
      next unless version == document.version
      next unless (diagnostics = @diagnostics_mutex.synchronize { @diagnostics[document_uri]? })
      next unless (issue = diagnostics.find(&.matches?(diagnostic)).try(&.issue))

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
          line: line_number.to_u32 - 1,
          character: prev_line.size.to_u32,
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
          line: line_number.to_u32,
          character: curr_line.size.to_u32,
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
        line: line_number.to_u32,
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

    # Must follow the children, since clients keep the order of same-position inserts.
    if (insert_after = action.insert_after) && !insert_after.empty?
      edits << LSProtocol::TextEdit.new(
        new_text: insert_after,
        range: LSProtocol::Range.new(
          start: end_pos,
          end: end_pos,
        ),
      )
    end
  end
end
