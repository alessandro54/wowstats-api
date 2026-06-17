class EnsureMetaTranslationsJob < ApplicationJob
  queue_as :default

  CONCURRENCY = 10

  def perform(force: false)
    @force  = force
    season  = PvpSeason.current
    return unless season

    ensure_item_translations(season)
    ensure_enchantment_translations(season)
    ensure_talent_translations(season)
  end

  private

    # rubocop:disable Metrics/AbcSize
    def ensure_item_translations(season)
      ids = (
        PvpMetaItemPopularity.where(pvp_season: season).distinct.pluck(:item_id) +
        PvpMetaGemPopularity.where(pvp_season: season).distinct.pluck(:item_id)
      ).uniq

      incomplete = ids_missing_translations("Item", ids)
      return if incomplete.empty?

      items         = Item.where(id: incomplete).to_a
      missing_map   = build_missing_map("Item", incomplete)
      Rails.logger.info("[EnsureMetaTranslationsJob] #{items.size} items/gems need translations")

      run_with_threads(items, concurrency: CONCURRENCY) do |item|
        missing_map[item.id].each do |locale|
          data = Blizzard::Api::GameData::Item.fetch(blizzard_id: item.blizzard_id, locale: locale)
          name = data["name"]
          item.set_translation("name", locale, name, meta: { source: "blizzard" }) if name.present?
          desc = data["description"]
          item.set_translation("description", locale, desc, meta: { source: "blizzard" }) if desc.present?
        end
      rescue Blizzard::Client::Error => e
        Rails.logger.warn("[EnsureMetaTranslationsJob] Item #{item.blizzard_id} failed: #{e.message}")
      end
    end
    # rubocop:enable Metrics/AbcSize

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def ensure_enchantment_translations(season)
      ids = PvpMetaEnchantPopularity.where(pvp_season: season).distinct.pluck(:enchantment_id)

      incomplete = ids_missing_translations("Enchantment", ids)
      return if incomplete.empty?

      # Resolve each enchantment's source item (the scroll/formula that created it).
      # The source item's name is the canonical enchantment name, fetchable via the Item API.
      source_map = CharacterItem
        .where(enchantment_id: incomplete)
        .where.not(enchantment_source_item_id: nil)
        .joins("INNER JOIN items si ON si.id = character_items.enchantment_source_item_id")
        .distinct
        .pluck(:enchantment_id, "si.blizzard_id")
        .to_h

      enchantments = Enchantment.where(id: incomplete).to_a
      missing_map  = build_missing_map("Enchantment", incomplete)
      Rails.logger.info("[EnsureMetaTranslationsJob] #{enchantments.size} enchantments need translations")

      run_with_threads(enchantments, concurrency: CONCURRENCY) do |enc|
        source_blz_id = source_map[enc.id]
        unless source_blz_id
          Rails.logger.warn("[EnsureMetaTranslationsJob] Enchantment #{enc.id} has no source item, skipping")
          next
        end

        missing_map[enc.id].each do |locale|
          data = Blizzard::Api::GameData::Item.fetch(blizzard_id: source_blz_id, locale: locale)
          name = data["name"]
          enc.set_translation("name", locale, name, meta: { source: "blizzard" }) if name.present?
        end
      rescue Blizzard::Client::Error => e
        Rails.logger.warn("[EnsureMetaTranslationsJob] Enchantment #{enc.id} failed: #{e.message}")
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # rubocop:disable Metrics/AbcSize
    def ensure_talent_translations(season)
      ids = PvpMetaTalentPopularity.where(pvp_season: season).distinct.pluck(:talent_id)

      incomplete = ids_missing_translations("Talent", ids)
      return if incomplete.empty?

      talents     = Talent.where(id: incomplete).to_a
      missing_map = build_missing_map("Talent", incomplete)
      Rails.logger.info("[EnsureMetaTranslationsJob] #{talents.size} talents need translations")

      run_with_threads(talents, concurrency: CONCURRENCY) do |talent|
        missing_map[talent.id].each do |locale|
          name = fetch_talent_name(talent, locale)
          talent.set_translation("name", locale, name, meta: { source: "blizzard" }) if name.present?
        end
      rescue Blizzard::Client::Error => e
        Rails.logger.warn("[EnsureMetaTranslationsJob] Talent #{talent.blizzard_id} failed: #{e.message}")
      end
    end
    # rubocop:enable Metrics/AbcSize

    def fetch_talent_name(talent, locale)
      data = if talent.talent_type == "pvp"
        Blizzard::Api::GameData::PvpTalent.fetch(blizzard_id: talent.blizzard_id, locale: locale)
      else
        Blizzard::Api::GameData::Talent.fetch(blizzard_id: talent.blizzard_id, locale: locale)
      end
      data["name"]
    rescue Blizzard::Client::NotFoundError
      nil
    end

    # Returns IDs that need processing: all IDs when forced, otherwise only those
    # missing a name translation for at least one supported locale.
    def ids_missing_translations(type, ids)
      return ids if @force
      return [] if ids.empty?

      complete = Translation
        .where(translatable_type: type, translatable_id: ids, locale: Wow::Locales::SUPPORTED_LOCALES, key: "name")
        .group(:translatable_id)
        .having("COUNT(DISTINCT locale) = ?", Wow::Locales::SUPPORTED_LOCALES.size)
        .pluck(:translatable_id)

      ids - complete
    end

    # Returns a map of id => [missing locales] for all ids in one query.
    def build_missing_map(type, ids)
      return ids.index_with { Wow::Locales::SUPPORTED_LOCALES.dup } if @force

      existing = Translation
        .where(translatable_type: type, translatable_id: ids, key: "name")
        .pluck(:translatable_id, :locale)
        .each_with_object(Hash.new { |h, k| h[k] = [] }) { |(id, locale), h| h[id] << locale }

      ids.index_with { |id| Wow::Locales::SUPPORTED_LOCALES - existing[id] }
    end
end
