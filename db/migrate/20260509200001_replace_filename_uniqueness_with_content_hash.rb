require "digest"

class ReplaceFilenameUniquenessWithContentHash < ActiveRecord::Migration[8.1]
  def up
    remove_index :file_descriptions, :filename

    add_column :file_descriptions, :content_hash, :string, limit: 64

    # Populate hash for records that still have raw_xml stored
    FileDescription.where.not(raw_xml: nil).find_each do |fd|
      fd.update_column(:content_hash, Digest::SHA256.hexdigest(fd.raw_xml))
    end

    add_index :file_descriptions, :content_hash, unique: true
  end

  def down
    remove_index :file_descriptions, :content_hash
    remove_column :file_descriptions, :content_hash
    add_index :file_descriptions, :filename, unique: true
  end
end
