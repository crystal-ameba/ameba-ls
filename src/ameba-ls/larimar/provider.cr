require "./fix_edits"
require "./ignore_edits"

class AmebaLS::Provider < Larimar::Provider
  include Larimar::CodeActionProvider

  include FixEdits
  include IgnoreEdits

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

  private def diagnostics_for(uri : URI) : Array(IssueDiagnostic)?
    @diagnostics_mutex.synchronize do
      @diagnostics[uri]?
    end
  end

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
    formatter = DiagnosticsFormatter.new(document.position_encoding)

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
  # Unlike `Larimar::Workspace.find_closest_shard_yml`, it also stops at a directory
  # containing only a `.ameba.yml`, and doesn't skip shards installed into the `lib`
  # folder of another one, so these are linted against their own root and config.
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
    range : LSProtocol::Range,
    context : LSProtocol::CodeActionContext,
    token : CancellationToken?,
  ) : Array(LSProtocol::CodeAction | LSProtocol::Command)?
    token.try(&.cancelled!)

    return unless (diagnostics = diagnostics_for(document.uri))

    # The preferred fixes come first, followed by the ignores.
    fixes = [] of LSProtocol::CodeAction | LSProtocol::Command
    ignores = [] of LSProtocol::CodeAction | LSProtocol::Command

    # A single directive ignores all of the issues of a rule within a line.
    ignored = Set({String, UInt32}).new

    diagnostics.each do |diagnostic|
      issue, diagnostic =
        diagnostic.issue, diagnostic.diagnostic

      next unless diagnostic.range.overlaps?(range)

      if fixable?(issue)
        fixes << fix_code_action(issue, diagnostic,
          data: code_action_data(document),
        )
      end

      if ignorable?(document, issue) &&
         ignored.add?({issue.rule.name, diagnostic.range.start.line})
        ignores << ignore_code_action(issue, diagnostic,
          data: code_action_data(document, ignore: true),
        )
      end
    end

    fixes.concat(ignores)

    # Applies to the whole document, so it's offered regardless of the requested range.
    if diagnostics.any? { |entry| fixable?(entry.issue) }
      fixes << fix_all_code_action(
        data: code_action_data(document, fix_all: true),
      )
    end

    fixes
  end

  # ameba:disable Metrics/CyclomaticComplexity
  def resolve_code_action(
    code_action : LSProtocol::CodeAction,
    token : CancellationToken?,
  ) : LSProtocol::CodeAction?
    token.try(&.cancelled!)

    return unless (data = code_action.data.try(&.as_h?)) &&
                  (document_uri_string = data["uri"]?.try(&.as_s?)) &&
                  (document_uri = URI.parse(document_uri_string)) &&
                  (document = controller.document?(document_uri)) &&
                  (version = data["version"]?.try(&.as_i?))

    ignore = data["ignore"]?.try(&.as_bool?) || false
    fix_all = data["fix_all"]?.try(&.as_bool?) || false

    # Only reads the document, so it doesn't block other readers.
    document.mutex.read do
      # The document has changed since the action was offered,
      # hence the issues it was offered for might not be there anymore.
      next unless version == document.version
      next unless (diagnostics = diagnostics_for(document_uri))

      if fix_all
        text_edits, fixed = fix_all_edits(document, diagnostics)
        next fix_all_code_action(
          diagnostics: fixed.map(&.diagnostic),
          edit: workspace_edit(document, text_edits),
        )
      end

      next unless (diagnostic = code_action.diagnostics.try(&.first?))
      next unless (issue = diagnostics.find(&.matches?(diagnostic)).try(&.issue))

      if ignore
        next unless (text_edit = ignore_edit(document, issue))
        ignore_code_action(issue, diagnostic,
          edit: workspace_edit(document, [text_edit]),
        )
      else
        next unless (text_edits = fix_edits(document, issue))
        fix_code_action(issue, diagnostic,
          edit: workspace_edit(document, text_edits),
        )
      end
    end
  end

  # Returns the data `#resolve_code_action` looks up the document
  # of the action by, along with the version it was offered for.
  private def code_action_data(document, ignore = false, fix_all = false) : JSON::Any
    data = {
      "uri"     => JSON::Any.new(document.uri.to_s),
      "version" => JSON::Any.new(document.version),
    }
    data["ignore"] = JSON::Any.new(true) if ignore
    data["fix_all"] = JSON::Any.new(true) if fix_all

    JSON::Any.new(data)
  end

  # Returns the action fixing the *issue*, offered with either *data* to resolve
  # it by, or resolved already with an *edit*.
  private def fix_code_action(issue, diagnostic, *, data = nil, edit = nil) : LSProtocol::CodeAction
    LSProtocol::CodeAction.new(
      title: "Fix #{issue.rule.name}",
      diagnostics: [diagnostic],
      kind: :quick_fix,
      is_preferred: true,
      data: data,
      edit: edit,
    )
  end

  # Returns the action ignoring the *issue*, offered with either *data* to resolve
  # it by, or resolved already with an *edit*.
  private def ignore_code_action(issue, diagnostic, *, data = nil, edit = nil) : LSProtocol::CodeAction
    LSProtocol::CodeAction.new(
      title: "Ignore #{issue.rule.name}",
      diagnostics: [diagnostic],
      kind: :quick_fix,
      data: data,
      edit: edit,
    )
  end

  # Returns the action fixing all of the fixable issues of a document, offered with
  # either *data* to resolve it by, or resolved already with an *edit* fixing the
  # issues of the given *diagnostics*.
  private def fix_all_code_action(*, diagnostics = nil, data = nil, edit = nil) : LSProtocol::CodeAction
    LSProtocol::CodeAction.new(
      title: "Fix all auto-correctable issues",
      diagnostics: diagnostics,
      kind: :source_fix_all,
      data: data,
      edit: edit,
    )
  end

  private def workspace_edit(document, text_edits : Array(LSProtocol::TextEdit)) : LSProtocol::WorkspaceEdit
    LSProtocol::WorkspaceEdit.new(
      changes: {document.uri => text_edits},
    )
  end
end
