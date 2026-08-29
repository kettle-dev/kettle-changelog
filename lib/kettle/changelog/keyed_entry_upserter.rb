# frozen_string_literal: true

module Kettle
  module Changelog
    class KeyedEntryUpserter
      SECTIONS = %w[Added Changed Deprecated Removed Fixed Security].freeze
      KEY_PREFIX = "[kc]"
      PROJECT_FILE_UPDATE_FIRST_LINE = /\A[-*]\s+\[kc\]\s+([^\s:]+):\s+updated\s+\d+\s+project\s+files?:\s*\z/
      PROJECT_FILE_UPDATE_CATEGORY_LINE = /\A\s{2,}[-*]\s+(.+?)\s+\((\d+)\)\s*\z/

      class << self
        # Consolidates repeated maintenance summaries after a prepared release
        # is updated in place. The AST supplies list-item boundaries; the two
        # regular expressions only parse the stable text payload inside those
        # already-classified Markdown items.
        def collapse_project_file_updates(source)
          require "ast/crispr/markdown/markly"
          context = Ast::Crispr::Markdown::Markly.document_context(content: source.to_s, source_label: "CHANGELOG.md")
          updates = context.structural_owners(owner_scope: :list_items)
            .select { |item| item.depth == 1 }
            .filter_map { |item| project_file_update_record(item) }
          duplicate_groups = updates.group_by { |update| update.fetch(:key) }.values.select { |group| group.length > 1 }
          return source.to_s if duplicate_groups.empty?

          lines = source.to_s.lines
          duplicate_groups.flatten.sort_by { |update| update.fetch(:start_line) }.reverse_each do |update|
            group = duplicate_groups.find { |candidate| candidate.include?(update) }
            first = group.min_by { |candidate| candidate.fetch(:start_line) }
            replacement = (update == first) ? project_file_update_entry(group).lines : []
            lines[(update.fetch(:start_line) - 1)...update.fetch(:end_line)] = replacement
          end
          lines.join
        end

        private

        def project_file_update_record(item)
          lines = item.source.to_s.lines
          key_match = PROJECT_FILE_UPDATE_FIRST_LINE.match(lines.shift.to_s.strip)
          return unless key_match

          counts = lines.filter_map do |line|
            match = PROJECT_FILE_UPDATE_CATEGORY_LINE.match(line)
            next unless match

            [match[1].tr(" ", "_").to_sym, match[2].to_i]
          end.to_h
          return if counts.empty?

          {
            key: key_match[1],
            counts: counts,
            start_line: item.location.start_line,
            end_line: item.location.end_line
          }
        end

        def project_file_update_entry(entries)
          counts = entries.each_with_object(Hash.new(0)) do |entry, totals|
            entry.fetch(:counts).each { |category, count| totals[category] += count }
          end
          total = counts.values.sum
          details = counts.sort_by { |category, _count| category.to_s }.map do |category, count|
            "  - #{category.to_s.tr("_", " ")} (#{count})"
          end
          ["- #{KEY_PREFIX} #{entries.first.fetch(:key)}: updated #{total} project file#{"s" unless total == 1}:", *details, ""].join("\n")
        end
      end

      def initialize(section:, key:, entry:, legacy_prefixes: [], root: Kettle::Dev::CIHelpers.project_root)
        @root = root
        @section = section.to_s
        @key = key.to_s.strip
        @entry = entry
        @legacy_prefixes = Array(legacy_prefixes).map { |prefix| prefix.to_s.strip }.reject(&:empty?)
        @changelog_path = ENV.fetch("K_CHANGELOG_PATH", File.join(@root, "CHANGELOG.md"))
      end

      def run
        validate!
        source = read_source!
        matches = find_matches(source)
        if matches.count { |match| match.fetch(:kind) == :keyed } > 1
          raise Error, "expected at most one #{key_label} entry in CHANGELOG.md"
        end
        if matches.any? { |match| match.fetch(:kind) == :keyed } && matches.any? { |match| match.fetch(:kind) == :legacy }
          raise Error, "found both keyed and legacy entries for #{key_label} in CHANGELOG.md"
        end

        body = @entry.respond_to?(:call) ? @entry.call(matches) : @entry
        rendered = render_entry(body)
        changed = matches.empty? || matches.any? { |match| normalize_source(match.fetch(:source)) != normalize_source(rendered) } || matches.length > 1
        write_updated_source(source, rendered, matches) if changed

        matched = if matches.empty?
          "inserted"
        elsif matches.first.fetch(:kind) == :legacy
          "legacy"
        else
          "keyed"
        end

        {
          changed: changed,
          key: @key,
          section: @section,
          entry: rendered,
          matched: matched
        }
      end

      private

      def validate!
        raise Error, "unsupported changelog section #{@section.inspect}" unless SECTIONS.include?(@section)
        raise Error, "changelog key must not be empty" if @key.empty?
        raise Error, "changelog key must not contain whitespace" if @key.match?(/\s/)
        raise Error, "missing CHANGELOG.md in #{Kettle::Dev.display_path(@root)}" unless File.file?(@changelog_path)
      end

      def read_source!
        File.read(@changelog_path)
      end

      def require_markly!
        require "ast/crispr/markdown/markly"
      rescue LoadError => error
        raise Error, "kettle-changelog keyed entry updates require ast-crispr-markdown-markly (#{error.message})"
      end

      def find_matches(source)
        require_markly!
        context = Ast::Crispr::Markdown::Markly.document_context(content: source, source_label: @changelog_path)
        sections = context.structural_owners(owner_scope: :heading_sections)
        unreleased = find_unreleased_heading!(sections)
        target = find_unreleased_section!(sections, unreleased)
        items = context.structural_owners(owner_scope: :list_items).select do |item|
          item.depth == 1 && within?(item, target)
        end

        items.filter_map do |item|
          kind = if keyed_item?(item.source)
            :keyed
          elsif legacy_item?(item.source)
            :legacy
          end
          next unless kind

          {
            kind: kind,
            source: item.source,
            start_line: item.location.start_line,
            end_line: item.location.end_line
          }
        end
      end

      def find_unreleased_heading!(sections)
        matches = sections.select do |owner|
          owner.level == 2 && owner.heading_source.to_s.strip == "## [Unreleased]"
        end
        raise Error, "expected exactly one ## [Unreleased] section in CHANGELOG.md, found #{matches.length}" unless matches.length == 1

        matches.first
      end

      def find_unreleased_section!(sections, unreleased)
        matches = sections.select do |owner|
          owner.heading_text.to_s.strip == @section &&
            owner.level == 3 &&
            owner.location.start_line > unreleased.location.start_line &&
            owner.location.end_line <= unreleased.location.end_line
        end
        raise Error, "expected at least one ### #{@section} section under ## [Unreleased] in CHANGELOG.md, found none" if matches.empty?

        matches.first
      end

      def within?(item, section)
        item.location.start_line > section.location.start_line &&
          item.location.end_line <= section.location.end_line
      end

      def keyed_item?(source)
        first_line(source).match?(/\A[-*]\s+\[kc\]\s+#{Regexp.escape(@key)}(?:\s|:)/)
      end

      def legacy_item?(source)
        return false if @legacy_prefixes.empty?

        text = first_line(source).sub(/\A[-*]\s+/, "").strip
        @legacy_prefixes.any? { |prefix| text.start_with?(prefix) }
      end

      def first_line(source)
        source.to_s.lines.first.to_s.strip
      end

      def key_label
        "#{KEY_PREFIX} #{@key}"
      end

      def render_entry(body)
        text = body.to_s.strip
        raise Error, "changelog entry must not be empty" if text.empty?
        raise Error, "keyed changelog entry body must not include a list marker" if text.lines.first.to_s.match?(/\A[-*]\s+/)

        first, *rest = text.lines.map(&:rstrip)
        (["- #{key_label}: #{first}"] + rest).join("\n") + "\n\n"
      end

      def normalize_source(source)
        source.to_s.strip
      end

      def write_updated_source(source, rendered, matches)
        if matches.empty?
          File.write(@changelog_path, insert_entry(source, rendered))
          return
        end

        lines = source.lines
        matches.sort_by { |match| match.fetch(:start_line) }.reverse_each.with_index do |match, index|
          start_index = match.fetch(:start_line) - 1
          end_index = match.fetch(:end_line)
          replacement = index.zero? ? rendered.lines : []
          lines[start_index...end_index] = replacement
        end
        File.write(@changelog_path, lines.join)
      end

      def insert_entry(source, rendered)
        require_markly!
        context = Ast::Crispr::Markdown::Markly.document_context(content: source, source_label: @changelog_path)
        sections = context.structural_owners(owner_scope: :heading_sections)
        unreleased = find_unreleased_heading!(sections)
        target = find_unreleased_section!(sections, unreleased)
        lines = source.lines
        index = target.location.end_line
        while index > target.location.start_line && lines.fetch(index - 1).strip.empty?
          index -= 1
        end

        previous_line = lines[index - 1].to_s
        next_line = lines[index].to_s
        before = previous_line.strip.empty? ? "" : "\n"
        after = (next_line.empty? || next_line.strip.empty?) ? "" : "\n"
        lines.insert(index, "#{before}#{rendered.rstrip}\n#{after}")
        lines.join
      end
    end
  end
end
