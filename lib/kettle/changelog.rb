# frozen_string_literal: true

require "version_gem"
require_relative "changelog/version"

module Kettle
  module Changelog
  end
end

Kettle::Changelog::Version.class_eval do
  extend VersionGem::Basic
end
