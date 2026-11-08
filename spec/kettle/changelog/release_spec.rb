# frozen_string_literal: true

RSpec.describe Kettle::Changelog::Release do
  let(:content) do
    <<~MD
      # Changelog

      ## [2.0.0] - 2026-01-02
      - TAG: [v2.0.0][tag]

      ### Added

      A paragraph with [a reference][ref].

      - Parent
        - Nested item

        Another paragraph.

      #### Details

      More detail.

      ## [1.0.0] - 2025-01-01
      - Old release.

      ## Community
      Please sponsor us.

      [ref]: https://example.com/reference
      [tag]: https://example.com/tag
      [unrelated]: https://example.com/other
    MD
  end

  it "extracts the requested release and only its referenced definitions" do
    result = described_class.extract(content: content, version: "v2.0.0")
    expect(result).to include(version: "2.0.0", date: "2026-01-02", tag: "v2.0.0", coverage: nil)
    expect(result[:markdown]).to include("- Parent\n  - Nested item\n\n  Another paragraph.", "#### Details", "[ref]: https://example.com/reference", "[tag]: https://example.com/tag")
    expect(result[:markdown]).not_to include("Old release", "sponsor", "[unrelated]:")
  end

  it "returns releases matching major and minor versions in document order" do
    input = <<~MD
      ## [v3.20.0]
      - Twenty.
      ## [3.2.1-rc.1]
      - Prerelease.
      ## [v3.2.0]
      - Two.
      ## [3.1.0]
      - One.
      ## [30.2.0]
      - Thirty.
    MD
    %w[3 v3].each do |version|
      expect(described_class.extract(content: input, version: version).map { |release| release[:version] }).to eq(%w[3.20.0 3.2.1-rc.1 3.2.0 3.1.0])
    end
    %w[3.2 v3.2].each do |version|
      releases = described_class.extract(content: input, version: version)
      expect(releases.map { |release| release[:version] }).to eq(%w[3.2.1-rc.1 3.2.0])
      expect(releases.last[:markdown]).to eq("- Two.\n")
    end
    expect { described_class.extract(content: input, version: "v4") }.to raise_error(Kettle::Changelog::Error)
    expect { described_class.extract(content: "## [3.2.0]\n## [v3.2.0]\n", version: "3") }.to raise_error(Kettle::Changelog::Error)
  end

  it "makes each release self-contained when definitions are shared across releases" do
    input = <<~MD
      # Changelog

      ## [3.2.0]
      - See [the shared guide][shared] and [local].

      [local]: https://example.com/local

      ## [3.1.0]
      - Also see [Shared][] and [the older guide][older].

      [SHARED]: https://example.com/shared
      [older]: https://example.com/older

      ## [2.0.0]
      - Reference [shared].
    MD
    releases = described_class.extract(content: input, version: "3")
    expect(releases.map { |release| release[:version] }).to eq(%w[3.2.0 3.1.0])
    expect(releases[0][:markdown]).to include("[SHARED]: https://example.com/shared", "[local]: https://example.com/local")
    expect(releases[0][:markdown]).not_to include("[older]:", "Also see")
    expect(releases[1][:markdown]).to include("[SHARED]: https://example.com/shared", "[older]: https://example.com/older")
    expect(releases[1][:markdown]).not_to include("[local]:", "the shared guide")
    older = described_class.extract(content: input, version: "2.0.0")
    expect(older[:markdown]).to include("[SHARED]: https://example.com/shared")
    releases.concat([older]).each do |release|
      expect(Markly.render_html(release.fetch(:markdown))).to include('href="https://example.com/shared"')
    end
  end

  it "preserves multi-line shared reference definitions" do
    input = <<~MD
      ## [3.0.0]
      - [Guide][shared]
      ## [2.0.0]
      - Old.
      [shared]:
        https://example.com/guide
        "Guide title"
    MD
    release = described_class.extract(content: input, version: "3.0.0")
    expect(release[:markdown]).to include("[shared]:\n  https://example.com/guide\n  \"Guide title\"")
    expect(Markly.render_html(release[:markdown])).to include('href="https://example.com/guide" title="Guide title"')
    expect(described_class.extract(content: input, version: "2.0.0")[:markdown]).to eq("- Old.\n")
  end

  it "selects the first published release when latest is requested" do
    result = described_class.extract(content: "## [Unreleased]\n- Work\n" + content, latest: true)
    expect(result).to include(version: "2.0.0", date: "2026-01-02")
    expect { described_class.extract(content: content, latest: true, version: "1.0.0") }.to raise_error(Kettle::Changelog::Error)
    expect { described_class.extract(content: "## [Unreleased]\n", latest: true) }.to raise_error(Kettle::Changelog::Error)
  end

  it "excludes a trailing level-three sponsorship footer from the last release" do
    input = "## 1.0.0\n### Fixed\n- Fix.\n### Sponsorship\nDonate today.\n"
    expect(described_class.extract(content: input, version: "1.0.0")[:markdown]).to eq("### Fixed\n- Fix.\n")
  end

  it "reads a legacy date and tag link from the release heading" do
    input = "## [1.0.0] 2025-01-01 ([tag][1.0.0t])\n- Item\n\n[1.0.0t]: https://github.com/example/project/releases/tag/v1.0.0\n"
    expect(described_class.extract(content: input, version: "1.0.0")).to include(date: "2025-01-01", tag: "v1.0.0")
  end

  it "rejects missing, ambiguous and invalid releases" do
    expect { described_class.extract(content: content, version: "3.0.0") }.to raise_error(Kettle::Changelog::Error)
    expect { described_class.extract(content: "## [1.0.0]\n## [v1.0.0]\n", version: "1.0.0") }.to raise_error(Kettle::Changelog::Error)
    expect { described_class.extract(content: "", version: "1.0.0") }.to raise_error(Kettle::Changelog::Error)
    expect { described_class.extract(content: content, version: "latest") }.to raise_error(Kettle::Changelog::Error)
  end
end

RSpec.describe "release command" do
  it "prints JSON on success and fails without a matching version" do
    require "open3"
    command = [RbConfig.ruby, File.expand_path("../../../exe/kettle-changelog", __dir__), "--release", "1.0.0"]
    output, error, status = Open3.capture3(*command, stdin_data: "## [1.0.0]\n- Item\n")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output).fetch("markdown")).to eq("- Item\n")
    output, _error, status = Open3.capture3(*command, stdin_data: "## [2.0.0]\n- Item\n")
    expect(status.success?).to be(false)
    expect(output).to be_empty
    output, error, status = Open3.capture3(RbConfig.ruby, command[1], "--latest", stdin_data: "## [2.0.0]\n- Latest\n## [1.0.0]\n- Old\n")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output).fetch("version")).to eq("2.0.0")
    output, error, status = Open3.capture3(RbConfig.ruby, command[1], "--release", "v3.2", stdin_data: "## [3.2.1]\n- New\n## [v3.2.0]\n- Old\n")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output).map { |release| release.fetch("version") }).to eq(%w[3.2.1 3.2.0])
  end
end
