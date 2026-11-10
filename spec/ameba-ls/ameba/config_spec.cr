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

  describe "#inspects?" do
    root = Path["/project"]

    build_config = ->(globs : Array(String), excluded : Array(String)) {
      AmebaLS::Config.load(root: root, skip_reading_config: true).tap do |config|
        config.globs = globs.to_set
        config.excluded = excluded.to_set
      end
    }

    it "selects files matching the default sections" do
      default = AmebaLS::Config.load(root: root, skip_reading_config: true)

      default.inspects?(root / "src" / "a.cr").should be_true
      default.inspects?(root / "src" / "a.ecr").should be_true
      default.inspects?(root / "src" / "a.txt").should be_false
      default.inspects?(root / "lib" / "dep" / "src" / "a.cr").should be_false
    end

    it "doesn't require a file to exist" do
      build_config.call(["**/*.cr"], [] of String)
        .inspects?(root / "not" / "saved" / "yet.cr").should be_true
    end

    it "matches globs against the root" do
      subject = build_config.call(["src/**/*.cr"], [] of String)

      subject.inspects?(root / "src" / "a.cr").should be_true
      subject.inspects?(root / "spec" / "a.cr").should be_false
      subject.inspects?(Path["/other/src/a.cr"]).should be_false
    end

    it "excludes files, directories and globs" do
      subject = build_config.call(["**/*.cr"], ["gen", "tmp/*.cr", "src/a.cr"])

      subject.inspects?(root / "gen" / "deep" / "a.cr").should be_false
      subject.inspects?(root / "tmp" / "a.cr").should be_false
      subject.inspects?(root / "src" / "a.cr").should be_false
      subject.inspects?(root / "src" / "b.cr").should be_true
    end

    it "supports rejected globs" do
      subject = build_config.call(["**/*.cr", "!vendor"], [] of String)

      subject.inspects?(root / "vendor" / "a.cr").should be_false
      subject.inspects?(root / "src" / "a.cr").should be_true
    end

    it "accepts paths relative to the root" do
      subject = build_config.call(["src/**/*.cr"], [] of String)

      subject.inspects?("src/not_there.cr").should be_true
      subject.inspects?("spec/not_there.cr").should be_false
    end

    it "doesn't select hidden files and directories by wildcards" do
      subject = build_config.call(["**/*.cr"], [] of String)

      subject.inspects?(root / "src" / ".a.cr").should be_false
      subject.inspects?(root / ".hidden" / "a.cr").should be_false
    end

    it "doesn't select nested directories by wildcard globs" do
      subject = build_config.call(["src/*"], [] of String)

      subject.inspects?(root / "src" / "a.cr").should be_true
      subject.inspects?(root / "src" / "foo" / "a.cr").should be_false
    end

    it "selects only Crystal files within directories" do
      subject = build_config.call(["src"], [] of String)

      subject.inspects?(root / "src" / "foo" / "a.cr").should be_true
      subject.inspects?(root / "src" / "a.yml").should be_false
    end
  end

  describe "#reset_malformed_globs!" do
    root = Path["/project"]

    it "keeps well-formed sections" do
      config = AmebaLS::Config.load(root: root, skip_reading_config: true)
      config.globs = Set{"src/**/*.cr"}
      config.excluded = Set{"gen"}

      config.reset_malformed_globs!.should be_empty
      config.globs.should eq(Set{"src/**/*.cr"})
      config.excluded.should eq(Set{"gen"})
    end

    it "resets only the malformed section" do
      config = AmebaLS::Config.load(root: root, skip_reading_config: true)
      config.globs = Set{"src/[a.cr"}
      config.excluded = Set{"gen"}

      config.reset_malformed_globs!.size.should eq(1)
      config.globs.should eq(Ameba::Config::DEFAULT_GLOBS)
      config.excluded.should eq(Set{"gen"})

      config.globs = Set{"src/**/*.cr"}
      config.excluded = Set{"gen/[a.cr"}

      config.reset_malformed_globs!.size.should eq(1)
      config.globs.should eq(Set{"src/**/*.cr"})
      config.excluded.should eq(Ameba::Config::DEFAULT_EXCLUDED)
    end

    it "resets both sections" do
      config = AmebaLS::Config.load(root: root, skip_reading_config: true)
      config.globs = Set{"src/[a.cr"}
      config.excluded = Set{"gen/[a.cr"}

      config.reset_malformed_globs!.size.should eq(2)
      config.globs.should eq(Ameba::Config::DEFAULT_GLOBS)
      config.excluded.should eq(Ameba::Config::DEFAULT_EXCLUDED)
    end
  end
end
