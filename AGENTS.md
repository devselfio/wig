# Wig

A library-first static site generator in Zig. Wig promotes CUBE CSS methodology and provides tools for fluid design tokens, color scheme management, and multi-style site architecture.

**Roadmap (workspace root):** [`WIG_ROADMAP.md`](../WIG_ROADMAP.md) — releases, dimension score targets vs peer deep-dives, intentional trade-offs, replay cadence.

## Who this is for

- **Site authors** — Content, frontmatter, data cascade, and Toupee templates: [Rendering pipeline](#rendering-pipeline), [Frontmatter](#frontmatter), [Data cascade](#data-cascade), [Template syntax](#template-syntax), [Page collection](#page-collection).
- **Zig embedders** — Library API and validation: [Library-first](#library-first), [Two-phase Site struct](#two-phase-site-struct), [Key types](#key-types), [Validation](#validation).
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
| [Toupee](https://github.com/QuiteClose/toupee) | HTML-native template engine (`<t-*>` elements); **v0.2+** includes `$()` dynamic dot-path segments | MIT |
| [Comb](https://github.com/QuiteClose/comb) | YAML parser | MIT |
| [zjot](https://github.com/QuiteClose/zjot) | Djot-to-HTML converter | MIT |

**`build.zig.zon`** pins these with `git+https://github.com/QuiteClose/{repo}.git#tag` plus a `1220…` content hash so a clone builds without sibling folders. Refresh pins with `zig fetch --save git+https://github.com/QuiteClose/toupee.git#vX.Y.Z` (use **`.url` + `.hash`** in the zon — a bare `git+…` string must not be stored under `.path`).

## Build commands

The wig repo's `build.zig` has `run`, `test`, and install steps only:

```
zig build          # compile wig CLI + library
zig build test     # run all tests (unit + spec tests)
zig build run      # run the wig CLI
```

**Binary workflow:** `wig init [path]` then `wig build [path] [--clean]` writes the static site to `<site-root>/zig-out/site/` (same layout as the spec runner). No project `build.zig` is required for SSG.

**Optional Zig project:** Users who embed the library may add their own `build.zig` with `zig build render`, `zig build serve`, or `zig build validate` wrappers; that is separate from the stock CLI.

## Project structure

```
wig/
  build.zig         # library module (wig) + CLI executable
  build.zig.zon     # declares toupee, comb, zjot dependencies
  src/
    root.zig        # public API: Site struct, re-exports dependency types
    main.zig        # wig CLI entry point
    config.zig      # site config + style manifest loading
    tokens.zig      # fluid typography + spacing computation (CUBE CSS)
    colours.zig     # color scheme resolution (palette indirection; data key `colors` or legacy `colours`)
    context.zig     # Comb.Value/std.json.Value -> Toupee.Value translation
    frontmatter.zig # shared YAML frontmatter detection + stripping
    bundles.zig     # asset bundles (CSS + JS): render, concat, hash
    scanner.zig     # walk pages/, collections, sections, render gating
    taxonomies.zig  # reverse index from page tags/categories
    pages.zig       # page rendering: content parsing, shortcodes, layout
    toc.zig         # heading extraction from HTML for table of contents
    search.zig      # search index generation (JSON)
    feeds.zig       # Atom feed + sitemap generation
    patterns.zig    # CSS doc comment parsing, pattern library pages
    app.zig         # web framework: App, route declaration, middleware
    router.zig      # route matching, path parameters, groups
    handler.zig     # request Context, Response, handler signatures
    session.zig     # cookie-based sessions, MemoryStore
    scaffold.zig    # wig init (copies skel/site), add style, add block, install
    html.zig        # shared HTML utilities (stripTags)
    test_runner.zig # spec test runner (`NNN_*.yaml` full-site builds)
    test_report.zig # report types, Reporter, Failure, unified diff formatting
    output_verifier.zig # output verification: HTML normalization, glob matching
    output_paths.zig  # canonical zig-out/site paths (build + future static server)
  test/
    NNN_*.yaml      # spec tests (3-digit id prefix; primary integration tests)
  skel/
    site/           # default project tree copied by `wig init` (`_core` + `default`, data, pages, assets)
```

## Architecture

### Library-first, CLI-first SSG

Wig is a Zig library (`Site`, `Site.buildAll`, …) and ships a **`wig` executable**. Most authors use only the binary: `wig init` copies `skel/site/` (shared `_core`, `default` style, `data/`, `pages/`, `assets/`), then `wig build` produces `zig-out/site/`. Embedders who import Wig into an app can still call the same APIs from their own `build.zig` or binaries.

### SSG and optional web framework

**Static site generation** is the primary, fully specified path: `Site.init`, `Site.buildAll`, the **`wig build`** command, and YAML specs in `test/NNN_*.yaml` (decimal id prefix).

**Optional web framework** pieces (`app.zig`, `router.zig`, `handler.zig`, `session.zig`, and helpers such as `devServer`) exist for users who want HTTP routing, handlers, and sessions on top of a built site. This layer is still **early**: behaviour is not fully specified, it is **not** exercised by the current YAML spec suite (which only drives full static builds), and APIs may change. Proper specification, coverage, and likely **spec-runner extensions** (e.g. HTTP-level or app-lifecycle tests) are follow-on work.

### Two-phase Site struct

- `Site.init(allocator, options)` opens the site root directory (`options.root` relative to the process CWD). It does **not** read YAML until `buildAll()`.
- `Site.buildAll()` loads site + style manifests and data files, runs the pipeline (see named phases in `root.zig`: `buildPhase_*`), and stores `site_config`, `style_configs`, `data_result`, `toupee.Engine`, and `build_arena` on the struct.

### Allocators and lifetimes (embedders + contributors)

- **`Site.allocator`** — The allocator passed to `init`. Owns long-lived state: config loaded after `buildAll()`, the **Toupee `Engine`** (template storage and internal arenas), and anything freed in `Site.deinit()`. Use it for work that must survive across builds or for HTTP handlers that outlive a single `buildAll()`.
- **`build_arena`** — After each successful `buildAll()`, an arena allocator holds most **per-build** data: scan results, the shared template name→source map, the main Toupee `Context` for rendering, and transient strings. The next `buildAll()` destroys and recreates this arena; **do not** retain pointers into it past the build or across a second `buildAll()` on the same `Site`.
- **Why the engine uses `Site.allocator`** — `Engine.init` / `addTemplate` use the main allocator so template memory is **not** tied to `build_arena`, avoiding use-after-free when the arena is reset on rebuild.
- **Optional HTTP layer** — `devServer` does not take `*Site`; use handler `Context.allocator` for per-response buffers. If a handler needs template rendering against post-build state, keep a `*Site` (or engine pointer) in user code—do not couple that into `devServer`’s signature.

### Output paths (`output_paths.zig`)

The library re-exports `wig.output_paths`. Use it for any code that must agree with the SSG on disk layout:

- `default_site_output_rel` — `"zig-out/site"` (relative to site root); same default as `TestRunnerConfig.output_dir`.
- `joinSiteOutputDirAbs(allocator, abs_site_root)` / `joinZigOutDirAbs` — owned absolute paths.
- `prepareSiteOutput(allocator, abs_site_root, clean)` — ensures directories exist (and optionally wipes the site output tree); used by `buildAll()`.

### Key types

```zig
const wig = @import("wig");

// Static build
var site = try wig.Site.init(allocator, .{ .root = ".", .draft = draft });
try site.buildAll(.{ .clean = clean });

// Dev server (HTTP layer is separate from `Site`; pass the built output directory)
var site = try wig.Site.init(allocator, .{ .root = ".", .draft = true });
try site.buildAll(.{ .clean = false });
var site_out = try site.openBuiltOutputDir();
defer site_out.close();
var app = try wig.devServer(allocator, site_out);
try app.listen(8080);
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

### Validation

`Site.validate()` performs a dry run (no rendering). It returns **`![]const Diagnostic`** (errors/warnings as a slice allocated with the site’s allocator — **caller must `free` the slice** when non-empty). Options:

```zig
const diags = try site.validate(.{ .external_links = true });
defer site.allocator.free(diags);
// inspect diags for .kind (.err / .warning) and .message
```

### Toupee API (template engine)

Context creation and data insertion:

```zig
var ctx = toupee.Context.init(allocator);
defer ctx.deinit();
ctx.put("title", .{ .string = "Hello" });        // top-level key
ctx.putAt("page.title", .{ .string = "About" });  // dot-path, creates intermediate maps
ctx.putAt("page.url", .{ .string = "/about/" });
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
- `<t-if var="...">` -- conditional (checks key **existence**, not truthiness)
- `<t-let name="..." value="...">` -- variable capture

**Conditional note:** `<t-if var="x">` checks whether `x` exists in context, not its value. A key set to `false` still passes. For boolean flags like `site.draft`, use the absent-key convention: only put the key when true.

### Frontmatter

YAML only, delimited by `---`. Required for all pages in `pages/`.

**Single rule:** Wig loads the YAML **root object** and places it under the template context key `document` unchanged in shape: each **root key** `K` becomes **`document.K`**. There is no second spelling (no “implicit merge” of a root `document:` block into `document.*`).

- Root `title:` → `document.title`. Root `data:` → `document.data` (cascade payload). Root `draft:` → `document.draft`, etc.
- If the root includes a key literally named `document`, its value is exposed as **`document.document`** (nested keys are `document.document.*`). That is almost never what you want for normal metadata; use root keys such as `title:` instead. See `test/035_frontmatter_document_key.yaml`.

Normalization only wraps the parse result as `{ document: <root mapping> }` for the internal pipeline. An empty fence (`---` then `---`) yields an empty `document` map. A sole root key `document:` **must** map to an object; a scalar (e.g. `document: foo`) is invalid.

**Well-known root keys** (each lives under `document` after load): `title`, `layout`, `style`, `date`, `tags`, `description`, `thumbnail`, `draft`, `debug`, `data` (cascade payload), `paginate`, etc. — merged into `document.*` in the rendering context except where noted below.

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

Files in `styles/` with frontmatter are template-rendered; without are plain text. CSS files get the full site context minus `document.*` (they see `styles.*`, `colors.*`, `site.*`, etc.; legacy sites may still use a top-level `colours` data directory and `colours.*` paths).

### Clean URLs

- `pages/about.dj` -> `about/index.html`
- `pages/_index.dj` -> `index.html` (section index -- only `_index` is special)
- `pages/sub/index.dj` -> `sub/index/index.html` (regular page named "index")
- `pages/posts/_index.dj` -> `posts/index.html` (section index)
- `pages/_404.dj` -> `404.html` (error page -- no directory wrapping)
- `pages/_500.dj` -> `500.html` (error page pattern for any `_NNN` prefix)

**Only `_index.dj` / `_index.html`** is the section index convention. A file named `index.dj` is treated as a normal page and gets clean URL wrapping (`index/index.html`).

### Data cascade

Sources merged in priority order (highest priority last -- later sources override earlier):

1. Global data files (`data/` -> top-level keys by filename, e.g. `data/site.yaml` -> `site.*`, `data/document.yaml` -> `document.*`)
2. Render flags (`site.draft`, `site.debug`)
3. Style manifest data (`styles.{name}.*`)
4. Page collection (`pages.*`) and taxonomies (`taxonomies.tags`)
5. Directory-level cascading data (`document.data`, from root key `data:` in `_index.dj` frontmatter, applied to child pages)
6. The current page's frontmatter fields (highest priority -- overrides all inherited `document.*` values)

**Reserved top-level keys:** `pages`, `styles`, `taxonomies` are system-provided. Data files must not shadow these names.

**Directory-level data overrides:** Root key `data:` in `_index.dj` frontmatter (`document.data` after load) can override any data key. For example, `data: site: author: GuestAuthor` overrides `site.author` for all pages in that directory and its children. Children and grandchildren inherit the override; pages outside the directory see the global value. Wig strips `document.data` from the template context after processing.

### Page collection

The `pages` context key is a nested map mirroring the `pages/` directory tree (`pages.*` in templates and data). Each page's metadata lives under a reserved `document` key:

- `pages/_index.dj` -> `pages.document` (root page metadata)
- `pages/about.dj` -> `pages.about.document` (leaf page metadata)
- `pages/blog/_index.dj` -> `pages.blog.document` (section index metadata)
- `pages/blog/post_one.dj` -> `pages.blog.post_one.document` (child page metadata)

Metadata keys include `path` (URL path), `title`, `date`, and all other keys copied from page YAML into that page’s `document` map. Example: `pages.blog.post_one.document.path` -> `/blog/post-one/`.

**`document` is a reserved key.** A page or directory named `document` is an error.

**File/directory collision:** `pages/blog.dj` is an error if `pages/blog/` also exists.

**Iteration:** `<t-for post in pages.blog>` iterates child pages (skips the `document` key). Access metadata inside the loop via `post.document.path`, `post.document.title`, etc.

### Current page (`document.*`)

When rendering a page, `document.*` is populated by merging (in priority order):

1. `data/document.yaml` -- global document defaults
2. Directory-level `data.document:` from ancestor `_index.dj` files
3. The page's own frontmatter as `document.*` (highest priority)

Wig also injects computed values:

- `document.path` -- URL path (e.g. `/about/`)
- `document.url` -- absolute URL (e.g. `https://example.com/about/`), built from `site.url` + `document.path`
- `document.style` -- full style manifest map (parsed from `style.yaml`). Access fields via `document.style.name`, `document.style.version`, etc.
- `document.parent` -- map with the parent page's document data (`path`, `title`, etc.). Nil for the root page.
- `document.children` -- list of **sibling** content pages in the same `pages/` directory as this section's `_index` (non-`_index` files only). Each item uses the **same page map shape** as the current page in context (`path`, `url`, `source`, nested `document`, etc.). Empty for leaf pages and for sections with no siblings.
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

Each style lives under `styles/{name}/` with this structure:

```
styles/default/
  style.yaml         # style manifest (name, bundles, tokens, scheme, custom fields)
  templates/
    layouts/*.html   # page shells (base.html, page.html, post.html)
    blocks/*.html    # components (breadcrumbs.html, card.html)
  css/
    compositions/*.css
    blocks/*.css
    fonts/*.css
    globals/*.css
    utilities/*.css
  patterns/
    blocks/
      *.yaml         # optional — merged into styles.{name}.patterns (see Pattern library)
      *.html         # HTML examples for pattern library / docs
    compositions/*.html
    utilities/*.html
```

- `templates/layouts/` -- page shells referenced via `document.layout`. Use `<t-extend template="layouts/page.html">`.
- `templates/blocks/` -- CUBE blocks (components). Use `<t-include template="blocks/card.html" />`. Each block has CSS in `css/blocks/` and HTML in `templates/blocks/`.
- `css/` -- stylesheets. Files with frontmatter (`---`) are rendered through Toupee (for tokens, colors). Files without frontmatter are plain text.
- `patterns/` -- pattern library material. **`patterns/{category}/*.yaml`** manifests are merged into template context (see **Pattern library**). HTML files under `patterns/**` can illustrate blocks; CSS doc-comment parsing in `patterns.zig` is separate and may feed future pattern index pages — it is not the same code path as YAML manifest merge.

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
| `_core:blocks/paragraph.html` | `_core` style's blocks |

Parsing: split on first colon. If present, left = style name, right = path. Applies to both `<t-extend>` and `<t-include>`. Colons in path segments are reserved. Cross-style references use **`style:path` only** (there is no `_core/layouts/...` slash alias).

### Bundles

Asset bundles are declared in `style.yaml` as a **nested map only**: `bundles` → **term** (e.g. `css`, `js`) → **bundle name** → **YAML sequence** of file path strings. There is no flat list form at the `bundles` key, and each bundle’s file list must be an array (a one-file bundle is `[ default/css/surface.css ]`, not a single unquoted path scalar). Each path is relative to the site’s **`styles/`** directory when the build opens it (e.g. `default/css/surface.css` for the `default` style).

**Legacy alias:** the style manifest may use the top-level key **`assets`** instead of **`bundles`** with the same nested shape; Wig treats them equivalently when loading `style.yaml`.

```yaml
name: default
bundles:
  css:
    surface:
      - default/css/surface.css
    main:
      - default/css/reset.css
      - default/css/main.css
  js:
    app:
      - default/js/app.js
```

The **term** (`css`, `js`, …) is only a grouping label: it names the output subdirectory under each style’s hashed assets tree and the emitted file extension. The engine does not special-case “CSS” vs “JS” beyond that.

The **bundle name** may contain `/` (e.g. `nested/demo`); output files go under `assets/{style}/{term}/…` with the same directory nesting, and the filename is `{leaf}.{hash}.{term}` where `leaf` is the last segment of the bundle name.

Templates read root-relative URLs from **`assets.{style}.{term}.…`** — **one nested map key per `/` segment** in the bundle name (not a single key containing a slash), e.g. `assets.default.css.nested.demo.path` for bundle name `nested/demo` under term `css`.

**Site `assets/`** at the project root (not under `styles/`) is copied verbatim into the output `assets/` directory by the build; it is separate from style bundles (no hashing, no manifest entry).

### Color schemes

Wig uses a three-layer color indirection system:

1. **Palette** -- maps color names to hex values. Each scheme uses its own native naming.
2. **Styles** -- maps semantic roles (`text.primary`, `background.primary`, `text.link`) to palette names.
3. **Syntax** -- maps code highlighting roles (`keyword`, `string`, `comment`) to palette names.

Schemes have `light` and `dark` variants. Scheme data lives in `data/colors/{name}.yaml` (merged as `colors.{name}` in site data). The style manifest declares which scheme to use: `scheme: mono`.

**Palette pre-resolution:** Wig resolves palette indirection at load time. When scheme data is loaded, Wig walks the `styles` and `syntax` maps and replaces palette names with their hex values. Template authors access resolved values directly (e.g. `colors.mono.light.styles.text.primary` contains `"#000000"`, not `"black"`).

**Legacy:** A `data/colours/` directory is still supported; it merges as the top-level `colours` key and receives the same resolution. Prefer `data/colors/` and `colors.*` for new sites.

**Dynamic path resolution (Toupee 0.2+):** Templates may use **`$(expression)`** inside dot-paths so a segment is chosen at render time (e.g. `colors.$(scheme).light…`). See Toupee’s `dynamic-path.test` and docs. Wig does not add syntax beyond Toupee’s resolver.

### CSS rendering context

CSS files with frontmatter are rendered through Toupee but do **not** have the `document.*` namespace (they are style assets, not pages). They receive the full site context minus `document.*`:
- `styles.*` -- all style manifests; **`styles.{name}.tokens.computed`** holds fluid typography and spacing from `tokens.compute` (e.g. `styles.default.tokens.computed.typography` as a list of `{name, value}` maps)
- `colors.*` -- all color scheme data from `data/colors/` (pre-resolved); legacy `colours.*` if you use `data/colours/`
- `site.*` -- site configuration
- All other data directory keys

### Template reusability

**Section-agnostic listing:** Prefer `document.children` (and includes with `context="document.children as …"`) so one block works for any section without hardcoding `pages.{section}`. See `test/013_post_iteration.yaml`, `test/014_parent_children_links.yaml`, and `test/034_blog_e2e.yaml`.

**Pagination uses an explicit collection path:** `paginate.collection` names a dot-path into the page map (e.g. `pages.posts`). That is intentional — pagination is configured in frontmatter and must point at a concrete collection. See `test/032_pagination.yaml`. This does not conflict with preferring `document.children` in templates; use whichever matches the job (reusable section lists vs paginated slices of a named collection).

```html
<t-include template="blocks/list-posts.html" context="document.children as posts" />
```

### Pattern library

**YAML manifests (authoring for templates):** Each style may include **`patterns/{category}/{stem}.yaml`** files. After Comb parse, they are merged into context at **`styles.{style}.patterns.{category}.{stem}`** (nested maps: category → stem → fields). In page layouts, the active style is available as **`document.style`**, so a block manifest is reachable as **`document.style.patterns.blocks.{stem}.name`** (and other fields you define: `description`, `example`, `variants`, …). The skeleton includes **[`skel/site/styles/default/patterns/blocks/example.yaml`](skel/site/styles/default/patterns/blocks/example.yaml)** as a minimal example.

**HTML examples:** Optional **`patterns/{category}/*.html`** files can sit beside manifests for human-facing examples.

**CSS doc comments vs YAML:** [`patterns.zig`](patterns.zig) can discover pattern-like metadata from **`css/blocks/*.css`** doc comments and (when that pipeline is fully wired) contribute **pattern library pages** — a different mechanism from **`pattern_manifests.zig`**, which only loads YAML into the Toupee context during **`buildAll`**. For structured data used in templates, **prefer YAML manifests**; treat CSS doc discovery as complementary documentation / future index generation, not a replacement for manifest merge.

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

Output: `feeds/{name}.xml` as valid Atom XML. Entries sorted by `document.date` (newest first). Each entry includes title, URL, date, and excerpt (from `document.excerpt`).

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

### Static assets

Files in `assets/` are copied verbatim to the output directory without rendering or frontmatter processing. Directory structure is preserved:

- `assets/robots.txt` -> `zig-out/site/assets/robots.txt`
- `assets/css/reset.css` -> `zig-out/site/assets/css/reset.css`
- `assets/images/logo.png` -> `zig-out/site/assets/images/logo.png`

### Tags

Document frontmatter may include `document.tags: [music, tech, zig]`. With `taxonomies: [tags]` in site config, Wig auto-generates tag index pages (requires `layouts/tag-index.html` and `layouts/tag-list.html` in the style):

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

**Runner status (parity):** Today the runner **always** runs `Site.init` + `buildAll(.{ .clean = true })` and checks `output.files` (and `output.exit` for expected failures). The **`test.action`** block in YAML is **reserved for future behaviour selection** (e.g. `validate` only, `build` then HTTP expectations, incremental second pass). New features should **declare** the intended `action` shape in specs **and** extend `test_runner.zig` in the same change (or follow-up) so the schema stays truthful.

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
```

Specs mirror the on-disk layout: YAML keys under `input.files` are path segments (e.g. `styles/default/templates/layouts/page.html`). The runner does not rewrite paths—use `templates/layouts/`, `templates/blocks/`, `patterns/blocks/`, etc. Templates use explicit paths: `<t-extend template="layouts/page.html">`, `<t-include template="blocks/footer.html">`.

Each spec’s `test.name` and `test.comment` state intent; the YAML fixtures and expected `output` are the **ground truth** for behaviour. Prefer writing or extending a spec **when adding an author-facing feature** unless the feature is explicitly in the “YAML not a fit” bucket above.

### Test runner modules

- **Spec file names:** `{id}_{slug}.yaml` where `id` is **at least two** decimal digits (convention: **three**, zero-padded, e.g. `034_blog_e2e.yaml`) so the suite can grow to **999** specs before renaming. Discovery sorts by **numeric** id (not plain strings, so `100_` orders after `099_`). **`WIG_TEST`** filters by numeric id: `34`, `034`, and `034` all match spec `034_…`.
- **TestRunnerConfig** (`test_runner.zig`): Configurable `output_dir` and `workspace_dir` (defaults match `output_paths.default_site_output_rel` and `default_test_workspace_rel`). Pass to `runSpecTests(..., config)`.
- **OutputVerifier** (`output_verifier.zig`): Verifies output directory against spec; HTML normalization, glob matching (`*` only), stack/arena for comparisons.
- **SpecLoader** (`test_runner.zig`): Abstraction for loading specs. `defaultSpecLoader` reads YAML from test_dir; future loaders (e.g. zip fixtures) can swap in.
