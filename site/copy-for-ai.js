// Copy-for-AI button — fetches the page's markdown alternate and copies
// it to the clipboard. Wires to any element with class `copy-for-ai` and a
// `data-md-url` attribute pointing at the .md alternate.
//
// Usage:
//   <button class="copy-for-ai" data-md-url="/architecture.md">Copy for AI</button>
//
// On click: fetches the .md alternate, copies the body to the clipboard,
// flips the button label to a brief confirmation, then restores. Errors
// fall back to a manual-copy message that opens the .md URL in a new tab.
//
// No build step; vanilla ES2017. Loaded once per page via a <script src="/copy-for-ai.js" defer> tag.
(function () {
  "use strict";

  function flashLabel(btn, text, durationMs) {
    var original = btn.dataset.originalLabel || btn.textContent;
    btn.dataset.originalLabel = original;
    btn.textContent = text;
    btn.disabled = true;
    setTimeout(function () {
      btn.textContent = original;
      btn.disabled = false;
    }, durationMs);
  }

  function handleClick(event) {
    var btn = event.currentTarget;
    var url = btn.dataset.mdUrl;
    if (!url) {
      console.error("[copy-for-ai] missing data-md-url on button", btn);
      return;
    }

    fetch(url, { credentials: "omit" })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.text();
      })
      .then(function (md) {
        if (!navigator.clipboard || !navigator.clipboard.writeText) {
          // Fallback: open the .md alternate in a new tab so the user
          // can manually copy. Honest about the limitation.
          window.open(url, "_blank", "noopener");
          flashLabel(btn, "Opened .md (copy from tab)", 2500);
          return;
        }
        return navigator.clipboard.writeText(md).then(function () {
          flashLabel(btn, "Copied!", 1500);
        });
      })
      .catch(function (err) {
        console.error("[copy-for-ai] fetch or clipboard failed", err);
        // Fallback: open the .md alternate so the user can copy manually.
        window.open(url, "_blank", "noopener");
        flashLabel(btn, "Opened .md (copy from tab)", 2500);
      });
  }

  function init() {
    var buttons = document.querySelectorAll(".copy-for-ai[data-md-url]");
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].addEventListener("click", handleClick);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
