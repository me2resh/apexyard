/**
 * Horizontal reviews carousel — scroll-snap + dot sync.
 */
(function () {
  function initCarousel(root) {
    const track = root.querySelector("[data-reviews-track]");
    const dots = root.querySelectorAll("[data-review-dot]");
    if (!track || !dots.length) return;

    const cards = track.querySelectorAll(".review-card");
    if (!cards.length) return;

    function activeIndex() {
      const trackRect = track.getBoundingClientRect();
      const center = trackRect.left + trackRect.width / 2;
      let best = 0;
      let bestDist = Infinity;
      cards.forEach((card, i) => {
        const rect = card.getBoundingClientRect();
        const cardCenter = rect.left + rect.width / 2;
        const dist = Math.abs(cardCenter - center);
        if (dist < bestDist) {
          bestDist = dist;
          best = i;
        }
      });
      return best;
    }

    function setActive(index) {
      dots.forEach((dot, i) => {
        const on = i === index;
        dot.classList.toggle("is-active", on);
        dot.setAttribute("aria-selected", on ? "true" : "false");
      });
    }

    function scrollToIndex(index) {
      const card = cards[index];
      if (!card) return;
      const offset =
        card.offsetLeft - (track.clientWidth - card.clientWidth) / 2;
      track.scrollTo({ left: offset, behavior: "smooth" });
    }

    let scrollTimer;
    track.addEventListener(
      "scroll",
      () => {
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(() => setActive(activeIndex()), 80);
      },
      { passive: true }
    );

    dots.forEach((dot) => {
      dot.addEventListener("click", () => {
        const index = Number(dot.dataset.reviewDot) || 0;
        scrollToIndex(index);
        setActive(index);
      });
    });

    setActive(0);
  }

  function init() {
    document.querySelectorAll("[data-reviews-carousel]").forEach(initCarousel);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
