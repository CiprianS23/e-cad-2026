import { Controller } from "@hotwired/stimulus"

// STUB pentru Faza 1 (paritate /harta în OpenLayers).
// Versiunea completă (drawing, snap, save parcelă/clădire) va fi rescrisă în Faza 2.
// Vechiul controller Leaflet e păstrat în digitizare_controller.js.leaflet-bak ca referință.
export default class extends Controller {
  static outlets = ["harta-map"]

  togglePanel() {
    this.element.classList.toggle("digi-panel--collapsed")
  }
}
