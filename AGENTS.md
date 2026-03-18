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

Pluggable via `Site.init()`. Default: zjot (Djot). The `ContentParser` type is a function pointer, defined in `pages.zig` and re-exported by `root.zig`:

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

YAML only, delimited by `---`. Required for all pages in `pages/`. Frontmatter uses explicit namespaces:

- `document:` -- metadata for this page (title, layout override, style override, etc.). Merged into `document.*` in the rendering context.
- `data:` -- cascading data for child pages. Mirrors the `data/` directory concept but scoped to the current directory. `data.document:` provides document defaults for children.

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

Files in `styles/` with frontmatter are template-rendered; without are plain text.

### Clean URLs

- `pages/about.dj` -> `about/index.html`
- `pages/index.dj` -> `index.html` (root exception)
- `pages/posts/_index.dj` -> `posts/index.html` (section exception)
- `pages/_404.dj` -> `404.html` (error page exception)

### Data cascade

Sources merged in priority order (highest priority last -- later sources override earlier):

1. Global data files (`data/` -> top-level keys by filename, e.g. `data/site.yaml` -> `site.*`, `data/document.yaml` -> `document.*`)
2. Render flags (`site.draft`, `site.debug`)
3. Style manifest data (`styles.{name}.*`)
4. Page collection (`pages.*`) and taxonomies (`taxonomies.tags`)
5. Directory-level cascading data (from `data:` in `_index.dj` frontmatter, applied to child pages)
6. Page frontmatter `document:` (highest priority -- overrides all inherited `document.*` values)

**Reserved top-level keys:** `pages`, `styles`, `taxonomies` are system-provided. Data files must not shadow these names.

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
- `document.url` -- absolute URL (e.g. `https://example.com/about/`)
- `document.breadcrumbs` -- list of ancestor pages from root to parent, each a map with `path` and `title`. The current page is NOT included. Example for `pages/posts/001_first.dj`:
  ```
  [
    { path: "/", title: "Root" },
    { path: "/posts/", title: "Post List" }
  ]
  ```
  Root page has an empty breadcrumbs list. Breadcrumb titles come from each ancestor's `document.title`.

This is the same data as `pages.{key}.document` but accessible without knowing the page's collection key.

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

## Dependency API Reference

See `DEPENDENCY_VERIFICATION.md` for verified API behaviors, type mappings, and critical findings from the dependency verification sprint.
