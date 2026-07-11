struct Ameba::Issue
  def location_range : LSProtocol::Range?
    return unless (location = self.location)
    return unless (end_location = self.end_location)

    LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: location.line_number.to_u - 1,
        character: location.column_number.to_u - 1,
      ),
      end: LSProtocol::Position.new(
        line: end_location.line_number.to_u - 1,
        character: end_location.column_number.to_u,
      ),
    )
  end
end
