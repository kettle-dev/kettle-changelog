# frozen_string_literal: true

RSpec.describe Kettle::Changelog do
  it "has a version number" do
    expect(Kettle::Changelog::VERSION).not_to be_nil
  end

  it "exposes the changelog CLI and entry helpers" do
    expect(described_class::CLI).to be < Object
    expect(described_class::EntryAdder).to be < Object
    expect(described_class::KeyedEntryUpserter).to be < Object
  end
end
