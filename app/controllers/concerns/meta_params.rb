module MetaParams
  extend ActiveSupport::Concern

  included do
    before_action :validate_meta_params!
  end

  private

    def validate_meta_params!
      validate_bracket!(params.require(:bracket)) or return
      validate_spec_id!(params.require(:spec_id)) or return
    end

    def bracket_param = @bracket_param ||= params.require(:bracket)
    def spec_id_param = @spec_id_param ||= params.require(:spec_id).to_i
    def slot_param    = @slot_param    ||= validate_slot(params[:slot])
end
