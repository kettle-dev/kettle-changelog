# frozen_string_literal: true

module Kettle
  module Changelog
    class TransferMerger
      STANDARD_HEADINGS = %w[Added Changed Deprecated Removed Fixed Security].freeze

      def self.apply(content:, entries:, excluded_keys: [])
        new(content: content, entries: entries, excluded_keys: excluded_keys).run
      end

      def initialize(content:, entries:, excluded_keys: [])
        @content = content.to_s
        @entries = Array(entries).filter_map do |entry|
          next unless entry.is_a?(Hash)

          key = entry_value(entry, :key).to_s
          lines = Array(entry_value(entry, :lines))
          next if key.empty? || lines.empty?

          {
            key: key,
            section: entry_value(entry, :section),
            lines: lines
          }
        end
        @excluded_keys = Array(excluded_keys).map(&:to_s).reject(&:empty?).to_set
      end

      def run
        normalized = remove_excluded_entries(@content)
        existing_keys = transfer_occurrences(normalized).map { |occurrence| occurrence.fetch(:key) }.to_set
        missing = @entries.reject { |entry| existing_keys.include?(entry.fetch(:key).to_s) }
        return ensure_trailing_newline(normalized) if missing.empty?

        lines = source_lines(normalized)
        unreleased = unreleased_line_index(lines)
        return ensure_trailing_newline(normalized) unless unreleased

        destination_end = unreleased_end_index(lines, unreleased)
        destination_body = lines[(unreleased + 1)...destination_end] || []
        items = changelog_items(destination_body)
        missing.group_by { |entry| entry.fetch(:section, "### Changed") }.each do |section, section_entries|
          section = STANDARD_HEADINGS.include?(section.to_s.delete_prefix("### ")) ? "### #{section.to_s.delete_prefix("### ").strip}" : "### Changed"
          items[section] ||= []
          items[section].pop while items[section].any? && items[section].last.to_s.strip.empty?
          items[section] << "" if items[section].any?
          section_entries.each do |entry|
            items[section].concat(Array(entry.fetch(:lines)).map(&:rstrip))
          end
        end

        merged_lines = lines[0...unreleased] +
          build_unreleased_section(lines.fetch(unreleased), items) +
          lines[destination_end..].to_a
        ensure_trailing_newline(merged_lines.join("\n").gsub(/\n{3,}/, "\n\n"))
      end

      private

      def remove_excluded_entries(content)
        return content if @excluded_keys.empty?

        lines = source_lines(content)
        removals = transfer_occurrences(content).filter_map do |occurrence|
          next unless @excluded_keys.include?(occurrence.fetch(:key).to_s)

          (occurrence.fetch(:start_line)..occurrence.fetch(:end_line))
        end
        return content if removals.empty?

        lines.each_with_index.reject do |_line, index|
          removals.any? { |range| range.cover?(index + 1) }
        end.map(&:first).join("\n").then { |text| ensure_trailing_newline(text.gsub(/\n{3,}/, "\n\n")) }
      end

      def transfer_occurrences(content)
        context = markdown_context(content)
        release_sections = context.structural_owners(owner_scope: :heading_sections)
          .select { |owner| owner.level == 2 }
          .sort_by { |owner| owner.location.start_line }
        list_items = context.structural_owners(owner_scope: :list_items)
        list_items.filter_map do |item|
          next unless item.depth == 1

          key = transfer_key(item.source)
          next unless key

          release = release_section_for(release_sections, item)
          next unless release

          {
            key: key,
            release_heading: "## #{release.heading_text}",
            start_line: item.location.start_line,
            end_line: item.location.end_line
          }
        end
      end

      def transfer_key(source)
        source.to_s.lines.first.to_s.strip[/\A[-*] +((?:kettle-jem-template)-\d{8}-\d{3})\b/, 1]
      end

      def release_section_for(sections, item)
        sections.each_with_index.find do |section, index|
          next_section = sections[index + 1]
          section_end_line = next_section ? next_section.location.start_line - 1 : section.location.end_line
          item.location.start_line > section.location.start_line && item.location.end_line <= section_end_line
        end&.first
      end

      def changelog_items(body_lines)
        items = {}
        heading = nil
        index = 0
        while index < body_lines.length
          line = body_lines.fetch(index)
          if line.start_with?("### ")
            heading = line.strip
            items[heading] ||= []
            index += 1
            next
          end

          if bullet_line?(line)
            collected, index = collect_list_item(body_lines, index)
            items[heading] ||= []
            items[heading].concat(collected)
            next
          end

          index += 1
        end
        items
      end

      def build_unreleased_section(heading, items)
        lines = [heading]
        STANDARD_HEADINGS.each do |standard_heading|
          heading_line = "### #{standard_heading}"
          lines << ""
          lines << heading_line
          lines << ""
          section_items = items[heading_line].to_a.dup
          section_items.pop while section_items.any? && section_items.last.to_s.strip.empty?
          lines.concat(section_items) if section_items.any?
        end
        lines << ""
      end

      def source_lines(content)
        content.to_s.split("\n")
      end

      def unreleased_line_index(lines)
        lines.index { |line| line.to_s.strip == "## [Unreleased]" }
      end

      def unreleased_end_index(lines, unreleased_index)
        index = unreleased_index + 1
        while index < lines.length
          line = lines.fetch(index)
          return index if link_reference_line?(line)
          return index if line.start_with?("# ") || (line.start_with?("## ") && line.to_s.strip != "## [Unreleased]")

          index += 1
        end
        lines.length
      end

      def link_reference_line?(line)
        line.to_s.lstrip.start_with?("[") && line.to_s.include?("]:")
      end

      def entry_value(entry, key)
        entry[key] || entry[key.to_s]
      end

      def bullet_line?(line)
        line.to_s.lstrip.start_with?("- ", "* ")
      end

      def collect_list_item(lines, start_index)
        line = lines.fetch(start_index).to_s
        base_indent = line.length - line.lstrip.length
        item_lines = [line.rstrip]
        index = start_index + 1
        in_fence = false
        while index < lines.length
          current = lines.fetch(index).to_s
          current_indent = current.length - current.lstrip.length
          break if !in_fence && heading_line?(current)
          break if !in_fence && bullet_line?(current) && current_indent <= base_indent

          if current.lstrip.start_with?("```")
            in_fence = !in_fence
            item_lines << current.rstrip
            index += 1
            next
          end

          break unless in_fence || current.strip.empty? || current_indent > base_indent

          item_lines << current.rstrip
          index += 1
        end
        [item_lines, index]
      end

      def heading_line?(line)
        line.to_s.lstrip.start_with?("#")
      end

      def markdown_context(content)
        require "ast/crispr/markdown/markly"
        Ast::Crispr::Markdown::Markly.document_context(content: content, source_label: "CHANGELOG.md")
      rescue LoadError => error
        raise Error, "kettle-changelog transfer merging requires ast-crispr-markdown-markly (#{error.message})"
      end

      def ensure_trailing_newline(content)
        "#{content.to_s.rstrip}\n"
      end
    end
  end
end
