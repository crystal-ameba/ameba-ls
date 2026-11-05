# Matches paths against globs without scanning the file system.
module AmebaLS::GlobUtils
  include Ameba::GlobUtils
  extend self

  # Glob selecting Crystal files within a directory.
  private DIRECTORY_GLOB = "**/*.{cr,ecr}"

  # Returns `true` if *path* is selected by the specified globs, the same
  # way `Ameba::GlobUtils#find_files_by_globs` would select it.
  #
  # ```
  # matches_globs?(["**/*.cr", "!lib"], "src/foo.cr") # => true
  # matches_globs?(["**/*.cr", "!lib"], "lib/foo.cr") # => false
  # ```
  #
  # Unlike `Ameba::GlobUtils#find_files_by_globs`, it doesn't scan the file system, so it can
  # be used to match paths of files not (yet) saved to disk. The only file
  # system access is checking whether globs prefixed with `!` point to
  # existing files. Hence, unlike `Ameba::GlobUtils#find_files_by_globs`, it:
  #
  # - selects files within directories pointed to by globs without wildcards,
  #   even if these directories don't exist (yet)
  # - selects files within symlinked directories matched by wildcards,
  #   which `Dir.glob` doesn't follow
  # - matches globs case-sensitively, even on case-insensitive file systems
  # - selects files hidden by file system attributes (on Windows)
  #
  # Raises `File::BadPatternError` if it encounters a malformed glob.
  def matches_globs?(globs, path, root = Dir.current) : Bool
    rejected = rejected_globs(globs, root)
    selected = globs - rejected

    root = Path[root].expand.to_posix.to_s
    path = Path[path].expand(root).to_posix.to_s

    matches_any_glob?(selected, path, root) &&
      !matches_any_glob?(rejected.map!(&.lchop), path, root)
  end

  # Raises `File::BadPatternError` if any of the *globs* is malformed.
  #
  # Matching raises only once it reaches the malformed part of a glob, which
  # depends on the path being matched. This checks all of them upfront.
  #
  # NOTE: `File.match?` also raises once a character set reaches a `\`
  # ending the file name, regardless of the glob, which this can't catch.
  #
  # ```
  # validate_globs!(["src/**/*.cr"]) # => nil
  # validate_globs!(["src/[a.cr"])   # raises File::BadPatternError
  # ```
  def validate_globs!(globs) : Nil
    globs.each do |glob|
      # Normalized the way `#matches_globs?` expands it, since segments
      # followed by `..` never get matched.
      normalized = Path[glob.lchop('!')].normalize.to_posix.to_s

      expand_braces(normalized).each do |pattern|
        segments(pattern).each do |segment|
          validate_segment!(segment, glob) if wildcard?(segment)
        end
      end
    end
  end

  # Mirrors the errors `File.match?` raises: on an unterminated character
  # set, and on an escape character at the end of the pattern.
  private def validate_segment!(segment, glob) : Nil
    chars = segment.chars
    i = 0

    while i < chars.size
      case chars[i]
      when '\\'
        if i + 1 == chars.size
          raise File::BadPatternError.new("Empty escape character in glob: #{glob}")
        end
        i += 2
      when '['
        i += 1
        i += 1 if chars[i]? == '^'

        # A `]` right after the opening `[` (or `[^`) is a member of the set.
        first = true
        while i < chars.size && (first || chars[i] != ']')
          i += chars[i] == '\\' ? 2 : 1
          first = false
        end

        if i >= chars.size
          raise File::BadPatternError.new("Unterminated character set in glob: #{glob}")
        end
        i += 1
      else
        i += 1
      end
    end
  end

  private def matches_any_glob?(globs, path, root)
    globs.any? do |glob|
      pattern = Path[glob].expand(root).to_posix.to_s

      next true if matches_pattern?(pattern, path, root)

      # Globs without wildcards might point to directories (see `#expand`)
      next false if wildcard?(glob) || glob.includes?('{')

      matches_pattern?("#{pattern}/#{DIRECTORY_GLOB}", path, root)
    end
  end

  # The *root* part of *pattern* is matched literally, the same way
  # `Dir.glob` matches it relative to the current directory, so glob
  # metacharacters and hidden entries in it don't affect the match.
  private def matches_pattern?(pattern, path, root)
    root = root.rstrip('/')
    prefix = "#{root}/"

    # Equal to *root* for globs like `.`
    if pattern == root || pattern.starts_with?(prefix)
      return false unless path.starts_with?(prefix)

      pattern, path = pattern[root.size..], path[root.size..]
    end

    path = segments(path)

    expand_braces(pattern).any? do |expanded|
      matches_segments?(segments(expanded), path)
    end
  end

  # Matches *path* segments against *pattern* segments the way `Dir.glob`
  # does. A `**` segment matches any number of directories, unless it's
  # the last one, in which case it behaves like `*`.
  private def matches_segments?(pattern, path, i = 0, j = 0) : Bool
    while i < pattern.size
      segment = pattern[i]

      if segment == "**" && i < pattern.size - 1
        return matches_recursive_segments?(pattern, path, i, j)
      end

      return false unless (name = path[j]?)
      return false unless matches_segment?(segment, name)

      i += 1
      j += 1
    end

    j == path.size
  end

  # `Dir.glob` doesn't recurse into hidden directories, nor does it match
  # hidden files directly following `**`, even by name.
  private def matches_recursive_segments?(pattern, path, i, j)
    return false if i + 2 == pattern.size && path.last?.try { |name| hidden?(name) }

    j.upto(path.size - 1) do |k|
      return true if matches_segments?(pattern, path, i + 1, k)
      break if hidden?(path[k])
    end

    false
  end

  # Hidden entries are matched only by segments without wildcards.
  private def matches_segment?(segment, name)
    return segment == name unless wildcard?(segment)

    !hidden?(name) && File.match?(segment, name)
  end

  private def wildcard?(glob)
    glob.each_char.any?(&.in?('*', '?', '[', '\\'))
  end

  private def hidden?(name)
    name.starts_with?('.')
  end

  private def segments(path)
    path.split('/', remove_empty: true)
  end

  # Expands brace alternatives the same way `Dir.glob` does, before the
  # pattern is split into segments.
  private def expand_braces(pattern : String) : Array(String)
    return [pattern] unless (positions = brace_positions(pattern))

    front, back = pattern[...positions.first], pattern[positions.last + 1..]

    positions.each_cons_pair.flat_map do |(alt_start, alt_end)|
      expand_braces("#{front}#{pattern[alt_start + 1...alt_end]}#{back}")
    end.to_a
  end

  # Returns positions of the first top-level brace pair in *pattern*,
  # along with the commas separating its alternatives.
  private def brace_positions(pattern : String) : Array(Int32)?
    positions = [] of Int32
    nest = 0
    escaped = false

    pattern.each_char_with_index do |char, index|
      if escaped
        escaped = false
        next
      end

      case char
      when '\\'
        escaped = true
      when '{'
        positions << index if nest.zero?
        nest += 1
      when ','
        positions << index if nest == 1
      when '}'
        # Unmatched, it leaves the braces that follow unexpanded.
        nest -= 1
        return positions << index if nest.zero?
      end
    end

    nil
  end
end
