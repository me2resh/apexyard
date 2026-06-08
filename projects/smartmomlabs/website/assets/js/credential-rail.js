/**
 * Credential rail — single source for stamp order, icons, and layouts.
 */
(function (root) {
  const ICON_DIR = "assets/icons/trust/";

  /** Canonical stamp order (SFDA first). */
  const STAMPS = [
    { id: "sfda", file: "stamp-sfda.svg", labelKey: "trust.sfda.short" },
    { id: "sugar", file: "stamp-sugar.svg", labelKey: "trust.sugar" },
    { id: "nutrients", file: "stamp-nutrients.svg", labelKey: "trust.nutrients" },
    { id: "halal", file: "stamp-halal.svg", labelKey: "trust.halal" },
    { id: "sachet", file: "stamp-sachet.svg", labelKey: "trust.powder" },
  ];

  const LAYOUTS = {
    hero: {
      listClass: "trust-rail trust-rail--hero",
      itemClass: "trust-rail__item",
      stampClass: "trust-rail__stamp",
      labelClass: "trust-rail__label",
      stampSize: 48,
    },
    chips: {
      listClass: "trust-chips",
      itemClass: "trust-chips__item",
      stampClass: "trust-chips__stamp",
      labelClass: "trust-chips__label",
      stampSize: 28,
    },
    pdp: {
      listClass: "trust-rail trust-rail--pdp",
      itemClass: "trust-rail__item",
      stampClass: "trust-rail__stamp",
      labelClass: "trust-rail__label",
      stampSize: 36,
    },
    inline: {
      listClass: "trust-rail trust-rail--inline",
      itemClass: "trust-rail__item",
      stampClass: "trust-rail__stamp",
      labelClass: "trust-rail__label",
      stampSize: 56,
    },
  };

  function stampHtml(stamp, layout) {
    const size = layout.stampSize;
    const itemClass = layout.itemClass || "trust-rail__item";
    const stampClass = layout.stampClass || "trust-rail__stamp";
    const labelClass = layout.labelClass || "trust-rail__label";
    const src = ICON_DIR + stamp.file;
    return (
      '<li class="' +
      itemClass +
      '">' +
      '<img class="' +
      stampClass +
      '" src="' +
      src +
      '" alt="" width="' +
      size +
      '" height="' +
      size +
      '" decoding="async" aria-hidden="true" />' +
      '<span class="' +
      labelClass +
      '" data-i18n="' +
      stamp.labelKey +
      '"></span>' +
      "</li>"
    );
  }

  function mount(el) {
    const layoutKey = el.getAttribute("data-trust-rail-mount") || "inline";
    const layout = LAYOUTS[layoutKey] || LAYOUTS.inline;
    const items = STAMPS.map((s) => stampHtml(s, layout)).join("");
    el.innerHTML =
      '<ul class="' +
      layout.listClass +
      '" data-i18n-aria-label="trust.rail.label">' +
      items +
      "</ul>";
  }

  function mountAll() {
    document.querySelectorAll("[data-trust-rail-mount]").forEach(mount);
  }

  root.BLENDAVIT_CREDENTIAL_RAIL = {
    STAMPS,
    LAYOUTS,
    mount,
    mountAll,
  };
})(typeof window !== "undefined" ? window : globalThis);
