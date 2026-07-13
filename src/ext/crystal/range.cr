{% skip_file if Range.has_method?(:overlaps?) %}

# https://github.com/crystal-lang/crystal/pull/17081
struct Range(B, E)
  protected def empty_without_iterating? : Bool
    return false unless (end_value = @end)
    return false unless (begin_value = @begin)

    @exclusive ? begin_value >= end_value : begin_value > end_value
  end

  # Returns `true` if this range and *other* have at least one value in common.
  #
  # ```
  # (1..5).overlaps?(5..10)  # => true
  # (1...5).overlaps?(5..10) # => false
  # (1...1).overlaps?(1..1)  # => false
  # ```
  def overlaps?(other : Range) : Bool
    return false if empty_without_iterating?
    return false if other.empty_without_iterating?

    if (end_value = @end) && (other_begin = other.begin)
      return false if @exclusive ? end_value <= other_begin : end_value < other_begin
    end

    if (other_end = other.end) && (begin_value = @begin)
      return false if other.excludes_end? ? other_end <= begin_value : other_end < begin_value
    end

    true
  end
end
