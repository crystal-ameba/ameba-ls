require "../../spec_helper"

describe LSProtocol::PositionEncodingKind do
  describe "#code_units" do
    it "counts the code units of a string in the encoding" do
      LSProtocol::PositionEncodingKind::Utf8.code_units("aź😀").should eq(7)
      LSProtocol::PositionEncodingKind::Utf16.code_units("aź😀").should eq(4)
      LSProtocol::PositionEncodingKind::Utf32.code_units("aź😀").should eq(3)
    end
  end
end
