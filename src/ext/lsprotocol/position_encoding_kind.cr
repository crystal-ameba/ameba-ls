enum LSProtocol::PositionEncodingKind
  # Returns the number of code units *string* takes in this encoding.
  def code_units(string : String) : Int32
    case self
    in .utf8?  then string.bytesize
    in .utf16? then string.each_char.sum { |char| code_units(char) }
    in .utf32? then string.size
    end
  end
end
