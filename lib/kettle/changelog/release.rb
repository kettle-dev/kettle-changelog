# frozen_string_literal: true

module Kettle
  module Changelog
    # Extracts releases without changing the input document.
    module Release
      HEADING = /\A(?:\[)?(v?\d+\.\d+\.\d+[0-9A-Za-z.+-]*)(?:\])?(?:\s+(?:-\s+)?(\d{4}-\d{2}-\d{2}))?(?:\s+\([^\n]*\))?\s*\z/
      DEFINITION = /\A {0,3}\[([^\]]+)\]:\s*\S+/
      FOOTER = /\A(?:community|sponsors?|sponsorship|support(?:ers| us)?|funding|contributing|contributors|acknowledg(?:e)?ments|license)\b/i

      module_function

      # @param content [String] Markdown changelog
      # @param version [String] release version or tag (with or without v)
      # @return [Hash, Array<Hash>] a release, or matching releases for a partial version
      # @raise [Kettle::Changelog::Error] when extraction is ambiguous or fails
      def extract(content:, version: nil, latest: false, **options)
        raise Error, "changelog must be a valid nonempty UTF-8 string" unless content.is_a?(String) && content.valid_encoding? && !content.strip.empty?
        raise Error, "specify a version or latest" unless latest != !version.nil?
        raise Error, "version must be a release version or tag" unless latest || (version.is_a?(String) && version.match?(/\Av?(?:\d+|\d+\.\d+|\d+\.\d+\.\d+[0-9A-Za-z.+-]*)\z/))

        require "ast/crispr/markdown/markly"
        context = Ast::Crispr::Markdown::Markly.document_context(content: content, source_label: "changelog")
        headings = context.structural_owners(owner_scope: :heading_sections).sort_by { |owner| owner.location.start_line }
        partial = !latest && version.match?(/\Av?\d+(?:\.\d+)?\z/)
        requested = version&.delete_prefix("v")
        matches = headings.select do |heading|
          match = heading.heading_text.to_s.strip.match(HEADING)
          release_version = match && match[1].delete_prefix("v")
          heading.level == 2 && match && (latest || (partial ? release_version.start_with?("#{requested}.") : release_version == requested))
        end
        matches = matches.first(1) if latest
        raise Error, "no release found for #{latest ? "latest" : version.inspect}" if matches.empty?
        versions = matches.map { |heading| heading.heading_text.to_s.strip.match(HEADING)[1].delete_prefix("v") }
        raise Error, "ambiguous release for #{version.inspect}" if versions.uniq.length != versions.length || (!partial && matches.length != 1)

        releases = matches.map { |selected| extract_heading(content, headings, selected) }
        partial ? releases : releases.first
      rescue LoadError => e
        raise Error, "release extraction requires the Markdown parser: #{e.message}"
      end

      def extract_heading(content, headings, selected)
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
      end
      private_class_method :extract_heading

      def normalize_label(label)
        label.to_s.strip.gsub(/\s+/, " ").downcase
      end
      private_class_method :normalize_label
    end
  end
end
