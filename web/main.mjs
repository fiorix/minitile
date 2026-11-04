import { scenes, sampleScene, sceneDuration, stepStart } from "./demo-scenes.mjs";
import { illustration, createIllustration } from "./demo-art.mjs";

const demo = document.querySelector(".guided-demo");
const stage = demo.querySelector(".demo-stage");
const bar = demo.querySelector(".demo-bar");
const chapters = demo.querySelector(".demo-chapters");
const play = demo.querySelector("[data-play]");
const action = demo.querySelector(".demo-action");
const chord = demo.querySelector(".action-chord");
const caption = demo.querySelector(".action-caption");
const steps = demo.querySelector(".demo-steps");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
let paused = reducedMotion.matches;
let visible = false;
let index = 0;
let elapsed = 0;
let frame = 0;
let lastTime = null;
let lastStep = "";
let lastScene = -1;
let lastDrawing = "";

stage.innerHTML = illustration();
const draw = createIllustration(stage);
chapters.innerHTML = scenes
  .map(
    (scene, i) =>
      `<button type="button" data-scene="${i}" aria-pressed="${i === 0}" aria-controls="demo-scene">${scene.label}</button>`,
  )
  .join("");
bar.hidden = false;
action.hidden = false;

// Symbols as printed on Mac keycaps, beside the names people search for.
const keyNames = {
  control: ["⌃", "Control"],
  option: ["⌥", "Option"],
  cmd: ["⌘", "Cmd"],
  shift: ["⇧", "Shift"],
  backtick: ["", "`"],
  space: ["", "Space"],
  left: ["←", "Left"],
  right: ["→", "Right"],
  up: ["↑", "Up"],
  down: ["↓", "Down"],
};
const arrows = { left: "←", right: "→", up: "↑", down: "↓" };
const hidden = (value) => `<span aria-hidden="true">${value}</span>`;
const spoken = (value) => `<span class="sr-only">${value}</span>`;

function chordMarkup(sample) {
  if (sample.keys.length)
    return sample.keys
      .map((key) => {
        const [symbol, name] = keyNames[key];
        if (arrows[key]) return `<kbd>${hidden(symbol)}${spoken(name)}</kbd>`;
        return `<kbd>${symbol ? `${hidden(symbol)} ` : ""}${name}</kbd>`;
      })
      .join("");
  if (sample.device === "trackpad")
    return `<span class="gesture">Four fingers ${hidden(arrows[sample.gesture])}${spoken(sample.gesture)}</span>`;
  return "";
}

function render() {
  const scene = scenes[index];
  const sample = sampleScene(scene, elapsed, reducedMotion.matches);
  const drawingKey = `${index}:${sample.index}:${reducedMotion.matches ? "static" : Math.min(sample.local, 1.6)}`;
  if (drawingKey !== lastDrawing) {
    draw(sample);
    lastDrawing = drawingKey;
  }
  chord.classList.toggle("pressing", sample.pressing);
  if (index !== lastScene) {
    steps.innerHTML = scene.steps
      .map(
        (_, i) =>
          `<button type="button" data-step-index="${i}" aria-label="Step ${i + 1} of ${scene.steps.length}"><span></span></button>`,
      )
      .join("");
    chapters
      .querySelectorAll("button")
      .forEach((button, i) =>
        button.setAttribute("aria-pressed", String(index === i)),
      );
    lastScene = index;
  }
  const dots = steps.querySelectorAll("button");
  const fill = Math.min(1, sample.local / scene.steps[sample.index].duration);
  dots[sample.index].style.setProperty("--fill", fill);
  const key = `${index}:${sample.index}`;
  if (key === lastStep) return;
  lastStep = key;
  dots.forEach((dot, i) => {
    if (i === sample.index) dot.setAttribute("aria-current", "step");
    else dot.removeAttribute("aria-current");
    dot.style.setProperty("--fill", i < sample.index ? 1 : 0);
  });
  chord.innerHTML = chordMarkup(sample);
  caption.textContent = sample.caption;
  stage.querySelector("#desk-desc").textContent =
    `${scene.label}. ${chord.textContent} ${sample.caption}`;
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
  play.textContent = paused ? "Play" : "Pause";
  play.setAttribute("aria-label", paused ? "Play tour" : "Pause tour");
  play.setAttribute("aria-pressed", String(!paused));
  demo.dataset.paused = paused;
  // Announce steps chosen by hand, without reading out an entire autoplaying tour.
  action.setAttribute("aria-live", paused ? "polite" : "off");
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
steps.addEventListener("click", (event) => {
  const button = event.target.closest("[data-step-index]");
  if (!button) return;
  // A chosen step pauses on its settled frame, after the keys and windows have moved.
  paused = true;
  elapsed = stepStart(scenes[index], Number(button.dataset.stepIndex)) + 1.4;
  syncPlayback();
});
play.addEventListener("click", () => {
  paused = !paused;
  syncPlayback();
});
demo.addEventListener("focusin", (event) => {
  // Keyboard users can explore the controls without the chapter changing under them.
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
