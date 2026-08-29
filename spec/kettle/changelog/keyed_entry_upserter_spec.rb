# frozen_string_literal: true

require "open3"

RSpec.describe Kettle::Changelog::KeyedEntryUpserter do
  around do |example|
    Dir.mktmpdir("kettle-changelog-keyed-entry-spec") do |root|
      @root = root
      example.run
    end
  end

  it "inserts one keyed entry with nested details" do
    write_changelog(<<~MARKDOWN)
      # Changelog

      ## [Unreleased]

      ### Added

      ### Changed

      ### Deprecated

      ### Removed

      ### Fixed

      ### Security
    MARKDOWN

    result = described_class.new(
      root: @root,
      section: "Changed",
      key: "kettle-jem-deps-floor",
      entry: "Update dependency floors:\n  - kettle-family (>= 1.2.50 -> >= 1.2.51)"
    ).run

    expect(result).to include(changed: true, matched: "inserted", key: "kettle-jem-deps-floor")
    expect(read_changelog).to include(<<~MARKDOWN)
      - [kc] kettle-jem-deps-floor: Update dependency floors:
        - kettle-family (>= 1.2.50 -> >= 1.2.51)

      ### Deprecated
    MARKDOWN
  end

  it "replaces a keyed entry and reports an identical rerun as unchanged" do
    write_changelog(<<~MARKDOWN)
      # Changelog

      ## [Unreleased]

      ### Changed

      - [kc] kettle-jem-workflow-pins: Update pinned actions:
        - actions/checkout v1.0.0 (#{"a" * 40}) -> v1.0.1 (#{"b" * 40})

      ### Fixed
    MARKDOWN

    upserter = described_class.new(
      root: @root,
      section: "Changed",
      key: "kettle-jem-workflow-pins",
      entry: "Update pinned actions:\n  - actions/checkout v1.0.0 (#{"a" * 40}) -> v1.0.2 (#{"c" * 40})"
    )

    expect(upserter.run).to include(changed: true, matched: "keyed")
    expect(upserter.run).to include(changed: false, matched: "keyed")
    expect(read_changelog.scan("[kc] kettle-jem-workflow-pins").length).to eq(1)
    expect(read_changelog).to include("v1.0.0 (#{"a" * 40}) -> v1.0.2 (#{"c" * 40})")
  end

  it "collapses matching legacy entries while preserving ordinary entries" do
    write_changelog(<<~MARKDOWN)
      # Changelog

      ## [Unreleased]

      ### Changed

      - Update kettle-jem template dependency floors: kettle-family (>= 1.2.50).

      - kettle-jem-deps-floor: Fix parsing of tokenized Gemfiles.

      - Update kettle-jem template dependency floors: kettle-family (>= 1.2.51).

      ### Fixed
    MARKDOWN

    result = described_class.new(
      root: @root,
      section: "Changed",
      key: "kettle-jem-deps-floor",
      legacy_prefixes: ["Update kettle-jem template dependency floors:"],
      entry: "Update kettle-jem template dependency floors:\n  - kettle-family (>= 1.2.50 -> >= 1.2.52)"
    ).run

    expect(result).to include(changed: true, matched: "legacy")
    updated = read_changelog
    expect(updated.scan("[kc] kettle-jem-deps-floor").length).to eq(1)
    expect(updated.scan("Update kettle-jem template dependency floors:").length).to eq(1)
    expect(updated).to include("- kettle-jem-deps-floor: Fix parsing of tokenized Gemfiles.")
  end

  it "does not modify an ordinary entry for the same tool" do
    write_changelog(<<~MARKDOWN)
      # Changelog

      ## [Unreleased]

      ### Changed

      - kettle-jem-deps-floor: Fix parsing of tokenized Gemfiles.

      ### Fixed
    MARKDOWN

    result = described_class.new(
      root: @root,
      section: "Changed",
      key: "kettle-jem-deps-floor",
      legacy_prefixes: ["Update kettle-jem template dependency floors:"],
      entry: "Update kettle-jem template dependency floors:\n  - kettle-family (>= 1.2.50 -> >= 1.2.51)"
    ).run

    expect(result.fetch(:matched)).to eq("inserted")
    expect(read_changelog).to include("- kettle-jem-deps-floor: Fix parsing of tokenized Gemfiles.")
    expect(read_changelog.scan("[kc] kettle-jem-deps-floor").length).to eq(1)
  end

  it "rejects duplicate keyed entries" do
    write_changelog(<<~MARKDOWN)
      # Changelog

      ## [Unreleased]

      ### Changed

      - [kc] kettle-jem-deps-floor: First.

      - [kc] kettle-jem-deps-floor: Second.
    MARKDOWN

    expect {
      described_class.new(
        root: @root,
        section: "Changed",
        key: "kettle-jem-deps-floor",
        entry: "Updated."
      ).run
    }.to raise_error(Kettle::Changelog::Error, /expected at most one \[kc\] kettle-jem-deps-floor entry/)
  end

  it "collapses repeated keyed project-file updates while preserving distinct keys" do
    source = <<~MARKDOWN
      ### Changed

      - [kc] kettle-jem/prepare: updated 30 project files:
        - configuration (1)
        - dependencies (26)
        - other (3)

      - [kc] kettle-jem/template: updated 2 project files:
        - dependencies (1)
        - other (1)

      - [kc] kettle-jem/prepare: updated 10 project files:
        - dependencies (9)
        - other (1)

      - [kc] kettle-jem/template: updated 4 project files:
        - code and tests (1)
        - dependencies (1)
        - other (1)
        - workflows (1)
    MARKDOWN

    updated = described_class.collapse_project_file_updates(source)

    expect(updated.scan("[kc] kettle-jem/prepare").length).to eq(1)
    expect(updated.scan("[kc] kettle-jem/template").length).to eq(1)
    expect(updated).to include("updated 40 project files:", "- dependencies (35)", "updated 6 project files:")
  end

  it "exposes keyed upserts through the JSON CLI interface" do
    write_changelog(<<~MARKDOWN)
      # Changelog

      ## [Unreleased]

      ### Changed

      ### Fixed
    MARKDOWN

    stdout, stderr, status = Open3.capture3(
      {"K_CHANGELOG_PATH" => File.join(@root, "CHANGELOG.md")},
      Gem.ruby,
      File.expand_path("../../../exe/kettle-changelog", __dir__),
      "--upsert-unreleased-entry",
      "--section",
      "Changed",
      "--key",
      "kettle-jem-deps-floor",
      "--entry",
      "Update dependency floors:\n  - kettle-family (>= 1.2.50 -> >= 1.2.51)",
      "--json"
    )

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to include("changed" => true, "key" => "kettle-jem-deps-floor")
  end

  def write_changelog(content)
    File.write(File.join(@root, "CHANGELOG.md"), content)
  end

  def read_changelog
    File.read(File.join(@root, "CHANGELOG.md"))
  end
end
