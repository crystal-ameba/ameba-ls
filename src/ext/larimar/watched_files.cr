# Larimar doesn't handle changes of watched files, so they get dispatched to providers here.
class Larimar::Provider
  # Called when any of the files watched for the client changes.
  def on_watched_files_change(changes : Array(LSProtocol::FileEvent)) : Nil
  end
end

class Larimar::ProviderController
  # Returns the documents open at the moment.
  def documents : Array(TextDocument)
    @documents_mutex.synchronize { @documents.values }
  end

  def on_notification(message : LSProtocol::DidChangeWatchedFilesNotification) : Nil
    @providers.each(&.on_watched_files_change(message.params.changes))
  end
end
