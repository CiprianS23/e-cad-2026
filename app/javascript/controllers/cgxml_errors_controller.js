import { Controller } from "@hotwired/stimulus"

// Handles mark-fixed, unfix, and group toggling on the show page.
export default class extends Controller {
  connect() {
    this.element.addEventListener("click", this._onClick.bind(this))
  }

  async _onClick(e) {
    const fixed = e.target.closest(".mark-fixed-btn")
    if (fixed) { e.preventDefault(); await this._markFixed(fixed); return }

    const unfix = e.target.closest(".unfix-btn")
    if (unfix) { e.preventDefault(); await this._unfix(unfix); return }

    const toggle = e.target.closest(".toggle-group")
    if (toggle) { e.preventDefault(); this._toggleGroup(toggle); return }
  }

  async _markFixed(btn) {
    const errorId = btn.dataset.errorId
    const fixUrl  = btn.dataset.fixUrl
    if (!errorId || !fixUrl) return

    btn.disabled = true
    try {
      const resp = await fetch(fixUrl, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrf()
        },
        body: JSON.stringify({ fixed_by: "manual" })
      })
      const data = await resp.json()
      if (data.success) {
        const row = document.getElementById(`error-${errorId}`)
        if (row) {
          row.classList.add("error-row-fixed")
          const actions = row.querySelector(".error-row-actions, .correction-form")
          if (actions) {
            actions.innerHTML = `<div class="error-row-fixed-label">Rezolvat manual
              <button class="btn btn-xs btn-outline unfix-btn"
                      data-error-id="${errorId}"
                      data-unfix-url="${fixUrl.replace('/fix', '/unfix')}">Anulează</button>
            </div>`
          }
        }
      }
    } catch { btn.disabled = false }
  }

  async _unfix(btn) {
    const errorId  = btn.dataset.errorId
    const unfixUrl = btn.dataset.unfixUrl
    if (!errorId || !unfixUrl) return

    btn.disabled = true
    try {
      const resp = await fetch(unfixUrl, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrf()
        }
      })
      const data = await resp.json()
      if (data.success) location.reload()
    } catch { btn.disabled = false }
  }

  _toggleGroup(btn) {
    const targetId = btn.dataset.target
    const list = document.getElementById(targetId)
    if (!list) return
    const hidden = list.style.display === "none"
    list.style.display = hidden ? "" : "none"
    btn.textContent = hidden ? "Ascunde" : "Arată"
  }

  _csrf() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
