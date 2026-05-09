namespace :siruta do
  desc "Încarcă codurile SIRUTA din db/seeds/siruta.csv"
  task load: :environment do
    csv_path = Rails.root.join("db/seeds/siruta.csv")
    abort "Fișierul #{csv_path} nu există." unless File.exist?(csv_path)

    require "csv"

    rows = CSV.read(csv_path, headers: true, encoding: "UTF-8").map do |row|
      {
        cod_siruta:     row["cod_siruta"].to_i,
        cod_judet:      row["cod_judet"].to_i,
        denumire_judet: row["denumire_judet"].strip,
        tip_uat:        row["tip_uat"].to_i,
        tip_uat_abrev:  row["tip_uat_abrev"].strip,
        denumire_uat:   row["denumire_uat"].strip
      }
    end

    inserted = 0
    updated  = 0

    SirutaUat.transaction do
      rows.each do |attrs|
        record = SirutaUat.find_or_initialize_by(cod_siruta: attrs[:cod_siruta])
        if record.new_record?
          record.assign_attributes(attrs)
          record.save!
          inserted += 1
        elsif record.slice(*attrs.keys.map(&:to_s)) != attrs.transform_keys(&:to_s)
          record.update!(attrs)
          updated += 1
        end
      end
    end

    puts "SIRUTA: #{inserted} înregistrări adăugate, #{updated} actualizate, #{SirutaUat.count} total."
  end

  desc "Șterge toate codurile SIRUTA din baza de date"
  task clear: :environment do
    count = SirutaUat.delete_all
    puts "SIRUTA: #{count} înregistrări șterse."
  end

  desc "Reîncarcă codurile SIRUTA (clear + load)"
  task reload: [:clear, :load]
end
