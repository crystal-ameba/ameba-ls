require "option_parser"
require "./ameba-ls"

OptionParser.parse do |parser|
  parser.banner = "Language server for Ameba, a linter for Crystal Programming Language"

  parser.on "-v", "--version", "Show version" do
    puts AmebaLS::VERSION
    exit
  end

  parser.on "-h", "--help", "Show help" do
    puts parser
    exit
  end

  parser.invalid_option do |option_flag|
    STDERR.puts "ERROR: #{option_flag} is not a valid option."
    STDERR.puts parser
    exit 1
  end
end

server = Larimar::Server.new(STDIN, STDOUT)

backend = Larimar::LogBackend.new(server,
  formatter: Larimar::LogFormatter,
)
Log.setup_from_env(backend: backend)

controller = Larimar::ProviderController.new
controller.register_provider(AmebaLS::Provider.new)

server.start(controller)
