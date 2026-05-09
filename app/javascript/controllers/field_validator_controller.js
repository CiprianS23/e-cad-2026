import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "feedback", "saveBtn"]
  static values = {
    entityType:  String,
    fieldName:   String,
    errorId:     Number,
    fixUrl:      String,
    validateUrl: String
  }

  connect() {
    this._timer = null
    this._lastValue = this.inputTarget.value
    this._validated = false
  }

  disconnect() {
    clearTimeout(this._timer)
  }

  validate() {
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this._doValidate(), 380)
  }

  async save() {
    const value = this.inputTarget.value.trim()
    this.saveBtnTarget.disabled = true
    this.saveBtnTarget.textContent = "Se salvează..."

    try {
      const resp = await fetch(this.fixUrlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken()
        },
        body: JSON.stringify({ corrected_value: value, fixed_by: "prestator" })
      })
      const data = await resp.json()

      if (data.success) {
        this._markRowFixed()
      } else {
        this._setFeedback("error", (data.errors || ["Eroare la salvare."]).join("; "))
        this.saveBtnTarget.disabled = false
        this.saveBtnTarget.textContent = "Salvează"
      }
    } catch {
      this._setFeedback("error", "Eroare de rețea. Reîncercați.")
      this.saveBtnTarget.disabled = false
      this.saveBtnTarget.textContent = "Salvează"
    }
  }

  async _doValidate() {
    const value = this.inputTarget.value.trim()

    if (value === this._lastValue && this._validated) return
    this._lastValue = value
    this._validated = true

    this._setFeedback("loading", "Se verifică...")

    try {
      const resp = await fetch(this.validateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken()
        },
        body: JSON.stringify({
          entity_type: this.entityTypeValue,
          field_name:  this.fieldNameValue,
          value
        })
      })
      const data = await resp.json()

      if (data.valid) {
        this._setFeedback("ok", "Valoare validă ✓")
        if (this.hasSaveBtnTarget) this.saveBtnTarget.disabled = false
      } else {
        this._setFeedback("error", data.errors.join("; "))
        if (this.hasSaveBtnTarget) this.saveBtnTarget.disabled = true
      }
    } catch {
      this._setFeedback("warn", "Validare indisponibilă momentan")
      if (this.hasSaveBtnTarget) this.saveBtnTarget.disabled = false
    }
  }

  _setFeedback(type, msg) {
    if (!this.hasFeedbackTarget) return
    const el = this.feedbackTarget
    el.className = `cf-feedback cf-feedback-${type}`
    el.textContent = msg
    el.setAttribute("aria-live", "polite")

    const input = this.inputTarget
    input.classList.remove("cf-input-ok", "cf-input-error")
    if (type === "ok")    input.classList.add("cf-input-ok")
    if (type === "error") input.classList.add("cf-input-error")
  }

  _markRowFixed() {
    const row = this.element.closest("[data-error-id]")
    if (!row) return

    row.classList.add("error-row-fixed")
    const content = row.querySelector(".error-row-content")
    const actions = row.querySelector(".correction-form")

    if (actions) {
      actions.innerHTML = `<div class="error-row-fixed-label">
        Rezolvat acum de <em>prestator</em>
        <button class="btn btn-xs btn-outline unfix-btn"
                data-error-id="${this.errorIdValue}"
                data-unfix-url="${this.fixUrlValue.replace('/fix', '/unfix')}">
          Anulează
        </button>
      </div>`
    }

    this._updateGlobalCounts(-1)
  }

  _updateGlobalCounts(delta) {
    const badge = document.querySelector("[data-unfixed-count]")
    if (badge) {
      const current = parseInt(badge.dataset.unfixedCount || "0", 10)
      const next = Math.max(0, current + delta)
      badge.dataset.unfixedCount = next
      badge.textContent = next + (next === 1 ? " eroare nerezolvată" : " erori nerezolvate")
    }
  }

  _csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
