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

    it "returns true for ranges touching at their boundaries" do
      lsp_range(1, 0, 1, 5).overlaps?(lsp_range(1, 5, 1, 9)).should be_true
      lsp_range(1, 5, 1, 9).overlaps?(lsp_range(1, 0, 1, 5)).should be_true
    end

    it "returns false for disjoint ranges" do
      lsp_range(1, 0, 1, 4).overlaps?(lsp_range(1, 5, 1, 9)).should be_false
      lsp_range(1, 0, 1, 9).overlaps?(lsp_range(2, 0, 2, 9)).should be_false
      lsp_range(2, 0, 2, 9).overlaps?(lsp_range(1, 0, 1, 9)).should be_false
    end

    it "accepts a selection range" do
      range = lsp_range(1, 0, 1, 9)

      range.overlaps?(LSProtocol::SelectionRange.new(range: lsp_range(1, 5, 1, 5))).should be_true
      range.overlaps?(LSProtocol::SelectionRange.new(range: lsp_range(2, 0, 2, 0))).should be_false
    end
  end
end
