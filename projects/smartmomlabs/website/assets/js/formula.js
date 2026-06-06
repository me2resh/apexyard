/**
 * Formula selection — single source of truth (toddlers | kids).
 */
(function (root) {
  const DEFAULT = "kids";
  const VALID = new Set(["toddlers", "kids"]);

  let current = DEFAULT;
  const listeners = new Set();

  function normalize(id) {
    return VALID.has(id) ? id : DEFAULT;
  }

  function get() {
    return current;
  }

  function set(id) {
    const next = normalize(id);
    if (next === current) return current;
    current = next;
    listeners.forEach((fn) => {
      try {
        fn(current);
      } catch (_) {}
    });
    return current;
  }

  function onChange(fn) {
    listeners.add(fn);
    return () => listeners.delete(fn);
  }

  function fromQueryString(search) {
    const params = new URLSearchParams(search || "");
    const v = params.get("variant");
    if (v) set(v);
    return get();
  }

  root.BLENDAVIT_FORMULA = {
    DEFAULT,
    VALID: Array.from(VALID),
    get,
    set,
    onChange,
    fromQueryString,
  };
})(typeof window !== "undefined" ? window : globalThis);
