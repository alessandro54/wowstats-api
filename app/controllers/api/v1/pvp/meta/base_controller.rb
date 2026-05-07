module Api
  module V1
    module Pvp
      module Meta
        class BaseController < Api::V1::BaseController
          private

            def bracket_param
              @bracket_param ||= params.require(:bracket)
            end

            def spec_id_param
              @spec_id_param ||= params.require(:spec_id).to_i
            end

            def slot_param
              @slot_param ||= validate_slot(params[:slot])
            end

            def socket_type_param
              @socket_type_param ||= validate_slot(params[:socket_type])
            end

            def validate_meta_params!
              validate_bracket!(params.require(:bracket)) or return
              validate_spec_id!(params.require(:spec_id)) or return
            end

            def serve_meta(*key_segments, &block)
              cache_key = meta_cache_key(*key_segments)
              json = meta_cache_fetch(cache_key, &block)
              render json: json
              set_cache_headers
            end
        end
      end
    end
  end
end
