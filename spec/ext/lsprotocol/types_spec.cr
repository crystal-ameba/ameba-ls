require "../../spec_helper"

describe LSProtocol::InitializeResult do
  it "reports the server name and version by default" do
    result = LSProtocol::InitializeResult.new(LSProtocol::ServerCapabilities.new)

    server_info = result.server_info.should_not(be_nil)
    server_info.name.should eq("ameba-ls")
    server_info.version.should eq(AmebaLS::VERSION)
  end
end

describe LSProtocol::Position do
  it "compares by line first, then by character" do
    (lsp_position(1, 9) < lsp_position(2, 0)).should be_true
    (lsp_position(2, 0) > lsp_position(1, 9)).should be_true
    (lsp_position(1, 1) < lsp_position(1, 2)).should be_true
    (lsp_position(1, 2) > lsp_position(1, 1)).should be_true
    (lsp_position(1, 1) == lsp_position(1, 1)).should be_true
  end

  it "hashes by value, consistently with `#==`" do
    lsp_position(1, 2).hash.should eq(lsp_position(1, 2).hash)
    Set{lsp_position(1, 2), lsp_position(1, 2)}.size.should eq(1)
  end
end

describe LSProtocol::Range do
  it "#empty? returns true for a range without characters" do
    lsp_range(1, 5, 1, 5).empty?.should be_true
    lsp_range(1, 5, 1, 6).empty?.should be_false
  end

  describe "#==" do
    it "compares by value" do
      (lsp_range(1, 0, 1, 9) == lsp_range(1, 0, 1, 9)).should be_true
      (lsp_range(1, 0, 1, 9) == lsp_range(1, 0, 1, 8)).should be_false
      (lsp_range(1, 0, 1, 9) == lsp_range(0, 0, 1, 9)).should be_false
    end
  end

  describe "#hash" do
    it "hashes by value, consistently with `#==`" do
      lsp_range(1, 0, 1, 9).hash.should eq(lsp_range(1, 0, 1, 9).hash)
      Set{lsp_range(1, 0, 1, 9), lsp_range(1, 0, 1, 9)}.size.should eq(1)
      Set{lsp_range(1, 0, 1, 9), lsp_range(1, 0, 1, 8)}.size.should eq(2)
    end
  end

  describe "#overlaps?" do
    it "returns true for a position inside of the range" do
      lsp_range(1, 0, 1, 9).overlaps?(lsp_range(1, 5, 1, 5)).should be_true
    end

    it "returns true for ranges partially covering each other" do
      lsp_range(1, 0, 2, 5).overlaps?(lsp_range(2, 0, 3, 0)).should be_true
      lsp_range(2, 0, 3, 0).overlaps?(lsp_range(1, 0, 2, 5)).should be_true
    end

    it "returns true for a position at the boundaries of the range" do
      lsp_range(1, 0, 1, 5).overlaps?(lsp_range(1, 5, 1, 5)).should be_true
      lsp_range(1, 0, 1, 5).overlaps?(lsp_range(1, 0, 1, 0)).should be_true
      lsp_range(1, 5, 1, 5).overlaps?(lsp_range(1, 0, 1, 5)).should be_true
    end

    it "returns true for an empty range at the boundary of another empty one" do
      lsp_range(1, 5, 1, 5).overlaps?(lsp_range(1, 5, 1, 5)).should be_true
    end

    it "returns false for ranges only touching at their boundaries, since their ends are exclusive" do
      lsp_range(1, 0, 1, 5).overlaps?(lsp_range(1, 5, 1, 9)).should be_false
      lsp_range(1, 5, 1, 9).overlaps?(lsp_range(1, 0, 1, 5)).should be_false
    end

    it "returns false for a selection of whole lines, ending where the next one starts" do
      lsp_range(0, 0, 1, 0).overlaps?(lsp_range(1, 0, 1, 4)).should be_false
    end

    it "returns false for disjoint ranges" do
      lsp_range(1, 0, 1, 4).overlaps?(lsp_range(1, 5, 1, 9)).should be_false
      lsp_range(1, 0, 1, 9).overlaps?(lsp_range(2, 0, 2, 9)).should be_false
      lsp_range(2, 0, 2, 9).overlaps?(lsp_range(1, 0, 1, 9)).should be_false
    end
  end
end

describe LSProtocol::CodeActionKind do
  it "#lsp_name returns the names used by LSP" do
    LSProtocol::CodeActionKind::QuickFix.lsp_name.should eq("quickfix")
    LSProtocol::CodeActionKind::Source.lsp_name.should eq("source")
    LSProtocol::CodeActionKind::SourceFixAll.lsp_name.should eq("source.fixAll")
    LSProtocol::CodeActionKind::Empty.lsp_name.should eq("")
  end

  it "#lsp_name round trips through parsing" do
    LSProtocol::CodeActionKind.each do |kind|
      LSProtocol::CodeActionKind.parse(kind.lsp_name).should eq(kind)
    end
  end
end

private def context_requesting(only)
  LSProtocol::CodeActionContext.from_json({diagnostics: [] of String, only: only}.to_json)
end

describe LSProtocol::CodeActionContext do
  describe "#requests?" do
    it "returns true when no kinds were requested" do
      context_requesting(nil).requests?(:quick_fix).should be_true
    end

    it "returns true for a requested kind" do
      context_requesting(%w[refactor quickfix]).requests?(:quick_fix).should be_true
    end

    it "returns true for a kind within a requested one" do
      context_requesting(%w[source]).requests?(:source_fix_all).should be_true
    end

    it "returns false for a kind that wasn't requested" do
      context_requesting(%w[source.fixAll]).requests?(:quick_fix).should be_false
      context_requesting(%w[source.fixAll]).requests?(:source).should be_false
      context_requesting(%w[quick]).requests?(:quick_fix).should be_false
    end

    it "accepts kinds not known to `LSProtocol::CodeActionKind`" do
      context_requesting(%w[source.fixAll.ameba]).requests?(:source_fix_all).should be_false
      context_requesting(%w[source.fixAll.ameba quickfix]).requests?(:quick_fix).should be_true
    end
  end
end
