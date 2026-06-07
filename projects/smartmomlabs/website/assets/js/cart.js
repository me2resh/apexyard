/**
 * Local cart state — persists to localStorage; used when checkoutEnabled is false
 * or before Shopify cart handoff when checkoutEnabled is true.
 */
(function (root) {
  const STORAGE_KEY = "blendavit-cart-v1";

  const PRODUCT_META = {
    toddlers: {
      titleKey: "card.t.title",
      image:
        "assets/images/WhatsApp_Image_2026-06-02_at_15.33.29__1_-311c9c0f-d5cc-43dc-a74a-3c9c6c2ce54b.png",
      priceKey: "toddlers_ksa",
    },
    kids: {
      titleKey: "card.k.title",
      image:
        "assets/images/WhatsApp_Image_2026-06-02_at_15.33.29-0ef57a1c-28be-4ac3-8c8d-68b498609c95.png",
      priceKey: "kids_ksa",
    },
  };

  function cfg() {
    return root.BLENDAVIT_CONFIG || {};
  }

  let memoryCart = null;

  function persistenceAllowed() {
    const consent = root.BLENDAVIT_CONSENT;
    if (!consent) return true;
    return consent.allows("cart");
  }

  function read() {
    if (!persistenceAllowed()) {
      return memoryCart ? { items: memoryCart.items.slice() } : { items: [] };
    }
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return { items: [] };
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed.items) ? parsed : { items: [] };
    } catch (_) {
      return { items: [] };
    }
  }

  function write(cart) {
    if (!persistenceAllowed()) {
      memoryCart = { items: cart.items.map((i) => ({ ...i })) };
    } else {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(cart));
      } catch (_) {}
    }
    document.dispatchEvent(
      new CustomEvent("blendavit:cart-change", { detail: { cart } })
    );
  }

  function unitPrice(variant) {
    const prices = cfg().prices || {};
    const meta = PRODUCT_META[variant];
    if (!meta) return 0;
    const base = Number(prices[meta.priceKey]) || 0;
    if (!base) return 0;
    if (root.BLENDAVIT_COMMERCE?.hasDiscount()) {
      const pct = Number(cfg().discountPercent) || 0;
      return Math.round(base * (1 - pct / 100) * 100) / 100;
    }
    return base;
  }

  function comparePrice(variant) {
    const prices = cfg().prices || {};
    const meta = PRODUCT_META[variant];
    if (!meta) return 0;
    return Number(prices[meta.priceKey]) || 0;
  }

  function add(variant, qty) {
    const amount = Math.max(1, qty || 1);
    const cart = read();
    const existing = cart.items.find((i) => i.variant === variant);
    if (existing) {
      existing.qty += amount;
    } else {
      cart.items.push({ variant, qty: amount });
    }
    write(cart);
    return cart;
  }

  function setQty(variant, qty) {
    const cart = read();
    const item = cart.items.find((i) => i.variant === variant);
    if (!item) return cart;
    if (qty <= 0) {
      cart.items = cart.items.filter((i) => i.variant !== variant);
    } else {
      item.qty = qty;
    }
    write(cart);
    return cart;
  }

  function remove(variant) {
    return setQty(variant, 0);
  }

  function clear() {
    write({ items: [] });
    return { items: [] };
  }

  function count(cart) {
    const c = cart || read();
    return c.items.reduce((sum, i) => sum + i.qty, 0);
  }

  function subtotal(cart) {
    const c = cart || read();
    return c.items.reduce((sum, i) => sum + unitPrice(i.variant) * i.qty, 0);
  }

  function lineItems(cart) {
    const c = cart || read();
    return c.items.map((i) => ({
      ...i,
      meta: PRODUCT_META[i.variant],
      unitPrice: unitPrice(i.variant),
      comparePrice: comparePrice(i.variant),
      lineTotal: unitPrice(i.variant) * i.qty,
    }));
  }

  if (typeof document !== "undefined") {
    document.addEventListener("blendavit:consent", (e) => {
      if (e.detail?.value === "all" && memoryCart?.items?.length) {
        write(memoryCart);
        memoryCart = null;
      }
    });
  }

  root.BLENDAVIT_CART = {
    PRODUCT_META,
    read,
    add,
    setQty,
    remove,
    clear,
    count,
    subtotal,
    lineItems,
    unitPrice,
    comparePrice,
  };
})(typeof window !== "undefined" ? window : globalThis);
