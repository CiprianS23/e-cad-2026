class CgxmlImportsController < ApplicationController
  def new
  end

  def create
    file = params[:cgxml_file]

    unless file.is_a?(ActionDispatch::Http::UploadedFile)
      return redirect_to new_cgxml_import_path, alert: "Selectați un fișier CGXML."
    end

    unless file.original_filename.match?(/\.(cgxml|xml)\z/i)
      return redirect_to new_cgxml_import_path, alert: "Fișierul trebuie să fie .cgxml sau .xml"
    end

    content  = file.read.force_encoding("UTF-8")
    @result   = CgxmlImportService.new(content, filename: file.original_filename).call
    @filename = file.original_filename

    if @result.file_description
      CgxmlValidateJob.perform_later(@result.file_description.id)
    end
  end
end
