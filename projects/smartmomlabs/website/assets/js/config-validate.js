/**
 * Config validation — logs purchase mode and misconfiguration warnings.
 */
(function (root) {
  function nonEmpty(value) {
    return typeof value === "string" && value.trim().length > 0;
  }

  function isHttpsUrl(value) {
    if (!nonEmpty(value)) return true;
    try {
      return new URL(value.trim()).protocol === "https:";
    } catch (_) {
      return false;
    }
  }

  function validate(cfg) {
    cfg = cfg || {};
    const market = cfg.market || "ksa";
    const checkout = cfg.checkoutUrls || {};
    const waitlist = cfg.waitlistUrls || {};
    const warnings = [];

    const hasCheckout =
      nonEmpty(cfg.shopifyStoreUrl) ||
      nonEmpty(checkout.toddlers_ksa) ||
      nonEmpty(checkout.kids_ksa);

    const hasExternalWaitlist =
      nonEmpty(cfg.waitlistUrl) ||
      nonEmpty(waitlist.toddlers_ksa) ||
      nonEmpty(waitlist.kids_ksa);

    const hasForm = nonEmpty(cfg.waitlistFormAction);
    const hasOnSite = Boolean(
      document.getElementById("preorder") || document.getElementById("waitlist")
    );
    const commerceMode = cfg.checkoutEnabled === false;

    let mode = "waitlist";
    if (commerceMode) mode = "commerce-preorder";
    if (hasCheckout && cfg.checkoutEnabled !== false) mode = "checkout";

    if (hasCheckout && hasExternalWaitlist) {
      warnings.push("Both checkoutUrls and waitlistUrls set — checkout takes priority.");
    }

    if (!commerceMode && !hasCheckout && !hasExternalWaitlist && !hasForm && !hasOnSite) {
      warnings.push("No checkout, waitlist URL, or #preorder form — buyers have no path.");
    }

    if (!hasCheckout && !hasExternalWaitlist && hasOnSite && !hasForm) {
      warnings.push("On-site waitlist only — set waitlistFormAction (e.g. Formspree) to capture emails.");
    }

    if (nonEmpty(cfg.shopifyStoreUrl) && !isHttpsUrl(cfg.shopifyStoreUrl)) {
      warnings.push("shopifyStoreUrl must use https://");
    }
    if (nonEmpty(cfg.waitlistFormAction) && !isHttpsUrl(cfg.waitlistFormAction)) {
      warnings.push("waitlistFormAction must use https://");
    }
    Object.entries(checkout).forEach(([key, url]) => {
      if (nonEmpty(url) && !isHttpsUrl(url)) {
        warnings.push("checkoutUrls." + key + " must use https://");
      }
    });
    Object.entries(waitlist).forEach(([key, url]) => {
      if (nonEmpty(url) && !isHttpsUrl(url)) {
        warnings.push("waitlistUrls." + key + " must use https://");
      }
    });
    if (nonEmpty(cfg.waitlistUrl) && !isHttpsUrl(cfg.waitlistUrl)) {
      warnings.push("waitlistUrl must use https://");
    }

    return { mode, market, warnings, hasCheckout, hasExternalWaitlist, hasForm, hasOnSite };
  }

  function logReport(report) {
    if (typeof console === "undefined") return;
    const log = console.info || console.log;
    log.call(console, "[blendavit] purchase mode:", report.mode, "(" + report.market + ")");
    report.warnings.forEach((w) => {
      (console.warn || log).call(console, "[blendavit] config:", w);
    });
  }

  root.BLENDAVIT_CONFIG_VALIDATE = {
    validate,
    logReport,
    run() {
      const report = validate(root.BLENDAVIT_CONFIG);
      logReport(report);
      return report;
    },
  };
})(typeof window !== "undefined" ? window : globalThis);
