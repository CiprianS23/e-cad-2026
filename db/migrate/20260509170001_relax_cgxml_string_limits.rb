class RelaxCgxmlStringLimits < ActiveRecord::Migration[8.1]
  # Real CGXML files often exceed the XSD-defined maxLength for string fields.
  # We remove length limits on columns where overflow is observed in practice.
  CHANGES = {
    deeds:            %i[deednumber deedtype authority valuecurrency valueamount],
    lands:            %i[cadsector e2identifier papercadno paperlbno topono cadgenno],
    buildings:        %i[buildingdestination e2identifier papercadno paperlbno topono cadgenno],
    building_common_parts: %i[commonparttype],
    individual_units: %i[identifier section apno entry floor landindivisionarea commonpartsarea
                          landdivisiontype commonpartstype e2identifier papercadno paperlbno topono cadgenno],
    parcels:          %i[usecategory titleno landplotno parcelno e2identifier papercadno paperlbno topono cadgenno],
    registrations:    %i[registrationtype righttype title quotatype initialquota actualquota valuecurrency valueamount],
    persons:          %i[firstname lastname idcode previouslastname fatherinitial citizenshipcountry
                          idcardtype idcardserialno idcardnumber],
    addresses:        %i[sirsup siruta districttype districtname streettype streetname postalnumber
                          block entry floor apno zipcode section],
    file_descriptions: %i[filename fileversion operationtype licensedname licensenumber],
    points:           %i[no]
  }

  def up
    CHANGES.each do |table, cols|
      cols.each do |col|
        change_column table, col, :string, limit: nil
      end
    end
  end

  def down
    # Restoring original limits is not worth the complexity — this is a one-way relaxation.
    raise ActiveRecord::IrreversibleMigration
  end
end
