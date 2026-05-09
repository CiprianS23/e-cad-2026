class AddImportTrackingToFileDescriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :file_descriptions, :import_status,            :string,  default: "done",    null: false
    add_column :file_descriptions, :validation_status,        :string,  default: "pending", null: false
    add_column :file_descriptions, :import_errors_count,      :integer, default: 0,         null: false
    add_column :file_descriptions, :validation_errors_count,  :integer, default: 0,         null: false
    add_column :file_descriptions, :validation_warnings_count,:integer, default: 0,         null: false
    add_column :file_descriptions, :raw_xml,                  :text
    add_column :file_descriptions, :imported_at,              :datetime

    add_index :file_descriptions, :validation_status
  end
end
