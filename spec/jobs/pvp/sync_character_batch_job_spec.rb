require "rails_helper"

RSpec.describe Pvp::SyncCharacterBatchJob, type: :job do
  include ActiveJob::TestHelper

  subject(:perform_job) do
    described_class.perform_now(
      character_ids: character_ids,
      locale:        locale
    )
  end

  let!(:character1) { create(:character, is_private: false) }
  let!(:character2) { create(:character, is_private: false) }
  let(:character_ids) { [ character1.id, character2.id ] }
  let(:locale) { "en_US" }

  before do
    clear_enqueued_jobs

    # Mock the SyncCharacterService to avoid actual API calls
    allow(Pvp::Characters::SyncCharacterService).to receive(:call)
      .and_return(ServiceResult.success(nil, context: { status: :no_entries }))
  end

  describe "#perform" do
    it "processes each character directly using SyncCharacterService" do
      perform_job

      expect(Pvp::Characters::SyncCharacterService)
        .to have_received(:call)
        .with(hash_including(character: character1, locale: locale))

      expect(Pvp::Characters::SyncCharacterService)
        .to have_received(:call)
        .with(hash_including(character: character2, locale: locale))
    end

    it "preloads all characters in a single query" do
      expect(Character).to receive(:where)
        .with(id: character_ids)
        .at_least(:once)
        .and_call_original

      perform_job
    end

    context "with a single character" do
      let(:character_ids) { [ character1.id ] }

      it "processes the character" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call)
          .with(hash_including(character: character1, locale: locale))
          .once
      end
    end

    context "when character_ids is empty" do
      let(:character_ids) { [] }

      it "returns early without processing" do
        expect(Pvp::Characters::SyncCharacterService).not_to receive(:call)

        perform_job
      end
    end

    context "when character_ids contains nil values" do
      let(:character_ids) { [ character1.id, nil, character2.id ] }

      it "compacts the array and processes valid characters" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call).twice
      end
    end

    context "when a character is within unavailability cooldown" do
      before { character1.update!(unavailable_until: 1.week.from_now) }

      it "skips the unavailable character without calling the service" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .not_to have_received(:call)
          .with(hash_including(character: character1))

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call)
          .with(hash_including(character: character2, locale: locale))
      end

      it "retains existing equipment and spec data on the entry for the cooldown character" do
        leaderboard = create(:pvp_leaderboard)

        entry = create(:pvp_leaderboard_entry,
          character:                   character1,
          pvp_leaderboard:             leaderboard,
          item_level:                  620,
          spec_id:                     265,
          hero_talent_tree_id:         3,
          hero_talent_tree_name:       "voidweaver",
          equipment_processed_at:      2.days.ago,
          specialization_processed_at: 2.days.ago)

        perform_job

        # With upsert model, the single entry retains its processed data
        # unchanged for skipped (cooldown) characters.
        entry.reload
        expect(entry.item_level).to eq(620)
        expect(entry.spec_id).to eq(265)
        expect(entry.hero_talent_tree_name).to eq("voidweaver")
      end
    end

    context "when a character's unavailability cooldown has expired" do
      before { character1.update!(unavailable_until: 1.day.ago) }

      it "processes the character again" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call)
          .with(hash_including(character: character1, locale: locale))
      end
    end

    context "when a character was recently synced (within TTL)" do
      before { character1.update!(last_equipment_snapshot_at: 1.hour.ago) }

      it "still sends the character to the service (TTL is the service's concern)" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call)
          .with(hash_including(character: character1, locale: locale))
      end
    end

    context "when a character's last sync is beyond TTL" do
      before { character1.update!(last_equipment_snapshot_at: 25.hours.ago) }

      it "processes the character" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call)
          .with(hash_including(character: character1, locale: locale))
      end
    end

    context "when a character has never been synced (nil last_equipment_snapshot_at)" do
      before { character1.update!(last_equipment_snapshot_at: nil) }

      it "processes the character" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call)
          .with(hash_including(character: character1, locale: locale))
      end
    end

    context "with private characters" do
      let!(:private_character) { create(:character, is_private: true) }
      let(:character_ids) { [ character1.id, private_character.id ] }

      it "filters out private characters and does not process them" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call)
          .with(hash_including(character: character1, locale: locale))

        expect(Pvp::Characters::SyncCharacterService)
          .not_to have_received(:call)
          .with(hash_including(character: private_character))
      end
    end

    context "when SyncCharacterService fails for one character" do
      before do
        call_count = 0
        allow(Pvp::Characters::SyncCharacterService).to receive(:call) do
          call_count += 1
          if call_count == 1
            ServiceResult.failure("API error")
          else
            ServiceResult.success(nil, context: { status: :synced })
          end
        end
      end

      it "continues processing other characters" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call).twice
      end

      it "logs the batch summary" do
        allow(Rails.logger).to receive(:info).and_call_original

        perform_job

        expect(Rails.logger).to have_received(:info).with(/\[SyncCharacterBatchJob\] 1\/2 ok/)
      end
    end

    context "when a Blizzard API error occurs for one character" do
      before do
        call_count = 0
        allow(Pvp::Characters::SyncCharacterService).to receive(:call) do
          call_count += 1
          raise Blizzard::Client::Error, "Server error" if call_count == 1


          ServiceResult.success(nil, context: { status: :no_entries })
        end
      end

      it "logs the error and continues with other characters" do
        expect(Rails.logger).to receive(:warn).with(/API error for character/).at_least(:once)

        perform_job

        expect(Pvp::Characters::SyncCharacterService)
          .to have_received(:call).twice
      end
    end

    context "when all characters fail with Blizzard API errors" do
      before do
        allow(Pvp::Characters::SyncCharacterService).to receive(:call)
          .and_raise(Blizzard::Client::Error.new("Rate limited"))
      end

      it "raises TotalBatchFailureError" do
        expect { perform_job }
          .to raise_error(BatchOutcome::TotalBatchFailureError, /All 2 items failed/)
      end
    end

    context "when all characters fail with rate limiting" do
      before do
        allow(Pvp::Characters::SyncCharacterService).to receive(:call)
          .and_raise(Blizzard::Client::RateLimitedError.new("429"))
      end

      it "raises TotalBatchFailureError with rate_limited status" do
        expect { perform_job }
          .to raise_error(BatchOutcome::TotalBatchFailureError, /rate_limited: 2/)
      end
    end

    context "when sync_cycle_id points to an aborted cycle" do
      let(:cycle) { create(:pvp_sync_cycle, status: :aborted) }

      subject(:perform_job) do
        described_class.perform_now(
          character_ids: character_ids,
          locale:        locale,
          sync_cycle_id: cycle.id
        )
      end

      it "skips processing without calling SyncCharacterService" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService).not_to have_received(:call)
      end
    end

    context "when sync_cycle_id points to an active cycle" do
      let(:cycle) { create(:pvp_sync_cycle, status: :syncing_characters) }

      subject(:perform_job) do
        described_class.perform_now(
          character_ids: character_ids,
          locale:        locale,
          sync_cycle_id: cycle.id
        )
      end

      it "processes characters normally" do
        perform_job

        expect(Pvp::Characters::SyncCharacterService).to have_received(:call).twice
      end
    end
  end
end
