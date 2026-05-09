class CreateContesteds < ActiveRecord::Migration[8.1]
  def change
    create_table :contesteds do |t|
      t.integer  :contestednumber
      t.datetime :contesteddate
      t.integer  :solutionnumber
      t.datetime :solutiondate

      t.timestamps
    end
  end
end
