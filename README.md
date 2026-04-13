# Wig

**Wig** is a static site generator and web-framework library in Zig: Djot/HTML content, YAML config and data, Toupee (`<t-*>`) templates, and **YAML-driven integration tests** for full-site behaviour.

## Quick start

```bash
zig build -p . install   # build the CLI
wig init mysite
cd mysite
wig build
```

Output is written to **`zig-out/site/`** under the project root.

## Dev server

```bash
wig serve [--port 8080] [--no-reload]
```

Builds the site, serves it over HTTP, watches for source file changes, rebuilds on change, and live-reloads connected browsers via WebSocket.

## Commands

| Command | Purpose |
|--------|---------|
| `wig init [path]` | Scaffold a project from `skel/site` |
| `wig build [path] [--clean] [--pretty] [--strict-links]` | Full static build with post-build link checking |
| `wig serve [path] [--port PORT] [--no-reload]` | Dev server with watch and live reload |
| `wig check [path] [--external]` | Validate config and templates without building |
| `wig -V`, `wig --version` | Print version |

**Not yet available:** `wig install` and `wig styles` exit with code **2** and a short message.

## Link checking

Internal links are checked automatically during every build. The link checker walks the output HTML, extracts `href` and `src` attributes, and verifies that internal paths and `#fragment` anchors resolve.

- **Warnings by default** -- broken links are reported but do not fail the build.
- **`--strict-links`** -- promotes warnings to errors (exit 1). Useful for CI.
- **`--external-links`** -- accepted but not yet implemented; external HTTP checking is planned.

## Check (config validation)

`wig check` validates site config (`data/site.yaml`), style manifests, and Toupee template resolution without running a full build. It catches missing config, bad template references, and structural issues early.

## CUBE CSS patterns

Wig is a style-focused site generator with first-class CUBE CSS support. Styles contain patterns organized by CUBE category (tokens, resets, globals, fonts, compositions, utilities, blocks, exceptions). CSS is auto-bundled with `@layer` declarations in cascade order. Pattern libraries are auto-generated with shell+iframe navigation and viewport controls.

See **[`AGENTS.md`](AGENTS.md)** for the full CUBE CSS categorization guide and pattern file format.

## Contributing

See **[`AGENTS.md`](AGENTS.md)** for architecture, conventions, and testing (YAML specs under `test/`, `zig build test`).

## Dependencies

Pinned in `build.zig.zon` (Toupee, Comb, zjot). **Minimum Zig:** `0.15.2`.
