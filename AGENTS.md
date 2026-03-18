# Wig

A library-first static site generator in Zig. Wig promotes CUBE CSS methodology and provides tools for fluid design tokens, colour scheme management, and multi-style site architecture.

## Dependencies

| Name | Purpose | License |
|------|---------|---------|
| [Toupee](https://github.com/QuiteClose/toupee) | HTML-native template engine (`<t-*>` elements) | MIT |
| [Comb](https://github.com/QuiteClose/comb) | YAML parser | MIT |
| [zjot](https://github.com/QuiteClose/zjot) | Djot-to-HTML converter | MIT |

## Build Commands

```
zig build          # compile wig CLI + library
zig build test     # run all tests
zig build run      # run the wig CLI
```

## Project Structure

```
wig/
  build.zig         # library module (wig) + CLI executable
  build.zig.zon     # declares toupee, comb, zjot dependencies
  src/
    root.zig        # public API: Site struct, re-exports dependency types
    main.zig        # wig CLI entry point
    config.zig      # site config + style manifest loading
    tokens.zig      # fluid typography + spacing computation (CUBE CSS)
    colours.zig     # colour scheme resolution (palette indirection)
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
    scaffold.zig    # wig init, add style, add block, install
    html.zig        # shared HTML utilities (stripTags)
    test_runner.zig # integration test runner (Toupee-style .test files)
  test/
    *.test          # integration test suites (HTML comment delimited)
```

## Architecture

### Library-first

Wig is a library that users import into their own Zig project. `wig init` scaffolds a project with `build.zig`, `src/render.zig`, `src/serve.zig`, and `src/validate.zig`. Users own these files and can customise them.

### Two-phase Site struct

- `Site.init()` loads config files (config-only).
- `Site.buildAll()` does all computation and rendering, populating build state (Engine, collections, taxonomies, asset map) on the Site struct.

### Key types

```zig
const wig = @import("wig");

// Static build
var site = try wig.Site.init(allocator, .{ .root = ".", .draft = draft });
try site.buildAll(.{ .clean = clean });

// Dev server
var site = try wig.Site.init(allocator, .{ .root = ".", .draft = true });
try site.buildAll(.{ .clean = false });
var app = try wig.devServer(&site);
try app.listen(8080);
```

### Rendering pipeline

Content rendering is a three-phase pipeline:

1. **Wig preprocess** -- resolve `{{ variable }}` interpolations in the Djot source. Uses Toupee's existing value resolution and transform system. Supports pipe-chained transforms: `{{ document.date | date:%B %e, %Y }}`.
2. **zjot** -- parse the preprocessed Djot into HTML. Toupee `<t-*>` tags and `t-var:*` attribute bindings pass through as raw HTML.
3. **Toupee** -- single render pass on the layout template with zjot's output slotted in via `<t-slot />`. Resolves all remaining template tags (`<t-var>`, `<t-if>`, `<t-for>`, `t-var:href`, etc.).

**Content authors** use `{{ }}` for value interpolation in Djot (e.g. links, inline values). **Template authors** use Toupee's `<t-*>` elements and attribute bindings in layout HTML.

For Toupee tags in Djot content, use Djot's raw HTML passthrough:
- Inline: `` `<t-include template="nav.html" />`{=html} ``
- Block: bare `<t-include template="nav.html" />` on its own line (Djot auto-detects block HTML)

### Content parsers

Pluggable via `Site.init()`. Default: zjot (Djot). The architecture supports additional content formats (e.g. Markdown via `.md` extension) by registering additional parsers. Markdown support is planned but not at launch.

The `ContentParser` type is a function pointer, defined in `pages.zig` and re-exported by `root.zig`:

```zig
pub const ContentParser = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;
pub const ContentParserEntry = struct { extension: []const u8, parse: ContentParser };
```

### Validation

`Site.validate()` performs a dry run (no rendering). Options:

```zig
try site.validate(.{ .external_links = true }); // also check external URLs via HTTP HEAD
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

Engine for cached templates:

```zig
var engine = try toupee.Engine.init(allocator);
defer engine.deinit();
try engine.loadFromDirectory("styles/default", ".html");  // load all templates
const html = try engine.renderTemplate(a, "page.html", &ctx, loader, .{});
```

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

YAML only, delimited by `---`. Required for all pages in `pages/`. Frontmatter has exactly one top-level key: `document:`.

- `document:` -- all page metadata (title, layout, style, date, tags, etc.). Merged into `document.*` in the rendering context.
- `document.data:` -- cascading data for child pages. Wig processes this at build time and **strips it from the template context**. It is a build instruction, not template data.

Example leaf page:
```yaml
---
document:
  title: About Us
---
```

Example section index (`_index.dj`) with cascading defaults:
```yaml
---
document:
  layout: blog-index.html
  title: Blog Posts
  data:
    document:
      style: blog
      layout: blog-post.html
---
```

Pages inherit `document.*` values from the cascade (see Data cascade below). Frontmatter `document:` values override inherited defaults.

Files in `styles/` with frontmatter are template-rendered; without are plain text. CSS files get the full site context minus `document.*` (they see `styles.*`, `colours.*`, `site.*`, etc.).

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
5. Directory-level cascading data (from `document.data:` in `_index.dj` frontmatter, applied to child pages)
6. Page frontmatter `document:` (highest priority -- overrides all inherited `document.*` values)

**Reserved top-level keys:** `pages`, `styles`, `taxonomies` are system-provided. Data files must not shadow these names.

**Directory-level data overrides:** The `document.data:` key in `_index.dj` frontmatter can override any data key, not just `document:`. For example, `document: data: site: author: GuestAuthor` overrides `site.author` for all pages in that directory and its children. Children and grandchildren inherit the override; pages outside the directory see the global value. Wig strips `document.data` from the template context after processing.

### Page collection (`pages.*`)

The `pages` context key is a nested map mirroring the `pages/` directory tree. Each page's metadata lives under a reserved `document` key:

- `pages/_index.dj` -> `pages.document` (root page metadata)
- `pages/about.dj` -> `pages.about.document` (leaf page metadata)
- `pages/blog/_index.dj` -> `pages.blog.document` (section index metadata)
- `pages/blog/post_one.dj` -> `pages.blog.post_one.document` (child page metadata)

Metadata keys include `path` (URL path), `title`, `date`, and all other frontmatter `document:` values. Example: `pages.blog.post_one.document.path` -> `/blog/post-one/`.

**`document` is a reserved key.** A page or directory named `document` is an error.

**File/directory collision:** `pages/blog.dj` is an error if `pages/blog/` also exists.

**Iteration:** `<t-for post in pages.blog>` iterates child pages (skips the `document` key). Access metadata inside the loop via `post.document.path`, `post.document.title`, etc.

### Current page (`document.*`)

When rendering a page, `document.*` is populated by merging (in priority order):

1. `data/document.yaml` -- global document defaults
2. Directory-level `data.document:` from ancestor `_index.dj` files
3. The page's own frontmatter `document:` values (highest priority)

Wig also injects computed values:

- `document.path` -- URL path (e.g. `/about/`)
- `document.url` -- absolute URL (e.g. `https://example.com/about/`), built from `site.url` + `document.path`
- `document.style` -- full style manifest map (parsed from `style.yaml`). Access fields via `document.style.name`, `document.style.version`, etc.
- `document.parent` -- map with the parent page's document data (`path`, `title`, etc.). Nil for the root page.
- `document.children` -- list of child page document maps. Empty list for leaf pages.
- `document.ancestors` -- list of ancestor page document maps, from parent to root (nearest first). Empty list for the root page.
- `document.excerpt` -- from `description:` in frontmatter, or falls back to the first paragraph of content (text-only).
- `document.thumbnail` -- from `thumbnail:` in frontmatter. Asset path (e.g. `/images/hero.jpg`).
- `document.toc` -- list of heading maps extracted from rendered content: `{id, text, level}`. Headings come from zjot `<section>` elements.
- `document.draft` -- boolean from frontmatter. When true, page is excluded from `wig build` but included with `wig build --draft`.

These are primitives -- features like breadcrumbs are built by template authors, not provided by Wig. For example, breadcrumbs can be implemented by iterating `document.ancestors` with `order="reverse"` on `<t-for>` to get root-first order.

This is the same data as `pages.{key}.document` but accessible without knowing the page's collection key.

### Date format

Dates in frontmatter use ISO 8601 format with optional time: `2026-03-16` (date only) or `2026-03-16T14:30:00Z` (with time). String comparison on `YYYY-MM-DD` gives correct chronological order. Used for sorting (`<t-for ... sort="document.date">`), feeds, sitemaps, and the `date` transform.

### Style directory structure

Each style lives under `styles/{name}/` with this structure:

```
styles/default/
  style.yaml         # style manifest (name, bundles, tokens, scheme, custom fields)
  templates/         # page-level templates (base.html, post.html, post-list.html)
  blocks/            # reusable HTML components (breadcrumbs.html, card.html)
  css/               # CSS files (with optional frontmatter for Toupee rendering)
```

- `templates/` -- page shells that extend a base and define the document structure. Referenced via `document.layout`.
- `blocks/` -- reusable components included via `<t-include template="blocks/name.html" />`. CUBE CSS "blocks" -- UI components with associated HTML structure.
- `css/` -- stylesheets. Files with frontmatter (`---`) are rendered through Toupee (for tokens, colours). Files without frontmatter are plain text.

### Bundles

Asset bundles are declared explicitly in `style.yaml`:

```yaml
name: default
bundles:
  - css/tokens.css
  - css/global.css
  - css/utilities.css
```

Bundles are concatenated in declared order. Files with frontmatter are rendered through Toupee first, then concatenated. Output location follows the style's directory structure.

### Colour schemes

Wig uses the three-layer colour indirection system from the prototype:

1. **Palette** -- maps colour names to hex values. Each scheme uses its own native naming.
2. **Styles** -- maps semantic roles (`text.primary`, `background.primary`, `text.link`) to palette names.
3. **Syntax** -- maps code highlighting roles (`keyword`, `string`, `comment`) to palette names.

Schemes have `light` and `dark` variants. Scheme data lives in `data/colours/{name}.yaml`. The style manifest declares which scheme to use: `scheme: mono`.

**Palette pre-resolution:** Wig resolves palette indirection at load time. When colour scheme data is loaded, Wig walks the `styles` and `syntax` maps and replaces palette names with their hex values. Template authors access resolved values directly (e.g. `colours.mono.light.styles.text.primary` contains `"#000000"`, not `"black"`).

**Future: dynamic path resolution.** Toupee will support `$()` syntax for dynamic key lookup: `mode.palette.$(mode.styles.text.primary)`. This resolves the inner expression first, then uses its value as part of the outer path. Planned but not yet implemented.

### CSS rendering context

CSS files with frontmatter are rendered through Toupee but do **not** have the `document.*` namespace (they are style assets, not pages). They receive the full site context minus `document.*`:
- `styles.*` -- all style manifests
- `colours.*` -- all colour scheme data (pre-resolved)
- `site.*` -- site configuration
- All other data directory keys

### Template reusability

Templates should use `document.children` rather than hardcoded collection paths like `pages.posts`. This makes templates section-agnostic -- the same list template works for any section:

```html
<t-include template="blocks/list-posts.html" context="document.children as posts" />
```

### Pattern library

Each style may have a `patterns/` directory for block documentation and examples. This is separate from `blocks/` (which contains the components themselves). Detailed spec deferred.

### Feeds

Atom feeds are declared in `data/site.yaml`:

```yaml
feeds:
  - posts
  - tech
```

Pages opt into feeds via frontmatter:

```yaml
document:
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

Files in `static/` are copied verbatim to the output directory without rendering or frontmatter processing. Directory structure is preserved:

- `static/robots.txt` -> `zig-out/site/robots.txt`
- `static/css/reset.css` -> `zig-out/site/css/reset.css`
- `static/images/logo.png` -> `zig-out/site/images/logo.png`

### Collection sorting

`<t-for>` supports sorting page collections by any document field:

```html
<t-for post in pages.blog sort="document.date" order="desc">
```

`sort` specifies the dot-path into each item's data. `order` is `asc` (default) or `desc`. Combined with `order="reverse"` on `document.ancestors` for breadcrumbs.

### Output

Always `zig-out/site/`. Production builds error if unclean. Draft builds overlay.

## Conventions

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

### Inline unit tests

Every module has inline `test` blocks covering its public API. Run with `zig build test`.

### Integration tests

File-based integration tests live in `wig/test/*.test`. The format uses HTML comment delimiters (same format as Toupee and Comb):

```
<!-- test: name of test -->
<!-- section-name -->
content
<!-- out -->
expected output
```

Each test case is dispatched to a domain-specific runner in `test_runner.zig` based on which sections are present. Supported domains:

| Section(s)             | Domain                                    |
|------------------------|-------------------------------------------|
| `html`                 | HTML tag stripping (`html.zig`)           |
| `path`                 | Collection key dotPath (`scanner.zig`)    |
| `source-path`          | Clean URL derivation (`scanner.zig`)      |
| `route` + `request`    | HTTP routing (`router.zig` + `app.zig`)   |
| `middleware`            | Middleware chain (`handler.zig`)          |
| `pages-json` + variants| Feeds, sitemap, search index              |
| `scaffold-cmd`         | Project scaffolding (`scaffold.zig`)      |
| `tokens`               | Fluid token computation (`tokens.zig`)    |
| `highlights` + `scheme:`| Colour scheme resolution (`colours.zig`) |
| `config`               | Site config loading (`config.zig`)        |
| `comb-input`           | YAML-to-Toupee conversion (`context.zig`)|
| `css-files`            | CSS bundle concatenation (`bundles.zig`)  |
| `scan-pages`           | Directory scanning (`scanner.zig`)        |
| `page-content`         | Page rendering + ToC + excerpts           |

Test files: `smoke.test`, `html.test`, `scanner.test`, `web-framework.test`, `post-build.test`, `scaffold.test`, `data-pipeline.test`, `css-pipeline.test`, `page-rendering.test`.

### Spec tests (YAML)

Full-site build tests in `wig/test/NN_name.yaml`. Each defines a complete site (data, styles, pages), an action (`wig: build`), and expected output files.

```yaml
test:
  name: Test name.
  comment: What this tests.
  action:
    wig: build
  fixtures: []
input:
  files:
    data: { ... }
    styles: { ... }
    pages: { ... }
output:
  files:
    index.html: |
      expected content
```

Tests 00-27 cover: minimal builds, pretty-printing, cross-page links, template inheritance, post iteration, breadcrumbs, transforms, HTML content, includes in content, index naming, error pages, nested paths, nested data, site data, data cascade overrides, directory data inheritance, parent/children links, multiple styles, excerpts/thumbnails, drafts, static assets, CSS tokens, colour schemes, sitemap, Atom feeds, search index, table of contents, and collection sorting.

## Dependency API Reference

See `DEPENDENCY_VERIFICATION.md` for verified API behaviors, type mappings, and critical findings from the dependency verification sprint.
