import { Controller } from "@hotwired/stimulus"

// Sidebar Toggle — colapsează/deschide panoul lateral stâng pe /harta.
// Persistă starea în localStorage ca user-ul să vadă același UI la reload.
// Pattern oglindă pentru `digi-panel` (panoul dreapta din digitizare).
export default class extends Controller {
  static STORAGE_KEY = "harta-sidebar-collapsed"

  connect() {
    if (localStorage.getItem(this.constructor.STORAGE_KEY) === "1") {
      this.element.classList.add("harta-sidebar--collapsed")
    }
  }

  toggle() {
    const collapsed = this.element.classList.toggle("harta-sidebar--collapsed")
    localStorage.setItem(this.constructor.STORAGE_KEY, collapsed ? "1" : "0")
    // Forțează OpenLayers să recalculeze size-ul după ce sidebar-ul își
    // schimbă lățimea — altfel harta apare ca dungă în viewport-ul vechi.
    window.dispatchEvent(new Event("resize"))
  }
}
