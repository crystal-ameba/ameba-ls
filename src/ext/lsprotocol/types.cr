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
end

enum LSProtocol::CodeActionKind
  # Returns the name of the kind used by LSP, which `#to_s` returns
  # for some of the kinds only.
  def lsp_name : String
    case self
    when .quick_fix? then "quickfix"
    when .refactor?  then "refactor"
    when .source?    then "source"
    when .notebook?  then "notebook"
    else                  to_s
    end
  end
end

class LSProtocol::CodeActionContext
  # Returns `true` if actions of the given *kind* were requested.
  #
  # Kinds form a hierarchy, so requesting `source` includes `source.fixAll`.
  def requests?(kind : LSProtocol::CodeActionKind) : Bool
    return true unless (only = self.only)

    name = kind.lsp_name
    only.any? do |requested|
      requested = requested.lsp_name if requested.is_a?(LSProtocol::CodeActionKind)
      name == requested || name.starts_with?("#{requested}.")
    end
  end
end
