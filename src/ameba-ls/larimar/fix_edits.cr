# Builds the edits fixing an issue with the correction its rule provides.
module AmebaLS::FixEdits
  # `Lint/SpecFilename` renames the file on disk from within its correction block,
  # instead of scheduling an edit, so it must never run while resolving a code action.
  private def fixable?(issue : Ameba::Issue) : Bool
    issue.correctable? &&
      !issue.rule.is_a?(Ameba::Rule::Lint::SpecFilename)
  end

  # Returns the edits fixing the *issue* within *document*, or `nil` if it can't be fixed.
  private def fix_edits(document, issue : Ameba::Issue) : Array(LSProtocol::TextEdit)?
    return unless fixable?(issue)

    corrector = Ameba::Source::Corrector.new(document.to_s)
    issue.correct(corrector)

    corrector_edits(document, corrector)
  end

  # Clients apply same-position edits in their array order, which here follows
  # the order `Ameba::Source::Corrector#process` applies them in.
  private def corrector_edits(document, corrector : Ameba::Source::Corrector) : Array(LSProtocol::TextEdit)
    code = document.to_s
    edits = [] of LSProtocol::TextEdit
    corrector.each_replacement do |begin_pos, end_pos, replacement|
      edits << LSProtocol::TextEdit.new(
        new_text: replacement,
        range: LSProtocol::Range.new(
          start: char_index_to_position(document, code, begin_pos),
          end: char_index_to_position(document, code, end_pos),
        ),
      )
    end
    edits
  end

  # Ameba's corrector counts characters, while `Larimar::TextDocument` counts bytes.
  private def char_index_to_position(document, code : String, index : Int32) : LSProtocol::Position
    offset = code.char_index_to_byte_index(index) ||
             raise IndexError.new("#{index} not in document")

    document.offset_to_position(offset)
  end
end
