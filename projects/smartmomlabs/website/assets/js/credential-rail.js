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
    sidebar: {
      listClass: "trust-rail trust-rail--sidebar",
      stampSize: 40,
    },
    inline: {
      listClass: "trust-rail trust-rail--inline",
      stampSize: 56,
    },
  };

  function stampHtml(stamp, size) {
    const src = ICON_DIR + stamp.file;
    return (
      '<li class="trust-rail__item">' +
      '<img class="trust-rail__stamp" src="' +
      src +
      '" alt="" width="' +
      size +
      '" height="' +
      size +
      '" decoding="async" aria-hidden="true" />' +
      '<span class="trust-rail__label" data-i18n="' +
      stamp.labelKey +
      '"></span>' +
      "</li>"
    );
  }

  function mount(el) {
    const layoutKey = el.getAttribute("data-trust-rail-mount") || "inline";
    const layout = LAYOUTS[layoutKey] || LAYOUTS.inline;
    const items = STAMPS.map((s) => stampHtml(s, layout.stampSize)).join("");
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
