/** KSA Shopify + commerce — flip checkoutEnabled when live */
window.BLENDAVIT_CONFIG = {
  /** Production origin — update when custom domain (blendavit.com) goes live */
  siteUrl: "https://website-dun-zeta-85.vercel.app",
  checkoutEnabled: false,
  market: "ksa",
  discountPercent: 20,
  discountCode: "FIRSTBLEND20",
  emailCaptureDelayMs: 2000,
  prices: {
    toddlers_ksa: 189,
    kids_ksa: 189,
  },
  shopifyStoreUrl: "",
  checkoutUrls: {
    toddlers_ksa: "",
    kids_ksa: "",
  },
  waitlistFormAction: "",
  waitlistUrls: {},
  depositMode: true,
};
