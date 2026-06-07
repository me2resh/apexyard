/**
 * Cookie / storage consent — gates non-essential localStorage (cart, discount).
 * Language preference is treated as essential (functional).
 */
(function (root) {
  const KEY = "blendavit_consent_v1";
  let entrySnoozed = false;

  function get() {
    try {
      return localStorage.getItem(KEY);
    } catch (_) {
      return null;
    }
  }

  function set(value) {
    try {
      localStorage.setItem(KEY, value);
    } catch (_) {}
    hideBanner();
    root.dispatchEvent(new CustomEvent("blendavit:consent", { detail: { value } }));
  }

  function pending() {
    return !get();
  }

  /** @param {"cart"|"discount"|"snooze"|"lang"} kind */
  function allows(kind) {
    const choice = get();
    if (kind === "lang") return true;
    if (!choice) return false;
    if (choice === "all") return true;
    return false;
  }

  function isEntrySnoozed() {
    if (entrySnoozed) return true;
    if (!allows("snooze")) return false;
    try {
      return sessionStorage.getItem("blendavit_entry_snooze") === "1";
    } catch (_) {
      return false;
    }
  }

  function snoozeEntry() {
    entrySnoozed = true;
    if (!allows("snooze")) return;
    try {
      sessionStorage.setItem("blendavit_entry_snooze", "1");
    } catch (_) {}
  }

  function hideBanner() {
    document.querySelector("[data-consent-banner]")?.setAttribute("hidden", "");
  }

  function showBanner() {
    const el = document.querySelector("[data-consent-banner]");
    if (el) el.removeAttribute("hidden");
  }

  function init() {
    const banner = document.querySelector("[data-consent-banner]");
    if (!banner) return;

    if (!pending()) {
      hideBanner();
      return;
    }

    showBanner();

    banner.querySelector("[data-consent-accept]")?.addEventListener("click", () => {
      set("all");
    });

    banner.querySelector("[data-consent-essential]")?.addEventListener("click", () => {
      set("essential");
    });
  }

  root.BLENDAVIT_CONSENT = {
    get,
    set,
    pending,
    allows,
    isEntrySnoozed,
    snoozeEntry,
    init,
  };
})(typeof window !== "undefined" ? window : globalThis);
