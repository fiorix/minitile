import {
  scenes,
  sampleScene,
  sceneDuration,
  stepStart,
} from "./demo-scenes.mjs";
import { illustration, createIllustration } from "./demo-art.mjs";
import { attachScrollDissolve } from "./demo-scroll.mjs";

const demo = document.querySelector(".guided-demo");
const stage = demo.querySelector(".demo-stage");
const controls = demo.querySelector(".demo-controls");
const chapters = demo.querySelector(".demo-chapters");
const title = demo.querySelector(".scene-title");
const description = demo.querySelector(".scene-description");
const caption = demo.querySelector(".action-caption");
const chord = demo.querySelector(".action-chord");
const counter = demo.querySelector(".scene-counter");
const progress = demo.querySelector(".scene-progress");
const play = demo.querySelector("[data-play]");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
let paused = reducedMotion.matches;
let visible = false;
let index = 0;
let elapsed = 0;
let frame = 0;
let lastTime = null;
let lastStep = "";
let lastDrawing = "";

stage.innerHTML = illustration();
const draw = createIllustration(stage);
chapters.innerHTML = scenes
  .map(
    (scene, i) =>
      `<button type="button" data-scene="${i}" aria-pressed="${i === 0}" aria-controls="demo-scene"><span>${String(i + 1).padStart(2, "0")}</span>${scene.label}</button>`,
  )
  .join("");
chapters.hidden = false;
controls.hidden = false;
demo.querySelector(".demo-action").hidden = false;
demo.querySelector(".scene-progress-track").hidden = false;

const labels = {
  control: "Control",
  option: "Option",
  cmd: "Cmd",
  shift: "Shift",
  backtick: "`",
  tab: "Tab",
  n: "N",
  left: "←",
  right: "→",
  up: "↑",
  down: "↓",
  space: "Space",
};
function render() {
  const scene = scenes[index];
  const sample = sampleScene(scene, elapsed, reducedMotion.matches);
  const drawingKey = `${index}:${sample.index}:${reducedMotion.matches ? "static" : Math.min(sample.local, 1.6)}`;
  if (drawingKey !== lastDrawing) {
    draw(sample);
    lastDrawing = drawingKey;
  }
  progress.style.transform = `scaleX(${sample.progress})`;
  demo.dataset.scene = scene.id;
  demo.dataset.step = sample.index;
  const key = `${index}:${sample.index}`;
  if (key === lastStep) return;
  lastStep = key;
  title.textContent = scene.title;
  description.textContent = scene.description;
  caption.textContent = sample.caption;
  counter.textContent = `${String(index + 1).padStart(2, "0")} / ${String(scenes.length).padStart(2, "0")}`;
  chord.innerHTML = sample.keys.length
    ? sample.keys.map((key) => `<kbd>${labels[key]}</kbd>`).join("")
    : `<span>${sample.device === "trackpad" ? "Four-finger swipe" : sample.device === "mouse" ? (sample.hold ? "Click + hold" : "Mouse") : "Your workspace"}</span>`;
  demo.querySelector(".action-count").textContent =
    `${sample.index + 1} / ${scene.steps.length}`;
  chapters
    .querySelectorAll("button")
    .forEach((button, i) =>
      button.setAttribute("aria-pressed", String(index === i)),
    );
  stage.querySelector("#desk-desc").textContent =
    `${scene.title} ${sample.caption}`;
}

function animate(time) {
  frame = 0;
  if (lastTime !== null) elapsed += Math.min((time - lastTime) / 1000, 0.1);
  lastTime = time;
  if (elapsed >= sceneDuration(scenes[index])) {
    elapsed = 0;
    index = (index + 1) % scenes.length;
  }
  render();
  frame = requestAnimationFrame(animate);
}

function syncPlayback() {
  cancelAnimationFrame(frame);
  frame = 0;
  lastTime = null;
  play.textContent = paused ? "Play tour" : "Pause";
  play.setAttribute("aria-label", paused ? "Play tour" : "Pause tour");
  play.setAttribute("aria-pressed", String(!paused));
  demo.dataset.paused = paused;
  // Announce manual steps, without reading out an entire autoplaying tour.
  demo
    .querySelector(".demo-action")
    .setAttribute("aria-live", paused ? "polite" : "off");
  if (!paused && visible && !document.hidden)
    frame = requestAnimationFrame(animate);
  render();
}

function selectScene(next) {
  index = (next + scenes.length) % scenes.length;
  elapsed = 0;
  syncPlayback();
}

chapters.addEventListener("click", (event) => {
  const button = event.target.closest("[data-scene]");
  if (button) selectScene(Number(button.dataset.scene));
});
demo
  .querySelector("[data-prev]")
  .addEventListener("click", () => selectScene(index - 1));
demo
  .querySelector("[data-next]")
  .addEventListener("click", () => selectScene(index + 1));
demo
  .querySelector("[data-replay]")
  .addEventListener("click", () => selectScene(index));
demo.querySelector("[data-step]").addEventListener("click", () => {
  paused = true;
  const scene = scenes[index];
  const next = sampleScene(scene, elapsed).index + 1;
  if (next === scene.steps.length) selectScene(index + 1);
  else {
    elapsed = stepStart(scene, next) + 1.4;
    syncPlayback();
  }
});
play.addEventListener("click", () => {
  paused = !paused;
  syncPlayback();
});
demo.addEventListener("focusin", (event) => {
  // Keyboard users can explore controls without the selected chapter changing.
  if (event.target !== play && event.target.matches(":focus-visible")) {
    paused = true;
    syncPlayback();
  }
});
reducedMotion.addEventListener("change", () => {
  paused = reducedMotion.matches;
  syncPlayback();
});
document.addEventListener("visibilitychange", syncPlayback);
const observer = new IntersectionObserver(([entry]) => {
  visible = entry.isIntersecting;
  syncPlayback();
});
observer.observe(demo);
addEventListener("pagehide", () => {
  cancelAnimationFrame(frame);
  frame = 0;
  lastTime = null;
});
addEventListener("pageshow", syncPlayback);
syncPlayback();
attachScrollDissolve(
  stage,
  document.querySelector("#shortcuts"),
  reducedMotion,
);
