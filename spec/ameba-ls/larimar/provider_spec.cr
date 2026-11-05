require "../../spec_helper"
require "file_utils"

private def with_workspace(ameba_yml = nil, &)
  dir = Path[File.tempname("ameba-ls-spec")]
  Dir.mkdir_p(dir)
  File.write(dir / "shard.yml", "name: spec\nversion: 0.0.0\n")
  File.write(dir / ".ameba.yml", ameba_yml) if ameba_yml

  yield (dir / "subject.cr").to_uri
ensure
  FileUtils.rm_rf(dir.to_s) if dir
end

private def action_titles(actions)
  actions.map(&.title)
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

    describe "configuration" do
      it "uses .ameba.yml from the closest shard root" do
        with_workspace("Lint/DebugCalls:\n  Enabled: false\n") do |uri|
          harness = ProviderHarness.new
          harness.open("pp 1\n", uri)

          harness.rule_names(uri).should be_empty
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

    it "returns nil when the issue index is missing or out of bounds" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])
      diagnostic = harness.actions(document, lsp_range(0, 0, 0, 0)).first.diagnostics

      {nil, 1}.each do |idx|
        data = {"uri" => JSON::Any.new(document.uri.to_s)} of String => JSON::Any
        data["idx"] = JSON::Any.new(idx.to_i64) if idx

        action = LSProtocol::CodeAction.new(
          title: "x",
          diagnostics: diagnostic,
          data: JSON::Any.new(data),
        )
        harness.provider.resolve_code_action(action, nil).should be_nil
      end
    end

    it "returns nil when a single issue action has no diagnostics" do
      harness = ProviderHarness.new
      document = harness.document("foo\n")
      harness.stub_diagnostics(document.uri, [stub_diagnostic])

      action = LSProtocol::CodeAction.new(
        title: "x",
        data: JSON::Any.new({
          "uri" => JSON::Any.new(document.uri.to_s),
          "idx" => JSON::Any.new(0_i64),
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
