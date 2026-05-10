import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static outlets = ["harta-map"]

  hartaMapOutletConnected(outlet) {
    if (outlet.map) {
      this._applyInitialState(outlet)
    } else {
      outlet.element.addEventListener("harta-map:ready", () => this._applyInitialState(outlet), { once: true })
    }
  }

  _applyInitialState(outlet) {
    // Aplică starea inițială pe harta-map (default-ul DOM-ului devine sursa de adevăr)
    const baseChecked = this.element.querySelector('input[name="base-layer"]:checked')
    if (baseChecked) outlet.setBaseLayer(baseChecked.value)

    this.element.querySelectorAll('input[type="checkbox"][data-overlay]').forEach(cb => {
      outlet.toggleOverlay(cb.dataset.overlay, cb.checked)
    })
  }

  selectBase(event) {
    if (!this.hasHartaMapOutlet) return
    this.hartaMapOutlet.setBaseLayer(event.target.value)
  }

  toggleOverlay(event) {
    if (!this.hasHartaMapOutlet) return
    this.hartaMapOutlet.toggleOverlay(event.target.dataset.overlay, event.target.checked)
  }
}
