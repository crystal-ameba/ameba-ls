require "./glob_utils"

class AmebaLS::Config < Ameba::Config
  property sources : Array(Ameba::Source) { super }

  # Returns `true` if the file at *path* is selected by `#globs` and not by
  # `#excluded`, the same way `#files` would select it.
  #
  # Doesn't scan the file system, so it can be used to match paths of files
  # not (yet) saved to disk. See `GlobUtils#matches_globs?` for how it differs
  # from `#files` as a result.
  def inspects?(path : Path | String) : Bool
    GlobUtils.matches_globs?(globs, path, root) &&
      !GlobUtils.matches_globs?(excluded, path, root)
  end

  # Resets `#globs` and `#excluded` to their defaults if they contain
  # a malformed glob, which `#inspects?` would otherwise raise on only
  # for some paths. Leaves the rest of the config intact.
  #
  # Returns the errors raised by the sections that were reset.
  def reset_malformed_globs! : Array(File::BadPatternError)
    errors = [] of File::BadPatternError
    begin
      GlobUtils.validate_globs!(globs)
    rescue ex : File::BadPatternError
      errors << ex
      self.globs = DEFAULT_GLOBS.dup
    end
    begin
      GlobUtils.validate_globs!(excluded)
    rescue ex : File::BadPatternError
      errors << ex
      self.excluded = DEFAULT_EXCLUDED.dup
    end
    errors
  end
end
