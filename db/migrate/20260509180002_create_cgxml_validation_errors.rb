class CreateCgxmlValidationErrors < ActiveRecord::Migration[8.1]
  def change
    create_table :cgxml_validation_errors do |t|
      t.references :file_description, null: false, foreign_key: true, index: true

      t.string  :entity_type,    null: false
      t.bigint  :entity_id
      t.string  :field_name
      t.string  :error_code,     null: false
      t.text    :error_message,  null: false
      t.string  :severity,       default: "error", null: false
      t.string  :current_value
      t.string  :expected_format
      t.string  :xpath

      t.datetime :fixed_at
      t.string   :fixed_by

      t.timestamps
    end

    add_index :cgxml_validation_errors, [ :file_description_id, :error_code ]
    add_index :cgxml_validation_errors, [ :file_description_id, :entity_type ]
    add_index :cgxml_validation_errors, [ :entity_type, :entity_id ]
    add_index :cgxml_validation_errors, :fixed_at
  end
end
