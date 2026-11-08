# frozen_string_literal: true

module Kettle
  module Changelog
    # Extracts a single release without changing the input document.
    module Release
      HEADING = /\A(?:\[)?(v?\d+\.\d+\.\d+[0-9A-Za-z.+-]*)(?:\])?(?:\s+(?:-\s+)?(\d{4}-\d{2}-\d{2}))?(?:\s+\([^\n]*\))?\s*\z/
      DEFINITION = /\A {0,3}\[([^\]]+)\]:\s*\S+/
      FOOTER = /\A(?:community|sponsors?|sponsorship|support(?:ers| us)?|funding|contributing|contributors|acknowledg(?:e)?ments|license)\b/i

      module_function

      # @param content [String] Markdown changelog
      # @param version [String] release version or tag (with or without v)
      # @return [Hash] release metadata and standalone Markdown body
      # @raise [Kettle::Changelog::Error] when extraction is ambiguous or fails
      def extract(content:, version:, **options)
        raise Error, "changelog must be a valid nonempty UTF-8 string" unless content.is_a?(String) && content.valid_encoding? && !content.strip.empty?
        raise Error, "version must be a release version or tag" unless version.is_a?(String) && version.match?(/\Av?\d+\.\d+\.\d+[0-9A-Za-z.+-]*\z/)

        require "ast/crispr/markdown/markly"
        context = Ast::Crispr::Markdown::Markly.document_context(content: content, source_label: "changelog")
        headings = context.structural_owners(owner_scope: :heading_sections).sort_by { |owner| owner.location.start_line }
        matches = headings.select do |heading|
          match = heading.heading_text.to_s.strip.match(HEADING)
          heading.level == 2 && match && match[1].delete_prefix("v") == version.delete_prefix("v")
        end
        raise Error, "expected exactly one release for #{version.inspect}, found #{matches.length}" unless matches.length == 1

        selected = matches.first
        heading_match = selected.heading_text.to_s.strip.match(HEADING)
        start = selected.location.start_line
        boundary = headings.find do |heading|
          heading.location.start_line > start && (heading.level <= 2 || (heading.level == 3 && heading.heading_text.to_s.strip.match?(FOOTER)))
        end
        lines = content.lines
        finish = boundary ? boundary.location.start_line - 1 : lines.length
        body_lines = lines[start...finish].to_a
        # Reference definitions are document scoped; remove them from the body and append only those used.
        definitions = {}
        definition_lines = []
        fence = nil
        lines.each_with_index do |line, index|
          marker = line[/\A {0,3}(`{3,}|~{3,})/, 1]
          if marker
            if fence.nil?
              fence = marker
            elsif marker[0] == fence[0] && marker.length >= fence.length
              fence = nil
            end
            next
          end
          next if fence

          match = line.match(DEFINITION)
          next unless match

          definitions[normalize_label(match[1])] ||= line
          definition_lines << index
        end
        body_lines = body_lines.each_with_index.reject { |_line, index| definition_lines.include?(start + index) }.map(&:first)
        body = body_lines.join.strip
        used = definitions.select do |label, _line|
          body.scan(/\[([^\]]+)\](?:\[([^\]]*)\])?/).any? do |first, second|
            normalize_label(second.nil? || second.empty? ? first : second) == label
          end
        end
        body = ([body] + used.values.map(&:strip)).reject(&:empty?).join("\n\n")
        stats = ReleaseStats.parse("## [#{heading_match[1].delete_prefix("v")}]#{heading_match[2] ? " - #{heading_match[2]}" : ""}\n#{body}")
        tag = body[/^\s*-\s+TAG:\s*\[([^\]]+)\]/, 1]
        heading_tag_ref = selected.heading_source.to_s[/\[tag\]\[([^\]]+)\]/i, 1]
        if !tag && heading_tag_ref
          tag = definitions[normalize_label(heading_tag_ref)].to_s[%r{/releases/tag/([^\s>]+)}, 1]
        end
        {version: heading_match[1].delete_prefix("v"), date: heading_match[2], tag: tag, markdown: body.empty? ? "" : "#{body}\n", coverage: stats[:coverage], branch_coverage: stats[:branch_coverage], documented: stats[:documented]}
      rescue LoadError => e
        raise Error, "release extraction requires the Markdown parser: #{e.message}"
      end

      def normalize_label(label)
        label.to_s.strip.gsub(/\s+/, " ").downcase
      end
      private_class_method :normalize_label
    end
  end
end
