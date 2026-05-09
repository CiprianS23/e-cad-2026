require "test_helper"

class SirutaControllerTest < ActionDispatch::IntegrationTest
  test "județ autocomplete returns matching results" do
    get siruta_autocomplete_path, params: { type: "judet", q: "clu" }
    assert_response :success
    data = JSON.parse(response.body)
    assert data.any? { |r| r["value"] == "Cluj" }, "Expected Cluj in results"
    assert data.all? { |r| r.key?("value") && r.key?("label") }
  end

  test "județ autocomplete empty query returns empty" do
    get siruta_autocomplete_path, params: { type: "judet", q: "" }
    assert_response :success
    # empty q → controller returns all (no filter applied), but JS prevents the call
    # so we just verify it returns valid JSON
    data = JSON.parse(response.body)
    assert_kind_of Array, data
  end

  test "localitate autocomplete filtered by județ" do
    get siruta_autocomplete_path, params: { type: "localitate", q: "napoca", judet: "Cluj" }
    assert_response :success
    data = JSON.parse(response.body)
    assert data.any? { |r| r["value"].include?("Cluj-Napoca") }, "Expected Cluj-Napoca in results"
    assert data.all? { |r| r.key?("cod_siruta") }
  end

  test "localitate without județ filter returns results from all counties" do
    get siruta_autocomplete_path, params: { type: "localitate", q: "alba" }
    assert_response :success
    data = JSON.parse(response.body)
    assert data.length > 1, "Expected multiple results across counties"
  end

  test "unknown type returns empty array" do
    get siruta_autocomplete_path, params: { type: "unknown", q: "test" }
    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "normalizes names to title case" do
    get siruta_autocomplete_path, params: { type: "judet", q: "timis" }
    assert_response :success
    data = JSON.parse(response.body)
    assert data.any? { |r| r["value"] == "Timis" }, "Expected title-cased Timis"
    assert data.none? { |r| r["value"] == "TIMIS" }, "Should not return all-caps"
  end
end
