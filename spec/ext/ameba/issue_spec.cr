require "../../spec_helper"

describe Ameba::Issue do
  describe "#lsp_location_range" do
    it "converts 1-based locations to 0-based positions, with an exclusive end" do
      issue = stub_issue(
        location: Crystal::Location.new(nil, 2, 3),
        end_location: Crystal::Location.new(nil, 4, 5),
      )
      issue.lsp_location_range(%w[], :utf8).to_json
        .should eq(lsp_range(1, 2, 3, 5).to_json)
    end

    it "falls back to the location when there's no end location" do
      issue = stub_issue(
        location: Crystal::Location.new(nil, 2, 3),
        end_location: nil,
      )
      issue.lsp_location_range(%w[], :utf8).to_json
        .should eq(lsp_range(1, 2, 1, 3).to_json)
    end

    it "points to the beginning of the file when there's no location" do
      issue = stub_issue(
        location: nil,
        end_location: nil,
      )
      issue.lsp_location_range(%w[], :utf8).to_json
        .should eq(lsp_range(0, 0, 0, 1).to_json)
    end

    it "counts the characters in the code units of the given encoding" do
      issue = stub_issue(
        location: Crystal::Location.new(nil, 2, 4),
        end_location: Crystal::Location.new(nil, 2, 5),
      )
      lines = ["", "ź😀 ab"]

      issue.lsp_location_range(lines, :utf8).to_json.should eq(lsp_range(1, 7, 1, 9).to_json)
      issue.lsp_location_range(lines, :utf16).to_json.should eq(lsp_range(1, 4, 1, 6).to_json)
      issue.lsp_location_range(lines, :utf32).to_json.should eq(lsp_range(1, 3, 1, 5).to_json)
    end

    it "counts the columns past the end of the line as one code unit each" do
      issue = stub_issue(
        location: Crystal::Location.new(nil, 1, 3),
        end_location: Crystal::Location.new(nil, 1, 3),
      )
      issue.lsp_location_range(%w[ź], :utf8).to_json
        .should eq(lsp_range(0, 3, 0, 4).to_json)
    end
  end
end
