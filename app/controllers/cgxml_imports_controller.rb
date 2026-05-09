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

    content = file.read.force_encoding("UTF-8")
    hash    = Digest::SHA256.hexdigest(content)

    if (existing = FileDescription.find_by(content_hash: hash))
      return redirect_to new_cgxml_import_path,
        alert: "Acest fisier a mai fost importat (#{existing.filename}, #{existing.imported_at&.strftime('%d.%m.%Y')})."
    end

    @result   = CgxmlImportService.new(content, filename: file.original_filename, content_hash: hash).call
    @filename = file.original_filename

    if @result.file_description
      CgxmlValidationService.new(@result.file_description).call
    end
  end
end
