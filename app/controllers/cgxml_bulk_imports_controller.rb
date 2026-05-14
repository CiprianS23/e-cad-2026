require "zip"

class CgxmlBulkImportsController < ApplicationController
  ALLOWED_EXTS = %w[.cgxml .xml].freeze
  MAX_ZIP_ENTRY_SIZE = 100.megabytes

  def new
  end

  # POST /cgxml_bulk_imports
  # Acceptă mai multe fișiere .cgxml/.xml și arhive .zip cu cgxml-uri înăuntru.
  # Pentru fiecare conținut: calculează hash, sare peste duplicate, creează un stub
  # FileDescription cu raw_file atașat și pune CgxmlImportJob în coadă.
  def create
    files = Array(params[:files]).reject(&:blank?)
    @corrected = ActiveModel::Type::Boolean.new.cast(params[:corrected])

    if files.empty?
      return redirect_to new_cgxml_bulk_import_path, alert: "Selectați cel puțin un fișier."
    end

    report = {
      accepted:           [],   # FileDescription stubs create
      duplicates:         [],   # filenames duplicate (skip silent)
      invalid_extension:  [],   # respinse de validare extensie
      zip_errors:         [],   # zip-uri stricate
      job_errors:         []    # erori la enqueue
    }

    files.each do |uploaded|
      next unless uploaded.respond_to?(:original_filename)
      name = uploaded.original_filename.to_s

      if name.match?(/\.zip\z/i)
        process_zip(uploaded, report)
      elsif name.match?(/(?:#{ALLOWED_EXTS.map { |e| Regexp.escape(e) }.join('|')})\z/i)
        content = uploaded.read.force_encoding("UTF-8")
        ingest_cgxml(name, content, report)
      else
        report[:invalid_extension] << name
      end
    end

    @report = report
    flash[:notice] = build_flash_summary(report)
    redirect_to cgxml_files_path
  end

  private

  def process_zip(uploaded, report)
    Zip::File.open(uploaded.tempfile.path) do |zip|
      zip.each do |entry|
        next if entry.directory?
        unless ALLOWED_EXTS.any? { |ext| entry.name.downcase.end_with?(ext) }
          report[:invalid_extension] << "#{uploaded.original_filename}!#{entry.name}"
          next
        end
        if entry.size > MAX_ZIP_ENTRY_SIZE
          report[:zip_errors] << "#{uploaded.original_filename}!#{entry.name} (prea mare: #{entry.size} bytes)"
          next
        end

        content = entry.get_input_stream.read.force_encoding("UTF-8")
        ingest_cgxml(File.basename(entry.name), content, report)
      end
    end
  rescue Zip::Error => e
    report[:zip_errors] << "#{uploaded.original_filename}: #{e.message}"
  end

  def ingest_cgxml(filename, content, report)
    hash = Digest::SHA256.hexdigest(content)

    if FileDescription.exists?(content_hash: hash)
      report[:duplicates] << filename
      return
    end

    fd = FileDescription.new(
      filename:                filename.to_s.first(50),
      content_hash:            hash,
      import_status:           "pending",
      validation_status:       "pending",
      is_systematic_corrected: !!@corrected
    )
    fd.raw_file.attach(
      io:           StringIO.new(content),
      filename:     filename,
      content_type: "application/xml"
    )
    fd.save!

    CgxmlImportJob.perform_later(fd.id)
    report[:accepted] << fd
  rescue => e
    Rails.logger.error("Bulk ingest failed for #{filename}: #{e.class}: #{e.message}")
    report[:job_errors] << "#{filename}: #{e.message}"
  end

  def build_flash_summary(report)
    parts = []
    parts << "#{report[:accepted].size} fișier(e) puse în coadă" if report[:accepted].any?
    parts << "#{report[:duplicates].size} duplicat(e) ignorate" if report[:duplicates].any?
    parts << "#{report[:invalid_extension].size} respinse (extensie greșită)" if report[:invalid_extension].any?
    parts << "#{report[:zip_errors].size} probleme la arhivă" if report[:zip_errors].any?
    parts << "#{report[:job_errors].size} erori la planificare" if report[:job_errors].any?
    parts.any? ? parts.join(" • ") : "Niciun fișier procesat."
  end
end
