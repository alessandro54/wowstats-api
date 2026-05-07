module Blizzard
  module Data
    module Talents
      # Fetches icon_url and description for talents that are missing them.
      # Tries Blizzard's talent endpoint, falls back to pvp-talent, then WoWHead.
      #
      # Called asynchronously by SyncTalentMediaJob after SyncTreeService completes.
      class SyncTalentMediaService < BaseService
        def initialize(region: "us", locale: "en_US")
          @client = Blizzard::Client.new(region: region, locale: locale)
        end

        def call
          incomplete_scope.find_each { |talent| sync_one(talent) }
          success(nil)
        rescue Blizzard::Client::Error, ActiveRecord::ActiveRecordError => e
          failure(e)
        end

        def incomplete_scope
          Talent.where(
            "icon_url IS NULL OR id NOT IN (" \
              "SELECT translatable_id FROM translations " \
              "WHERE translatable_type = 'Talent' AND key = 'description' AND locale = ?" \
            ")",
            client.locale
          )
        end

        def sync_one(talent)
          talent_data = fetch_talent_data(talent.blizzard_id)
          spell_id    = talent.spell_id || talent_data[:spell_id]

          save_name(talent, talent_data[:name])
          save_description(talent, talent_data[:description])
          sync_icon(talent, spell_id) if spell_id && talent.icon_url.nil?
        rescue Blizzard::Client::NotFoundError
          sync_pvp_talent(talent)
        rescue Blizzard::Client::Error => e
          log_warn("Media fetch failed for talent #{talent.blizzard_id}: #{e.message}")
        end

        private

          attr_reader :client

          # PvP talents live at /data/wow/pvp-talent/{id} instead of /data/wow/talent/{id}.
          # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          def sync_pvp_talent(talent)
            talent_data = fetch_pvp_talent_data(talent.blizzard_id)
            spell_id    = talent.spell_id || talent_data[:spell_id]

            save_name(talent, talent_data[:name])
            save_description(talent, talent_data[:description])
            sync_icon(talent, spell_id) if spell_id && talent.icon_url.nil?
          rescue Blizzard::Client::NotFoundError
            sync_icon(talent, talent.spell_id) if talent.spell_id && talent.icon_url.nil?
            sync_icon_from_wowhead(talent) if talent.reload.icon_url.nil? && talent.spell_id
          rescue Blizzard::Client::Error => e
            log_warn("PvP media fetch failed for talent #{talent.blizzard_id}: #{e.message}")
          end
          # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

          def sync_icon(talent, spell_id)
            url = fetch_spell_icon_url(spell_id)
            # rubocop:disable Rails/SkipsModelValidations
            Talent.where(id: talent.id).update_all(icon_url: url, spell_id: spell_id) if url
            # rubocop:enable Rails/SkipsModelValidations
          rescue Blizzard::Client::Error => e
            log_warn("Icon fetch failed for spell #{spell_id}: #{e.message}")
          end

          def fetch_talent_data(blizzard_id)
            data  = client.get("/data/wow/talent/#{blizzard_id}", namespace: client.static_namespace)
            ranks = Array(data["rank_descriptions"])
            desc  = ranks.max_by { |r| r["rank"].to_i }&.dig("description")

            { spell_id: data.dig("spell", "id"), description: desc, name: data["name"] }
          end

          def fetch_pvp_talent_data(blizzard_id)
            data = client.get("/data/wow/pvp-talent/#{blizzard_id}", namespace: client.static_namespace)
            { spell_id: data.dig("spell", "id"), description: data["description"], name: data["name"] }
          end

          def fetch_spell_icon_url(spell_id)
            data = client.get(
              "/data/wow/media/spell/#{spell_id}",
              namespace: client.static_namespace
            )
            Array(data["assets"]).find { |a| a["key"] == "icon" }&.dig("value")
          end

          # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          def sync_icon_from_wowhead(talent)
            data = fetch_wowhead_tooltip(talent.spell_id)
            return unless data

            if data[:icon_url] && talent.icon_url.nil?
              # rubocop:disable Rails/SkipsModelValidations
              Talent.where(id: talent.id).update_all(icon_url: data[:icon_url])
              # rubocop:enable Rails/SkipsModelValidations
              log_info("WoWHead fallback icon for talent #{talent.blizzard_id}: #{data[:icon_url]}")
            end

            save_description(talent, data[:description]) if data[:description].present?
          rescue => e
            log_warn("WoWHead fallback failed for spell #{talent.spell_id}: #{e.message}")
          end
          # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

          def fetch_wowhead_tooltip(spell_id)
            uri  = URI("https://nether.wowhead.com/tooltip/spell/#{spell_id}")
            resp = Net::HTTP.get_response(uri)
            return nil unless resp.is_a?(Net::HTTPSuccess)

            body = JSON.parse(resp.body)
            icon = body["icon"]
            desc = body["tooltip"]
              &.gsub(/<br\s*\/?>|<\/(?:div|p|td|tr|li)>/i, "\n")
              &.gsub(/<[^>]+>/, "")
              &.gsub(/\n{3,}/, "\n\n")
              &.strip&.presence

            {
              icon_url:    icon.present? ? "https://render.worldofwarcraft.com/us/icons/56/#{icon}.jpg" : nil,
              description: desc
            }
          end

          def save_name(talent, name)
            return unless name.present?

            talent.set_translation("name", client.locale, name, meta: { source: "blizzard" })
          end

          def save_description(talent, description)
            return unless description.present?

            talent.set_translation("description", client.locale, description, meta: { source: "blizzard" })
          end
      end
    end
  end
end
