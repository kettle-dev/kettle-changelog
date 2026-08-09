# frozen_string_literal: true

module Kettle
  module Changelog
    # Version namespace for this gem.
    module Version
      # Current gem version.
      VERSION = "0.1.0"
    end
    # Current gem version exposed at the traditional constant location.
    VERSION = Version::VERSION # Traditional Constant Location
  end
end
