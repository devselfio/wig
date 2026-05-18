# Wig

A library-first static site generator and web framework in Zig. Wig promotes CUBE CSS methodology and provides tools for fluid design tokens, color scheme management, and multi-style site architecture. The same templates and data model serve both SSG output (files) and HTTP responses (HTMX fragments from a Zig backend).

## Who this is for

- **Site authors** — Content, frontmatter, data cascade, and Toupee templates: [Rendering pipeline](#rendering-pipeline), [Frontmatter](#frontmatter), [Data cascade](#data-cascade), [Template syntax](#template-syntax), [Page collection](#page-collection).
- **Zig app developers** — Hybrid SSG + web-framework architecture: [SSG + web framework](#ssg--web-framework-hybrid-architecture), [Key types](#key-types), [Check](#check-configtemplate-validation), [Link checking](#link-checking).
- **Zig embedders** — Library API: [Library-first](#library-first-design), [Two-phase Site struct](#two-phase-site-struct), [Key types](#key-types).
- **Wig contributors** — Source layout and tests: [Project structure](#project-structure), [Testing](#testing).

## Contents

- [Dependencies](#dependencies)
- [Build commands](#build-commands)
- [Project structure](#project-structure)
- [Architecture](#architecture) (site model, allocators, output paths, templates, styles, feeds, tags, pagination, output, …)
- [Conventions](#conventions)
- [Testing](#testing)

## Dependencies

| Name | Purpose | License |
|------|---------|---------|
| [Toupee](https://github.com/QuiteClose/toupee) | HTML-native template engine (`<t-*>` elements); includes `$()` dynamic dot-path segments | MIT |
| [Comb](https://github.com/QuiteClose/comb) | YAML parser | MIT |
| [zjot](https://github.com/QuiteClose/zjot) | Djot-to-HTML converter | MIT |

**`build.zig.zon`** pins these with `git+https://github.com/QuiteClose/{repo}.git#tag` plus a `1220…` content hash so a clone builds without sibling folders. Refresh pins with `zig fetch --save git+https://github.com/QuiteClose/toupee.git#vX.Y.Z` (use **`.url` + `.hash`** in the zon — a bare `git+…` string must not be stored under `.path`).

**Tagging convention:** Always pin dependencies to git tags (`#vX.Y.Z`), not bare commit SHAs. Commit-hash pins are acceptable only temporarily during cross-repo development of an unreleased feature. As soon as the dependency is tagged, update the pin to the tag.

## Build commands

The wig repo's `build.zig` has `run`, `test`, and install steps only:

```
zig build          # compile wig CLI + library
zig build test     # run all tests (unit + spec tests)
zig build run      # run the wig CLI
```

**Binary workflow:** `wig init [path]` then `wig build [path] [--clean] [--strict-links]` writes the static site to `<site-root>/zig-out/site/` (same layout as the spec runner). Internal links are checked post-build; `--strict-links` makes broken links errors. No project `build.zig` is required for SSG.

**Dev server:** `wig serve [path] [--host HOST] [--port PORT] [--no-reload]` builds the site, serves it over HTTP, watches for source file changes, rebuilds on change, and live-reloads connected browsers via WebSocket. Default host is 127.0.0.1; use `0.0.0.0` to accept connections from other machines. Default port is 8080.

**Optional Zig project:** Users who embed the library may add their own `build.zig` with `zig build render`, `zig build serve`, or `zig build check` wrappers; that is separate from the stock CLI.

## Project structure

```
wig/
  build.zig         # library module (wig) + CLI executable
  build.zig.zon     # declares toupee, comb, zjot dependencies
  src/
    root.zig        # public API: Site struct, BuildResult, orchestration (buildPhase_*)
    main.zig        # wig CLI entry point
    config.zig      # site config + style manifest loading
    page_meta.zig   # PageMeta, CascadeData, PaginateConfig structs; parsePageMeta, toTemplateValue
    build_context.zig # BuildContext struct, Hooks (pre/post scan/render/build)
    diagnostics.zig # Diagnostic, Collector (structured error/warning accumulation)
    collections.zig # buildPageValue, buildCollections, buildParentMap, buildChildrenMap
    cascade.zig     # cascade resolution: resolveLayout, resolveStyle, applyCascadeToContext
    template_loader.zig # StyleLoader + loadTemplates (shared by buildAll and check)
    tag_pages.zig   # taxonomy tag page rendering (/tags/, /tags/{slug}/, /tags/{a}/{b}/)
    tokens.zig      # fluid typography + spacing computation (CUBE CSS)
    colors.zig      # color scheme resolution (palette indirection; data key `colors`)
    context.zig     # Comb.Value/std.json.Value -> Toupee.Value translation
    comb_utils.zig  # safe typed extraction from comb.Value (getString, getBool, getList, etc.)
    slug.zig        # URL slugification (slugifyStem, isSpecialStem, slugifyTerm)
    xml.zig         # XML escaping (appendXmlEscaped)
    frontmatter.zig # shared YAML frontmatter detection + stripping
    pattern_parser.zig  # pattern file parser: front-matter + body split on <!-- variant: .* --> delimiters
    pattern_loader.zig  # pattern directory scanner: styles/{name}/patterns/{category}/*.html, file + generic resource discovery
    import_resolver.zig # imports: resolution: merge patterns across styles, topological ordering
    auto_bundler.zig    # @layer CSS auto-bundling from resolved patterns, CUBE order, content-hashed output
    scanner.zig     # walk pages/, collections (ScanResult.init), sections, render gating
    taxonomies.zig  # reverse index from page tags/categories (context key: `tags`)
    pages.zig       # page rendering: unified renderPage, content parsing, shortcodes, layout
    toc.zig         # heading extraction from HTML for table of contents
    search.zig      # search index generation (search.json)
    feeds.zig       # Atom feed + sitemap generation
    app.zig         # web framework: App, route declaration, middleware
    router.zig      # route matching, path parameters, RouteGroup (with deinit)
    handler.zig     # request Context (with deinit), Endpoint, pipeline()
    session.zig     # cookie-based sessions, MemoryStore (returns pointers, handles overwrites)
    scaffold.zig    # wig init (copies skel/site), add style, add block, install
    skel.zig        # embedded skel/site tree for wig init scaffolding
    html.zig        # shared HTML utilities (stripTags)
    test_runner.zig # spec test runner (`NNN_*.yaml` full-site builds)
    test_report.zig # report types, Reporter, Failure, unified diff formatting
    output_verifier.zig # output verification: HTML normalization, glob matching
    output_paths.zig  # canonical zig-out/site paths (build + dev server)
    link_checker.zig # post-build internal link + fragment checking
    serve.zig       # dev server: DevServer struct, HTTP thread, rebuild loop, WS broadcast
    watcher.zig     # file system watcher (polling); detects source changes for dev server
    mime.zig        # extension-to-content-type lookup (used by dev server)
    serve/
      reload.js     # embedded WebSocket reload client (~20 lines); injected into HTML
  test/
    NNN_*.yaml      # spec tests (3-digit id prefix; primary integration tests)
  skel/
    site/           # default project tree copied by `wig init` (`cube` + `default`, data, pages, files)
```

### Typed PageMeta architecture

The pipeline uses **typed representations until the template boundary**. All well-known frontmatter fields are parsed into a `PageMeta` struct at scan time; only `raw_frontmatter` (as `toupee.Value`) crosses into template rendering.

```
comb.Value (YAML parse) → parsePageMeta → PageMeta (typed, compile-time safe)
                                        → raw_frontmatter (toupee.Value, for template context)
```

`PageEntry` carries both: `meta: PageMeta` for pipeline logic (cascade, search, feeds, tag pages) and `raw_frontmatter: toupee.Value` for the `document.*` template namespace. This eliminates ~25 instances of runtime map-drilling boilerplate.

## Architecture

### Library-first design

Wig is a Zig library (`Site`, `Site.buildAll`, …) that also ships a **`wig` executable**. Most authors use only the binary: `wig init` copies `skel/site/` (shared `cube`, `default` style, `data/`, `pages/`, `files/`), then `wig build` produces `zig-out/site/`. Embedders who import Wig into an app can still call the same APIs from their own `build.zig` or binaries.

### SSG + web framework (hybrid architecture)

Wig is **both** an SSG and a **library for Zig web applications**. The same templates, data model, styles, and CUBE CSS methodology serve two output targets:

1. **SSG path** (`wig build`): Scans `pages/`, renders through Toupee, writes HTML files to `zig-out/site/`. Deploy to GitHub Pages, Netlify, or any static host. This is the primary, fully specified path with YAML specs in `test/NNN_*.yaml`.

2. **Web-framework path** (Zig app in `src/`): A Zig application imports Wig as a library, handles HTTP requests, builds a Toupee context from request data, and renders templates into response bodies. HTMX snippets can be returned as rendered fragments (no `<t-extends>` wrapper). The static site and the dynamic backend coexist: static pages on GitHub Pages can poll the backend for interactive content.

**Typical hybrid project layout:**

```
my-project/
  files/           # static files (images, fonts, robots.txt) → output root
  data/            # YAML data (site.yaml, document.yaml, colors/)
  src/
    main.zig       # Zig app: imports wig, handles routes, renders responses
  styles/          # CUBE CSS: cube/ + default/ (templates, css, data/)
  pages/           # Djot/HTML content for SSG path
  build.zig        # builds both: wig SSG output + src/main.zig binary
  build.zig.zon    # depends on wig (which brings toupee, comb, zjot)
```

**How the two paths share everything:**
- **Templates** — `src/main.zig` loads the same Toupee `Engine` with the same templates from `styles/`. A route handler calls `engine.renderToString("blocks/game-grid.html", ctx)` to produce an HTMX fragment.
- **Data** — `data/site.yaml`, color schemes, tokens are available to both paths. The SSG injects them via `buildAll`; the app loads them via Wig's config API.
- **Styles** — Auto-bundled pattern CSS (`@layer` order), CUBE layers, fluid tokens are built by `wig build` and served as static assets by both GitHub Pages and the app server.

**Web-framework layer** (`app.zig`, `router.zig`, `handler.zig`, `session.zig`) is still **early**: behaviour is not fully specified, it is **not** exercised by the current YAML spec suite, and APIs may change. The four technical requirements are:

1. **Render-to-string** — render a Toupee template with a context, return the HTML string.
2. **Request context → template context** — map HTTP request data into `toupee.Value`.
3. **Route → handler → template** — Sinatra-level simplicity: `app.route("/game", handler)`.
4. **Fragment rendering** — render a template without `<t-extends>`, returning just the HTML fragment (essential for HTMX `hx-get` responses).

**Deployment model:** Static site on GitHub Pages (or similar). Dynamic backend as a containerised Zig binary. Static pages use HTMX attributes (`hx-get`, `hx-swap`) to request fragments from the backend. The backend serves fragments only — it does not need to serve the full site.

### Two-phase Site struct

- `Site.init(allocator, options)` opens the site root directory (`options.root` relative to the process CWD). It does **not** read YAML until `buildAll()`.
- `Site.buildAll()` loads site + style manifests and data files, runs the pipeline (see named phases in `root.zig`: `buildPhase_*`), and stores `site_config`, `style_configs`, `data_result`, `toupee.Engine`, and `build_arena` on the struct.

### Allocators and lifetimes (embedders + contributors)

- **`Site.allocator`** — The allocator passed to `init`. Owns long-lived state: config loaded after `buildAll()`, the **Toupee `Engine`** (template storage and internal arenas), and anything freed in `Site.deinit()`. Use it for work that must survive across builds or for HTTP handlers that outlive a single `buildAll()`.
- **`build_arena`** — After each successful `buildAll()`, an arena allocator holds most **per-build** data: scan results, the shared template name→source map, the main Toupee `Context` for rendering, and transient strings. The next `buildAll()` destroys and recreates this arena; **do not** retain pointers into it past the build or across a second `buildAll()` on the same `Site`.
- **Why the engine uses `Site.allocator`** — `Engine.init` / `addTemplate` use the main allocator so template memory is **not** tied to `build_arena`, avoiding use-after-free when the arena is reset on rebuild.
- **Dev server** (`serve.zig`) — `DevServer.run` takes `*Site` and manages the build-serve-watch-reload cycle. The server reads built output from `zig-out/site/` under a shared `RwLock` (readers serve files; writer rebuilds). Per-request allocations use `Site.allocator`.
- **Web-framework / HTTP layer** — For hybrid apps where handlers render Toupee templates: keep a `*Site` (or engine pointer) in the app’s `src/main.zig` so handlers can call render-to-string.

### Output paths (`output_paths.zig`)

The library re-exports `wig.output_paths`. Use it for any code that must agree with the SSG on disk layout:

- `default_site_output_rel` — `"zig-out/site"` (relative to site root); same default as `TestRunnerConfig.output_dir`.
- `joinSiteOutputDirAbs(allocator, abs_site_root)` / `joinZigOutDirAbs` — owned absolute paths.
- `prepareSiteOutput(allocator, abs_site_root, clean)` — ensures directories exist (and optionally wipes the site output tree); used by `buildAll()`.

### Key types

```zig
const wig = @import("wig");

// Static build — buildAll returns BuildResult with page count and diagnostics
var site = try wig.Site.init(allocator, .{ .root = ".", .draft = draft });
const result = try site.buildAll(.{ .clean = clean, .pretty = false });
std.debug.print("Built {d} pages\n", .{result.page_count});

// Dev server (builds, serves, watches, and live-reloads)
var site = try wig.Site.init(allocator, .{ .root = "." });
try wig.DevServer.run(allocator, &site, .{ .port = 8080, .live_reload = true });
```

### Rendering pipeline

Content rendering is a three-phase pipeline:

1. **Wig preprocess** -- resolve `{{ variable }}` interpolations in the Djot source. Uses Toupee's existing value resolution and transform system. Supports pipe-chained transforms: `{{ document.date | date:%B %e, %Y }}`.
2. **zjot** -- parse the preprocessed Djot into HTML. Toupee `<t-*>` tags and `t-var:*` attribute bindings pass through as raw HTML.
3. **Toupee** -- single render pass on the layout template with zjot's output slotted in via `<t-slot />`. Resolves all remaining template tags (`<t-var>`, `<t-if>`, `<t-for>`, `t-var:href`, etc.).

**Content authors** use `{{ }}` for value interpolation in Djot (e.g. links, inline values). **Template authors** use Toupee's `<t-*>` elements and attribute bindings in layout HTML.

For Toupee tags in Djot content, use Djot's raw HTML passthrough:
- Inline: `` `<t-include template="blocks/nav.html" />`{=html} ``
- Block: bare `<t-include template="blocks/nav.html" />` on its own line (Djot auto-detects block HTML)

### Content parsers

Pluggable via `Site.init()`. Default: zjot (Djot). The architecture supports additional content formats (e.g. Markdown via `.md` extension) by registering additional parsers. Markdown support is planned but not at launch.

**Djot emphasis:** In zjot/djot, a single asterisk run wraps **strong** (`*word*` → one `<strong>`). Doubling asterisks (`**word**`) opens/closes two delimiter runs and can yield **nested** `<strong>` tags; prefer `*…*` for ordinary bold in specs unless nested strong is intentional.

The `ContentParser` type is a function pointer, defined in `pages.zig` and re-exported by `root.zig`:

```zig
pub const ContentParser = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;
pub const ContentParserEntry = struct { extension: []const u8, parse: ContentParser };
```

### Check (config/template validation)

`Site.check()` performs a dry run (no rendering). It returns **`![]const Diagnostic`** (errors/warnings as a slice allocated with the site’s allocator — **caller must `free` the slice** when non-empty). Options:

```zig
const diags = try site.check(.{ .external_links = true });
defer site.allocator.free(diags);
// inspect diags for .kind (.err / .warning) and .message
```

### Link checking

Internal links are checked automatically during `buildAll()` as a post-render phase. The link checker walks all `.html` files in the output tree, extracts `href` and `src` attributes, and verifies that internal targets exist (both file paths and `#fragment` anchors).

- **Warnings by default** — broken links produce warnings in `BuildResult.diagnostics`. The build still succeeds (exit 0).
- **`--strict-links`** — promotes link warnings to errors, causing the build to fail (exit 1). Use in CI pipelines that require zero broken links.
- **`--external-links`** — accepted on the CLI but not yet implemented; external HTTP checking is planned for a future release.
- **Source attribution** — diagnostics include the originating source file path (e.g. `blog/post.dj`) by mapping output files back to source pages.

```zig
const result = try site.buildAll(.{ .strict_links = true });
// result.diagnostics contains link-checking errors/warnings
```

### Toupee API (template engine)

Context creation and data insertion:

```zig
var ctx = toupee.Context.init(allocator);
defer ctx.deinit();
ctx.put("title", .{ .string = "Hello" });            // top-level key
ctx.putAt("document.title", .{ .string = "About" }); // dot-path, creates intermediate maps
ctx.putAt("document.url", .{ .string = "/about/" });
```

Engine for cached templates: Wig's StyleLoader loads from `templates/layouts/` and `templates/blocks/`. Template names use explicit paths: `layouts/page.html`, `blocks/card.html`.

Value type supports: `.string`, `.boolean`, `.integer`, `.float`, `.list`, `.map`, `.nil`.

### Template syntax

Toupee uses `<t-*>` HTML elements. Key tags:
- `<t-extend template="...">` -- template inheritance
- `<t-slot />` -- slot for child content
- `<t-include template="...">` -- component inclusion (supports `isolated` + `context` for scope isolation)
- `<t-var name="...">default</t-var>` -- variable output (HTML-escaped)
- `<t-raw name="..." />` -- unescaped output (for CSS values)
- `<t-for item in collection>` -- iteration
- `<t-if var="...">` -- conditional (default: checks key **existence**; see comparisons below)
- `<t-let name="..." value="...">` -- variable capture

**Conditional sources:** `<t-if>` supports three source attributes: `var` (context variable), `attr` (template attribute), `slot` (slot existence). Exactly one is required.

**Conditional comparisons:** By default, `<t-if var="x">` checks whether `x` exists in context. Add a comparison attribute for richer tests:

| Attribute | Meaning |
|-----------|---------|
| *(none)* | Key exists (default) |
| `not-exists` | Key does not exist |
| `truthy` | Value is truthy (non-empty string, `true`, non-zero number, non-empty list/map) |
| `not-truthy` | Value is falsy (empty string, `false`, zero, empty list/map, nil, or missing) |
| `equals="v"` | String-equal to `v` |
| `not-equals="v"` | Not string-equal to `v` |
| `contains="v"` | String contains `v` |
| `starts-with="v"` | String starts with `v` |
| `ends-with="v"` | String ends with `v` |
| `matches="v"` | Matches pattern `v` |

**Existence vs truthiness:** `<t-if var="x">` passes when `x` is present regardless of value (a key set to `false` still passes). Use `<t-if var="x" truthy>` when you need to check the value itself.

### Frontmatter

YAML only, delimited by `---`. Required for all pages in `pages/`.

**Single rule:** Wig loads the YAML **root object** and places it under the template context key `document` unchanged in shape: each **root key** `K` becomes **`document.K`**. There is no second spelling (no “implicit merge” of a root `document:` block into `document.*`).

- Root `title:` → `document.title`. Root `data:` → `document.data` (cascade payload). Root `draft:` → `document.draft`, etc.
- If the root includes a key literally named `document`, its value is exposed as **`document.document`** (nested keys are `document.document.*`). That is almost never what you want for normal metadata; use root keys such as `title:` instead. See `test/035_frontmatter_document_key.yaml`.

Normalization only wraps the parse result as `{ document: <root mapping> }` for the internal pipeline. An empty fence (`---` then `---`) yields an empty `document` map. A sole root key `document:` **must** map to an object; a scalar (e.g. `document: foo`) is invalid.

**Well-known root keys** (each lives under `document` after load): `title`, `layout`, `style`, `date`, `tags`, `description`, `thumbnail`, `draft`, `debug`, `slugify`, `search`, `data` (cascade payload), `paginate`, etc. — merged into `document.*` in the rendering context except where noted below.

`document.data` — cascading data for child pages. Wig processes this at build time and **strips it from the template context**. It is a build instruction, not template data.

Example leaf page:

```yaml
---
title: About Us
---
```

Example section index (`_index.dj`) with cascading defaults:

```yaml
---
layout: blog-index.html
title: Blog Posts
data:
  document:
    style: blog
    layout: blog-post.html
---
```

Pages inherit `document.*` values from the cascade (see Data cascade below). This page’s frontmatter overrides inherited defaults at `document.*`.

Files in `styles/` with frontmatter are template-rendered; without are plain text. CSS files get the full site context minus `document.*` (they see `styles.*`, `colors.*`, `site.*`, etc.).

### Clean URLs

- `pages/about.dj` -> `about/index.html`
- `pages/_index.dj` -> `index.html` (section index -- only `_index` is special)
- `pages/sub/index.dj` -> `sub/index/index.html` (regular page named "index")
- `pages/posts/_index.dj` -> `posts/index.html` (section index)
- `pages/_404.dj` -> `404.html` (error page -- no directory wrapping)
- `pages/_500.dj` -> `500.html` (error page pattern for any `_NNN` prefix)

**Only `_index.dj` / `_index.html`** is the section index convention. A file named `index.dj` is treated as a normal page and gets clean URL wrapping (`index/index.html`).

**URL slugification:** When `slugify: true` is set in the data cascade (default via `data/document.yaml`), page filename stems are slugified: underscores become hyphens and letters are lowercased. For example, `my_post.dj` -> `/my-post/`. Special stems (`_index`, `index`, `_NNN` error pages) are never slugified. Individual pages can override with `slugify: false` in frontmatter.

### Template context model

Wig's template context has three tiers:

**Site scope** (top-level keys):
- `site` -- from `data/site.yaml`
- `pages` -- page collection (engine-computed)
- `tags` -- tag indexes (engine-computed)
- `styles` -- full style tree (engine-computed)
- *Any other key* -- from files in `data/` (e.g. `data/colors/solarized.yaml` -> `colors.solarized`)

**Style scope** (`styles.{name}.*`):
- `tokens` -- design tokens (from `style.yaml`, extended with `tokens.computed`)
- `css.path` -- hashed auto-bundled CSS path (engine-computed)
- `patterns` -- resolved pattern tree with categories, items lists, and flat all list (engine-computed)
- `files` -- nested map mirroring `styles/{name}/files/` directory (engine-computed; keyed by stem, values are web path strings; directories with files get an `items` list)
- *Any other key* -- from `style.yaml` or from files in `styles/{name}/data/`

**Page scope** (per-page):
- `document` -- frontmatter cascade + engine-computed values (path, url, layout, style, parent, ancestors, children, toc, excerpt)
- `paginate` -- pagination chunks (when active)

**Reserved site-level keys** (data files must not shadow): `pages`, `styles`, `tags`, `paginate`.

**Reserved style-level keys** (style data files must not shadow): `css`, `patterns`, `tokens`, `files`.

### Data cascade

Sources merged in priority order (highest priority last -- later sources override earlier):

1. Global data files (`data/` -> top-level keys by filename, e.g. `data/site.yaml` -> `site.*`, `data/document.yaml` -> `document.*`)
2. Render flags (`site.draft`, `site.debug`)
3. Style manifest data (`styles.{name}.*`) and style data directories (`styles/{name}/data/`)
4. Page collection (`pages.*`) and tag indexes (`tags.*`)
5. Directory-level cascading data (`document.data`, from root key `data:` in `_index.dj` frontmatter, applied to child pages)
6. The current page's frontmatter fields (highest priority -- overrides all inherited `document.*` values)

**Directory-level data overrides:** Root key `data:` in `_index.dj` frontmatter (`document.data` after load) can override any data key. For example, `data: site: author: GuestAuthor` overrides `site.author` for all pages in that directory and its children. Children and grandchildren inherit the override; pages outside the directory see the global value. Wig strips `document.data` from the template context after processing.

**Self-exclusion:** A section's `_index.dj` data cascade applies to children in that directory, not to the `_index.dj` itself. The section index page inherits from its parent's cascade, not its own `data:` block. See `test/011_data_cascade_override.yaml`.

### Page collection

The `pages` context key is a nested map mirroring the `pages/` directory tree (`pages.*` in templates and data). Each page's metadata lives under a reserved `document` key:

- `pages/_index.dj` -> `pages.document` (root page metadata)
- `pages/about.dj` -> `pages.about.document` (leaf page metadata)
- `pages/blog/_index.dj` -> `pages.blog.document` (section index metadata)
- `pages/blog/post_one.dj` -> `pages.blog.post_one.document` (child page metadata)

Metadata keys include `path` (URL path), `title`, `date`, and all other keys copied from page YAML into that page’s `document` map. Example: `pages.blog.post_one.document.path` -> `/blog/post-one/` (with default slugification enabled, underscores become hyphens in URLs; the collection key retains the original stem).

**`document` is a reserved key.** A page or directory named `document` is an error.

**File/directory collision:** `pages/blog.dj` is an error if `pages/blog/` also exists.

**Iteration:** `<t-for post in pages.blog>` iterates child pages (skips the `document` key). Access metadata inside the loop via `post.document.path`, `post.document.title`, etc.

### Current page (`document.*`)

The `document.*` namespace is the sole per-page context. There is no `page.*` namespace.

When rendering a page, `document.*` is populated by merging (in priority order):

1. `data/document.yaml` -- global document defaults
2. Directory-level `data.document:` from ancestor `_index.dj` files
3. The page's own frontmatter keys promoted to `document.*` (highest priority; engine-computed keys like `path`, `url`, `toc`, `excerpt`, `style`, `layout`, `parent`, `ancestors`, `children` are not overwritten by frontmatter)

Wig also injects computed values:

- `document.path` -- URL path (e.g. `/about/`)
- `document.url` -- absolute URL (e.g. `https://example.com/about/`), built from `site.url` + `document.path`
- `document.style` -- full style manifest map (parsed from `style.yaml`). Access fields via `document.style.name`, `document.style.version`, etc.
- `document.parent` -- map with the parent page's document data (`path`, `title`, etc.). Nil for the root page.
- `document.children` -- list of **child** content pages in the same `pages/` directory as this section's `_index` (non-`_index` files only). Each item uses the **same page map shape** as the current page in context (`path`, `url`, `source`, nested `document`, etc.). Empty for leaf pages and for sections with no children.
- `document.ancestors` -- list of ancestor page document maps, from parent to root (nearest first). Empty list for the root page.
- `document.excerpt` -- from `description:` in frontmatter, or falls back to the first paragraph of content (text-only).
- `document.thumbnail` -- from `thumbnail:` in frontmatter. Asset path (e.g. `/images/hero.jpg`).
- `document.toc` -- list of heading maps extracted from rendered content: `{id, text, level}`. Headings come from zjot `<section>` elements. **`id` is a URL fragment** (e.g. `#Introduction`) suitable for `href` on `<a>`; the HTML `section` still uses the bare id attribute value.
- `document.draft` -- boolean from frontmatter. When true, page is excluded from `wig build` but included with `wig build --draft`.

These are primitives -- features like breadcrumbs are built by template authors, not provided by Wig. For example, breadcrumbs can be implemented by iterating `document.ancestors` with `order="reverse"` on `<t-for>` to get root-first order.

This is the same data as `pages.{key}.document` but accessible without knowing the page's collection key.

### Date format

Dates in frontmatter use ISO 8601 format with optional time: `2026-03-16` (date only) or `2026-03-16T14:30:00Z` (with time). String comparison on `YYYY-MM-DD` gives correct chronological order. Used for sorting (`<t-for ... sort="document.date">`), feeds, sitemaps, and the `date` transform.

### Style directory structure (CUBE-aligned)

Each style lives under `styles/{name}/` with well-defined subdirectory roles:

```
styles/default/
  style.yaml         # style manifest (name, imports, tokens, scheme, custom fields)
  patterns/          # RESERVED: pattern files (frontmatter + example markup)
    tokens/*.html
    resets/*.html
    globals/*.html
    fonts/*.html
    compositions/*.html
    utilities/*.html
    blocks/*.html
    exceptions/*.html
  templates/         # RESERVED: Toupee templates (layouts + blocks)
    layouts/*.html   # page shells (base.html, page.html, post.html)
    blocks/*.html    # components (breadcrumbs.html, card.html)
  data/              # RESERVED: style-scoped data (styles.{name}.*)
  demo/              # RESERVED: raw files copied to pages/ on style install
  files/             # raw files, binary-safe, no preprocessing → /assets/styles/{name}/
  css/               # resource: pattern CSS; auto-bundled if pattern-matched
    tokens/*.css
    resets/*.css
    globals/*.css
    fonts/*.css
    compositions/*.css
    utilities/*.css
    blocks/*.css
    exceptions/*.css
  {anything}/        # generic resource directories (js/, scripts/, shaders/, etc.)
```

**Reserved directories** (special handling by the pipeline):
- `patterns/` — CUBE CSS patterns. Each `.html` file has YAML front-matter and an HTML body. Variants separated by `<!-- variant: name -->`. See **Pattern file format**.
- `templates/layouts/` — page shells referenced via `document.layout`. Use `<t-extend template="layouts/page.html">`.
- `templates/blocks/` — CUBE blocks (components). Use `<t-include template="blocks/card.html" />`.
- `data/` — style-scoped data. YAML/JSON files under `styles/{name}/data/` are loaded into `styles.{name}.*`.
- `demo/` — raw files for demo content, copied to `pages/` on style install.

**`files/`** — raw files (images, fonts, etc.), copied verbatim to `/assets/styles/{name}/` in output. Exposed in context as `styles.{name}.files` (nested map keyed by stem; directories with files get an `items` list). **Stem collision is an error:** two files sharing a stem but differing in extension (e.g. `icon.svg` and `icon.png`) fail the build.

**Generic resource directories** — any non-reserved subdirectory is treated as a resource type. Names are author-chosen (`css/`, `js/`, `scripts/`, `images/`, etc.). Files mirror the pattern hierarchy (`{category}/{id}.{ext}`). Discovered dynamically — Wig is unopinionated about what resource types exist. Text-based resource files with a `---` frontmatter fence are rendered through Toupee for token interpolation. The auto-bundler requires the name `css/` by convention.

**Output mapping:**

```
files/  is the input,  assets/  is the output.

Site:   files/{rest}                         →  /{rest}
Style:  styles/{style}/files/{rest}          →  /assets/styles/{style}/{rest}
Rsrc:   styles/{style}/{type}/{cat}/{id}.ext →  /assets/{type}/styles/{style}/{cat}/{id}.ext
```

**Collision check:** If the site-level `files/assets/styles/` directory exists, the build errors to prevent conflicts with style file output paths.

### CUBE CSS categorization guide

Wig is a style-focused site generator with first-class support for the CUBE CSS methodology. Patterns are organized into the following categories, which determine both the `@layer` order in auto-bundled CSS and the sidebar display order in the pattern library:

| Category | Layer | Purpose | Examples |
|----------|-------|---------|----------|
| **tokens** | `tokens` | Design token custom properties (colors, spacing, typography) | Color swatches, spacing scale, type scale |
| **resets** | `resets` | CSS reset / normalization | Box-sizing, margin removal, form resets |
| **globals** | `globals` | Document-level styles applied via element selectors | Body typography, link styles, surface backgrounds |
| **fonts** | `fonts` | Font-face declarations and font stack utilities | System font stack, custom web fonts |
| **compositions** | `compositions` | Layout primitives (no visual styling) | Stack, Cluster, Sidebar, Grid, Switcher, Center, Flow, Region, Repel, Wrapper |
| **utilities** | `utilities` | Single-property utility classes | Text sizes, text colors, indent, radius, visually-hidden |
| **blocks** | `blocks` | Styled components with semantic markup | Button, Tag, Prose, Skip Link, Card, Header, Footer |
| **exceptions** | `exceptions` | Data-attribute overrides for edge cases | `[data-narrow]` for constrained widths |

**Layer ordering:** CSS is auto-bundled with `@layer` declarations in the order above. This ensures the CUBE CSS cascade: resets first, exceptions last.

**Categorization guidelines:**
- A pattern that sets layout (flex/grid) without visual styling → **compositions**
- A pattern that applies a single property → **utilities**
- A pattern with semantic markup and visual styling → **blocks**
- A pattern that overrides via `data-*` attributes → **exceptions**
- Document-level element selectors (h1-h6, p, a) → **globals**
- Custom property definitions → **tokens**

### Pattern file format

Each pattern is an HTML file with YAML front-matter in `styles/{name}/patterns/{category}/{id}.html`:

```html
---
name: Button
source: .button
description: Styled control for button and anchor elements.
config:
  - property: --button-bg
    default: var(--color-bg-secondary)
    description: Background color.
notes: Use the <code>templates/blocks/button.html</code> template for consistent markup.
---
<button class="button">Default</button>
<!-- variant: Primary -->
<button class="button" data-type="primary">Primary</button>
```

**Front-matter fields:** `name` (display name), `source` (CSS selector), `description` (HTML allowed via `t-raw`), `config` (list of `{property, default, description}` maps), `exceptions` (list of `{attribute, description}` maps), `notes` (HTML), `links` (list of `{label, url}` maps).

**Body:** HTML example markup. Default example is the text before the first variant delimiter.

**Variant delimiters:** `<!-- variant: Name -->` on its own line separates variants. Each variant gets its own preview and source view.

**Front-matter-only patterns:** Patterns with no body (e.g. tokens, resets) are valid. They document configuration without providing example markup.

**Pattern example rendering:** All pattern examples are rendered through Toupee before being stored in the context. This allows patterns to use `<t-include>` to reference actual templates, preventing duplication and drift between examples and templates. Toupee is inert on plain HTML — examples without `<t-*>` tags pass through unchanged. The rendering happens during `buildPhase_patternsAndBundle`, before the full context is built, using the style context (tokens, colors, data) so examples can reference style values via `<t-var>`.

**Resource discovery by convention:**
- `css/{category}/{id}.css` — pattern CSS (stored raw after frontmatter strip; rendered per-consumer at bundle time — see CSS auto-bundling below)
- `templates/{category}/{id}.html` — Toupee template (raw source shown in pattern library)
- `{type}/{category}/{id}.{ext}` — generic resources (any non-reserved directory name: `js/`, `scripts/`, etc.)
- `files/{category}/{id}/*` — raw files (copied verbatim to `/assets/styles/{style}/{category}/{id}/`)

Generic resources are discovered dynamically — any subdirectory not in the reserved set (`data/`, `demo/`, `patterns/`, `templates/`, `files/`) is treated as a resource type. Text-based resource files with `---` frontmatter are rendered through Toupee before output.

### Imports

Styles declare dependencies via `imports:` in `style.yaml`. Imported patterns merge into the importing style's namespace (local patterns override imported ones at the same `{category}/{id}`).

```yaml
imports:
  cube:
    patterns: "**"          # import all patterns from cube
  highlights:
    patterns:
      blocks:
        - code-editor       # import specific pattern
      globals: "**"         # import entire category
    data:
      colors: [rosepine, solarized]  # validate data exists in upstream
```

**Pattern imports** (`patterns:`): Merged into the local style's resolved pattern set. Local patterns at the same `{category}/{id}` take precedence. Resources (CSS, templates, and any generic resource types) travel with the pattern.

**Data imports** (`data:`): Validate that the specified data exists in the upstream style's namespace. Data remains accessible at `styles.{upstream}.*` — it is not copied into the importing style's namespace.

**Build order:** `imports:` keys determine topological sort order for pattern resolution and auto-bundling. Upstream styles are processed before their dependents.

### Template resolution

**Explicit paths in HTML:** Authors must use explicit paths so the loader knows which subdirectory to use. Toupee uses the `template` attribute for both `<t-extend>` and `<t-include>`.

| Element | Path form | Example |
|---------|-----------|---------|
| `<t-extend template="...">` | `layouts/X.html` | `layouts/page.html` |
| `<t-include template="...">` | `blocks/X.html` | `blocks/footer.html` |

The path prefix selects the subdirectory. No resolution order or fallback is needed.

**Short form for document.layout:** Because Wig knows the style and that `document.layout` is always a layout, frontmatter can use the short form at the YAML root:

```yaml
layout: page.html
```

Resolves to `{style}/templates/layouts/page.html`. No `layouts/` prefix needed in frontmatter.

**Cross-style override:** Use `style:path` to pull templates from another style:

| Form | Meaning |
|------|---------|
| `blocks/paragraph.html` | Current style's blocks |
| `cube:blocks/paragraph.html` | `cube` style's blocks |

Parsing: split on first colon. If present, left = style name, right = path. Applies to both `<t-extend>` and `<t-include>`. Colons in path segments are reserved. Cross-style references use **`style:path` only** (there is no `cube/layouts/...` slash alias).

### CSS auto-bundling

Wig automatically bundles CSS from resolved patterns into a single hashed file per style. No manual `bundles:` configuration is needed.

**How it works:**
1. Patterns are resolved (local + imported via `imports:`)
2. CSS files at `css/{category}/{id}.css` are stored raw (frontmatter stripped, Toupee tags preserved)
3. At bundle-assembly time, each CSS body is rendered through Toupee with a **per-consumer context**: the base `style_ctx` plus a top-level `style` key bound to the consuming style's data (`styles.{consumer}.*`). This means a CSS file shipped from an imported style (e.g. `highlights`) can produce different output for each consumer, enabling consumer-driven theme bundling.
4. Each category's CSS is wrapped in an `@layer` block (CUBE order: tokens, resets, globals, fonts, compositions, utilities, blocks, exceptions)
5. The concatenated CSS is content-hashed and written to `zig-out/site/assets/css/styles/{style}.{hash}.css`

**Per-consumer context keys:** Templates in CSS files can reference:
- `style.*` — the consuming style's manifest data (e.g. `style.highlights.available`)
- `styles.*` — all styles' data (e.g. `styles.highlights.colors.*` for imported schemes)
- `site.*`, `colors.*` — global site and color data

**Style manifest items:** Map-of-maps blocks in `style.yaml` (such as `highlights.available`) get an `items` list synthesised automatically, so `<t-for pair in style.highlights.available>` iterates them in declaration order.

**Template access:** `document.style.css.path` provides the hashed CSS path for the current page's style:

```html
<link rel="stylesheet" t-var:href="document.style.css.path" />
```

**Generated CSS structure:**

```css
@layer tokens { /* css/tokens/*.css */ }
@layer resets { /* css/resets/*.css */ }
@layer globals { /* css/globals/*.css */ }
@layer fonts { /* css/fonts/*.css */ }
@layer compositions { /* css/compositions/*.css */ }
@layer utilities { /* css/utilities/*.css */ }
@layer blocks { /* css/blocks/*.css */ }
@layer exceptions { /* css/exceptions/*.css */ }
```

**CSS with front-matter:** CSS files with `---` delimiters are rendered through Toupee before bundling. This enables token interpolation in CSS (e.g. generating custom properties from YAML data).

### Color schemes

Wig resolves palette indirection **per colour scheme YAML** merged into **`colors`** (including style-scoped `styles/{style}/data/colors/`):

1. **Palette** — maps author-chosen colour names → hex (`#…`).
2. **Semantic maps** — flat or nested YAML maps listing **palette key strings** (`document`, **`terminal`**, `syntax`).
   - **`document`**: UI roles for page chrome (text.primary, backgrounds, …).
   - **`syntax`**: code-highlighting roles.
   - **`terminal`**: canonical terminal slots (`black`, `bright-white`, `foreground`, `background`, …) → **`palette`** names; resolved at load time beside **`document`** / **`syntax`**.
3. Older site-level scheme files omit **`terminal`**; Highlights-generated themes include it explicitly.

Legacy note: manifests may still declare `scheme:` for site `data/colors/`; Highlights pairs use `style.highlights` (see Highlights style README under `wig-stand/`).

**Palette pre-resolution (`colors.resolveColorsData`):** Wig walks **`document`**, **`terminal`**, and **`syntax`** and replaces palette name strings with **`palette`** hexes. Resolved values exposed to Toupee/CSS are literals (hex strings).

For site-level examples: `colors.mono-light.document.text.primary` may resolve to `#000000` instead of `"black"`.

**Dynamic path resolution:** Templates may use **`$(expression)`** inside dot-paths so a segment is chosen at render time (e.g. `colors.$(scheme).light…`). See Toupee’s `dynamic-path.test` and docs. Wig does not add syntax beyond Toupee’s resolver.

### Resource rendering context

Text-based resource files (CSS, JS, or any generic resource) with frontmatter are rendered through Toupee but do **not** have the `document.*` namespace (they are style resources, not pages). They receive the full site context minus `document.*`:
- `styles.*` -- all style manifests; **`styles.{name}.tokens.computed`** holds fluid typography and spacing from `tokens.compute` (e.g. `styles.default.tokens.computed.typography` as a list of `{name, value}` maps)
- `colors.*` -- all color scheme data from `data/colors/` (pre-resolved)
- `site.*` -- site configuration
- All other data directory keys

This applies uniformly to all resource types — CSS, JS, SVG, or any text-based file in a generic resource directory that includes a `---` frontmatter fence.

### Template reusability

**Section-agnostic listing:** Prefer `document.children` (and includes with `context="document.children as …"`) so one block works for any section without hardcoding `pages.{section}`. See `test/013_post_iteration.yaml`, `test/014_parent_children_links.yaml`, and `test/034_blog_e2e.yaml`.

**Pagination uses an explicit collection path:** `paginate.collection` names a dot-path into the page map (e.g. `pages.posts`). That is intentional — pagination is configured in frontmatter and must point at a concrete collection. See `test/032_pagination.yaml`. This does not conflict with preferring `document.children` in templates; use whichever matches the job (reusable section lists vs paginated slices of a named collection).

```html
<t-include template="blocks/list-posts.html" context="document.children as posts" />
```

### Pattern library

Wig provides first-class CUBE CSS pattern support. Each style's patterns are HTML files with YAML front-matter in `styles/{name}/patterns/{category}/{id}.html`. See **Pattern file format** for the file structure.

**Context tree:** Resolved patterns are exposed at `styles.{name}.patterns`:
- `styles.{name}.patterns.{category}.{id}` — individual pattern fields (name, description, example, variants, css_source, template_source, etc.)
- `styles.{name}.patterns.{category}.items` — iterable list of patterns in that category
- `styles.{name}.patterns.all` — flat list of all patterns in CUBE order, each with a composite `slug` field (`{category}/{id}`)

**Active style shortcut:** Since `document.style` resolves to the full style object, templates can use `document.style.patterns.{category}.items` without knowing the style name.

**Pagination:** The pattern library uses slug-based pagination with `paginate.layout` to generate both the shell and per-pattern pages from a single `_index.dj`:

```yaml
layout: cube:layouts/patterns.html
paginate:
  collection: document.style.patterns.all
  size: 1
  slug: slug
  alias: pattern
  layout: cube:layouts/pattern.html
```

This generates:
- `patterns/index.html` — the shell (rendered with `cube:layouts/patterns.html`)
- `patterns/blocks/button/index.html` — individual pattern (rendered with `cube:layouts/pattern.html`)
- `patterns/compositions/stack/index.html` — etc.

**Shell+iframe model:** The pattern library shell template (`patterns.html`) renders a sidebar grouped by CUBE category with viewport controls (Mobile/Tablet/Desktop/Full). Each pattern link targets a named iframe that loads the individual pattern page. The pattern page template (`pattern.html`) renders the pattern's metadata, configuration table, live example, source view, and variants.

**Library overview page:** The body content of the `patterns/_index.dj` file is rendered as the default view when the pattern library loads, accessible via a "Library" link at the top of the sidebar. Clicking a pattern link hides the overview and shows the iframe; clicking "Library" hides the iframe and restores the overview. Each style can provide its own introductory content about its patterns and design language.

### Feeds

Atom feeds are declared in `data/site.yaml`:

```yaml
feeds:
  - posts
  - tech
```

Pages opt into feeds via frontmatter:

```yaml
feeds: [posts, tech]
```

Output: `feeds/{name}.xml` as valid Atom XML (RFC 4287 compliant). The feed includes required `<id>` and `<updated>` elements. Entries sorted by `document.date` (newest first). Each entry includes `<id>` (absolute URL), title, URL, date, excerpt (from `document.excerpt`), and `<content type="html">` (rendered page body).

### Sitemap

Wig generates `sitemap.xml` automatically. Each page gets a `<url>` entry with:
- `<loc>` -- absolute URL (from `site.url` + `document.path`)
- `<lastmod>` -- from `document.date` (omitted if no date)

Draft pages are excluded from the sitemap.

### Search index

Wig generates `search.json` with one entry per page:

```json
{
  "url": "https://example.com/blog/post/",
  "title": "My Post",
  "content": "Plain text content with HTML stripped.",
  "excerpt": "From description or first paragraph.",
  "tags": ["zig", "web"],
  "date": "2026-03-16",
  "section": "blog"
}
```

Fields: `url`, `title`, `content` (text-only), `excerpt`, `tags` (list or empty), `date` (or null), `section` (parent directory name or null).

**Excluding pages:** Set `search: false` in page frontmatter to exclude a page from `search.json`. The page is still built and published; it simply does not appear in the search index. See `test/041_search_exclusion.yaml`.

### Static files

Files in `files/` are copied verbatim to the **output root** without rendering or frontmatter processing. Directory structure is preserved:

- `files/robots.txt` -> `zig-out/site/robots.txt`
- `files/assets/css/reset.css` -> `zig-out/site/assets/css/reset.css`
- `files/assets/images/logo.png` -> `zig-out/site/assets/images/logo.png`

`files/` is the input directory; `assets/` is the output directory convention. To place files at `/assets/...` in the output, create `files/assets/...` in the input.

### Tags

Document frontmatter may include `document.tags: [music, tech, zig]`. With `taxonomies: [tags]` in site config (the `taxonomies` key in `site.yaml` lists the frontmatter field names to index; the resulting context key is `tags`), Wig auto-generates tag index pages (requires `layouts/tag-index.html` and `layouts/tag-list.html` in the style):

- `/tags/` — index of all tags with counts (**ordered by page count descending**, then slug)
- `/tags/{slug}/` — documents with that tag
- `/tags/{a}/{b}/` — documents that have **both** tags; path segments are the two slugs sorted **descending lexicographically** (not by popularity)

Only co-occurring pairs that appear on at least one page get an intersection URL.

Context on tag pages: `tag.tags` (all tags with counts), `tag.documents` (matching docs), `tag.path_tags` (tags in current path), `tag.document` (page metadata).

### Pagination

Frontmatter `paginate:` enables paginated list pages. The **`collection`** field is always an explicit dot-path (e.g. `pages.posts`), not `document.children` — see [Template reusability](#template-reusability) for how that relates to section-agnostic templates. Full behaviour (context shape, URL scheme) is defined by `test/032_pagination.yaml`.

```yaml
paginate:
  collection: pages.posts
  size: 10
  path: page
  alias: posts
```

Context: `paginate.items` (current page chunk), `paginate.page` (1-indexed), `paginate.total_pages`, `paginate.previous` / `paginate.next` (maps with `url`, `page` when applicable). URL scheme: page 1 at base path, page 2+ at `base_path/page/N/`.

**Layout override for slug pagination:** When using slug-based pagination (`slug:` field), a `layout:` field inside `paginate:` causes dual rendering: the section index page renders using the page's own `layout:` (e.g. a navigation shell), while each paginated sub-page renders using `paginate.layout:` (e.g. a detail view). Without this field, slug pagination generates only the sub-pages.

```yaml
paginate:
  collection: colors
  size: 1
  slug: id
  alias: color
  layout: detail.html    # sub-pages use this layout
```

See `test/060_paginate_layout_override.yaml`.

### Collection sorting

`<t-for>` supports sorting page collections by any document field:

```html
<t-for post in pages.blog sort="document.date" order="desc">
```

`sort` specifies the dot-path into each item's data. `order` is `asc` (default) or `desc`. Combined with `order="reverse"` on `document.ancestors` for breadcrumbs.

### Output

Always under `<site_root>/zig-out/site/` (see `wig.output_paths`). Production builds error if unclean. Draft builds overlay. Import `output_paths` if you need the same path strings or helpers outside `buildAll()` (e.g. tests, static file server).

## Conventions

- **Template paths:** Use explicit paths in HTML: `layouts/X.html` for extends, `blocks/X.html` for includes. Short form `page.html` only for `document.layout` in frontmatter.
- Template indentation: two spaces. `<t-*>` tags do not introduce indentation.
- Error messages: include file path. Where possible, line number and suggestion.
- Module soft limit: ~800 lines.
- CSS templates use `<t-raw>` for value output (prevents HTML escaping).
- Content interpolation uses `{{ variable }}` syntax (resolved before zjot). Supports transforms: `{{ name | upper }}`.
- Toupee tags in Djot content use raw HTML passthrough: `` `<t-include ...>`{=html} `` (inline) or bare tags on own line (block).
- Heading IDs: zjot puts IDs on `<section>` elements (case-preserving), not headings. `toc.zig` extracts accordingly.
- `wig build` outputs HTML with content placed at slot depth but no internal re-indentation.
- `wig build --pretty` applies full HTML-aware re-indentation to output.
- `makePath(...) catch {}` is intentional throughout the build pipeline. Directory creation is best-effort; the immediately-following `createFile` call surfaces the real error if the path is invalid.

## Testing

### Philosophy: YAML specs + Zig unit tests

Wig uses **two complementary** test layers:

| Layer | Role | Audience |
|-------|------|----------|
| **`test/NNN_*.yaml` specs** | End-to-end, **self-contained** scenarios: minimal site in `input.files`, declared **`test.action`**, observable checks under **`output`** (today: built files; later: status, diagnostics, HTTP expectations where applicable). | Contributors, reviewers, and **tooling** (including AI agents) — the spec is both **regression test** and **executable documentation** of how the product is supposed to behave. |
| **Inline `test` blocks** | Fast, **narrow** checks: single functions, parsers, edge cases, and internals that would be noisy or fragile in YAML. | Implementers refactoring modules. |

**Design goals for the YAML format**

1. **Prefer specs for user-visible behaviour** — Anything an author or embedder can rely on (cascade rules, URLs, feeds, errors, CLI-equivalent flows) should eventually be expressible as **input → action → expected outcome**, so the suite stays the **canonical narrative** of Wig’s behaviour.
2. **Grow the schema deliberately** — Extend **`test.action`**, **`input`**, and **`output`** (and related keys) when a feature needs integration coverage; document new fields in this file and add at least one spec that uses them. Avoid turning YAML into an unconstrained second language: **small vocabulary, clear semantics**.
3. **Honest runner parity** — The runner must implement what the schema promises. Until it does, treat missing branches as **TODO** and say so here (see below). Specs should not claim behaviour the runner does not execute.
4. **When YAML is a poor fit** — Long-lived processes (**watch**, **live reload**, real **TCP** servers), timing/races, and heavy fuzzing belong in **Zig tests** or manual/e2e flows. For those features, still add a YAML spec **only when** you can assert a **deterministic** slice (e.g. “after one build, file X exists”) or keep the story in **`test.comment`** and point to Zig tests for the non-deterministic part.
5. **Static HTTP can stay in the story** — Request → status/body/headers against a built tree or in-memory `App.dispatch` is a good fit for YAML **once** the runner supports it; full browser or WebSocket replay is not.

**Trade-offs (intentional)**

- Specs are **slower** and **heavier** than unit tests; keep each file **focused** (one main behaviour + `test.name` / `test.comment` explaining *why*).
- Golden `output.files` **churn** when formatting changes; prefer stable assertions (normalization already lives in `output_verifier.zig`) and small fixtures.
- **Duplication** with unit tests is acceptable when the spec documents the **integrated** story; avoid re-stating the same edge case in five YAML files unless each teaches a different author-facing scenario.

### Inline unit tests

Every module has inline `test` blocks covering its public API. Run with `zig build test`. They **do not replace** YAML specs; they prove **local correctness** while specs prove **wired-up behaviour**.

### Spec tests (primary integration tests)

Full-site tests in `wig/test/NNN_*.yaml` are the **primary integration tests** and **living documentation**. They run via `runSpecTests` in `test_runner.zig` and `zig build test`.

**Runner status (parity):** The runner supports `action: wig: build` (with `--draft`, `--pretty`, `--strict-links` flags), `action: wig: check` (config/template validation), `output.files` assertions, `output.exit` (expected failures), and `output.diagnostics` (diagnostic kind + substring matching). Multi-document YAML (via `---` separators) runs each document as an independent sub-test. New features should **declare** the intended `action` shape in specs **and** extend `test_runner.zig` in the same change (or follow-up) so the schema stays truthful.

Spec format (illustrative — extend `action` / `output` as capabilities grow):

```yaml
test:
  name: Test name.
  comment: What this tests (and, for agents, what behaviour is guaranteed).
  action:
    wig: build   # reserved vocabulary; runner must implement each variant
  fixtures: []
input:
  files:
    data: { ... }
    styles: { ... }
    pages: { ... }
output:
  exit: 0        # optional; 1 = expect build/init failure
  files:
    index.html: |
      expected content
  diagnostics:   # optional; assert specific build diagnostics
    - kind: warning
      contains: "broken link"
```

Specs mirror the on-disk layout: YAML keys under `input.files` are path segments (e.g. `styles/default/templates/layouts/page.html`). The runner does not rewrite paths—use `templates/layouts/`, `templates/blocks/`, `styles/default/patterns/blocks/`, etc. Templates use explicit paths: `<t-extend template="layouts/page.html">`, `<t-include template="blocks/footer.html">`.

Each spec’s `test.name` and `test.comment` state intent; the YAML fixtures and expected `output` are the **ground truth** for behaviour. Prefer writing or extending a spec **when adding an author-facing feature** unless the feature is explicitly in the “YAML not a fit” bucket above.

### Test runner modules

- **Spec file names:** `{id}_{slug}.yaml` where `id` is **at least two** decimal digits (convention: **three**, zero-padded, e.g. `034_blog_e2e.yaml`) so the suite can grow to **999** specs before renaming. Discovery sorts by **numeric** id (not plain strings, so `100_` orders after `099_`). **`WIG_TEST`** filters by numeric id: `34`, `034`, and `034` all match spec `034_…`.
- **TestRunnerConfig** (`test_runner.zig`): Configurable `output_dir` and `workspace_dir` (defaults match `output_paths.default_site_output_rel` and `default_test_workspace_rel`). Pass to `runSpecTests(..., config)`.
- **OutputVerifier** (`output_verifier.zig`): Verifies output directory against spec; HTML normalization, glob matching (`*` only), stack/arena for comparisons.
- **SpecLoader** (`test_runner.zig`): Abstraction for loading specs. `defaultSpecLoader` reads YAML from test_dir; kept for future loaders.
