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

YAML only, delimited by `---`. Required for all pages in `pages/`. Files in `styles/` with frontmatter are template-rendered; without are plain text. Frontmatter on style files is data-bearing (augments the rendering context).

### Clean URLs

- `pages/about.dj` -> `about/index.html`
- `pages/index.dj` -> `index.html` (root exception)
- `pages/posts/_index.dj` -> `posts/index.html` (section exception)
- `pages/_404.dj` -> `404.html` (error page exception)

### Data cascade

1. Global data (`data/` -> nested keys by directory)
2. Render flags (`site.draft`, `site.debug`)
3. Style manifest data (`styles.{name}.*`)
4. Collections (`pages.posts`) and taxonomies (`taxonomies.tags`)
5. Page frontmatter (`page.*`)

`page.path` = URL path (`/about/`). `page.url` = absolute URL. `page.excerpt` = first paragraph (or frontmatter `description:`).

### Output

Always `zig-out/site/`. Production builds error if unclean. Draft builds overlay.

## Conventions

- Template indentation: two spaces. `<t-*>` tags do not introduce indentation.
- Error messages: include file path. Where possible, line number and suggestion.
- Module soft limit: ~800 lines.
- CSS templates use `<t-raw>` for value output (prevents HTML escaping).
- zjot shortcodes in Djot use `` `<t-include ...>`{=html} `` syntax.
- Heading IDs: zjot puts IDs on `<section>` elements, not headings. `toc.zig` extracts accordingly.

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
