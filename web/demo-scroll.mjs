import { ease } from "./demo-scenes.mjs";

export function dissolveFrame(inputTop, viewportHeight, reduced = false) {
  if (reduced)
    return { progress: 0, hardware: 1, hands: 1, table: 1, blur: 0, shift: 0 };
  const progress = Math.max(
    0,
    Math.min(1, (viewportHeight * 0.62 - inputTop) / (viewportHeight * 0.4)),
  );
  return {
    progress,
    hardware: 1 - ease(progress / 0.75),
    hands: 1 - ease(progress / 0.55),
    table: ease((progress - 0.3) / 0.7),
    blur: 5 * ease(progress / 0.8),
    shift: 28 * progress,
  };
}

export function attachScrollDissolve(stage, shortcuts, reducedMotion) {
  const main = document.querySelector("main");
  let frame = 0;

  function update() {
    frame = 0;
    const bounds = stage.getBoundingClientRect();
    const scale = bounds.width / 1120;
    const state = dissolveFrame(
      bounds.top + 488 * scale,
      innerHeight,
      reducedMotion.matches,
    );
    main.classList.toggle("scroll-dissolve", !reducedMotion.matches);
    main.style.setProperty("--input-overlap", `${216 * scale}px`);
    main.style.setProperty("--hardware-opacity", state.hardware);
    main.style.setProperty("--hands-opacity", state.hands);
    main.style.setProperty("--input-blur", `${state.blur}px`);
    main.style.setProperty("--input-shift", `${state.shift}px`);
    main.style.setProperty("--shortcut-opacity", state.table);
    main.style.setProperty("--shortcut-shift", `${24 * (1 - state.table)}px`);
    shortcuts.dataset.dissolve = state.progress.toFixed(3);
  }

  function schedule() {
    if (!frame && !document.hidden) frame = requestAnimationFrame(update);
  }

  const resize = new ResizeObserver(schedule);
  resize.observe(stage);
  addEventListener("scroll", schedule, { passive: true });
  addEventListener("resize", schedule);
  addEventListener("pageshow", schedule);
  document.addEventListener("visibilitychange", schedule);
  reducedMotion.addEventListener("change", schedule);
  addEventListener("pagehide", () => {
    cancelAnimationFrame(frame);
    frame = 0;
  });
  update();
}
