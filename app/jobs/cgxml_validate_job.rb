class CgxmlValidateJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 2

  def perform(file_description_id)
    fd = FileDescription.find_by(id: file_description_id)
    return unless fd

    CgxmlValidationService.new(fd).call
  rescue => e
    fd&.update_columns(validation_status: "pending")
    raise e
  end
end
