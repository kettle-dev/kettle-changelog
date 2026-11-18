# frozen_string_literal: true

module Kettle
  module Changelog
    # Guarantees that `## [Unreleased]` has the requested `### Section`
    # subsection, creating it in Keep a Changelog order when missing. A bare
    # scaffold (e.g. `bundle gem`) ships an empty `## [Unreleased]`, which
    # would otherwise make the first entry add fail on a never-templated gem.
    module UnreleasedSection
      module_function

      def ensure(source, section, source_label: "CHANGELOG.md")
        require "ast/crispr/markdown/markly"
        context = Ast::Crispr::Markdown::Markly.document_context(content: source, source_label: source_label)
        owners = context.structural_owners(owner_scope: :heading_sections)
        unreleased = owners.select { |owner| owner.level == 2 && owner.heading_source.to_s.strip == "## [Unreleased]" }
        return source unless unreleased.length == 1

        unreleased = unreleased.first
        children = owners.select do |owner|
          owner.level == 3 &&
            owner.location.start_line > unreleased.location.start_line &&
            owner.location.end_line <= unreleased.location.end_line
        end
        return source if children.any? { |owner| owner.heading_text.to_s.strip == section }

        lines = source.lines
        order = EntryAdder::SECTIONS
        later = children
          .select { |owner| (order.index(owner.heading_text.to_s.strip) || -1) > order.index(section) }
          .min_by { |owner| owner.location.start_line }
        index = if later
          later.location.start_line - 1
        else
          i = unreleased.location.end_line
          i -= 1 while i > unreleased.location.start_line && lines.fetch(i - 1).strip.empty?
          i
        end
        before = lines[index - 1].to_s.strip.empty? ? "" : "\n"
        after = lines[index].to_s.strip.empty? ? "" : "\n"
        lines.insert(index, "#{before}### #{section}\n#{after}")
        lines.join
      end
    end
  end
end
