require "./spec_helper"

private BINARY_PATH = File.tempname("ameba-ls-spec")

private def run_cli(*args)
  output, error = IO::Memory.new, IO::Memory.new
  status = Process.run(BINARY_PATH, args.to_a, output: output, error: error)

  {status, output.to_s, error.to_s}
end

# Drives the compiled server over stdio, just like an editor would.
private class ClientSession
  @process : Process
  @id = 0

  def initialize(args = [] of String, env = {"LOG_LEVEL" => nil} of String => String?)
    @process = Process.new(BINARY_PATH, args,
      env: env,
      input: :pipe,
      output: :pipe,
      error: :close,
    )
  end

  def close
    @process.terminate
    @process.wait
  end

  def notify(method, params)
    write({jsonrpc: "2.0", method: method, params: params})
  end

  def request(method, params)
    id = (@id += 1)
    write({jsonrpc: "2.0", id: id, method: method, params: params})

    read_until do |message|
      message["id"]?.try(&.as_i?) == id && !message["method"]?
    end
  end

  def read_until(&block : JSON::Any -> Bool) : JSON::Any
    channel = Channel(JSON::Any).new(1)

    spawn do
      while (message = read_message)
        if block.call(message)
          channel.send(message)
          break
        end
      end
    end

    select
    when message = channel.receive
      message
    when timeout(30.seconds)
      raise "Timed out waiting for a message from the server"
    end
  end

  private def write(message)
    json = message.to_json
    input = @process.input

    input << "Content-Length: " << json.bytesize << "\r\n\r\n" << json
    input.flush
  end

  private def read_message : JSON::Any?
    output = @process.output

    return unless (headers = output.gets("\r\n\r\n"))
    return unless (length = headers[/Content-Length: (\d+)/, 1]?.try(&.to_i))

    JSON.parse(output.read_string(length))
  end
end

describe "ameba-ls executable" do
  before_all do
    error = IO::Memory.new
    status = Process.run("crystal",
      ["build", "--no-debug", "-o", BINARY_PATH, Path[__DIR__, "..", "src", "cli.cr"].to_s],
      error: error,
    )
    fail "Unable to build the executable:\n#{error}" unless status.success?
  end

  after_all do
    File.delete?(BINARY_PATH)
    File.delete?("#{BINARY_PATH}.dwarf")
  end

  it "shows the version" do
    {"-v", "--version"}.each do |flag|
      status, output, _ = run_cli(flag)

      status.success?.should be_true
      output.chomp.should eq(AmebaLS::VERSION)
    end
  end

  it "shows the help" do
    {"-h", "--help"}.each do |flag|
      status, output, _ = run_cli(flag)

      status.success?.should be_true
      output.should contain("Language server for Ameba")
      output.should contain("--version")
    end
  end

  it "accepts the --stdio option" do
    session = ClientSession.new(["--stdio"])

    begin
      init = session.request("initialize", {processId: nil, rootUri: nil, capabilities: {} of String => String})
      init["result"]["serverInfo"]["name"].should eq("ameba-ls")
    ensure
      session.close
    end
  end

  it "logs only warnings and errors to the client by default" do
    session = ClientSession.new

    begin
      session.request("initialize", {processId: nil, rootUri: nil, capabilities: {} of String => String})
      session.notify("initialized", {} of String => String)
      session.notify("textDocument/didOpen", {
        textDocument: {uri: SPEC_URI.to_s, languageId: "crystal", version: 1, text: "pp 1\n"},
      })

      log_messages = [] of JSON::Any
      session.read_until do |message|
        log_messages << message if message["method"]? == "window/logMessage"
        message["method"]? == "textDocument/publishDiagnostics"
      end

      log_messages.should be_empty
    ensure
      session.close
    end
  end

  it "logs the messages exchanged with the client with LOG_LEVEL=info" do
    session = ClientSession.new(env: {"LOG_LEVEL" => "info"})

    begin
      session.request("initialize", {processId: nil, rootUri: nil, capabilities: {} of String => String})
      session.notify("initialized", {} of String => String)

      session.read_until do |message|
        message["method"]? == "window/logMessage" &&
          message["params"]["message"].as_s.includes?("Received message")
      end
    ensure
      session.close
    end
  end

  it "rejects invalid options" do
    status, _, error = run_cli("--nope")

    status.success?.should be_false
    status.exit_code.should eq(1)
    error.should contain("--nope is not a valid option")
  end

  it "serves diagnostics and code actions over stdio" do
    uri = SPEC_URI.to_s
    session = ClientSession.new

    begin
      init = session.request("initialize", {processId: nil, rootUri: nil, capabilities: {} of String => String})
      result = init["result"]
      result["serverInfo"]["name"].should eq("ameba-ls")
      result["serverInfo"]["version"].should eq(AmebaLS::VERSION)
      result["capabilities"]["codeActionProvider"]["resolveProvider"].as_bool.should be_true

      session.notify("initialized", {} of String => String)
      session.notify("textDocument/didOpen", {
        textDocument: {
          uri:        uri,
          languageId: "crystal",
          version:    1,
          text:       "foo = 1   \nbar = 2  \nputs foo, bar\n",
        },
      })

      published = session.read_until(&.["method"]?.==("textDocument/publishDiagnostics"))
      published["params"]["uri"].should eq(uri)
      published["params"]["diagnostics"].as_a.map(&.["code"].as_s)
        .should contain("Layout/TrailingWhitespace")

      actions = session.request("textDocument/codeAction", {
        textDocument: {uri: uri},
        range:        {
          start: {line: 0, character: 0},
          end:   {line: 0, character: 0},
        },
        context: {diagnostics: [] of String},
      })["result"].as_a

      fix = actions.find!(&.["title"]?.==("Fix Lint/Formatting"))
      fix["edit"]?.should be_nil

      resolved = session.request("codeAction/resolve", fix)["result"]

      resolved["title"].should eq(fix["title"])
      resolved["edit"]["changes"][uri].as_a.should_not be_empty
    ensure
      session.close
    end
  end
end
