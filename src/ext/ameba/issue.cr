struct Ameba::Issue
  # Returns the range of the issue, with its character offsets expressed
  # in the code units of *encoding*, as counted within the *lines* of its source.
  #
  # On lines missing from *lines*, the character offsets are the columns themselves.
  def lsp_location_range(lines, encoding : LSProtocol::PositionEncodingKind) : LSProtocol::Range
    location = self.location || Crystal::Location.new(nil, 1, 1)
    end_location = self.end_location || location

    LSProtocol::Range.new(
      start: lsp_position(location.line_number, location.column_number - 1, lines, encoding),
      end: lsp_position(end_location.line_number, end_location.column_number, lines, encoding),
    )
  end

  # Converts the 0-based character *column* within the 1-based *line_number*.
  private def lsp_position(line_number, column, lines, encoding) : LSProtocol::Position
    character = column

    if (line = lines[line_number - 1]?)
      # Columns past the end of the line (e.g. its newline) count as one code unit each.
      character = encoding.code_units(line[0, column]) +
                  Math.max(column - line.size, 0)
    end

    LSProtocol::Position.new(
      line: line_number.to_u32 - 1,
      character: character.to_u32,
    )
  end
end
