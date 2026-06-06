/**
 * Purchase path — checkout vs waitlist resolution (pure cfg + formula + surface).
 * Interface: createResolver(cfg).resolve(formula, surface) → action object.
 */
(function (root) {
  const FORMULAS = ["toddlers", "kids"];
  const SURFACES = ["home", "pdp"];

  function variantKey(formula, market) {
    return formula + "_" + market;
  }

  function createResolver(cfg) {
    const config = cfg || {};
    const market = config.market || "ksa";

    function hasCheckout(formula) {
      const key = variantKey(formula, market);
      const urls = config.checkoutUrls || {};
      return Boolean(urls[key] || config.shopifyStoreUrl);
    }

    function hasExternalWaitlist(formula) {
      const key = variantKey(formula, market);
      const urls = config.waitlistUrls || {};
      return Boolean(urls[key] || config.waitlistUrl);
    }

    function hasAnyCheckout() {
      const urls = config.checkoutUrls || {};
      return Boolean(
        config.shopifyStoreUrl || urls.toddlers_ksa || urls.kids_ksa
      );
    }

    function checkoutHref(formula) {
      const key = variantKey(formula, market);
      const checkout = config.checkoutUrls || {};
      if (checkout[key]) return checkout[key];
      if (config.shopifyStoreUrl) {
        return config.shopifyStoreUrl.replace(/\/$/, "") + "/cart";
      }
      return null;
    }

    function waitlistHref(formula) {
      const key = variantKey(formula, market);
      const waitlist = config.waitlistUrls || {};
      if (waitlist[key]) return waitlist[key];
      if (config.waitlistUrl) {
        const base = config.waitlistUrl;
        const sep = base.includes("?") ? "&" : "?";
        return base + sep + "variant=" + encodeURIComponent(formula);
      }
      return null;
    }

    function onSiteWaitlistHref(formula, surface) {
      if (surface === "pdp") {
        return "index.html?variant=" + encodeURIComponent(formula) + "#waitlist";
      }
      return "#waitlist";
    }

    function labelKey(formula) {
      if (hasCheckout(formula)) {
        return config.depositMode ? "buy.deposit" : "buy.checkout";
      }
      return "buy.waitlist";
    }

    function fineKey(formula) {
      return hasCheckout(formula) ? "pdp.fine" : "waitlist.fine";
    }

    /**
     * @param {'toddlers'|'kids'} formula
     * @param {'home'|'pdp'} surface
     * @returns {{ behavior: string, href: string, labelKey: string, fineKey: string, external: boolean, formula: string }}
     */
    function resolve(formula, surface) {
      const f = FORMULAS.includes(formula) ? formula : "kids";
      const checkout = checkoutHref(f);
      if (checkout) {
        return {
          behavior: "checkout",
          href: checkout,
          labelKey: labelKey(f),
          fineKey: fineKey(f),
          external: true,
          formula: f,
        };
      }
      const externalWaitlist = waitlistHref(f);
      if (externalWaitlist) {
        return {
          behavior: "external-waitlist",
          href: externalWaitlist,
          labelKey: "buy.waitlist",
          fineKey: "waitlist.fine",
          external: true,
          formula: f,
        };
      }
      return {
        behavior: "on-site-waitlist",
        href: onSiteWaitlistHref(f, surface),
        labelKey: "buy.waitlist",
        fineKey: "waitlist.fine",
        external: false,
        formula: f,
      };
    }

    return {
      market,
      hasCheckout,
      hasExternalWaitlist,
      hasAnyCheckout,
      resolve,
      labelKey,
      fineKey,
    };
  }

  let active = null;

  root.BLENDAVIT_PURCHASE = {
    FORMULAS,
    SURFACES,
    variantKey,
    createResolver,
    getResolver() {
      if (!active) {
        active = createResolver(root.BLENDAVIT_CONFIG || {});
      }
      return active;
    },
    resetResolver() {
      active = null;
    },
  };
})(typeof window !== "undefined" ? window : globalThis);
