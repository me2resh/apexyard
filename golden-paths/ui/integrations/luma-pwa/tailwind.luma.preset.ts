import type { Config } from "tailwindcss";
import uiPreset from "../../theme/tailwind.preset";

/**
 * LUMA ONLY — extends neutral portfolio preset with LUMA tokens.
 * Import only in Dr-kersho/luma-pwa, never in blendavit or other clients.
 */
const lumaPreset = {
  presets: [uiPreset],
  theme: {
    extend: {
      borderRadius: {
        ui: "var(--radius-ui, 10px)",
        card: "var(--radius-card, 12px)",
      },
      colors: {
        luma: {
          cherry: "var(--luma-cherry)",
          gold: "var(--luma-gold)",
          ivory: "var(--luma-ivory)",
          navy: "var(--luma-navy)",
          border: "var(--luma-border)",
        },
      },
    },
  },
} satisfies Config;

export default lumaPreset;
