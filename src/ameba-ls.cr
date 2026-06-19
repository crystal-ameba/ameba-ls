require "log"
require "ameba"
require "larimar/api/provider_server"

module AmebaLS
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end

require "./ext/**"
require "./ameba-ls/**"
