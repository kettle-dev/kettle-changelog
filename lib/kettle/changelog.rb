# frozen_string_literal: true

require "version_gem"
require "kettle/dev"
require_relative "changelog/version"

module Kettle
  module Changelog
    class Error < StandardError; end

    autoload :CLI, "kettle/changelog/cli"
    autoload :EntryAdder, "kettle/changelog/entry_adder"
    autoload :TransferMerger, "kettle/changelog/transfer_merger"
  end
end

Kettle::Changelog::Version.class_eval do
  extend VersionGem::Basic
end
