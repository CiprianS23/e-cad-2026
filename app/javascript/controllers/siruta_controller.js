import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values  = { url: String }
  static targets = ["judetInput", "localitateInput", "judetDropdown", "localitateDropdown"]

  connect() {
    this._judetTimer = null
    this._locTimer   = null
    this._judetIdx   = -1
    this._locIdx     = -1
    this._onOutside  = this._handleOutsideClick.bind(this)
    document.addEventListener("click", this._onOutside)
  }

  disconnect() {
    document.removeEventListener("click", this._onOutside)
  }

  // ── event handlers ────────────────────────────────────────────────

  onJudetInput() {
    clearTimeout(this._judetTimer)
    this._judetTimer = setTimeout(() => this._fetchJudete(), 180)
  }

  onJudetKeydown(e) {
    this._handleKeydown(e, this.judetDropdownTarget, (val) => {
      this.judetInputTarget.value = val
      this._hide(this.judetDropdownTarget)
      this._clearLocalitate()
      this.localitateInputTarget.focus()
    }, "_judetIdx")
  }

  onLocalitateInput() {
    clearTimeout(this._locTimer)
    this._locTimer = setTimeout(() => this._fetchLocalitati(), 180)
  }

  onLocalitateKeydown(e) {
    this._handleKeydown(e, this.localitateDropdownTarget, (val) => {
      this.localitateInputTarget.value = val
      this._hide(this.localitateDropdownTarget)
    }, "_locIdx")
  }

  // ── fetch ─────────────────────────────────────────────────────────

  async _fetchJudete() {
    const q = this.judetInputTarget.value.trim()
    if (!q) { this._hide(this.judetDropdownTarget); return }

    const items = await this._get({ type: "judet", q })
    this._render(this.judetDropdownTarget, items, "_judetIdx", (item) => {
      this.judetInputTarget.value = item.value
      this._hide(this.judetDropdownTarget)
      this._clearLocalitate()
      this.localitateInputTarget.focus()
    })
  }

  async _fetchLocalitati() {
    const q     = this.localitateInputTarget.value.trim()
    const judet = this.judetInputTarget.value.trim()
    if (!q && !judet) { this._hide(this.localitateDropdownTarget); return }

    const items = await this._get({ type: "localitate", q, judet })
    this._render(this.localitateDropdownTarget, items, "_locIdx", (item) => {
      this.localitateInputTarget.value = item.value
      this._hide(this.localitateDropdownTarget)
    })
  }

  async _get(params) {
    try {
      const url = this.urlValue + "?" + new URLSearchParams(params)
      const res = await fetch(url, { headers: { "Accept": "application/json" } })
      return res.ok ? await res.json() : []
    } catch { return [] }
  }

  // ── render ────────────────────────────────────────────────────────

  _render(el, items, idxKey, onSelect) {
    el.innerHTML = ""
    this[idxKey]  = -1
    if (!items.length) { el.hidden = true; return }

    items.forEach((item, i) => {
      const li = document.createElement("li")
      li.className    = "ac-item"
      li.textContent  = item.label
      li.dataset.idx  = i
      li.addEventListener("mousedown", (e) => { e.preventDefault(); onSelect(item) })
      el.appendChild(li)
    })
    el._items    = items
    el._onSelect = onSelect
    el.hidden    = false
  }

  _handleKeydown(e, dropdown, onSelect, idxKey) {
    if (dropdown.hidden) return
    const items = dropdown.querySelectorAll(".ac-item")
    if (!items.length) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      this[idxKey] = Math.min(this[idxKey] + 1, items.length - 1)
      this._highlight(dropdown, this[idxKey])
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this[idxKey] = Math.max(this[idxKey] - 1, 0)
      this._highlight(dropdown, this[idxKey])
    } else if (e.key === "Enter" && this[idxKey] >= 0) {
      e.preventDefault()
      const item = dropdown._items[this[idxKey]]
      if (item) { onSelect(item); this._hide(dropdown) }
    } else if (e.key === "Escape") {
      this._hide(dropdown)
    }
  }

  _highlight(dropdown, idx) {
    dropdown.querySelectorAll(".ac-item").forEach((li, i) => {
      li.classList.toggle("ac-item--active", i === idx)
    })
  }

  _hide(el) {
    el.hidden    = true
    el.innerHTML = ""
  }

  _clearLocalitate() {
    this.localitateInputTarget.value = ""
    this._hide(this.localitateDropdownTarget)
  }

  _handleOutsideClick(e) {
    if (this.element.contains(e.target)) return
    if (this.hasJudetDropdownTarget)     this._hide(this.judetDropdownTarget)
    if (this.hasLocalitateDropdownTarget) this._hide(this.localitateDropdownTarget)
  }
}
