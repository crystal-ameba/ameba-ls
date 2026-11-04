require "./spec_helper"
require "yaml"

describe AmebaLS do
  it "reports the version from shard.yml" do
    shard = YAML.parse(File.read(Path[__DIR__, "..", "shard.yml"]))

    AmebaLS::VERSION.should eq(shard["version"].as_s)
  end
end
