# Builds the edits ignoring an issue with an inline `ameba:disable` directive,
# either by extending an existing directive Ameba honors, or by adding a new one.
module AmebaLS::IgnoreEdits
  # Parses inline directives the way Ameba does, telling apart the ones it ignores.
  private module InlineDirectives
    extend Ameba::InlineComments
  end

  # The index of the group capturing the rules of a directive.
  private DIRECTIVE_RULES_GROUP =
    Ameba::InlineComments::COMMENT_DIRECTIVE_REGEX.name_table.key_for("rules")

  # Returns `true` if the *issue* can be ignored with an inline directive.
  #
  # An issue with no location can't be ignored by a directive, as it has no line.
  #
  # The *literal_lines* of `MultilineLiterals.lines_in` the *document* can be
  # passed in when checking many issues, so the document is parsed only once.
  private def ignorable?(document, issue : Ameba::Issue, literal_lines : Set(Int32)? = nil) : Bool
    return false unless (line_number = issue.location.try(&.line_number))

    !issue.rule.special? &&
      !breaks_shebang?(document, line_number) &&
      !within_literal?(document, line_number, literal_lines)
  end

  # A directive ignoring an issue reported on the first line would have to be placed
  # either above or at the end of it, which in both cases would break a shebang there.
  private def breaks_shebang?(document, line_number : Int32) : Bool
    line_number == 1 &&
      document.to_s.starts_with?("#!")
  end

  # A directive placed on a line within a multi-line literal (e.g. a heredoc)
  # would become a part of its value, instead of a comment.
  private def within_literal?(document, line_number : Int32, literal_lines : Set(Int32)? = nil) : Bool
    literal_lines ||= MultilineLiterals.lines_in(document.to_s)
    literal_lines.includes?(line_number)
  end

  # Returns an edit ignoring the *issue* within *document*, or `nil` if it can't be ignored.
  #
  # Prefers extending a directive on the line above the issue, then the one ending
  # the line of the issue, and only then adds a new directive above that line.
  private def ignore_edit(document, issue : Ameba::Issue) : LSProtocol::TextEdit?
    return unless ignorable?(document, issue)
    return unless (line = issue.location.try(&.line_number.- 1))

    rule_name = issue.rule.name

    extend_directive(document, line - 1, rule_name, above: true) ||
      extend_directive(document, line, rule_name, above: false) ||
      add_directive(document, line, rule_name)
  end

  # Returns an edit appending *rule_name* right after the rules of the `disable`
  # directive within the *line* of *document*, if Ameba honors it there, i.e.
  # if it's the line *above* the issue and a comment one, or if it's the line
  # of the issue and the directive ends it.
  #
  # Ameba ignores a directive followed by another comment, or commented out itself,
  # while the one ending a line is told apart from one within a string literal.
  private def extend_directive(document, line : Int32, rule_name : String, *, above : Bool) : LSProtocol::TextEdit?
    return unless (line_text = line_at(document, line))
    text, line_start = line_text

    return unless (match = Ameba::InlineComments::COMMENT_DIRECTIVE_REGEX.match(text))
    return unless Ameba::InlineComments::Action.parse?(match["action"]).try(&.disable?)

    rules_end = match.byte_end(DIRECTIVE_RULES_GROUP)

    if above
      return unless text.lstrip.starts_with?('#')
    else
      return unless text.byte_slice(rules_end).blank?
    end

    # Lexes the line, hence it goes last.
    return unless InlineDirectives.parse_inline_directive(text)

    insert_edit(document, line_start + rules_end, ", #{rule_name}")
  end

  # Returns an edit adding a directive disabling *rule_name* above the *line*
  # of *document*, indented the same way, or `nil` if there's no such line.
  private def add_directive(document, line : Int32, rule_name : String) : LSProtocol::TextEdit?
    return unless (line_text = line_at(document, line))
    text, line_start = line_text

    indent = text[/\A[ \t]*/]
    newline = document.to_s.includes?("\r\n") ? "\r\n" : "\n"

    insert_edit(document, line_start, "#{indent}# ameba:disable #{rule_name}#{newline}")
  end

  # Returns the text of the *line* of *document*, without its line break,
  # along with the byte offset it starts at, or `nil` if there's no such line.
  private def line_at(document, line : Int32) : {String, Int32}?
    return if line.negative?

    line_start = document.position_to_offset(
      LSProtocol::Position.new(line: line.to_u32, character: 0_u32)
    )
    # A character past the end of the line resolves to the end of that line.
    line_end = document.position_to_offset(
      LSProtocol::Position.new(line: line.to_u32, character: UInt32::MAX)
    )

    {document.to_s.byte_slice(line_start, line_end - line_start), line_start}
  rescue IndexError
  end

  # Returns an edit inserting *text* at the byte *offset* of *document*.
  private def insert_edit(document, offset : Int32, text : String) : LSProtocol::TextEdit
    position = document.offset_to_position(offset)

    LSProtocol::TextEdit.new(
      new_text: text,
      range: LSProtocol::Range.new(start: position, end: position),
    )
  end
end
