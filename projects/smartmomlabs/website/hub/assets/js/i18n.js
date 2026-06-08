(function () {
  const STRINGS = {
    ar: {
      "skip": "انتقل إلى المحتوى الرئيسي",
      "meta.title": "Smart Mom Labs | حلول غذائية مبنية على الأدلة",
      "meta.desc": "محفظة مكملات غذائية للعائلة في الخليج — بليندافيت متاح الآن، باقي العلامات قريبًا.",
      "lang.ar": "عربي",
      "lang.en": "EN",
      "nav.brands": "العلامات",
      "nav.science": "معيار الأدلة",
      "nav.trade": "للتجار",
      "hero.eyebrow": "حلول حقيقية لبشر حقيقيين",
      "hero.title": "فيتامينات لا يتذوّقها أطفالك — مبنية على أدلة من الدرجة أ و ب",
      "hero.lead": "محفظة Smart Mom Labs تجمع مساحيق بلا طعم، مناعة، حديد، ومكملات للعائلة. بليندافيت متاح للحجز الآن داخل المملكة.",
      "trust.1": "مكونات نظيفة",
      "trust.2": "مسحوق بلا نكهة",
      "trust.3": "0غ سكر في بليندافيت",
      "trust.4": "مسجّل لدى الهيئة",
      "trust.5": "أدلة قابلة للتحقق",
      "products.title": "علاماتنا",
      "products.sub": "بليندافيت متاح للحجز — باقي العلامات قيد الإطلاق.",
      "card.live": "متاح",
      "card.soon": "قريبًا",
      "blendavit.title": "بليندافيت®",
      "blendavit.meta": "مسحوق بلا طعم · 1–12 سنة",
      "blendavit.desc": "12 عنصرًا مع حديد ليبوفير في ظرف واحد يوميًا.",
      "blendavit.cta": "تسوقي بليندافيت",
      "immuno.title": "IMMUNOSHIELD+",
      "immuno.meta": "مناعة · أطفال وبالغين",
      "immuno.desc": "مناعة مدربة بآليات متعددة — قريبًا.",
      "alpha.title": "ALPHABRAIN",
      "alpha.meta": "تركيز · أوميغا 3 + ب",
      "alpha.desc": "تغذية للعقل في عصر الشاشات — قريبًا.",
      "ferro.title": "FERRO-PRO®",
      "ferro.meta": "حديد ليبوفير",
      "ferro.desc": "امتصاص أعلى بلا آثار معدنية — قريبًا.",
      "gut.title": "عائلة الأمعاء",
      "gut.meta": "Little Pro+ · Provi+",
      "gut.desc": "ما قبل وما بعد وما بعد الحيوي — قريبًا.",
      "erova.note": "EROVA® للبالغين — رابط منفصل عند الإطلاق.",
      "science.title": "معيار الأدلة",
      "science.sub": "لا نعتمد على دراسات حيوانية فقط — كل ادعاء مربوط بدرجة أ أو ب.",
      "science.a": "درجة أ",
      "science.a.desc": "تجارب سريرية منشورة",
      "science.b": "درجة ب",
      "science.b.desc": "أدلة وبائية وتركيبة",
      "science.skus": "12 SKU",
      "science.skus.desc": "في المحفظة الكاملة",
      "trade.title": "شراكة صيدليات وتجزئة",
      "trade.sub": "تواصل معنا لتوزيع Smart Mom Labs داخل المملكة.",
      "trade.cta": "تواصل للتجارة",
      "footer.brands": "العلامات",
      "footer.company": "الشركة",
      "footer.legal": "القانوني",
      "footer.blendavit": "بليندافيت",
      "footer.disclaimer": "مكملات غذائية فقط — لا تشخّص ولا تعالج الأمراض.",
    },
    en: {
      "skip": "Skip to main content",
      "meta.title": "Smart Mom Labs | Evidence-grade supplement portfolio",
      "meta.desc": "GCC family supplement portfolio — blendavit is live for reserve; more brands coming soon.",
      "lang.ar": "عربي",
      "lang.en": "EN",
      "nav.brands": "Brands",
      "nav.science": "Evidence standard",
      "nav.trade": "Trade",
      "hero.eyebrow": "Real solutions for real humans",
      "hero.title": "Vitamins they'll never taste — built on Grade A & B evidence",
      "hero.lead": "Smart Mom Labs brings tasteless powders, immunity, iron, and family nutrition together. blendavit is open for reserve in KSA today.",
      "trust.1": "Clean ingredients",
      "trust.2": "Unflavored powder",
      "trust.3": "0g sugar in blendavit",
      "trust.4": "SFDA registered",
      "trust.5": "Verifiable citations",
      "products.title": "Our brands",
      "products.sub": "blendavit is live — the rest of the portfolio is launching soon.",
      "card.live": "Live",
      "card.soon": "Coming soon",
      "blendavit.title": "blendavit®",
      "blendavit.meta": "Tasteless powder · ages 1–12",
      "blendavit.desc": "12 nutrients including Lipofer iron in one daily sachet.",
      "blendavit.cta": "Shop blendavit",
      "immuno.title": "IMMUNOSHIELD+",
      "immuno.meta": "Immunity · kids & adults",
      "immuno.desc": "Trained immunity, three mechanisms — coming soon.",
      "alpha.title": "ALPHABRAIN",
      "alpha.meta": "Focus · omega-3 + B vitamins",
      "alpha.desc": "Screen-era brain nutrition — coming soon.",
      "ferro.title": "FERRO-PRO®",
      "ferro.meta": "Liposomal iron",
      "ferro.desc": "Higher absorption without metallic taste — coming soon.",
      "gut.title": "Gut family",
      "gut.meta": "Little Pro+ · Provi+",
      "gut.desc": "Pre, pro, and postbiotic stack — coming soon.",
      "erova.note": "EROVA® for adults — separate link at launch.",
      "science.title": "Evidence standard",
      "science.sub": "No animal-study-only claims — every line ties to Grade A or B research.",
      "science.a": "Grade A",
      "science.a.desc": "Published clinical trials",
      "science.b": "Grade B",
      "science.b.desc": "Epidemiology & formulation logic",
      "science.skus": "12 SKUs",
      "science.skus.desc": "Across the full portfolio",
      "trade.title": "Pharmacy & retail partnerships",
      "trade.sub": "Contact us to distribute Smart Mom Labs in KSA.",
      "trade.cta": "Contact trade",
      "footer.brands": "Brands",
      "footer.company": "Company",
      "footer.legal": "Legal",
      "footer.blendavit": "blendavit",
      "footer.disclaimer": "Food supplements only — not intended to diagnose or treat disease.",
    },
  };

  const STORAGE_KEY = "sml-hub-lang";

  function getLang() {
    const params = new URLSearchParams(window.location.search);
    const q = params.get("lang");
    if (q === "en" || q === "ar") return q;
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "en" || stored === "ar") return stored;
    return "ar";
  }

  function t(key) {
    const lang = getLang();
    return STRINGS[lang][key] || STRINGS.ar[key] || key;
  }

  function apply(lang) {
    const next = lang === "en" ? "en" : "ar";
    localStorage.setItem(STORAGE_KEY, next);
    document.documentElement.lang = next;
    document.documentElement.dir = next === "ar" ? "rtl" : "ltr";
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (key) el.textContent = t(key);
    });
    document.querySelectorAll("[data-i18n-placeholder]").forEach((el) => {
      const key = el.getAttribute("data-i18n-placeholder");
      if (key) el.setAttribute("placeholder", t(key));
    });
    document.querySelectorAll("[data-lang-btn]").forEach((btn) => {
      btn.classList.toggle("active", btn.getAttribute("data-lang-btn") === next);
    });
    const titleKey = document.body.getAttribute("data-page-title");
    const descKey = document.body.getAttribute("data-page-desc");
    if (titleKey) document.title = t(titleKey);
    if (descKey) {
      const meta = document.querySelector('meta[name="description"]');
      if (meta) meta.setAttribute("content", t(descKey));
    }
  }

  window.SML_HUB_I18N = { apply, t, getLang, STRINGS };
  apply(getLang());
})();
