require "../../spec_helper"
require "file_utils"

module AmebaLS
  subject = GlobUtils
  root = Path[__DIR__, "..", "..", ".."].expand

  current_file_basename = File.basename(__FILE__)

  describe GlobUtils do
    describe "#matches_globs?" do
      it "matches a file by filepath" do
        subject.matches_globs?([__FILE__], __FILE__, root: root)
          .should be_true
      end

      it "matches a relative path" do
        subject.matches_globs?(["spec/**/*_spec.cr"], "spec/foo_spec.cr", root: root)
          .should be_true
      end

      it "matches files by directory" do
        subject.matches_globs?(["spec"], "spec/foo/bar.cr", root: root)
          .should be_true
      end

      it "matches only crystal files by directory" do
        subject.matches_globs?(["spec"], "spec/foo/bar.yml", root: root)
          .should be_false
      end

      it "matches files by globs" do
        subject.matches_globs?(["**/*_spec.cr"], __FILE__, root: root)
          .should be_true
      end

      it "doesn't match files outside of globs" do
        subject.matches_globs?(["src/**/*.cr"], __FILE__, root: root)
          .should be_false
      end

      it "doesn't match rejected globs" do
        subject.matches_globs?(["**/*_spec.cr", "!**/#{current_file_basename}"], __FILE__, root: root)
          .should be_false
      end

      it "doesn't match rejected folders" do
        subject.matches_globs?(["**/*_spec.cr", "!spec"], __FILE__, root: root)
          .should be_false
      end

      it "matches files not saved to disk" do
        subject.matches_globs?(["**/*.cr", "!lib"], "src/not_there.cr", root: root)
          .should be_true
      end

      it "matches files in directories only if they're Crystal files" do
        subject.matches_globs?(["src"], "src/foo.yml", root: root)
          .should be_false
      end

      it "doesn't match nested directories by wildcard globs" do
        subject.matches_globs?(["src/*"], "src/foo/bar.cr", root: root)
          .should be_false
      end

      it "treats trailing `**` as `*`" do
        subject.matches_globs?(["src/**"], "src/foo.cr", root: root)
          .should be_true
        subject.matches_globs?(["src/**"], "src/foo/bar.cr", root: root)
          .should be_false
      end

      it "doesn't match hidden files and directories by wildcards" do
        subject.matches_globs?(["**/*.cr"], "src/.foo.cr", root: root)
          .should be_false
        subject.matches_globs?(["**/*.cr"], ".foo/bar.cr", root: root)
          .should be_false
        subject.matches_globs?(["src"], "src/.foo/bar.cr", root: root)
          .should be_false
      end

      it "matches hidden files and directories by name" do
        subject.matches_globs?([".foo/*.cr"], ".foo/bar.cr", root: root)
          .should be_true
        subject.matches_globs?([".foo"], ".foo/bar.cr", root: root)
          .should be_true
      end

      it "doesn't match hidden files directly following `**`, even by name" do
        subject.matches_globs?(["**/.foo.cr"], "src/.foo.cr", root: root)
          .should be_false
        subject.matches_globs?(["**/src/.foo.cr"], "src/.foo.cr", root: root)
          .should be_true
      end

      it "doesn't match a path without any segments" do
        subject.matches_globs?(["**/*.cr"], "/", root: "/")
          .should be_false
      end

      it "raises on malformed globs" do
        expect_raises(File::BadPatternError) do
          subject.matches_globs?(["src/[a.cr"], "src/a.cr", root: root)
        end
      end

      it "expands braces" do
        subject.matches_globs?(["{src,spec/foo}/*.cr"], "spec/foo/bar.cr", root: root)
          .should be_true
        subject.matches_globs?(["{src,spec/foo}/*.cr"], "spec/bar.cr", root: root)
          .should be_false
      end

      # Glob metacharacters and hidden entries in the root itself must not
      # affect matching, like they don't for `Dir.glob` run from within it.
      {
        "glob_utils",
        "glob_utils[a]{b,c}*?",
        "glob_utils[unterminated",
        ".glob_utils[hidden]/root",
      }.each do |root_name|
        it "agrees with #find_files_by_globs (root: #{root_name})" do
          # Resolved, so `Dir.current` within it (on macOS: `/private/var/…`)
          # doesn't differ from it, making `Dir.glob` see the root after all.
          tmp_dir = Path[File.tempname("glob_utils")]
          Dir.mkdir_p(tmp_dir)
          tmp_dir = Path[File.realpath(tmp_dir)]
          tmp_root = tmp_dir / root_name
          files = %w[
            a.cr b.ecr c.yml .d.cr
            src/a.cr src/.b.cr src/c.yml
            src/server/a.cr src/server/.c.cr src/server/sub/b.cr
            src/.hidden/a.cr
            .github/a.cr .github/sub/b.cr
            lib/dep/src/a.cr
            a_spec.cr/b.cr
          ] + ["a}b.cr", "a}{b,c}.cr", "}{a}.cr"]
          files.each do |file|
            path = tmp_root / file
            Dir.mkdir_p(path.parent)
            File.touch(path)
          end

          begin
            [
              %w[**/*.cr], %w[**/*], %w[**], %w[*/*.cr], %w[src], %w[src/],
              %w[src/*], %w[src/*/], %w[src/**], %w[lib/**], %w[**/*_spec.cr],
              %w[.github], %w[.github/**/*.cr], %w[**/.github/*.cr], %w[src/.hidden/*.cr],
              ["{src,lib}/**/*.cr"], ["{src/server,lib}"], ["src/*.{cr,ecr}"], %w[src/[a-b].cr],
              %w[**/.d.cr], %w[**/.c.cr], %w[src/**/.c.cr], %w[**/server/.c.cr],
              %w[**/server/**/*.cr], %w[**/**/*.cr], %w[.], %w[src/../lib],
              ["{src/{server,x},lib}/**/*.cr"],
              # An unmatched `}` leaves the braces that follow unexpanded.
              ["a}{b,c}.cr"], ["}{a}.cr"], ["}{{a,b}}.cr"], ["{a,b}}.cr"],
              %w[**/*.cr !lib], %w[**/*.cr !lib/**], %w[src/**/*.cr !src/server/*],
              ["**/*.cr", "!{lib,src/server}"], %w[src/**/*.cr !src/server/sub/b.cr],
            ].each do |globs|
              # `Dir.glob` treats the root as a pattern too, unless it's the
              # current directory, which is how the CLI is typically run.
              found = Dir.cd(tmp_root) do
                subject.find_files_by_globs(globs, tmp_root)
                  .map { |path| Path[path].expand.to_s }
              end

              files.each do |file|
                path = (tmp_root / file).to_s
                matched = subject.matches_globs?(globs, path, tmp_root)

                unless matched == found.includes?(path)
                  fail "#{globs} #{matched ? "matched" : "didn't match"} #{file}"
                end
              end
            end
          ensure
            FileUtils.rm_rf(tmp_dir)
          end
        end
      end
    end

    describe "#validate_globs!" do
      it "accepts well-formed globs" do
        globs = [
          "**/*.cr", "!lib", "src/[a-c].cr", "src/[^a].cr", "src/[]].cr",
          "src/[^]].cr", "src/[a-].cr", "src/[\\]].cr", "src/\\[a.cr",
          "{src,spec}/**/*.cr", "src/*{a.cr", "src/[a.cr/../b.cr",
        ]
        subject.validate_globs!(globs)
      end

      it "raises on malformed globs, whichever path they would be matched against" do
        [
          "src/[a.cr", "src/[^a.cr", "src/[].cr", "src/*\\", "src/[a\\",
          "{src,spec/[a}/*.cr", "!src/[a.cr", "src/*.cr/[a/*.cr",
        ].each do |glob|
          expect_raises(File::BadPatternError, glob) do
            subject.validate_globs!([glob])
          end
        end
      end

      it "agrees with matching" do
        paths = %w[src/a.cr src/[a.cr src/].cr src/b/a.cr]

        [
          "src/[a.cr", "src/[^a.cr", "src/[].cr", "src/[]].cr", "src/*\\",
          "src/[a\\", "src/[\\]].cr", "src/[a-].cr", "src/*[ab][c",
        ].each do |glob|
          raised = paths.any? do |path|
            subject.matches_globs?([glob], path, root: root)
            false
          rescue File::BadPatternError
            true
          end

          validated = begin
            subject.validate_globs!([glob])
            true
          rescue File::BadPatternError
            false
          end

          fail "#{glob} raised on matching, but not on validation" if raised && validated
        end
      end
    end
  end
end
