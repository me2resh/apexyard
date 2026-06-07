(function () {
  const purchase = () => window.BLENDAVIT_PURCHASE.getResolver();
  const formula = () => window.BLENDAVIT_FORMULA;

  function t(key) {
    const lang = document.documentElement.lang || "ar";
    const pack = window.BLENDAVIT_I18N?.strings?.[lang];
    return pack?.[key] || "";
  }

  function labelForAction(action) {
    return t(action.labelKey) || t("pdp.cta");
  }

  function variantMeta(formulaId) {
    const card = document.querySelector(
      '.variant-card[data-variant="' + formulaId + '"]'
    );
    return {
      pack: card?.dataset.pack || card?.dataset.image,
      altKey: card?.dataset.altKey,
    };
  }

  function applyImageAlt(img, key) {
    if (!img || !key) return;
    img.dataset.i18n = key;
    const label = t(key);
    if (label) img.alt = label;
  }

  function syncPdpPresentation(formulaId) {
    const meta = variantMeta(formulaId);
    const img = document.getElementById("pdp-image");
    if (img && meta.pack) img.src = meta.pack;
    applyImageAlt(img, meta.altKey);
    const kids = document.getElementById("panel-kids");
    const todd = document.getElementById("panel-toddlers");
    if (kids && todd) {
      const isToddlers = formulaId === "toddlers";
      kids.hidden = isToddlers;
      todd.hidden = !isToddlers;
    }
  }

  function syncFormulaDom(formulaId) {
    document.querySelectorAll(".variant-card").forEach((el) => {
      el.classList.toggle("active", el.dataset.variant === formulaId);
    });
    const pdpRoot = document.querySelector(".page-pdp [data-reserve-root]");
    if (pdpRoot) {
      pdpRoot.dataset.variant = formulaId;
      pdpRoot.dataset.market = purchase().market;
    }
    const input = document.getElementById("waitlist-variant");
    const label = document.querySelector("[data-waitlist-variant-label]");
    if (input) input.value = formulaId;
    if (label) {
      const key = formulaId === "toddlers" ? "card.t.title" : "card.k.title";
      label.textContent = t(key);
    }
  }

  function applyActionToButton(btn, action) {
    btn.href = action.href;
    btn.textContent = labelForAction(action);
    btn.removeAttribute("aria-disabled");
    btn.classList.remove("is-loading");
    btn.removeAttribute("aria-busy");

    if (action.behavior === "on-site-waitlist") {
      btn.dataset.waitlistVariant = action.formula;
    } else {
      btn.removeAttribute("data-waitlist-variant");
    }

    if (action.external) {
      btn.setAttribute("target", "_blank");
      btn.setAttribute("rel", "noopener noreferrer");
    } else {
      btn.removeAttribute("target");
      btn.removeAttribute("rel");
    }
  }

  function commerceActive() {
    return window.BLENDAVIT_COMMERCE?.isCommerceMode?.() === true;
  }

  function syncBuyButtons() {
    if (commerceActive()) return;

    const resolver = purchase();
    document.querySelectorAll("[data-buy-btn]").forEach((btn) => {
      const formulaId = btn.dataset.variant || formula().get();
      applyActionToButton(btn, resolver.resolve(formulaId, "home"));
    });

    const pdpRoot = document.querySelector(".page-pdp [data-reserve-root]");
    const pdpBtn = pdpRoot?.querySelector("[data-reserve-btn]");
    const fine = pdpRoot?.querySelector(".reserve-fine");
    if (pdpBtn && pdpRoot) {
      const formulaId = pdpRoot.dataset.variant || formula().get();
      const action = resolver.resolve(formulaId, "pdp");
      applyActionToButton(pdpBtn, action);
      if (fine) {
        fine.dataset.i18n = action.fineKey;
        fine.textContent = t(action.fineKey) || fine.textContent;
      }
    }

    const preorderSection = document.getElementById("preorder");
    if (preorderSection) {
      preorderSection.hidden = resolver.hasAnyCheckout();
    }
  }

  function openOnSiteWaitlist(formulaId) {
    formula().set(formulaId);
    const section = document.getElementById("preorder");
    if (!section) return;
    section.scrollIntoView({ behavior: "smooth", block: "start" });
    const email = section.querySelector('input[type="email"]');
    if (email) window.setTimeout(() => email.focus(), 400);
  }

  function handlePurchaseClick(event, btn, surface) {
    const formulaId =
      btn.dataset.variant || btn.dataset.waitlistVariant || formula().get();
    const action = purchase().resolve(formulaId, surface);

    if (action.behavior === "on-site-waitlist") {
      event.preventDefault();
      if (surface === "pdp") {
        window.location.href = action.href;
        return;
      }
      openOnSiteWaitlist(action.formula);
      return;
    }

    btn.classList.add("is-loading");
    btn.setAttribute("aria-busy", "true");
  }

  function syncPdpPriceBlock(formulaId) {
    const block = document.querySelector("[data-pdp-price-block]");
    const btn = document.querySelector("[data-pdp-add]");
    if (block) block.dataset.variant = formulaId;
    if (btn) btn.dataset.variant = formulaId;
    document.dispatchEvent(new CustomEvent("blendavit:discount-unlocked"));
  }

  function onFormulaChange(formulaId) {
    syncFormulaDom(formulaId);
    syncPdpPresentation(formulaId);
    syncPdpPriceBlock(formulaId);
    syncBuyButtons();
  }

  function initVariantCards() {
    const root = document.querySelector(".page-pdp [data-reserve-root]");
    if (!root) return;
    root.querySelectorAll(".variant-card").forEach((card) => {
      card.addEventListener("click", () => {
        formula().set(card.dataset.variant || formula().DEFAULT);
      });
    });
  }

  function initBuyButtons() {
    if (!commerceActive()) {
      document.querySelectorAll("[data-buy-btn]").forEach((btn) => {
        btn.addEventListener("click", (event) => handlePurchaseClick(event, btn, "home"));
      });

      const pdpBtn = document.querySelector("[data-reserve-btn]");
      if (pdpBtn) {
        pdpBtn.addEventListener("click", (event) =>
          handlePurchaseClick(event, pdpBtn, "pdp")
        );
      }
    }
    syncBuyButtons();
  }

  function initWaitlistForm() {
    const form = document.querySelector("[data-waitlist-form]");
    if (!form) return;
    const action = window.BLENDAVIT_CONFIG?.waitlistFormAction;
    if (action) form.action = action;

    form.addEventListener("submit", (event) => {
      if (!action) {
        event.preventDefault();
        const email = form.querySelector('input[type="email"]');
        if (email && !email.value) {
          email.focus();
          return;
        }
        const note = form.querySelector("[data-waitlist-config-hint]");
        if (note) note.hidden = false;
      }
    });
  }

  function initMobileNav() {
    const dialog = document.getElementById("nav-menu");
    const openBtn = document.querySelector("[data-nav-open]");
    if (!dialog || !openBtn) return;
    openBtn.addEventListener("click", () => {
      dialog.showModal();
      openBtn.setAttribute("aria-expanded", "true");
    });
    dialog.querySelectorAll("[data-nav-close]").forEach((el) => {
      el.addEventListener("click", () => {
        dialog.close();
        openBtn.setAttribute("aria-expanded", "false");
      });
    });
    dialog.addEventListener("close", () => openBtn.setAttribute("aria-expanded", "false"));
  }

  function initFromUrl() {
    formula().fromQueryString(window.location.search);
    const hash = window.location.hash;
    if (
      (hash === "#preorder" || hash === "#waitlist") &&
      document.getElementById("preorder")
    ) {
      window.setTimeout(() => openOnSiteWaitlist(formula().get()), 300);
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    if (window.BLENDAVIT_CONSENT) window.BLENDAVIT_CONSENT.init();
    if (window.BLENDAVIT_CREDENTIAL_RAIL) window.BLENDAVIT_CREDENTIAL_RAIL.mountAll();
    if (window.BLENDAVIT_CONFIG_VALIDATE) window.BLENDAVIT_CONFIG_VALIDATE.run();
    window.BLENDAVIT_PURCHASE?.resetResolver();
    if (window.BLENDAVIT_I18N) window.BLENDAVIT_I18N.init();
    if (window.BLENDAVIT_COMMERCE) window.BLENDAVIT_COMMERCE.init();
    formula().onChange(onFormulaChange);
    initFromUrl();
    initVariantCards();
    initBuyButtons();
    initWaitlistForm();
    initMobileNav();
    onFormulaChange(formula().get());
  });

  document.addEventListener("blendavit:lang", () => {
    onFormulaChange(formula().get());
  });
})();
