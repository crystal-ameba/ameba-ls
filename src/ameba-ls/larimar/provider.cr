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
    @diagnostics_mutex.synchronize do
      @diagnostics.delete(document.uri)
    end
    publish_empty_diagnostics(document)
  end

  private def handle_ameba(document : Larimar::TextDocument, disabled_rules = nil) : Nil
    # Other schemes (`untitled:`, `git:`) have no meaningful path on disk.
    return unless document.uri.scheme == "file"

    # Larimar handles each notification in its own fiber, so a change might get
    # handled after the document has been closed, while waiting for its lock.
    # Its diagnostics would then never get cleared.
    return unless open?(document)

    # Whatever happens below, the previous issues no longer match the document.
    @diagnostics_mutex.synchronize do
      @diagnostics.delete(document.uri)
    end

    document_path = Path[URI.decode(document.uri.path)]
    root = project_root(document_path)
    config = load_config(root)

    unless inspects?(config, document_path)
      Log.debug(&.emit("Skipping a file not selected by `Globs` and `Excluded`",
        source: document_path.to_s,
        root: root.to_s,
      ))
      publish_empty_diagnostics(document)
      return
    end

    source = Ameba::Source.new(
      document.to_s,
      document_path,
      document_path.relative_to(root),
    )
    formatter = DiagnosticsFormatter.new

    config.sources = [source]
    config.formatter = formatter

    if disabled_rules
      # Excluding instead of disabling, since `Lint/UnneededDisableDirective`
      # would otherwise report inline directives for these rules as unneeded.
      config.rules.each do |rule|
        rule.excluded = Set{source.path.to_s} if rule.name.in?(disabled_rules)
      end
    end

    Log.debug(&.emit("Running ameba",
      source: source.path.to_s,
      root: root.to_s,
    ))

    begin
      Ameba::Runner.new(config).run
    rescue ex
      # The previous diagnostics are gone already, so they shouldn't stay on the client either.
      publish_empty_diagnostics(document)
      raise ex
    end

    diagnostics = formatter.diagnostics
    @diagnostics_mutex.synchronize do
      @diagnostics[document.uri] = diagnostics
    end

    publish_diagnostics(document, diagnostics)
  end

  # Returns `true` unless *document* has been closed (or reopened as another document) since.
  private def open?(document : Larimar::TextDocument) : Bool
    controller.@documents[document.uri]?.same?(document)
  end

  # Globs are validated upfront, yet `File.match?` still raises once
  # a character set reaches a `\` ending the file name. The CLI can't
  # inspect such a file either, since `Dir.glob` raises on it too.
  private def inspects?(config : Config, path : Path) : Bool
    config.inspects?(path)
  rescue ex : File::BadPatternError
    Log.debug(exception: ex, &.emit("Not inspecting a file the globs can't match",
      path: path.to_s,
    ))
    false
  end

  # Returns the closest directory containing either a `.ameba.yml` or a `shard.yml`,
  # the same way Ameba's CLI picks the root, or the directory of the file itself
  # if there's none.
  #
  # Unlike `Larimar::Workspace.find_closest_shard_yml`, it doesn't skip a shard
  # just because a `../../lib` directory happens to exist next to it, which is
  # the case for shards placed in e.g. `/app` or `/workspaces/<name>`, since
  # `/lib` exists on Linux.
  private def project_root(path : Path) : Path
    Ameba::Config.find_root_path(path) || path.parent
  end

  # An invalid config shouldn't leave the document without diagnostics, so
  # it falls back to the defaults, after letting the user know about the error.
  #
  # Malformed `Globs` or `Excluded` sections fall back to their defaults
  # alone, keeping the rest of the config (e.g. rule settings) in effect,
  # since the CLI only fails on them once it reaches the malformed part.
  private def load_config(root : Path)
    Config.load(root: root).tap do |config|
      errors = config.reset_malformed_globs!
      if errors.empty?
        @config_errors_mutex.synchronize do
          @config_errors.delete(root)
        end
      else
        message = errors.join("; ") do |ex|
          ex.message || ex.class.name
        end
        report_config_error(root, message)
      end
    end
  rescue ex
    report_config_error(root, ex.message || ex.class.name)
    Config.load(root: root, skip_reading_config: true)
  end

  # Called on every change, so the same error is reported only once.
  private def report_config_error(root : Path, message : String) : Nil
    already_reported = @config_errors_mutex.synchronize do
      prev_message = @config_errors[root]?.tap do
        @config_errors[root] = message
      end
      prev_message == message
    end
    return if already_reported

    config_path = root / Ameba::Config::Loader::FILENAME
    config_path = Ameba::Config.find_config_path(config_path) || config_path

    show_message(
      message: "#{config_path}: #{message}",
      type: :error,
    )
  end

  private def show_message(message : String, type : LSProtocol::MessageType) : Nil
    controller.server.send_msg(
      LSProtocol::ShowMessageNotification.new(
        params: LSProtocol::ShowMessageParams.new(
          message: message,
          type: type,
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

  private def publish_empty_diagnostics(document) : Nil
    publish_diagnostics(document, [] of LSProtocol::Diagnostic)
  end

  def provide_code_actions(
    document : Larimar::TextDocument,
    range : LSProtocol::Range | LSProtocol::SelectionRange,
    context : LSProtocol::CodeActionContext,
    token : CancellationToken?,
  ) : Array(LSProtocol::CodeAction | LSProtocol::Command)?
    raise_if_cancelled(token)

    diagnostics = @diagnostics_mutex.synchronize do
      @diagnostics[document.uri]?
    end
    return unless diagnostics

    result = [] of LSProtocol::CodeAction | LSProtocol::Command

    # A single directive ignores all of the issues of a rule within a line.
    ignored = Set({String, Int32?}).new

    diagnostics.each do |diagnostic|
      issue, diagnostic =
        diagnostic.issue, diagnostic.diagnostic

      next unless diagnostic.range.overlaps?(range)

      if fixable?(issue)
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

      if ignorable?(document, issue, ignored)
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

  # `Lint/SpecFilename` renames the file on disk from within its correction block,
  # instead of scheduling an edit, so it must never run while resolving a code action.
  private def fixable?(issue : Ameba::Issue) : Bool
    issue.correctable? &&
      !issue.rule.is_a?(Ameba::Rule::Lint::SpecFilename)
  end

  # Returns `true` if an action ignoring the *issue* should be offered,
  # recording its rule and line in *ignored*, so it's offered once per line.
  private def ignorable?(document, issue, ignored) : Bool
    !issue.rule.special? &&
      !breaks_shebang?(document, issue) &&
      ignored.add?({issue.rule.name, issue.location.try(&.line_number)})
  end

  # A directive ignoring an issue reported on the first line would have to be placed
  # either above or at the end of it, which in both cases would break a shebang there.
  private def breaks_shebang?(document, issue) : Bool
    (issue.location.try(&.line_number) == 1) &&
      document.to_s.starts_with?("#!")
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

    # Only reads the document, so it doesn't block other readers.
    document.mutex.read do
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
      newline = document.to_s.includes?("\r\n") ? "\r\n" : "\n"

      position = LSProtocol::Position.new(
        line: line_number.to_u32,
        character: 0_u32,
      )
      text_edits << LSProtocol::TextEdit.new(
        new_text: "#{indent}# ameba:disable #{issue.rule.name}#{newline}",
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
    return unless fixable?(issue)

    corrector = Ameba::Source::Corrector.new(document.to_s)
    issue.correct(corrector)

    workspace_edit = LSProtocol::WorkspaceEdit.new(
      changes: {document.uri => get_text_edits(document, corrector)},
    )

    LSProtocol::CodeAction.new(
      title: "Fix #{issue.rule.name}",
      diagnostics: [diagnostic],
      edit: workspace_edit,
      kind: :quick_fix,
      is_preferred: true,
    )
  end

  # Clients apply same-position edits in their array order, which here follows
  # the order `Ameba::Source::Corrector#process` applies them in.
  private def get_text_edits(document, corrector : Ameba::Source::Corrector) : Array(LSProtocol::TextEdit)
    edits = [] of LSProtocol::TextEdit
    corrector.each_replacement do |begin_pos, end_pos, replacement|
      edits << LSProtocol::TextEdit.new(
        new_text: replacement,
        range: LSProtocol::Range.new(
          start: document.index_to_position(begin_pos),
          end: document.index_to_position(end_pos),
        ),
      )
    end
    edits
  end
end
