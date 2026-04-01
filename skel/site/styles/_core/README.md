# `_core` style

**Shared CUBE CSS suite** for all Wig sites: compositions, utilities, blocks, and syntax helpers that every theme should reuse instead of re-declaring primitives.

- **Templates** under `templates/{layouts,blocks}/` are always registered; extend `_core:layouts/base.html` from site layouts.
- **Bundle `cube`**: one fingerprinted CSS file (`assets._core.css.cube.path`). Load it **before** your style’s surface/tokens CSS so `--color-*`, `--size-step-*`, `--space-*`, `--syntax-*`, and `--stroke*` resolve.
- **`css/fonts/system.css`**: optional `.font-system` / `.font-mono` utilities; body uses the same system stacks by default. Add self-hosted `@font-face` (or a future `wig add font` flow) when you want a custom face.
- **Patterns** mirror the prototype `examples/` layout for the pattern library.

## Layer contents

| Layer | Role |
|-------|------|
| globals | reset, document base (`body`), syntax highlighting |
| fonts | system stacks, `.font-system` / `.font-mono` helpers |
| compositions | center, cluster, **flow** (owl), grid, region, repel, sidebar, stack, switcher, **wrapper** |
| utilities | indent, text-colors, text-sizes, visually-hidden, radius |
| blocks | button, tag, prose |
| exceptions | `[data-exception="narrow"]` |

## Site style contract

Your **default** (or theme) style should ship a small **surface** (or tokens) bundle that defines semantic custom properties consumed by `_core`, e.g. `colors.*` → `--color-text-primary`, `tokens.computed.typography` → `--size-step-*`, plus `--stroke`, `--radius-s`, `--space-m`, etc. See `styles/default/css/surface.css` in the skeleton site.
