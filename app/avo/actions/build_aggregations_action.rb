class Avo::Actions::BuildAggregationsAction < Avo::BaseAction
  self.name = "Build Aggregations"
  self.standalone = true
  self.visible = -> { view.index? }

  def fields
    field :skip_staleness_check, as: :boolean, default: true,
      help: "Ignore min_interval and force all aggregations to run"
  end

  def handle(fields:, **)
    season = PvpSeason.current
    unless season
      error("No current season found.")
      return
    end

    if fields[:skip_staleness_check]
      # Reset snapshot timestamps so stale? check passes for all aggregations
      Pvp::BuildAggregationsService::AGGREGATIONS.each do |_key, _service, model_class|
        model_class.where(pvp_season_id: season.id).update_all(snapshot_at: 1.year.ago) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    Pvp::BuildAggregationsJob.perform_later(pvp_season_id: season.id)
    succeed("BuildAggregationsJob enqueued for #{season.display_name || "season #{season.blizzard_id}"}.")
  end
end
