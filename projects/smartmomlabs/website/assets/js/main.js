(function () {
  const cfg = window.BLENDAVIT_CONFIG || {};
  const MARKET = "ksa";

  function t(key) {
    const lang = document.documentElement.lang || "ar";
    const pack = window.BLENDAVIT_I18N?.strings?.[lang];
    return pack?.[key] || "";
  }

  function hasCheckoutConfig(variant) {
    const key = variant + "_" + MARKET;
    const urls = cfg.checkoutUrls || {};
    return Boolean(urls[key] || cfg.shopifyStoreUrl);
  }

  function variantControl(variant) {
    return (
      document.querySelector('.variant-tab[data-variant="' + variant + '"], .variant-card[data-variant="' + variant + '"]') ||
      null
    );
  }

  function applyImageAlt(img, key) {
    if (!img || !key) return;
    img.dataset.i18n = key;
    const label = t(key);
    if (label) img.alt = label;
  }

  function syncPdpVariant(variant) {
    const tab = variantControl(variant);
    const imgSrc = tab && (tab.dataset.image || tab.dataset.pack);
    const altKey = tab && tab.dataset.altKey;
    const img = document.getElementById("pdp-image");
    if (img && imgSrc) img.src = imgSrc;
    applyImageAlt(img, altKey);
    const kids = document.getElementById("panel-kids");
    const todd = document.getElementById("panel-toddlers");
    if (kids && todd) {
      const isToddlers = variant === "toddlers";
      kids.hidden = isToddlers;
      todd.hidden = !isToddlers;
    }
  }

  function setActiveVariant(variant) {
    document.querySelectorAll(".variant-tab, .variant-card").forEach((tab) => {
      tab.classList.toggle("active", tab.dataset.variant === variant);
    });
    document.querySelectorAll("[data-reserve-root]").forEach((root) => {
      root.dataset.variant = variant;
      root.dataset.market = MARKET;
    });
    updateHeroFromVariant(variant);
    syncPdpVariant(variant);
    updateReserveLinks();
  }

  function updateHeroFromVariant(variant) {
    const tab = document.querySelector('.variant-tab[data-variant="' + variant + '"]');
    const badge = document.getElementById("hero-age-badge");
    const pack = document.getElementById("hero-pack");
    if (!tab) return;
    if (badge) {
      const min = tab.dataset.ageMin || "4";
      const sub = tab.dataset.ageSublabel || "";
      const labelKey = tab.dataset.ageBadgeKey || (sub ? "badge.toddlers" : "badge.years");
      badge.textContent = "";
      badge.appendChild(document.createTextNode(sub ? `${min}–${sub}` : `${min}+`));
      const span = document.createElement("span");
      span.textContent = t(labelKey);
      badge.appendChild(span);
    }
    if (pack && tab.dataset.pack) pack.src = tab.dataset.pack;
    applyImageAlt(pack, tab.dataset.altKey);
  }

  function initVariantTabs(root) {
    const tabs = root.querySelectorAll(".variant-tab, .variant-card");
    tabs.forEach((tab) => {
      tab.addEventListener("click", () => {
        setActiveVariant(tab.dataset.variant || "kids");
      });
    });
  }

  function updateProductCardLinks() {
    document.querySelectorAll("[data-product-link]").forEach((link) => {
      const variant = link.dataset.variant || "kids";
      link.href = "product.html?variant=" + variant + "&market=" + MARKET;
    });
  }

  function reserveUrl(root) {
    const variant = root.dataset.variant || "kids";
    const key = variant + "_" + MARKET;
    const urls = cfg.checkoutUrls || {};
    if (urls[key]) return urls[key];
    if (cfg.shopifyStoreUrl) return cfg.shopifyStoreUrl.replace(/\/$/, "") + "/cart";
    return "product.html?variant=" + variant + "&market=" + MARKET;
  }

  function syncReserveButtonState(root) {
    const btn = root.querySelector("[data-reserve-btn]");
    if (!btn) return;
    const fine = root.querySelector(".reserve-fine");
    const variant = root.dataset.variant || "kids";
    const isPdp = window.location.pathname.endsWith("product.html");

    btn.dataset.defaultI18n = btn.dataset.defaultI18n || btn.dataset.i18n || "";
    if (fine) fine.dataset.defaultI18n = fine.dataset.defaultI18n || fine.dataset.i18n || "";

    if (isPdp && !hasCheckoutConfig(variant)) {
      btn.href = "#";
      btn.dataset.i18n = "pdp.cta.pending";
      btn.textContent = t("pdp.cta.pending") || btn.textContent;
      btn.setAttribute("aria-disabled", "true");
      btn.classList.remove("is-loading");
      btn.removeAttribute("aria-busy");
      if (fine) {
        fine.dataset.i18n = "pdp.fine.pending";
        fine.textContent = t("pdp.fine.pending") || fine.textContent;
      }
      return;
    }

    btn.href = reserveUrl(root);
    btn.dataset.i18n = btn.dataset.defaultI18n;
    btn.textContent = t(btn.dataset.defaultI18n) || btn.textContent;
    btn.removeAttribute("aria-disabled");
    if (fine) {
      fine.dataset.i18n = fine.dataset.defaultI18n;
      fine.textContent = t(fine.dataset.defaultI18n) || fine.textContent;
    }
  }

  function updateReserveLinks() {
    document.querySelectorAll("[data-reserve-root]").forEach((root) => {
      syncReserveButtonState(root);
    });
    updateProductCardLinks();
  }

  function setBtnLoading(btn) {
    btn.classList.add("is-loading");
    btn.setAttribute("aria-busy", "true");
  }

  function initReserveButtons() {
    document.querySelectorAll("[data-reserve-root]").forEach((root) => {
      root.dataset.market = MARKET;
      initVariantTabs(root);
      const btn = root.querySelector("[data-reserve-btn]");
      if (btn) {
        btn.addEventListener("click", (event) => {
          syncReserveButtonState(root);
          if (btn.getAttribute("aria-disabled") === "true") {
            event.preventDefault();
            return;
          }
          btn.href = reserveUrl(root);
          setBtnLoading(btn);
        });
        syncReserveButtonState(root);
      }
    });
    document.querySelectorAll("a.btn-gold[href]").forEach((btn) => {
      if (btn.hasAttribute("data-reserve-btn")) return;
      btn.addEventListener("click", () => setBtnLoading(btn));
    });
    document.querySelectorAll(".hero-variant-pick").forEach((root) => initVariantTabs(root));
  }

  function initQueryParams() {
    const params = new URLSearchParams(window.location.search);
    const variant = params.get("variant");
    if (!variant) return;
    setActiveVariant(variant);
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

  document.addEventListener("DOMContentLoaded", () => {
    if (window.BLENDAVIT_I18N) window.BLENDAVIT_I18N.init();
    initReserveButtons();
    initMobileNav();
    initQueryParams();
    const activeVariant =
      document.querySelector(".variant-tab.active, .variant-card.active")?.dataset.variant || "kids";
    updateHeroFromVariant(activeVariant);
    syncPdpVariant(activeVariant);
    updateReserveLinks();
  });

  document.addEventListener("blendavit:lang", () => {
    const active =
      document.querySelector(".variant-tab.active, .variant-card.active")?.dataset.variant || "kids";
    updateHeroFromVariant(active);
  });
})();
