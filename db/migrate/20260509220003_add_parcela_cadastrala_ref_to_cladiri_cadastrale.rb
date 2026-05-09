class AddParcelaCadastralaRefToCladiriCadastrale < ActiveRecord::Migration[8.1]
  def change
    add_reference :cladiri_cadastrale, :parcela_cadastrala,
                  null: false, foreign_key: { to_table: :parcele_cadastrale }
  end
end
