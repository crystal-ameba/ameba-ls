require "../../spec_helper"
require "file_utils"

private def with_workspace(ameba_yml = nil, &)
  tmp_dir = Path[File.tempname("ameba-ls-spec")]
  # Nested, since `Larimar::Workspace.find_closest_shard_yml` skips a `shard.yml`
  # with an existing `../../lib`, which right within `/tmp` is `/lib` on Linux.
  dir = tmp_dir / "workspace"
  Dir.mkdir_p(dir)
  File.write(dir / "shard.yml", "name: spec\nversion: 0.0.0\n")
  File.write(dir / ".ameba.yml", ameba_yml) if ameba_yml

  yield (dir / "subject.cr").to_uri
ensure
  FileUtils.rm_rf(tmp_dir.to_s) if tmp_dir
end

private def published_codes(harness)
  harness.published.last["params"]["diagnostics"].as_a.map(&.["code"].as_s)
end

private def action_titles(actions)
  actions.map(&.title)
end

private def with_spec_file(&)
  with_workspace do |uri|
    path = Path[uri.path].parent / "spec" / "foo.cr"
    Dir.mkdir_p(path.parent)
    File.write(path, "puts 1\n")

    yield path.to_uri, path
  end
end

describe AmebaLS::Provider do
  describe "diagnostics lifecycle" do
    it "publishes diagnostics on open" do
      harness = ProviderHarness.new
      harness.open("pp 1\n")

      message = harness.published.last
      message["method"].should eq("textDocument/publishDiagnostics")
      message["params"]["uri"].should eq(SPEC_URI.to_s)
      message["params"]["diagnostics"].as_a.map(&.["code"].as_s).should eq(["Lint/DebugCalls"])
    end

    it "publishes nothing but an empty list for a clean file" do
      harness = ProviderHarness.new
      harness.open("foo = 1\nputs foo\n")

      harness.published.last["params"]["diagnostics"].as_a.should be_empty
    end

    it "skips documents with a non-file URI" do
      harness = ProviderHarness.new
      uri = URI.parse("untitled:Untitled-1")
      document = harness.open("pp 1\n", uri)

      harness.published.should be_empty
      harness.provider
        .provide_code_actions(document, far_away_range, code_action_context, nil)
        .should be_nil
    end

    it "reports syntax errors" do
      harness = ProviderHarness.new
      harness.open("def foo(\n")

      harness.rule_names.should eq(["Lint/Syntax"])
    end

    it "disables the noisy rules on change, while still running the others" do
      harness = ProviderHarness.new
      document = harness.document("pp 1  \n\n\n")

      harness.provider.on_change(document)

      harness.rule_names.should eq(["Lint/DebugCalls"])
      AmebaLS::Provider::RULES_DISABLED.each do |rule_name|
        harness.rule_names.should_not contain(rule_name)
      end
    end

    it "doesn't report directives of the rules disabled on change as unneeded" do
      harness = ProviderHarness.new
      harness.provider.on_change(
        harness.document("# ameba:disable Layout/TrailingWhitespace\nputs 1   \n")
      )

      harness.rule_names.should be_empty
    end

    it "still reports directives of the other rules as unneeded on change" do
      harness = ProviderHarness.new
      harness.provider.on_change(
        harness.document("# ameba:disable Lint/DebugCalls\nputs 1\n")
      )

      harness.rule_names.should eq(["Lint/UnneededDisableDirective"])
    end

    it "runs all of the rules on open and save" do
      code = "pp 1  \n\n\n"

      opened = ProviderHarness.new
      opened.open(code)
      opened.rule_names.should contain("Layout/TrailingWhitespace")
      opened.rule_names.should contain("Layout/TrailingBlankLines")
      opened.rule_names.should contain("Lint/Formatting")

      saved = ProviderHarness.new
      saved.provider.on_save(saved.document(code))
      saved.rule_names.sort.should eq(opened.rule_names.sort)
    end

    it "replaces the previous diagnostics when the document is analysed again" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")
      harness.rule_names.should eq(["Lint/DebugCalls"])

      document.update_whole("puts 1\n")
      harness.provider.on_save(document)

      harness.rule_names.should be_empty
      harness.published.last["params"]["diagnostics"].as_a.should be_empty
    end

    it "skips issues disabled with an inline comment" do
      harness = ProviderHarness.new
      harness.open("pp 1 # ameba:disable Lint/DebugCalls\n")

      harness.rule_names.should be_empty
    end

    it "forgets diagnostics and clears them on the client on close" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")

      harness.provider.on_close(document)

      message = harness.published.last
      message["params"]["uri"].should eq(SPEC_URI.to_s)
      message["params"]["diagnostics"].as_a.should be_empty
      harness.provider
        .provide_code_actions(document, far_away_range, code_action_context, nil)
        .should be_nil
    end

    it "ignores a change handled after the document got closed" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")

      # The way `Larimar::ProviderController` closes it.
      harness.controller.@documents.delete(document.uri)
      harness.provider.on_close(document)

      harness.provider.on_change(document)

      harness.published.last["params"]["diagnostics"].as_a.should be_empty
      harness.provider.@diagnostics[document.uri]?.should be_nil
    end

    it "ignores a change to a document that got reopened since" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")
      harness.provider.on_close(document)
      harness.open("puts 1\n")
      published_count = harness.published.size

      harness.provider.on_change(document)

      harness.published.size.should eq(published_count)
      harness.rule_names.should be_empty
    end

    describe "configuration" do
      it "resolves rule's `Excluded` against the shard root" do
        with_workspace("Lint/DebugCalls:\n  Excluded:\n    - gen/a.cr\n") do |uri|
          root = Path[uri.path].parent
          excluded, other = (root / "gen" / "a.cr").to_uri, (root / "gen" / "b.cr").to_uri

          harness = ProviderHarness.new
          harness.open("pp 1\n", excluded)
          harness.open("pp 1\n", other)

          harness.rule_names(excluded).should be_empty
          harness.rule_names(other).should eq(["Lint/DebugCalls"])
        end
      end

      it "looks for .ameba.yml starting from the shard root, not the working directory" do
        with_workspace("Lint/DebugCalls:\n  Enabled: false\n") do |uri|
          nested = Path[uri.path].parent / "nested"
          Dir.mkdir_p(nested)
          File.write(nested / "shard.yml", "name: nested\nversion: 0.0.0\n")
          nested_uri = (nested / "subject.cr").to_uri

          harness = ProviderHarness.new
          harness.open("pp 1\n", nested_uri)

          harness.rule_names(nested_uri).should be_empty
        end
      end

      it "uses .ameba.yml from the closest shard root" do
        with_workspace("Lint/DebugCalls:\n  Enabled: false\n") do |uri|
          harness = ProviderHarness.new
          harness.open("pp 1\n", uri)

          harness.rule_names(uri).should be_empty
        end
      end

      it "falls back to the defaults on an invalid .ameba.yml" do
        with_workspace("a: [\n") do |uri|
          harness = ProviderHarness.new
          harness.open("pp 1\n", uri)

          harness.rule_names(uri).should eq(["Lint/DebugCalls"])
          harness.published.last["method"].should eq("textDocument/publishDiagnostics")
        end
      end

      it "reports an invalid .ameba.yml only once, until it gets fixed and broken again" do
        with_workspace("a: [\n") do |uri|
          harness = ProviderHarness.new
          config_errors = -> {
            harness.published.select(&.["method"].==("window/showMessage"))
          }

          document = harness.open("pp 1\n", uri)
          harness.provider.on_change(document)

          config_errors.call.size.should eq(1)
          message = config_errors.call.first["params"]
          message["type"].should eq(LSProtocol::MessageType::Error.value)
          message["message"].as_s.should contain(".ameba.yml")

          config_path = Path[uri.path].parent / ".ameba.yml"

          File.write(config_path, "Lint/DebugCalls:\n  Enabled: false\n")
          harness.provider.on_change(document)
          harness.rule_names(uri).should be_empty

          File.write(config_path, "a: [\n")
          harness.provider.on_change(document)
          config_errors.call.size.should eq(2)
        end
      end

      it "uses .ameba.yml from a shard root with percent-encoded characters in its path" do
        {"my project": "my%20project", "a%20b": "a%2520b"}.each do |name, encoded|
          with_workspace do |uri|
            root = Path[uri.path].parent / name.to_s
            Dir.mkdir_p(root)
            File.write(root / "shard.yml", "name: spec\nversion: 0.0.0\n")
            File.write(root / ".ameba.yml", "Lint/DebugCalls:\n  Enabled: false\n")

            # Percent-encoded, the way clients send it (unlike `Path#to_uri`)
            encoded_uri = URI.new("file", path: URI.encode_path((root / "subject.cr").to_posix.to_s))
            encoded_uri.path.should end_with("/#{encoded}/subject.cr")

            harness = ProviderHarness.new
            harness.open("pp 1\n", encoded_uri)

            harness.rule_names(encoded_uri).should be_empty
          end
        end
      end

      it "uses the defaults when the shard root has no .ameba.yml" do
        with_workspace do |uri|
          harness = ProviderHarness.new
          harness.open("pp 1\n", uri)

          harness.rule_names(uri).should eq(["Lint/DebugCalls"])
        end
      end
    end
  end

  describe "top-level config sections" do
    it "honors `Excluded`" do
      with_workspace("Excluded:\n  - gen\n") do |uri|
        root = Path[uri.path].parent
        harness = ProviderHarness.new

        harness.open("pp 1\n", (root / "gen" / "deep" / "a.cr").to_uri)
        published_codes(harness).should be_empty

        harness.open("pp 1\n", (root / "src" / "a.cr").to_uri)
        published_codes(harness).should eq(["Lint/DebugCalls"])
      end
    end

    it "honors `Globs`" do
      with_workspace("Globs:\n  - src/**/*.cr\n") do |uri|
        root = Path[uri.path].parent
        harness = ProviderHarness.new

        harness.open("pp 1\n", (root / "other" / "a.cr").to_uri)
        published_codes(harness).should be_empty

        harness.open("pp 1\n", (root / "src" / "a.cr").to_uri)
        published_codes(harness).should eq(["Lint/DebugCalls"])
      end
    end

    it "reports a malformed glob once, falling back to the default section for every file" do
      with_workspace("Excluded:\n  - gen/[a.cr\n") do |uri|
        root = Path[uri.path].parent
        harness = ProviderHarness.new
        config_errors = -> {
          harness.published.select(&.["method"].==("window/showMessage"))
        }

        # Only matching paths under `gen` would reach the malformed part.
        {root / "gen" / "a.cr", root / "src" / "a.cr"}.each do |path|
          harness.open("pp 1\n", path.to_uri)
          published_codes(harness).should eq(["Lint/DebugCalls"])
        end

        config_errors.call.size.should eq(1)
        config_errors.call.first["params"]["message"].as_s.should contain("gen/[a.cr")
      end
    end

    it "keeps the rest of the config when a glob is malformed" do
      with_workspace("Excluded:\n  - gen/[a.cr\nLint/DebugCalls:\n  Enabled: false\n") do |uri|
        root = Path[uri.path].parent
        harness = ProviderHarness.new

        harness.open("pp 1\n", (root / "src" / "a.cr").to_uri)
        published_codes(harness).should be_empty

        harness.published.count(&.["method"].==("window/showMessage")).should eq(1)
      end
    end

    # On Windows, `\` is a path separator, so a file name can't end with it.
    {% unless flag?(:windows) %}
      it "doesn't inspect a file the globs raise on" do
        with_workspace("Globs:\n  - src/*[ab]\n") do |uri|
          root = Path[uri.path].parent
          harness = ProviderHarness.new

          # A character set reaching a `\` ending the file name raises,
          # as it does for `Dir.glob`. `Path#to_uri` would escape it.
          harness.open("pp 1\n", URI.new("file", path: "#{root}/src/a\\"))
          published_codes(harness).should be_empty

          harness.open("pp 1\n", (root / "src" / "b").to_uri)
          published_codes(harness).should eq(["Lint/DebugCalls"])
        end
      end
    {% end %}

    it "clears diagnostics and code actions after a file becomes excluded" do
      with_workspace do |uri|
        harness = ProviderHarness.new
        document = harness.open("pp 1\n", uri)
        published_codes(harness).should eq(["Lint/DebugCalls"])

        File.write(Path[uri.path].parent / ".ameba.yml", "Excluded:\n  - subject.cr\n")
        harness.provider.on_change(document)

        published_codes(harness).should be_empty
        harness.provider
          .provide_code_actions(document, lsp_range(0, 0, 0, 0), code_action_context, nil)
          .should be_nil
      end
    end
  end

  describe "#provide_code_actions" do
    it "returns nil for a document that hasn't been analysed" do
      harness = ProviderHarness.new
      document = harness.document("pp 1\n")

      harness.provider
        .provide_code_actions(document, far_away_range, code_action_context, nil)
        .should be_nil
    end

    it "offers only the actions of diagnostics overlapping the range" do
      harness = ProviderHarness.new
      document = harness.document("foo\nbar\n")
      harness.stub_diagnostics(document.uri, [
        stub_diagnostic(rule: Ameba::Rule::Lint::DebugCalls.new, line: 1),
        stub_diagnostic(rule: Ameba::Rule::Style::UnlessElse.new, line: 2),
      ])

      action_titles(harness.actions(document, lsp_range(1, 0, 1, 0)))
        .should eq(["Ignore Style/UnlessElse"])
    end

    it "accepts a selection range" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])

      selection = LSProtocol::SelectionRange.new(range: lsp_range(0, 0, 0, 0))
      actions = harness.provider
        .provide_code_actions(document, selection, code_action_context, nil)
        .should_not(be_nil)

      actions.map(&.as(LSProtocol::CodeAction).title)
        .should eq(["Ignore Layout/TrailingWhitespace"])
    end

    it "only offers to ignore issues that can't be corrected" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])

      action = harness.actions(document, lsp_range(0, 0, 0, 0)).first
      action.title.should eq("Ignore Layout/TrailingWhitespace")
      action.kind.should eq(LSProtocol::CodeActionKind::QuickFix)
      action.is_preferred.should be_falsey
      action.diagnostics.should_not(be_nil).size.should eq(1)
    end

    it "offers to fix and ignore correctable issues, with the preferred fix first" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [
        stub_diagnostic(rule: Ameba::Rule::Lint::DebugCalls.new),
        stub_diagnostic(correction: noop_correction),
      ])

      actions = harness.actions(document, lsp_range(0, 0, 0, 0))
      action_titles(actions).first.should eq("Fix Layout/TrailingWhitespace")
      actions.first.is_preferred.should be_true
      action_titles(actions).should contain("Ignore Layout/TrailingWhitespace")
      action_titles(actions).should contain("Ignore Lint/DebugCalls")
    end

    it "doesn't offer to ignore special rules" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [
        stub_diagnostic(rule: Ameba::Rule::Lint::Syntax.new),
        stub_diagnostic(rule: Ameba::Rule::Lint::UnneededDisableDirective.new, correction: noop_correction),
      ])

      action_titles(harness.actions(document, lsp_range(0, 0, 0, 0)))
        .should eq(["Fix Lint/UnneededDisableDirective"])
    end

    it "offers nothing for a real syntax error" do
      harness = ProviderHarness.new
      document = harness.open("def foo(\n")

      harness.actions(document, lsp_range(0, 0, 9, 0)).should be_empty
    end
  end

  describe "cancellation" do
    cancelled_token = -> {
      CancellationTokenSource.new.tap(&.cancel).token
    }

    it "aborts providing code actions" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")

      expect_raises(CancellationException) do
        harness.provider
          .provide_code_actions(document, far_away_range, code_action_context, cancelled_token.call)
      end
    end

    it "aborts resolving a code action" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")
      action = harness.actions(document, lsp_range(0, 0, 0, 0)).first

      expect_raises(CancellationException) do
        harness.provider.resolve_code_action(action, cancelled_token.call)
      end
    end

    it "carries on with a token that wasn't cancelled" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")
      token = CancellationTokenSource.new.token

      actions = harness.provider
        .provide_code_actions(document, lsp_range(0, 0, 0, 0), code_action_context, token)
        .should_not(be_nil)
      action = actions.first.as(LSProtocol::CodeAction)

      harness.provider.resolve_code_action(action, token).should_not be_nil
    end
  end

  describe "#resolve_code_action" do
    it "returns nil when the action carries no data" do
      harness = ProviderHarness.new

      harness.provider
        .resolve_code_action(LSProtocol::CodeAction.new(title: "x"), nil)
        .should be_nil
    end

    it "returns nil for an unknown document" do
      harness = ProviderHarness.new
      document = harness.open("foo = 1  \nbar = 2  \nputs foo, bar\n")
      action = harness.actions(document, lsp_range(0, 0, 9, 0)).first

      other = ProviderHarness.new
      other.provider.resolve_code_action(action, nil).should be_nil
    end

    it "returns nil for a document without diagnostics" do
      harness = ProviderHarness.new
      document = harness.open("foo = 1  \nbar = 2  \nputs foo, bar\n")
      action = harness.actions(document, lsp_range(0, 0, 9, 0)).first

      harness.provider.on_close(document)

      harness.provider.resolve_code_action(action, nil).should be_nil
    end

    it "returns nil when the document version is missing or outdated" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])
      diagnostic = harness.actions(document, lsp_range(0, 0, 0, 0)).first.diagnostics

      {nil, document.version + 1}.each do |version|
        data = {"uri" => JSON::Any.new(document.uri.to_s)} of String => JSON::Any
        data["version"] = JSON::Any.new(version.to_i64) if version

        action = LSProtocol::CodeAction.new(
          title: "x",
          diagnostics: diagnostic,
          data: JSON::Any.new(data),
        )
        harness.provider.resolve_code_action(action, nil).should be_nil
      end
    end

    it "returns nil when the document has changed since the action was offered" do
      harness = ProviderHarness.new
      document = harness.open("puts 1.is_a?(Nil)\nputs 2.is_a?(Nil)\nputs 3.is_a?(Nil)\n")
      action = harness.actions(document, lsp_range(1, 0, 1, 20))
        .find!(&.title.==("Fix Style/IsANil"))

      # The remaining issues match the one above in everything but the document version
      document.update_whole("puts 2.is_a?(Nil)\nputs 3.is_a?(Nil)\n", version: 1)
      harness.provider.on_change(document)

      harness.provider.resolve_code_action(action, nil).should be_nil
    end

    it "returns nil when the diagnostic is no longer there" do
      harness = ProviderHarness.new
      document = harness.open("puts 1.is_a?(Nil)\n")
      action = harness.actions(document, lsp_range(0, 0, 0, 20))
        .find!(&.title.==("Fix Style/IsANil"))

      document.update_whole("puts 1\n")
      harness.provider.on_save(document)

      harness.provider.resolve_code_action(action, nil).should be_nil
    end

    it "finds the issue after the same version got analysed with different rules" do
      harness = ProviderHarness.new
      document = harness.document("puts 1.is_a?(Nil)   \nputs 2.is_a?(Nil)\n")

      harness.provider.on_change(document)
      action = harness.actions(document, lsp_range(1, 0, 1, 20))
        .find!(&.title.==("Fix Style/IsANil"))

      # Shifts the following issues, due to the rules disabled on change
      harness.provider.on_save(document)

      apply_edits(document, harness.resolve(action))
        .should eq("puts 1.is_a?(Nil)   \nputs 2.nil?\n")
    end

    it "returns nil when a single issue action has no diagnostics" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])

      action = LSProtocol::CodeAction.new(
        title: "x",
        data: JSON::Any.new({
          "uri"     => JSON::Any.new(document.uri.to_s),
          "version" => JSON::Any.new(document.version.to_i64),
        } of String => JSON::Any),
      )
      harness.provider.resolve_code_action(action, nil).should be_nil
    end

    it "resolves actions after a JSON round trip, as received from a client" do
      harness = ProviderHarness.new
      document = harness.open("foo = 1   \nbar = 2  \nputs foo, bar\n")

      harness.actions(document, lsp_range(0, 0, 9, 0)).each do |action|
        received = LSProtocol::CodeAction.from_json(action.to_json)
        resolved = harness.resolve(received)

        resolved.title.should eq(action.title)
        resolved.edit.should_not be_nil
        resolved.to_json.should_not be_empty
      end
    end
  end

  describe "fix action" do
    it "only corrects the issue it was requested for" do
      harness = ProviderHarness.new
      document = harness.open("foo = 1   \nbar = 2  \nputs foo, bar\n")

      action = harness.actions(document, lsp_range(0, 7, 0, 7))
        .find!(&.title.==("Fix Layout/TrailingWhitespace"))
      resolved = harness.resolve(action)

      resolved.kind.should eq(LSProtocol::CodeActionKind::QuickFix)
      resolved.is_preferred.should be_true
      resolved.diagnostics.should_not(be_nil).size.should eq(1)
      apply_edits(document, resolved).should eq("foo = 1\nbar = 2  \nputs foo, bar\n")
    end

    it "supports corrections made of several edits" do
      code = "unless a\n  b\nelse\n  c\nend\n"
      harness = ProviderHarness.new
      document = harness.open(code)

      action = harness.actions(document, lsp_range(0, 0, 0, 0))
        .find!(&.title.==("Fix Style/UnlessElse"))

      apply_edits(document, harness.resolve(action))
        .should eq("if a\n  c\nelse\n  b\nend\n")
    end

    it "applies text inserted before a replacement ahead of it" do
      code = "foo bar"
      harness = ProviderHarness.new
      document = harness.document(code)
      harness.stub_diagnostics(document.uri, [
        stub_diagnostic(code, correction: ->(corrector : Ameba::Source::Corrector) {
          corrector.replace(4...7, "baz")
          corrector.wrap(4...7, "<", ">")
          nil
        }),
      ])

      action = harness.actions(document, lsp_range(0, 0, 0, 0)).first

      apply_edits(document, harness.resolve(action)).should eq("foo <baz>")
    end
  end

  describe "Lint/SpecFilename" do
    it "is reported for spec files without the `_spec` suffix" do
      with_spec_file do |uri, _path|
        harness = ProviderHarness.new
        harness.open("puts 1\n", uri)

        harness.rule_names(uri).should eq(["Lint/SpecFilename"])
      end
    end

    it "only offers to ignore the issue" do
      with_spec_file do |uri, _path|
        harness = ProviderHarness.new
        document = harness.open("puts 1\n", uri)

        harness.actions(document, lsp_range(0, 0, 0, 0)).map(&.title)
          .should eq(["Ignore Lint/SpecFilename"])
      end
    end

    it "doesn't rename the file when resolving a fix action" do
      with_spec_file do |uri, path|
        harness = ProviderHarness.new
        document = harness.open("puts 1\n", uri)

        ignore = harness.actions(document, lsp_range(0, 0, 0, 0)).first
        fix = LSProtocol::CodeAction.new(
          title: "Fix Lint/SpecFilename",
          diagnostics: ignore.diagnostics,
          data: JSON::Any.new(ignore.data.should_not(be_nil).as_h.reject("ignore")),
        )

        harness.provider.resolve_code_action(fix, nil).should be_nil

        File.exists?(path).should be_true
        File.exists?(path.sibling("foo_spec.cr")).should be_false
      end
    end
  end

  describe "ignore action" do
    it "adds a comment above the offending line" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])

      action = harness.actions(document, lsp_range(0, 0, 0, 0))
        .find!(&.title.==("Ignore Layout/TrailingWhitespace"))
      resolved = harness.resolve(action)

      resolved.title.should eq("Ignore Layout/TrailingWhitespace")
      resolved.kind.should eq(LSProtocol::CodeActionKind::QuickFix)
      resolved.is_preferred.should be_falsey
      apply_edits(document, resolved).should eq("# ameba:disable Layout/TrailingWhitespace\nfoo\n")
    end

    it "keeps the indentation of the offending line" do
      harness = ProviderHarness.new
      document = harness.document("def a\n  foo\nend\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic(line: 2)])

      action = harness.actions(document, lsp_range(1, 0, 1, 0)).first

      apply_edits(document, harness.resolve(action))
        .should eq("def a\n  # ameba:disable Layout/TrailingWhitespace\n  foo\nend\n")
    end

    it "extends a directive on the previous line" do
      harness = ProviderHarness.new
      document = harness.document("  # ameba:disable Lint/DebugCalls\n  foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic(line: 2)])

      action = harness.actions(document, lsp_range(1, 0, 1, 0)).first

      apply_edits(document, harness.resolve(action))
        .should eq("  # ameba:disable Lint/DebugCalls, Layout/TrailingWhitespace\n  foo\n")
    end

    it "extends a directive at the end of the offending line" do
      harness = ProviderHarness.new
      document = harness.document("foo # ameba:disable Lint/DebugCalls\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])

      action = harness.actions(document, lsp_range(0, 0, 0, 0)).first

      apply_edits(document, harness.resolve(action))
        .should eq("foo # ameba:disable Lint/DebugCalls, Layout/TrailingWhitespace\n")
    end

    it "doesn't mistake a regular comment for a directive" do
      harness = ProviderHarness.new
      document = harness.document("# a comment\nfoo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic(line: 2)])

      action = harness.actions(document, lsp_range(1, 0, 1, 0)).first

      apply_edits(document, harness.resolve(action))
        .should eq("# a comment\n# ameba:disable Layout/TrailingWhitespace\nfoo\n")
    end

    it "keeps the line endings of the document" do
      harness = ProviderHarness.new
      document = harness.document("bar\r\n  foo\r\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic(line: 2)])

      action = harness.actions(document, lsp_range(1, 0, 1, 0)).first

      apply_edits(document, harness.resolve(action))
        .should eq("bar\r\n  # ameba:disable Layout/TrailingWhitespace\r\n  foo\r\n")
    end

    it "returns nil for an issue without a location" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic(location: nil)])

      action = harness.actions(document, lsp_range(0, 0, 0, 0)).first

      harness.provider.resolve_code_action(action, nil).should be_nil
    end

    it "produces a directive ameba actually honours" do
      harness = ProviderHarness.new
      document = harness.open("pp 1\n")

      action = harness.actions(document, lsp_range(0, 0, 0, 0))
        .find!(&.title.==("Ignore Lint/DebugCalls"))

      document.update_whole(apply_edits(document, harness.resolve(action)))
      harness.provider.on_save(document)

      harness.rule_names.should be_empty
    end

    it "can target the blank lines at the end of a file" do
      harness = ProviderHarness.new
      document = harness.open("puts 1\n\n\n")

      action = harness.actions(document, lsp_range(0, 0, 9, 0))
        .find!(&.title.==("Ignore Layout/TrailingBlankLines"))

      apply_edits(document, harness.resolve(action))
        .should contain("# ameba:disable Layout/TrailingBlankLines\n")
    end
  end

  # `LSProtocol::CodeActionKind#to_s` only maps some of the kinds to their LSP
  # names, so this currently serializes as "QuickFix".
  pending "serializes quick fixes with the quickfix kind" do
    harness = ProviderHarness.new
    document = harness.document("foo\n")
    harness.stub_diagnostics(document.uri, [stub_diagnostic])

    action = harness.actions(document, lsp_range(0, 0, 0, 0)).first

    JSON.parse(action.to_json)["kind"].should eq("quickfix")
  end
end
