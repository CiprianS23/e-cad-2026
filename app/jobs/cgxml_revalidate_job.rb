class CgxmlRevalidateJob < ApplicationJob
  queue_as :default

  # Re-rulează doar validarea (nu și importul) pe un FileDescription existent.
  # Folosit pentru bulk re-validate când regulile validatorului se schimbă.
  def perform(file_description_id)
    fd = FileDescription.find(file_description_id)
    CgxmlValidationService.new(fd).call
  end
end
