class Larimar::TextDocument
  # Returns the number of code units *string* takes in the given *encoding*.
  def self.code_units(string : String, encoding : LSProtocol::PositionEncodingKind) : Int32
    case encoding
    in .utf8?  then string.bytesize
    in .utf16? then string.each_char.sum { |char| code_units(char, encoding) }
    in .utf32? then string.size
    end
  end
end
