/**
 * blendavit scroll reveals — Impeccable animate (product register).
 * transform + opacity only; respects prefers-reduced-motion.
 */
(function () {
  const STAGGER_MS = 72;
  const REVEAL_SELECTORS = [
    ".section-head",
    ".product-card",
    ".expert-card",
    ".trust-chips__item",
    ".science-stat",
    ".compare-panel",
    ".step-rail-item",
    ".timeline__item",
    ".benefit",
    ".benefit-strip",
    ".review-card",
    ".faq-item",
    ".preorder-cta__inner",
    ".newsletter-bar__inner",
    ".variant-card",
    ".pdp-gallery",
    ".pdp-buy-box",
  ].join(",");

  function prefersReducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  function revealElement(el, delayMs) {
    el.classList.add("motion-reveal");
    if (delayMs > 0) el.style.setProperty("--motion-delay", delayMs + "ms");
  }

  function collectRevealTargets() {
    const seen = new Set();
    const targets = [];
    document.querySelectorAll("main section").forEach((section) => {
      let delay = 0;
      section.querySelectorAll(REVEAL_SELECTORS).forEach((el) => {
        if (seen.has(el)) return;
        seen.add(el);
        revealElement(el, delay);
        delay += STAGGER_MS;
        targets.push(el);
      });
    });
    return targets;
  }

  function initScrollReveal() {
    if (prefersReducedMotion()) {
      document.querySelectorAll(".motion-reveal").forEach((el) => {
        el.classList.add("is-visible");
      });
      return;
    }

    const targets = collectRevealTargets();
    if (!targets.length || !("IntersectionObserver" in window)) {
      targets.forEach((el) => el.classList.add("is-visible"));
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      { root: null, rootMargin: "0px 0px -8% 0px", threshold: 0.12 }
    );

    targets.forEach((el) => observer.observe(el));
  }

  window.BLENDAVIT_MOTION = { init: initScrollReveal };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initScrollReveal);
  } else {
    initScrollReveal();
  }
})();
