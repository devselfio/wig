# Wig

**Wig** is a static site generator in Zig: Djot/HTML content, YAML config and data, Toupee (`<t-*>`) templates, and **YAML-driven integration tests** for full-site behaviour.

## Quick start

```bash
zig build -p . install   # build the CLI; see wig/AGENTS.md for the usual dev workflow
wig init mysite
cd mysite
wig build
```

Output is written to **`zig-out/site/`** under the project root.

## Preview (no in-tree server in v0.1)

There is **no** `wig serve` in **v0.1.0**. After a successful build, preview the site with any static file server, for example:

```bash
cd zig-out/site && python3 -m http.server 8000
```

In-repo HTTP preview (`devServer`, `listen`) is planned for **v0.3+** per [`WIG_ROADMAP.md`](../WIG_ROADMAP.md). The HTTP stack in the library is intentionally ahead of the CLI for static preview.

## Commands

| Command | Purpose |
|--------|---------|
| `wig init [path]` | Scaffold a project from `skel/site` |
| `wig build [path] [--clean]` | Full static build → `zig-out/site/` |
| `wig validate [path] [--external]` | Validate config and templates without rendering |
| `wig -V`, `wig --version` | Print semver |

**Not in v0.1.0:** `wig install` and `wig styles` exit with code **2** and a short message. See [`CHANGELOG.md`](CHANGELOG.md).

## Validation

`wig validate` currently checks:

- Site config (`data/site.yaml`) and style manifests
- Toupee template load + **`Engine.validate`** (template graph / diagnostics)

It does **not** yet perform a full external link graph or HTTP checks. The **`--external`** flag is accepted and emits a **warning** that URL checking is planned for **v0.2+** (see [`CHANGELOG.md`](CHANGELOG.md)).

## Contributing

- **CONTRIBUTING.md** is planned for **v1.0.0**. Until then, use **[`AGENTS.md`](AGENTS.md)** — especially **§Testing** (YAML specs under `test/`, `zig build test`, and how to add a spec).
- Product roadmap: [`WIG_ROADMAP.md`](../WIG_ROADMAP.md).

## Dependencies

Pinned in `build.zig.zon` (Toupee, Comb, zjot). **Minimum Zig:** `0.15.2`.
