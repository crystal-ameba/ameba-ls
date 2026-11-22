# Asks the client to watch config files for changes, if it's able to,
# and calls `#on_config_change` once any of them changes.
module AmebaLS::ConfigWatcher
  # The ID of the registration watching config files for changes.
  CONFIG_WATCHER_ID = "ameba-ls/config-watcher"

  # Called once any of the watched config files has changed.
  abstract def on_config_change : Nil

  def when_ready : Nil
    return unless watches_files?

    controller.server.send_msg(
      LSProtocol::RegistrationRequest.new(
        id: CONFIG_WATCHER_ID,
        params: LSProtocol::RegistrationParams.new(
          registrations: [config_watcher_registration],
        ),
      )
    )
  end

  def on_watched_files_change(changes : Array(LSProtocol::FileEvent)) : Nil
    return unless changes.any? { |change| config_file?(change.uri) }

    on_config_change
  end

  # Returns `true` if the client is able to register watchers.
  private def watches_files? : Bool
    !!controller.capabilities
      .try(&.workspace)
      .try(&.did_change_watched_files)
      .try(&.dynamic_registration)
  end

  private def config_watcher_registration : LSProtocol::Registration
    options = LSProtocol::DidChangeWatchedFilesRegistrationOptions.new(
      watchers: [
        LSProtocol::FileSystemWatcher.new(
          glob_pattern: "**/#{Ameba::Config::Loader::FILENAME}",
        ),
      ],
    )

    LSProtocol::Registration.new(
      id: CONFIG_WATCHER_ID,
      method: "workspace/didChangeWatchedFiles",
      register_options: JSON.parse(options.to_json),
    )
  end

  private def config_file?(uri : URI) : Bool
    uri.scheme == "file" &&
      Path[URI.decode(uri.path)].basename == Ameba::Config::Loader::FILENAME
  end
end
