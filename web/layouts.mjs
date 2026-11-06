export const layoutNames = {
  1: ["full page"],
  2: ["side by side", "stacked"],
  3: ["main + stack", "stack + main", "main on top", "main at bottom", "columns", "rows"],
  4: ["four quarters"],
};

// Rectangles in a unit square, before the inset and gaps are applied.
const arrangements = {
  1: [[[0, 0, 1, 1]]],
  2: [
    [
      [0, 0, 0.5, 1],
      [0.5, 0, 0.5, 1],
    ],
    [
      [0, 0, 1, 0.5],
      [0, 0.5, 1, 0.5],
    ],
  ],
  3: [
    [
      [0, 0, 0.5, 1],
      [0.5, 0, 0.5, 0.5],
      [0.5, 0.5, 0.5, 0.5],
    ],
    [
      [0.5, 0, 0.5, 1],
      [0, 0, 0.5, 0.5],
      [0, 0.5, 0.5, 0.5],
    ],
    [
      [0, 0, 1, 0.5],
      [0, 0.5, 0.5, 0.5],
      [0.5, 0.5, 0.5, 0.5],
    ],
    [
      [0, 0.5, 1, 0.5],
      [0, 0, 0.5, 0.5],
      [0.5, 0, 0.5, 0.5],
    ],
    [
      [0, 0, 1 / 3, 1],
      [1 / 3, 0, 1 / 3, 1],
      [2 / 3, 0, 1 / 3, 1],
    ],
    [
      [0, 0, 1, 1 / 3],
      [0, 1 / 3, 1, 1 / 3],
      [0, 2 / 3, 1, 1 / 3],
    ],
  ],
  4: [
    [
      [0, 0, 0.5, 0.5],
      [0.5, 0, 0.5, 0.5],
      [0, 0.5, 0.5, 0.5],
      [0.5, 0.5, 0.5, 0.5],
    ],
  ],
};

export function layout(count, variant = 0) {
  const options = arrangements[count];
  if (!options || !Number.isInteger(variant) || variant < 0)
    throw new RangeError("Invalid layout");
  return options[variant % options.length].map(([x, y, width, height]) => ({
    x,
    y,
    width,
    height,
  }));
}
