require "net/http"

module Gis
  # Proxy WMTS pentru servicii upstream care necesită basic auth (credențialele
  # nu trebuie expuse în browser). Browser-ul cere tile-uri de la Rails;
  # Rails le aduce de la upstream cu basic auth și le retransmite.
  #
  # Caching: răspunsurile sunt deterministe (același matrix/col/row → același
  # PNG), deci setăm Cache-Control public 30 zile + ETag derivat din path.
  class WmtsProxyController < ApplicationController
    # Endpoint pentru ortofotoplanul UAT Sascut 2022 (geosys.ro, basic auth).
    # WMTS upstream: https://geosys.ro/mapproxy/uat_sascut/wmts/sascut_2022/
    #                96dpi_3844_grid/{TileMatrix}/{TileCol}/{TileRow}.png
    SASCUT_UPSTREAM = "https://geosys.ro/mapproxy/uat_sascut/wmts/sascut_2022/96dpi_3844_grid".freeze

    def sascut
      matrix, col, row = params.values_at(:matrix, :col, :row)
      url = "#{SASCUT_UPSTREAM}/#{matrix}/#{col}/#{row}.png"
      fetch_and_stream(url)
    end

    private

    def fetch_and_stream(url)
      uri = URI.parse(url)
      req = Net::HTTP::Get.new(uri)
      req.basic_auth(geosys_creds.fetch(:username), geosys_creds.fetch(:password))

      response = Net::HTTP.start(uri.hostname, uri.port,
                                 use_ssl: uri.scheme == "https",
                                 open_timeout: 5, read_timeout: 15) do |http|
        http.request(req)
      end

      case response
      when Net::HTTPSuccess
        # Tile-urile WMTS sunt imutabile per (layer, matrix, col, row) — cache agresiv
        expires_in 30.days, public: true
        send_data response.body, type: response.content_type || "image/png",
                                 disposition: "inline"
      when Net::HTTPNotFound, Net::HTTPBadRequest
        # Tile în afara extent-ului ortofotoplanului (mapproxy întoarce 400).
        # Răspundem 404 ca OL să-l ignore în liniște, fără erori în consolă.
        head :not_found
      else
        Rails.logger.warn("WMTS proxy upstream #{response.code} pentru #{url}")
        head :bad_gateway
      end
    rescue Net::ReadTimeout, Net::OpenTimeout, SocketError, Errno::ECONNREFUSED => e
      Rails.logger.warn("WMTS proxy timeout/conn pentru #{url}: #{e.class}")
      head :gateway_timeout
    end

    def geosys_creds
      creds = Rails.application.credentials.geosys
      raise "Lipsește Rails.application.credentials.geosys (username/password)" unless creds
      creds
    end
  end
end
