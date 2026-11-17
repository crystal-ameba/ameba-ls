require "../../spec_helper"

describe Larimar::TextDocument do
  describe ".code_units" do
    it "counts the code units of a string in the given encoding" do
      Larimar::TextDocument.code_units("aź😀", :utf8).should eq(7)
      Larimar::TextDocument.code_units("aź😀", :utf16).should eq(4)
      Larimar::TextDocument.code_units("aź😀", :utf32).should eq(3)
    end
  end
end
