require "../../spec_helper"

describe Ameba::Issue do
  describe "#lsp_location_range" do
    it "converts 1-based locations to 0-based positions, with an exclusive end" do
      issue = stub_issue(
        location: Crystal::Location.new(nil, 2, 3),
        end_location: Crystal::Location.new(nil, 4, 5),
      )

      issue.lsp_location_range.to_json.should eq(lsp_range(1, 2, 3, 5).to_json)
    end

    it "falls back to the location when there's no end location" do
      issue = stub_issue(
        location: Crystal::Location.new(nil, 2, 3),
        end_location: nil,
      )

      issue.lsp_location_range.to_json.should eq(lsp_range(1, 2, 1, 3).to_json)
    end

    it "points to the beginning of the file when there's no location" do
      issue = stub_issue(location: nil, end_location: nil)

      issue.lsp_location_range.to_json.should eq(lsp_range(0, 0, 0, 1).to_json)
    end
  end
end
