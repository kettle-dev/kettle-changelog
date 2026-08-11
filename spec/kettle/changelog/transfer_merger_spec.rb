# frozen_string_literal: true

require "kettle/changelog"

RSpec.describe Kettle::Changelog::TransferMerger do
  let(:content) do
    <<~MARKDOWN
      # Changelog

      ## [Unreleased]

      ### Added

      ### Changed

      - Existing change.

      ### Fixed

      - kettle-jem-template-20260801-001 - Existing transfer.

      ## [1.0.0] - 2026-01-01

      - Released.
    MARKDOWN
  end

  let(:entry) do
    {
      key: "kettle-jem-template-20260802-001",
      section: "### Changed",
      lines: ["- kettle-jem-template-20260802-001 - New transfer."]
    }
  end

  it "merges missing transfer entries into the matching Unreleased section" do
    result = described_class.apply(content: content, entries: [entry])

    expect(result).to include("- Existing change.\n\n- kettle-jem-template-20260802-001 - New transfer.")
    expect(result).to include("### Fixed\n\n- kettle-jem-template-20260801-001 - Existing transfer.")
  end

  it "removes excluded transfer entries structurally" do
    result = described_class.apply(
      content: content,
      entries: [entry],
      excluded_keys: ["kettle-jem-template-20260801-001"]
    )

    expect(result).not_to include("kettle-jem-template-20260801-001")
    expect(result).to include("kettle-jem-template-20260802-001 - New transfer.")
  end

  it "is idempotent for an already-applied transfer entry" do
    once = described_class.apply(content: content, entries: [entry])

    expect(described_class.apply(content: once, entries: [entry])).to eq(once)
  end

  it "accepts JSON-shaped transfer entries" do
    result = described_class.apply(
      content: content,
      entries: [{
        "key" => "kettle-jem-template-20260802-001",
        "section" => "### Changed",
        "lines" => ["- kettle-jem-template-20260802-001 - New transfer."]
      }]
    )

    expect(result.scan("kettle-jem-template-20260802-001").size).to eq(1)
  end
end
