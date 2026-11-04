# frozen_string_literal: true

RSpec.describe Kettle::Changelog::ReleaseStats do
  def changelog(*sections) = ["# Changelog\n\n## [Unreleased]\n\n### Added\n\n", *sections].join

  let(:full) do
    <<~MD
      ## [2.1.0] - 2026-10-25
      - TAG: [v2.1.0][2.1.0t]
      - COVERAGE: 98.48% -- 649/659 lines in 16 files
      - BRANCH COVERAGE: 93.53% -- 217/232 branches in 16 files
      - 90.83% documented

      ### Changed

      - Something

    MD
  end

  it "reads line, branch and documentation stats from the latest release" do
    expect(described_class.parse(changelog(full))).to eq(
      version: "2.1.0", date: "2026-10-25",
      coverage: {percent: 98.48, covered: 649, total: 659, files: 16},
      branch_coverage: {percent: 93.53, covered: 217, total: 232, files: 16},
      documented: 90.83
    )
  end

  it "ignores stats lines under [Unreleased]" do
    text = "## [Unreleased]\n- COVERAGE: 1.00% -- 1/100 lines in 1 files\n\n" + full
    expect(described_class.parse(text)[:coverage][:percent]).to eq(98.48)
  end

  it "does not fall back to an older release when the latest has no stats" do
    older = "## [2.0.0] - 2026-01-01\n- COVERAGE: 50.00% -- 5/10 lines in 1 files\n\n"
    latest = "## [2.1.0] - 2026-10-25\n- TAG: [v2.1.0][2.1.0t]\n\n### Added\n\n"
    stats = described_class.parse(changelog(latest, older))
    expect(stats).to include(version: "2.1.0", coverage: nil, branch_coverage: nil, documented: nil)
  end

  it "ignores stats-looking lines inside subsections" do
    latest = "## [2.1.0] - 2026-10-25\n- TAG: x\n\n### Added\n\n- COVERAGE: 5.00% -- 5/100 lines in 1 files\n\n"
    expect(described_class.parse(changelog(latest))[:coverage]).to be_nil
  end

  it "requires the exact generated line shape" do
    latest = "## [2.1.0] - 2026-10-25\n- COVERAGE: 98.48%\n- Coverage: 98.48% -- 649/659 lines in 16 files\n- BRANCH COVERAGE: 9% -- 1/2 lines in 1 files\n\n"
    expect(described_class.parse(changelog(latest))).to include(coverage: nil, branch_coverage: nil)
  end

  it "reads coverage without branch or documentation lines" do
    latest = "## [1.0.0] - 2026-02-02\n- COVERAGE: 100.00% -- 10/10 lines in 1 files\n\n"
    expect(described_class.parse(changelog(latest))).to include(coverage: {percent: 100.0, covered: 10, total: 10, files: 1}, branch_coverage: nil, documented: nil)
  end

  it "returns nil when there is no released section" do
    expect(described_class.parse(changelog)).to be_nil
    expect(described_class.parse("")).to be_nil
  end
end
