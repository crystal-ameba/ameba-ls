class LSProtocol::InitializeResult
  def initialize(
    @capabilities : ServerCapabilities?,
    @server_info : ServerInfo? = ServerInfo.new(
      name: "ameba-ls",
      version: AmebaLS::VERSION,
    ),
  )
    previous_def
  end
end

class LSProtocol::Position
  include Comparable(self)

  def <=>(other : self)
    {line, character} <=> {other.line, other.character}
  end

  # Consistent with `#==`, which `Comparable` defines by value.
  def hash(hasher)
    {line, character}.hash(hasher)
  end
end

class LSProtocol::Range
  def ==(other : self)
    start == other.start && self.end == other.end
  end

  # Consistent with `#==`.
  def hash(hasher)
    {start, self.end}.hash(hasher)
  end

  # Returns `true` if the range has no characters, like the one of a cursor.
  def empty?
    start == self.end
  end

  # Returns `true` if this range and *other* have a character in common,
  # with their ends being exclusive.
  #
  # An empty range (e.g. a cursor) overlaps the ranges it's placed within,
  # including at their boundaries.
  def overlaps?(other : self)
    if empty? || other.empty?
      (start..self.end)
        .overlaps?(other.start..other.end)
    else
      start < other.end &&
        other.start < self.end
    end
  end

  def overlaps?(other : SelectionRange)
    overlaps?(other.range)
  end
end
