import { geometryFrame } from "./geometry.mjs";
import { layout, layoutNames } from "./layouts.mjs";

const desktop = document.querySelector(".desktop");
const windows = [...desktop.querySelectorAll(".demo-window")];
const countButtons = [...document.querySelectorAll("[data-count]")].filter(
  (node) => node.tagName === "BUTTON",
);
const cycleButton = document.querySelector(".cycle-button");
const previewStatus = document.querySelector(".preview-status");
let count = 3;
let variant = 0;

function arrange() {
  const rectangles = layout(count, variant);
  desktop.dataset.count = count;
  desktop.dataset.variant = variant;
  desktop.setAttribute(
    "aria-label",
    `Illustrative preview of ${count} tiled window${count === 1 ? "" : "s"}`,
  );
  windows.forEach((window, i) => {
    window.hidden = i >= count;
    if (window.hidden) return;
    const { x, y, width, height } = rectangles[i];
    Object.assign(window.style, {
      left: `calc(${x * 100}% + ${x === 0 ? 8 : 4}px)`,
      top: `calc(${y * 100}% + ${y === 0 ? 8 : 4}px)`,
      width: `calc(${width * 100}% - ${(x === 0 ? 8 : 4) + (Math.abs(x + width - 1) < 1e-9 ? 8 : 4)}px)`,
      height: `calc(${height * 100}% - ${(y === 0 ? 8 : 4) + (Math.abs(y + height - 1) < 1e-9 ? 8 : 4)}px)`,
    });
  });
  countButtons.forEach((button) =>
    button.setAttribute(
      "aria-pressed",
      String(Number(button.dataset.count) === count),
    ),
  );
  cycleButton.disabled = layoutNames[count].length === 1;
  previewStatus.textContent = `${count} window${count === 1 ? "" : "s"} / ${layoutNames[count][variant]}`;
}

for (const button of countButtons) {
  button.disabled = false;
  button.addEventListener("click", () => {
    count = Number(button.dataset.count);
    variant = 0;
    arrange();
  });
}
cycleButton.addEventListener("click", () => {
  variant = (variant + 1) % layoutNames[count].length;
  arrange();
});
arrange();

const canvas = document.querySelector("#hero-canvas");
const context = canvas.getContext("2d");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const motionToggle = document.querySelector(".motion-toggle");
let paused = reducedMotion.matches;
let inView = true;
let frame = 0;
let elapsed = 0;
let lastTime = null;
let width = 0;
let height = 0;

function draw() {
  if (!context) return;
  context.clearRect(0, 0, width, height);
  const { segments, faces, labels } = geometryFrame(width, height, elapsed);
  for (const { points, alpha } of faces) {
    context.fillStyle = `rgba(200,221,248,${alpha})`;
    context.beginPath();
    points.forEach(([x, y], i) =>
      i ? context.lineTo(x, y) : context.moveTo(x, y),
    );
    context.closePath();
    context.fill();
  }
  for (const { a, b, alpha, accent, weight } of segments) {
    context.strokeStyle = `rgba(${accent ? "200,221,248" : "116,137,165"},${alpha})`;
    context.lineWidth = weight;
    context.beginPath();
    context.moveTo(...a);
    context.lineTo(...b);
    context.stroke();
  }
  for (const { text, position, size, alpha, align, rotation } of labels) {
    context.save();
    context.translate(...position);
    context.rotate(rotation);
    context.fillStyle = `rgba(200,221,248,${alpha})`;
    context.font = `${size}px ui-monospace, monospace`;
    context.textAlign = align;
    context.fillText(text, 0, 0);
    context.restore();
  }
}

function animate(time) {
  frame = 0;
  if (lastTime !== null) elapsed += Math.min((time - lastTime) / 1000, 0.1);
  lastTime = time;
  draw();
  frame = requestAnimationFrame(animate);
}

function syncMotion() {
  if (frame) cancelAnimationFrame(frame);
  frame = 0;
  lastTime = null;
  document.documentElement.classList.toggle(
    "motion-paused",
    paused || document.hidden,
  );
  motionToggle.setAttribute("aria-pressed", String(paused));
  motionToggle.querySelector(".motion-label").textContent = paused
    ? "Play motion"
    : "Pause motion";
  motionToggle.querySelector(".motion-symbol").textContent = paused
    ? "\u25b7"
    : "\u2161";
  if (context && !paused && !document.hidden && inView)
    frame = requestAnimationFrame(animate);
  else draw();
}

motionToggle.hidden = false;
motionToggle.addEventListener("click", () => {
  paused = !paused;
  syncMotion();
});
reducedMotion.addEventListener("change", () => {
  paused = reducedMotion.matches;
  syncMotion();
});
document.addEventListener("visibilitychange", syncMotion);

if (context) {
  const resize = new ResizeObserver(() => {
    const bounds = canvas.getBoundingClientRect();
    width = bounds.width;
    height = bounds.height;
    const ratio = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    draw();
    canvas.parentElement.classList.add("geometry-ready");
  });
  resize.observe(canvas);
  const visibility = new IntersectionObserver(([entry]) => {
    inView = entry.isIntersecting;
    syncMotion();
  });
  visibility.observe(canvas);
  addEventListener("pagehide", () => {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    lastTime = null;
  });
  addEventListener("pageshow", syncMotion);
}
syncMotion();
