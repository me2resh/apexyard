/**
 * EllaOla-style commerce UI — entry offer, cart drawer, restock modal, toast.
 * Controlled by BLENDAVIT_CONFIG.checkoutEnabled.
 */
(function (root) {
  const DISCOUNT_KEY = "blendavit_discount_unlocked";
  const EMAIL_KEY = "blendavit_subscriber_email";
  const ENTRY_SNOOZE_KEY = "blendavit_entry_snooze";

  function cfg() {
    return root.BLENDAVIT_CONFIG || {};
  }

  function t(key) {
    const lang = document.documentElement.lang || "ar";
    return root.BLENDAVIT_I18N?.strings?.[lang]?.[key] || "";
  }

  function isCommerceMode() {
    return cfg().checkoutEnabled === false;
  }

  function hasDiscount() {
    try {
      return localStorage.getItem(DISCOUNT_KEY) === "1";
    } catch (_) {
      return false;
    }
  }

  function formatMoney(amount) {
    const lang = document.documentElement.lang || "ar";
    const n = Number(amount);
    if (!n) return "";
    if (lang === "ar") return n.toFixed(0) + " ر.س";
    return "SAR " + n.toFixed(0);
  }

  function unlockDiscount(email) {
    try {
      localStorage.setItem(DISCOUNT_KEY, "1");
      if (email) localStorage.setItem(EMAIL_KEY, email);
    } catch (_) {}
    document.dispatchEvent(new CustomEvent("blendavit:discount-unlocked"));
    syncDiscountUi();
  }

  function syncDiscountUi() {
    const on = hasDiscount();
    document.querySelectorAll("[data-discount-badge]").forEach((el) => {
      el.hidden = !on;
    });
    document.querySelectorAll("[data-price-block]").forEach((block) => {
      const variant = block.dataset.variant;
      if (!variant || !root.BLENDAVIT_CART) return;
      const compare = root.BLENDAVIT_CART.comparePrice(variant);
      const current = root.BLENDAVIT_CART.unitPrice(variant);
      const compareEl = block.querySelector("[data-price-compare]");
      const currentEl = block.querySelector("[data-price-current]");
      if (compareEl) {
        compareEl.textContent = on && compare ? formatMoney(compare) : "";
        compareEl.hidden = !(on && compare);
      }
      if (currentEl) {
        const display = on ? current : compare;
        currentEl.textContent = display ? formatMoney(display) : "";
      }
    });
    renderCart();
  }

  function trapFocus(dialog, onClose) {
    const focusable = dialog.querySelectorAll(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    );
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    function onKey(e) {
      if (e.key === "Escape") {
        dialog.close();
        onClose?.();
        return;
      }
      if (e.key !== "Tab" || !focusable.length) return;
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
    dialog.addEventListener("keydown", onKey);
    return () => dialog.removeEventListener("keydown", onKey);
  }

  function openDialog(dialog) {
    if (!dialog || dialog.open) return;
    const release = trapFocus(dialog, () => release?.());
    dialog.showModal();
    const focusTarget =
      dialog.querySelector("[autofocus]") ||
      dialog.querySelector("input, button, [href]");
    focusTarget?.focus();
  }

  function showToast(variant) {
    const toast = document.querySelector("[data-cart-toast]");
    if (!toast) return;
    const titleKey =
      variant === "toddlers" ? "card.t.title" : "card.k.title";
    const msg = document.querySelector("[data-cart-toast-msg]");
    if (msg) msg.textContent = t("commerce.toast.added").replace("{product}", t(titleKey));
    toast.hidden = false;
    clearTimeout(showToast._timer);
    showToast._timer = setTimeout(() => {
      toast.hidden = true;
    }, 3200);
  }

  function renderCart() {
    const cart = root.BLENDAVIT_CART;
    if (!cart) return;
    const lines = cart.lineItems();
    const list = document.querySelector("[data-cart-lines]");
    const empty = document.querySelector("[data-cart-empty]");
    const footer = document.querySelector("[data-cart-footer]");
    const subtotalEl = document.querySelector("[data-cart-subtotal]");
    const countEl = document.querySelector("[data-cart-count]");

    const totalQty = cart.count();
    if (countEl) {
      countEl.textContent = String(totalQty);
      countEl.hidden = totalQty === 0;
    }

    if (!list) return;
    list.innerHTML = "";

    if (!lines.length) {
      if (empty) empty.hidden = false;
      if (footer) footer.hidden = true;
      if (subtotalEl) subtotalEl.textContent = "";
      return;
    }

    if (empty) empty.hidden = true;
    if (footer) footer.hidden = false;

    lines.forEach((line) => {
      const li = document.createElement("li");
      li.className = "cart-line";
      li.dataset.variant = line.variant;
      const title = t(line.meta.titleKey);
      li.innerHTML =
        '<img class="cart-line__img" src="' +
        line.meta.image +
        '" alt="" width="72" height="72" />' +
        '<div class="cart-line__body">' +
        '<p class="cart-line__title">' +
        title +
        "</p>" +
        '<p class="cart-line__price">' +
        formatMoney(line.unitPrice) +
        "</p>" +
        '<div class="cart-line__qty">' +
        '<button type="button" class="cart-qty-btn" data-cart-dec aria-label="-">−</button>' +
        '<span data-cart-qty>' +
        line.qty +
        "</span>" +
        '<button type="button" class="cart-qty-btn" data-cart-inc aria-label="+">+</button>' +
        "</div>" +
        "</div>" +
        '<button type="button" class="cart-line__remove" data-cart-remove aria-label="' +
        t("commerce.cart.remove") +
        '">×</button>';
      list.appendChild(li);
    });

    if (subtotalEl) subtotalEl.textContent = formatMoney(cart.subtotal());

    list.querySelectorAll("[data-cart-inc]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const v = btn.closest(".cart-line")?.dataset.variant;
        const item = lines.find((l) => l.variant === v);
        if (v && item) cart.setQty(v, item.qty + 1);
      });
    });
    list.querySelectorAll("[data-cart-dec]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const v = btn.closest(".cart-line")?.dataset.variant;
        const item = lines.find((l) => l.variant === v);
        if (v && item) cart.setQty(v, item.qty - 1);
      });
    });
    list.querySelectorAll("[data-cart-remove]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const v = btn.closest(".cart-line")?.dataset.variant;
        if (v) cart.remove(v);
      });
    });
  }

  function openCartDrawer() {
    renderCart();
    openDialog(document.querySelector("[data-cart-drawer]"));
  }

  function addToCart(variant) {
    if (!root.BLENDAVIT_CART) return;
    root.BLENDAVIT_CART.add(variant, 1);
    showToast(variant);
    openCartDrawer();
  }

  function handleCheckout() {
    const config = cfg();
    const resolver = root.BLENDAVIT_PURCHASE?.getResolver();
    const cart = root.BLENDAVIT_CART?.read();
    if (!cart?.items?.length) return;
    const firstVariant = cart.items[0].variant || "kids";

    if (config.checkoutEnabled && resolver?.hasCheckout(firstVariant)) {
      const action = resolver.resolve(firstVariant, "home");
      if (action.href) {
        window.location.href = action.href;
        return;
      }
    }

    const restock = document.querySelector("[data-restock-modal]");
    const drawer = document.querySelector("[data-cart-drawer]");
    drawer?.close();
    if (restock) {
      openDialog(restock);
    }
  }

  function proceedToPreorder() {
    const restock = document.querySelector("[data-restock-modal]");
    restock?.close();
    const section = document.getElementById("preorder");
    if (section) {
      if (!window.location.pathname.endsWith("index.html") && !window.location.pathname.endsWith("/")) {
        window.location.href = "index.html#preorder";
        return;
      }
      section.scrollIntoView({ behavior: "smooth", block: "start" });
      const email = section.querySelector('input[type="email"]');
      if (email) setTimeout(() => email.focus(), 400);
    }
  }

  function initEntryModal() {
    const dialog = document.querySelector("[data-entry-modal]");
    if (!dialog || hasDiscount()) return;

    try {
      if (sessionStorage.getItem(ENTRY_SNOOZE_KEY) === "1") return;
    } catch (_) {}

    const delay = Number(cfg().emailCaptureDelayMs) || 2000;
    setTimeout(() => {
      if (!dialog.open) openDialog(dialog);
    }, delay);

    dialog.querySelector("[data-entry-dismiss]")?.addEventListener("click", () => {
      try {
        sessionStorage.setItem(ENTRY_SNOOZE_KEY, "1");
      } catch (_) {}
      dialog.close();
    });

    dialog.querySelector("[data-entry-form]")?.addEventListener("submit", (e) => {
      e.preventDefault();
      const email = dialog.querySelector('input[type="email"]')?.value?.trim();
      if (!email) return;
      unlockDiscount(email);
      const codeEl = dialog.querySelector("[data-entry-code]");
      if (codeEl) codeEl.textContent = cfg().discountCode || "FIRSTBLEND20";
      dialog.querySelector("[data-entry-success]")?.removeAttribute("hidden");
      dialog.querySelector("[data-entry-form-wrap]")?.setAttribute("hidden", "");
      setTimeout(() => dialog.close(), 2200);
    });
  }

  function initCartUi() {
    document.querySelectorAll("[data-cart-open]").forEach((btn) => {
      btn.addEventListener("click", () => openCartDrawer());
    });

    document.querySelector("[data-cart-close]")?.addEventListener("click", () => {
      document.querySelector("[data-cart-drawer]")?.close();
    });

    document.querySelector("[data-cart-checkout]")?.addEventListener("click", handleCheckout);

    document.querySelector("[data-restock-continue]")?.addEventListener("click", proceedToPreorder);

    document.querySelector("[data-restock-close]")?.addEventListener("click", () => {
      document.querySelector("[data-restock-modal]")?.close();
    });

    document.addEventListener("blendavit:cart-change", renderCart);
    document.addEventListener("blendavit:discount-unlocked", syncDiscountUi);
    document.addEventListener("blendavit:lang", syncDiscountUi);

    renderCart();
    syncDiscountUi();
  }

  function initAddToCartButtons() {
    document.querySelectorAll("[data-add-to-cart]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const variant = btn.dataset.variant || btn.dataset.waitlistVariant || "kids";
        addToCart(variant);
      });
    });
  }

  function syncCommerceLabels() {
    if (!isCommerceMode()) return;
    const label = t("commerce.addToCart");
    document.querySelectorAll("[data-add-to-cart]").forEach((btn) => {
      btn.textContent = label;
    });
    const checkoutBtn = document.querySelector("[data-cart-checkout]");
    if (checkoutBtn) {
      checkoutBtn.textContent = cfg().checkoutEnabled
        ? t("commerce.cart.checkoutLive")
        : t("commerce.cart.checkout");
    }
  }

  function init() {
    if (!isCommerceMode() && !root.BLENDAVIT_CART) return;
    initEntryModal();
    initCartUi();
    initAddToCartButtons();
    syncCommerceLabels();
    document.addEventListener("blendavit:lang", syncCommerceLabels);
  }

  root.BLENDAVIT_COMMERCE = {
    init,
    hasDiscount,
    unlockDiscount,
    addToCart,
    openCartDrawer,
    isCommerceMode,
    formatMoney,
  };
})(typeof window !== "undefined" ? window : globalThis);
