module Blizzard
  module News
    class SyncPatchNotesService < BaseService
      LIST_API_URL       = "https://news.blizzard.com/en-us/api/news/world-of-warcraft"
      RELEVANT_CATEGORY  = "News"
      RELEVANT_TITLE_RE  = KnowledgeDocument::RELEVANT_TITLE_RE

      def call
        articles = fetch_article_list
        return failure("Failed to fetch Blizzard news list") unless articles

        synced = articles.count { |a| relevant?(a) && sync_article(a) }
        log_info("Synced #{synced} article(s)")
        success(synced)
      rescue => e
        failure(e)
      end

      private

        def fetch_article_list
          uri       = URI(LIST_API_URL)
          uri.query = URI.encode_www_form(pageSize: 50)
          resp      = Net::HTTP.get_response(uri)
          return nil unless resp.is_a?(Net::HTTPSuccess)

          JSON.parse(resp.body).dig("feed", "contentItems")
        rescue JSON::ParserError
          nil
        end

        def relevant?(article)
          props    = article["properties"]
          category = props["category"].to_s
          title    = props["title"].to_s
          category == RELEVANT_CATEGORY && RELEVANT_TITLE_RE.match?(title)
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def sync_article(article)
          props               = article["properties"]
          external_id         = props["newsId"]
          external_updated_at = props["lastUpdated"].present? ? Time.zone.parse(props["lastUpdated"]) : nil
          url                 = props["newsUrl"]

          doc = KnowledgeDocument.find_or_initialize_by(source: "blizzard_news", external_id: external_id)

          if doc.persisted? && !doc.stale?
            log_info("Up-to-date: #{props['title']}")
            return false
          end

          result = ArticleExtractorService.call(url: url)
          unless result.success?
            log_warn("Extraction failed for #{external_id}: #{result.error}")
            return false
          end

          doc.update!(
            title:               props["title"],
            url:                 url,
            category:            props["category"],
            content:             result.payload,
            external_updated_at: external_updated_at,
            fetched_at:          Time.current,
            metadata:            { slug: props["newsSlug"] }
          )

          log_info("Synced: #{props['title']}")
          true
        rescue => e
          log_warn("Failed to sync #{article.dig('properties', 'newsId')}: #{e.message}")
          false
        end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
    end
  end
end
