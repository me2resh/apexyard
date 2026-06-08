(function () {
  document.querySelectorAll("[data-lang-btn]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const lang = btn.getAttribute("data-lang-btn");
      if (lang) window.SML_HUB_I18N.apply(lang);
    });
  });
})();
