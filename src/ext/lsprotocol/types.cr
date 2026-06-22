class LSProtocol::InitializeResult
  def initialize(
    @capabilities : ServerCapabilities?,
    @server_info : ServerInfo? = ServerInfo.new(
      name: "ameba-ls",
      version: AmebaLS::VERSION,
    ),
  )
    previous_def
  end
end
