require "../../spec_helper"

describe Range do
  describe "#overlaps?" do
    it "returns true for ranges sharing values" do
      (1..5).overlaps?(3..10).should be_true
      (3..10).overlaps?(1..5).should be_true
      (1..10).overlaps?(3..5).should be_true
    end

    it "treats inclusive ends as shared" do
      (1..5).overlaps?(5..10).should be_true
      (5..10).overlaps?(1..5).should be_true
    end

    it "treats exclusive ends as not shared" do
      (1...5).overlaps?(5..10).should be_false
      (5..10).overlaps?(1...5).should be_false
    end

    it "returns false for disjoint ranges" do
      (1..2).overlaps?(3..4).should be_false
      (3..4).overlaps?(1..2).should be_false
    end

    it "returns false for empty ranges" do
      (1...1).overlaps?(1..1).should be_false
      (1..1).overlaps?(1...1).should be_false
      (5..1).overlaps?(1..5).should be_false
    end

    it "supports open ended ranges" do
      (1..).overlaps?(5..10).should be_true
      (..5).overlaps?(5..10).should be_true
      (..4).overlaps?(5..10).should be_false
      (6..).overlaps?(1..5).should be_false
      (..5).overlaps?(1..).should be_true
    end
  end
end
