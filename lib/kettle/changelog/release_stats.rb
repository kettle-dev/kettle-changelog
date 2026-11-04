# frozen_string_literal: true

module Kettle
  module Changelog
    # Reads the generated stats back out of a changelog's latest released section.
    #
    # The writer (CLI) puts these lines directly under each release heading:
    #
    #   ## [2.1.0] - 2026-10-25
    #   - TAG: [v2.1.0][2.1.0t]
    #   - COVERAGE: 98.48% -- 649/659 lines in 16 files
    #   - BRANCH COVERAGE: 93.53% -- 217/232 branches in 16 files
    #   - 90.83% documented
    #
    # Only these exact shapes count. `[Unreleased]` is ignored, and so are older releases: a gem whose
    # latest release lacks the lines reports nothing rather than a stale number from an earlier one.
    module ReleaseStats
      NUMBER = '(\d+(?:\.\d+)?)'
      RELEASE_HEADING = /\A## \[(\d+\.\d+\.\d+[0-9A-Za-z.+-]*)\](?: - (\d{4}-\d{2}-\d{2}))?/
      LINE_COVERAGE = /\A- COVERAGE: #{NUMBER}% -- (\d+)\/(\d+) lines in (\d+) files\s*\z/
      BRANCH_COVERAGE = /\A- BRANCH COVERAGE: #{NUMBER}% -- (\d+)\/(\d+) branches in (\d+) files\s*\z/
      DOCUMENTED = /\A- #{NUMBER}%\s+documented\s*\z/

      module_function

      # @param text [String] full CHANGELOG.md contents
      # @return [Hash, nil] nil when the changelog has no released section; otherwise
      #   {version:, date:, coverage:, branch_coverage:, documented:} with nil for anything not found
      def parse(text)
        lines = text.to_s.lines
        start = lines.index { |l| l.match?(RELEASE_HEADING) }
        return unless start

        heading = lines[start].match(RELEASE_HEADING)
        stats = {version: heading[1], date: heading[2], coverage: nil, branch_coverage: nil, documented: nil}
        lines[(start + 1)..].each do |line|
          break if line.start_with?("#") # next heading, or the first ### subsection: the stats lines come before both

          if (m = line.match(LINE_COVERAGE))
            stats[:coverage] ||= counts(m)
          elsif (m = line.match(BRANCH_COVERAGE))
            stats[:branch_coverage] ||= counts(m)
          elsif (m = line.match(DOCUMENTED))
            stats[:documented] ||= m[1].to_f
          end
        end
        stats
      end

      def counts(match)
        {percent: match[1].to_f, covered: match[2].to_i, total: match[3].to_i, files: match[4].to_i}
      end
      private_class_method :counts
    end
  end
end
