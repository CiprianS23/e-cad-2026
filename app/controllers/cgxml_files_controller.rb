class CgxmlFilesController < ApplicationController
  before_action :set_file_description, only: [ :show, :revalidate, :report ]

  def index
    scope = FileDescription.order(created_at: :desc)
    case params[:source]
    when "corrected" then scope = scope.where(is_systematic_corrected: true)
    when "sporadic"  then scope = scope.where(is_systematic_corrected: false)
    end
    @files = scope.page(params[:page]).per(20)
    @stats = {
      total:     FileDescription.count,
      valid:     FileDescription.where(validation_status: "valid").count,
      errors:    FileDescription.where(validation_status: "errors").count,
      pending:   FileDescription.where(validation_status: "pending").count,
      corrected: FileDescription.where(is_systematic_corrected: true).count,
      sporadic:  FileDescription.where(is_systematic_corrected: false).count
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
    CgxmlValidationService.new(@fd).call
    redirect_to cgxml_file_path(@fd), notice: "Revalidarea s-a finalizat."
  end

  # GET /cgxml_files/comparison
  # Dashboard cu rate erori per cod, sporadic OCPI vs corectat sistematic.
  # Folosit pentru:
  # - Identifică reguli false-positive (apar mult pe corectat)
  # - Confirmă reguli legitime (apar doar pe sporadic)
  # - Vezi care anomalii rezistă chiar și după corecția prestator
  def comparison
    sp_ids = FileDescription.where(is_systematic_corrected: false).pluck(:id)
    co_ids = FileDescription.where(is_systematic_corrected: true).pluck(:id)

    @n_sp = sp_ids.size
    @n_co = co_ids.size

    @rows = CgxmlValidationError.distinct.pluck(:error_code).compact.sort.map do |code|
      base = CgxmlValidationError.where(error_code: code)
      sp = base.where(file_description_id: sp_ids).distinct.count(:file_description_id)
      co = base.where(file_description_id: co_ids).distinct.count(:file_description_id)
      sev = base.distinct.pluck(:severity).join("/")
      {
        code:    code,
        severity: sev,
        sp:      sp,
        co:      co,
        sp_pct:  @n_sp > 0 ? (100.0 * sp / @n_sp).round(1) : 0,
        co_pct:  @n_co > 0 ? (100.0 * co / @n_co).round(1) : 0,
        sample_msg: base.first&.error_message&.truncate(120)
      }
    end.sort_by { |r| [-r[:co_pct], -r[:sp]] }

    @summary = {
      sporadic: {
        total:  @n_sp,
        valid:  FileDescription.where(id: sp_ids, validation_status: "valid").count,
        errors: FileDescription.where(id: sp_ids, validation_status: "errors").count
      },
      corrected: {
        total:  @n_co,
        valid:  FileDescription.where(id: co_ids, validation_status: "valid").count,
        errors: FileDescription.where(id: co_ids, validation_status: "errors").count
      }
    }
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
