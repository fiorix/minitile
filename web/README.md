# minitile website

A static consumer website using HTML, CSS, and browser JavaScript modules. It shares its wireframe geometry and brand assets with the project README. No framework, dependency installation, or build step is required.

## Preview

```sh
cd web
npm run dev
```

Open `http://127.0.0.1:4173`. Set `PORT=4180` to use another port. The server binds to loopback and serves this directory. Reload the page after editing; there is no live reload.

## Checks

```sh
npm test
```

The tests verify that all illustrative layouts partition the available space without overlap, that geometry stays finite across viewport sizes, and that its motion loop closes. The hero tests also check horizontal page movement, vertical workspace movement, window conservation, retiling, and continuity between animation stages. Browser verification should cover narrow and wide screens, the hero's moving and static states, all window counts and layout variants, keyboard focus, download navigation, setup disclosure, reduced motion, manual pause, and JavaScript disabled.

The window preview is an illustration, not a native app recording or a second implementation of the window manager. Its controls change only the example on the page. It does not capture operating-system shortcut chords.

## Publication

Serve the contents of `web/` as the website root. Asset paths are relative, so the site also works under a repository subpath on GitHub Pages. `.nojekyll` keeps the output static. Nothing in this worktree publishes or deploys automatically.

Before a public release:

- Replace the disabled download button and its release note with a real release URL and verified requirements. Update the matching README badge and download section.
- Add the public repository link once the GitHub repository exists.
- Set the canonical website URL and an absolute `og:image` URL for `assets/welcome.png` after the final host is known.

See [BRAND.md](../BRAND.md) for the palette, identity, and reproducible asset exports.
