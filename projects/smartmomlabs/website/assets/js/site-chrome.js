/**
 * Sticky promo dismiss + mobile shop bar visibility.
 */
(function () {
  const PROMO_KEY = "blendavit-promo-dismissed";

  function syncPromoHeight() {
    const bar = document.querySelector("[data-promo-bar]");
    const root = document.documentElement;
    if (!bar || document.body.classList.contains("promo-dismissed")) {
      root.style.setProperty("--promo-h", "0px");
      return;
    }
    root.style.setProperty("--promo-h", `${bar.offsetHeight}px`);
  }

  function initPromoBar() {
    const bar = document.querySelector("[data-promo-bar]");
    if (!bar) {
      syncPromoHeight();
      return;
    }

    if (sessionStorage.getItem(PROMO_KEY) === "1") {
      document.body.classList.add("promo-dismissed");
      syncPromoHeight();
      return;
    }

    const dismiss = () => {
      document.body.classList.add("promo-dismissed");
      sessionStorage.setItem(PROMO_KEY, "1");
      syncPromoHeight();
    };

    bar.querySelector("[data-promo-dismiss]")?.addEventListener("click", dismiss);

    if ("ResizeObserver" in window) {
      const ro = new ResizeObserver(() => syncPromoHeight());
      ro.observe(bar);
    }
    syncPromoHeight();
    document.addEventListener("blendavit:lang", syncPromoHeight);
  }

  function initShopBar() {
    const bar = document.querySelector("[data-shop-bar]");
    const hero = document.querySelector(".hero--ella, .hero, .page-pdp .pdp-buy-box");
    if (!bar || !hero || !("IntersectionObserver" in window)) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        const show = !entry.isIntersecting;
        bar.classList.toggle("is-visible", show);
        bar.setAttribute("aria-hidden", show ? "false" : "true");
      },
      { root: null, threshold: 0, rootMargin: "0px" }
    );
    observer.observe(hero);
  }

  function init() {
    initPromoBar();
    initShopBar();
  }

  function scrollToNewsletter() {
    const section = document.getElementById("newsletter");
    if (!section) return false;
    section.scrollIntoView({ behavior: "smooth", block: "start" });
    const email = section.querySelector('input[type="email"]');
    if (email) window.setTimeout(() => email.focus(), 400);
    return true;
  }

  window.BLENDAVIT_SITE_CHROME = { scrollToNewsletter };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
