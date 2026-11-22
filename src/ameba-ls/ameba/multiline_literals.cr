# Finds the lines placed within multi-line string-like literals (including heredocs),
# where a comment would become a part of the literal's value.
#
# Uses AST instead of `Ameba::Tokenizer`, which doesn't lex heredocs the way the parser does.
class AmebaLS::MultilineLiterals < Crystal::Visitor
  # Returns (1-based) numbers of such lines, excluding the line each literal starts at.
  def self.lines_in(code : String) : Set(Int32)
    source = Ameba::Source.new(code)
    visitor = new(source)
    source.ast.accept(visitor)
    visitor.lines
  rescue Crystal::SyntaxException
    Set(Int32).new
  end

  getter lines = Set(Int32).new

  def initialize(@source : Ameba::Source)
  end

  def visit(node : Crystal::StringLiteral | Crystal::StringInterpolation | Crystal::RegexLiteral | Crystal::SymbolLiteral)
    add_lines(node)
    true
  end

  def visit(node : Crystal::ArrayLiteral)
    add_lines(node) if percent_literal?(node)
    true
  end

  def visit(node : Crystal::ASTNode)
    true
  end

  # `%w[]` and `%i[]`, as opposed to `[]`, which allows for comments between its elements.
  private def percent_literal?(node)
    return false unless (location = node.location)

    @source.lines[location.line_number - 1]?
      .try(&.[location.column_number - 1]?) == '%'
  end

  private def add_lines(node)
    return unless (location = node.location) && (end_location = node.end_location)

    ((location.line_number + 1)..end_location.line_number).each do |line_number|
      lines << line_number
    end
  end
end
