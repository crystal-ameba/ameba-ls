require "../../spec_helper"

describe AmebaLS::Config do
  it "allows overriding the sources" do
    source = Ameba::Source.new("foo\n", "subject.cr")

    config = AmebaLS::Config.load(path: nil)
    config.sources = [source]

    config.sources.should eq([source])
  end

  it "falls back to the sources found by ameba" do
    config = AmebaLS::Config.load(path: nil)

    config.sources.map(&.path.to_s).any?(&.ends_with?("config_spec.cr"))
      .should be_true
  end
end
