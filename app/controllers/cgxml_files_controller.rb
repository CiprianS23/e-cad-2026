class CgxmlFilesController < ApplicationController
  before_action :set_file_description, only: [ :show, :revalidate, :report ]

  def index
    @files = FileDescription.order(created_at: :desc).page(params[:page]).per(20)
    @stats = {
      total:    FileDescription.count,
      valid:    FileDescription.where(validation_status: "valid").count,
      errors:   FileDescription.where(validation_status: "errors").count,
      pending:  FileDescription.where(validation_status: "pending").count
    }
  end

  def show
    @errors_by_code = @fd.cgxml_validation_errors
                         .unfixed
                         .group_by(&:error_code)
                         .transform_keys { |k| CgxmlValidationError.new(error_code: k).error_code_label }

    @errors_by_entity = @fd.cgxml_validation_errors
                           .unfixed
                           .group_by(&:entity_type)

    @fixed_count   = @fd.cgxml_validation_errors.fixed.count
    @unfixed_count = @fd.cgxml_validation_errors.unfixed.count
  end

  def revalidate
    @fd.update_columns(validation_status: "pending")
    CgxmlValidateJob.perform_later(@fd.id)
    redirect_to cgxml_file_path(@fd), notice: "Revalidarea a fost programată."
  end

  def report
    @errors = @fd.cgxml_validation_errors.order(:severity, :entity_type, :field_name)
    respond_to do |format|
      format.html
      format.json do
        render json: {
          file:     @fd.filename,
          exported: @fd.exportdate,
          validated_at: @fd.updated_at,
          status:   @fd.validation_status,
          summary: {
            errors:   @fd.validation_errors_count,
            warnings: @fd.validation_warnings_count
          },
          errors_by_code: @errors.group_by(&:error_code).transform_values { |errs|
            errs.map { |e|
              {
                entity_type: e.entity_type,
                entity_id:   e.entity_id,
                field:       e.field_name,
                message:     e.error_message,
                current:     e.current_value,
                expected:    e.expected_format,
                fixed:       e.fixed?
              }
            }
          }
        }
      end
    end
  end

  private

  def set_file_description
    @fd = FileDescription.find(params[:id])
  end
end
