import { Controller } from "@hotwired/stimulus"

// Flash dismissible: buton ✕ pentru închidere manuală + auto-dismiss după 6s.
// Acceptă atribut `data-flash-sticky` pentru a dezactiva auto-dismiss
// (ex: pentru `alert` / `error` care necesită confirmare manuală).
export default class extends Controller {
  static values = { timeout: { type: Number, default: 6000 } }

  connect() {
    if (this.element.dataset.flashSticky !== "true") {
      this._timer = setTimeout(() => this.dismiss(), this.timeoutValue)
    }
  }

  disconnect() {
    if (this._timer) clearTimeout(this._timer)
  }

  dismiss() {
    if (this._timer) clearTimeout(this._timer)
    this.element.classList.add("flash--dismissing")
    setTimeout(() => this.element.remove(), 250)
  }
}
