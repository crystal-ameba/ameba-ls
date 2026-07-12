struct Ameba::Issue
  def lsp_location_range : LSProtocol::Range
    location = self.location || Crystal::Location.new(nil, 1, 1)
    end_location = self.end_location || location

    LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: location.line_number.to_u32 - 1,
        character: location.column_number.to_u32 - 1,
      ),
      end: LSProtocol::Position.new(
        line: end_location.line_number.to_u32 - 1,
        character: end_location.column_number.to_u32,
      ),
    )
  end
end
