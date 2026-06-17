module Blizzard
  module News
    class ArticleExtractorService < BaseService
      CLASSIC_LABELS = [
        "The Burning Crusade Classic",
        "Mists of Pandaria Classic",
        "Season of Discovery",
        "WoW Classic Era",
        "Hardcore",
        "Wrath of the Lich King Classic",
        "Cataclysm Classic"
      ].freeze

      def initialize(url:)
        @url = url
      end

      def call
        html = fetch_html
        return failure("HTTP error fetching #{@url}") unless html

        content = extract_midnight_content(html)
        success(content)
      rescue => e
        failure(e)
      end

      private

        attr_reader :url

        def fetch_html
          uri  = URI(url)
          resp = Net::HTTP.get_response(uri)
          resp.is_a?(Net::HTTPSuccess) ? resp.body : nil
        end

        # Walks the <section class="blog"> DOM, skips any block that follows a
        # Classic game label until the next date header or Midnight section header.
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def extract_midnight_content(html)
          doc     = Nokogiri::HTML(html)
          section = doc.at_css("section.blog") || doc.at_css("article")
          return "" unless section

          lines      = []
          in_classic = false

          section.children.each do |node|
            next if node.text? && node.text.strip.empty?
            next if node.name == "hr"

            if date_header?(node)
              in_classic = false
              lines << "\n#{node.text.strip}"
            elsif classic_label?(node)
              in_classic = true
            elsif section_header?(node)
              in_classic = false
              lines << node.text.strip
            elsif !in_classic
              case node.name
              when "ul" then lines << extract_list(node)
              when "p"
                text = node.text.strip
                lines << text if text.present?
              end
            end
          end

          lines.reject(&:empty?).join("\n").strip
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def date_header?(node)
          node.name == "p" && node.at_css("span[style*='daa520']")
        end

        def classic_label?(node)
          return false unless node.name == "p"

          CLASSIC_LABELS.include?(node.text.strip)
        end

        def section_header?(node)
          node.name == "p" && node.at_css("strong") && !date_header?(node)
        end

        # rubocop:disable Metrics/AbcSize
        def extract_list(ul, indent: 0)
          ul.css("> li").map do |li|
            prefix    = ("  " * indent) + "- "
            own_text  = li.children
              .select { |c| c.text? || %w[strong em].include?(c.name) }
              .map(&:text)
              .join
              .strip
            nested    = li.css("> ul").map { |sub| extract_list(sub, indent: indent + 1) }.join("\n")
            nested.present? ? "#{prefix}#{own_text}\n#{nested}" : "#{prefix}#{own_text}"
          end.join("\n")
        end
      # rubocop:enable Metrics/AbcSize
    end
  end
end
