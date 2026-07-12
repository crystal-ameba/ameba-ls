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
end

class LSProtocol::Range
  def overlaps?(other : self)
    (start..self.end)
      .overlaps?(other.start..other.end)
  end

  def overlaps?(other : LSProtocol::SelectionRange)
    overlaps?(other.range)
  end
end
