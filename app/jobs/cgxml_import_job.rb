class CgxmlImportJob < ApplicationJob
  queue_as :default

  # Procesează un FileDescription stub creat de fluxul bulk: descarcă raw_file din
  # Active Storage, rulează importul propriu-zis și apoi validarea CGXML v3.
  def perform(file_description_id)
    fd = FileDescription.find(file_description_id)
    fd.update_columns(import_status: "in_progress")

    content = fd.raw_file.download.force_encoding("UTF-8")

    CgxmlImportService.new(
      content,
      filename: fd.filename,
      content_hash: fd.content_hash,
      file_description: fd
    ).call

    fd.reload
    CgxmlValidationService.new(fd).call unless fd.import_status == "failed"
  rescue => e
    Rails.logger.error("CgxmlImportJob##{file_description_id} failed: #{e.class}: #{e.message}")
    FileDescription.where(id: file_description_id).update_all(
      import_status:       "failed",
      import_errors_count: 1,
      validation_status:   "errors",
      imported_at:         Time.current
    )
    raise
  end
end
