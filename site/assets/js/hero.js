(() => {
  const stage = document.querySelector(".hero-stage");
  if (!stage) return;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const CODE = "98765";

  // Animation sequence:
  //   1) phone bank notification fades in
  //   2) mac bank notification fades in
  //   3) mac otifier notification fades in
  //   4) verification code types into the safari cells
  const phoneBank   = document.querySelector('.phone-notifs [data-banner="bank"]');
  const macBank     = document.querySelector('.mac-notifs [data-banner="bank"]');
  const macOtifier  = document.querySelector('.mac-notifs [data-banner="otifier"]');
  const sequence    = [phoneBank, macBank, macOtifier].filter(Boolean);
  const allBanners  = document.querySelectorAll("[data-banner]");
  const cells       = document.querySelectorAll(".vcode-cell");
  const card        = document.getElementById("vcode-card");
  const kbdHint     = document.querySelector(".kbd-hint");
  const kbdCmd      = document.querySelector('.kbd-key[data-key="cmd"]');
  const kbdV        = document.querySelector('.kbd-key[data-key="v"]');

  const setStatic = () => {
    stage.classList.remove("anim");
    allBanners.forEach((b) => b.classList.add("is-in"));
    cells.forEach((c, i) => {
      c.textContent = CODE[i] || "";
      c.classList.add("is-typed");
    });
    if (card) card.classList.add("is-success");
  };

  if (reduceMotion) {
    setStatic();
    return;
  }

  stage.classList.add("anim");
  cells.forEach((c) => (c.textContent = ""));

  let timers = [];
  const after = (ms, fn) => timers.push(setTimeout(fn, ms));
  const reset = () => {
    timers.forEach(clearTimeout);
    timers = [];
    allBanners.forEach((b) => b.classList.remove("is-in"));
    cells.forEach((c) => {
      c.textContent = "";
      c.classList.remove("is-typed");
    });
    if (card) card.classList.remove("is-success");
    if (kbdHint) kbdHint.classList.remove("is-in");
    if (kbdCmd) kbdCmd.classList.remove("is-pressed");
    if (kbdV) kbdV.classList.remove("is-pressed");
  };

  // Tunable timings (ms)
  const FIRST_BANNER_AT = 700;   // when the first banner appears
  const BANNER_STEP     = 1000;  // gap between each banner
  const TYPE_PAUSE      = 700;   // pause after last banner before typing starts
  const TYPE_STEP       = 140;   // delay between each digit
  const SUCCESS_PAUSE   = 300;   // pause after last digit before the green pulse
  const LOOP_PAUSE      = 4000;  // hold on the final state before looping

  const play = () => {
    reset();

    // 1–3) Banners cascade in
    sequence.forEach((banner, i) => {
      after(FIRST_BANNER_AT + i * BANNER_STEP, () => banner.classList.add("is-in"));
    });

    // 4) Show ⌘+V hint, then type the code into the safari cells
    const typeStart = FIRST_BANNER_AT + sequence.length * BANNER_STEP + TYPE_PAUSE;

    // Keyboard hint appears 700ms before typing, each key "presses" in sequence
    const kbdShowAt = typeStart - 700;
    after(kbdShowAt,        () => kbdHint?.classList.add("is-in"));
    after(kbdShowAt + 280,  () => kbdCmd?.classList.add("is-pressed"));
    after(kbdShowAt + 520,  () => kbdV?.classList.add("is-pressed"));

    [...CODE].forEach((digit, i) => {
      after(typeStart + i * TYPE_STEP, () => {
        const cell = cells[i];
        if (!cell) return;
        cell.textContent = digit;
        cell.classList.add("is-typed");
      });
    });

    // Fade out the kbd hint once the digits land
    after(typeStart + CODE.length * TYPE_STEP, () => {
      kbdHint?.classList.remove("is-in");
    });

    const successAt = typeStart + CODE.length * TYPE_STEP + SUCCESS_PAUSE;
    after(successAt, () => {
      if (card) card.classList.add("is-success");
    });

    after(successAt + LOOP_PAUSE, play);
  };

  let started = false;
  const kick = () => {
    if (started) return;
    started = true;
    after(450, play);
  };

  // Start the animation as soon as the document is ready. setTimeout is
  // throttled in hidden tabs but that's fine — a returning visitor will see
  // the steady-state populated by the previous loop iteration.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", kick, { once: true });
  } else {
    kick();
  }
})();
