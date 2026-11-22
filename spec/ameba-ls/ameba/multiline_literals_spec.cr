require "../../spec_helper"

describe AmebaLS::MultilineLiterals do
  describe ".lines_in" do
    it "finds lines of a heredoc" do
      AmebaLS::MultilineLiterals.lines_in("x = <<-TXT\n  a\n  TXT\nputs x\n")
        .should eq(Set{2, 3})
    end

    it "finds lines of a heredoc opened along with other code" do
      AmebaLS::MultilineLiterals.lines_in("foo(<<-A, 1) # c\n  a\n  A\nputs 2\n")
        .should eq(Set{2, 3})
    end

    it "finds lines of every heredoc opened on the same line" do
      AmebaLS::MultilineLiterals.lines_in("foo(<<-A, <<-B)\n  a\n  A\n  b\n  B\nputs 2\n")
        .should eq(Set{2, 3, 4, 5})
    end

    it "finds lines of a string" do
      AmebaLS::MultilineLiterals.lines_in(%(x = "a\n  b"\nputs x\n))
        .should eq(Set{2})
    end

    it "finds lines of a percent array" do
      AmebaLS::MultilineLiterals.lines_in("x = %w[\n  a\n  b\n]\ny = %i[\n  a\n]\n")
        .should eq(Set{2, 3, 4, 6, 7})
    end

    it "finds lines of a regex" do
      AmebaLS::MultilineLiterals.lines_in("x = /a\n  b/\n")
        .should eq(Set{2})
    end

    it "skips arrays, which allow for comments" do
      AmebaLS::MultilineLiterals.lines_in("x = [\n  1,\n  2,\n]\n")
        .should be_empty
    end

    it "doesn't fail on invalid code" do
      AmebaLS::MultilineLiterals.lines_in("x = (\n").should be_empty
    end
  end
end
