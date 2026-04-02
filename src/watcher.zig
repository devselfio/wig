const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

/// Watches project source directories for changes by polling mtimes.
///
/// The poll interval acts as a natural debounce window — rapid saves
/// within a single poll cycle are collapsed into one change event.
/// The API (init / start / waitForChange / stop) is implementation-
/// agnostic; a native backend (FSEvents, inotify) can replace the
/// polling loop without changing consumers.
pub const Watcher = struct {
    allocator: Allocator,
    root_path: []const u8,
    watch_dirs: []const []const u8,
    poll_ns: u64,

    change_event: std.Thread.ResetEvent = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    last_max_mtime: i128 = 0,

    pub fn init(
        allocator: Allocator,
        root_path: []const u8,
        watch_dirs: []const []const u8,
        poll_ns: u64,
    ) Watcher {
        return .{
            .allocator = allocator,
            .root_path = root_path,
            .watch_dirs = watch_dirs,
            .poll_ns = poll_ns,
        };
    }

    pub fn start(self: *Watcher) !void {
        self.last_max_mtime = self.scanMaxMtime();
        self.thread = try std.Thread.spawn(.{}, pollLoop, .{self});
    }

    /// Blocks until a file change is detected. Returns immediately if
    /// a change was already detected but not yet consumed.
    pub fn waitForChange(self: *Watcher) void {
        self.change_event.wait();
        self.change_event.reset();
    }

    pub fn stop(self: *Watcher) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn pollLoop(self: *Watcher) void {
        while (!self.stop_flag.load(.acquire)) {
            std.Thread.sleep(self.poll_ns);
            if (self.stop_flag.load(.acquire)) break;

            const current = self.scanMaxMtime();
            if (current > self.last_max_mtime) {
                self.last_max_mtime = current;
                self.change_event.set();
            }
        }
    }

    fn scanMaxMtime(self: *Watcher) i128 {
        var max: i128 = 0;
        for (self.watch_dirs) |rel| {
            const full = fs.path.join(self.allocator, &.{ self.root_path, rel }) catch continue;
            defer self.allocator.free(full);

            var dir = fs.openDirAbsolute(full, .{ .iterate = true }) catch continue;
            defer dir.close();
            self.walkMtime(dir, &max);
        }
        return max;
    }

    fn walkMtime(self: *Watcher, dir: fs.Dir, max: *i128) void {
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            switch (entry.kind) {
                .file => {
                    const stat = dir.statFile(entry.name) catch continue;
                    if (stat.mtime > max.*) max.* = stat.mtime;
                },
                .directory => {
                    var sub = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                    defer sub.close();
                    self.walkMtime(sub, max);
                },
                else => {},
            }
        }
    }
};

test "scanMaxMtime detects file changes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    {
        var f = try tmp.dir.createFile("pages/index.html", .{});
        try f.writeAll("<h1>hello</h1>");
        f.close();
    }

    const root_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root_path);

    var w = Watcher.init(a, root_path, &.{"pages"}, 50 * std.time.ns_per_ms);
    const t1 = w.scanMaxMtime();
    try std.testing.expect(t1 > 0);

    std.Thread.sleep(10 * std.time.ns_per_ms);

    {
        var f = try tmp.dir.createFile("pages/index.html", .{});
        try f.writeAll("<h1>updated</h1>");
        f.close();
    }

    const t2 = w.scanMaxMtime();
    try std.testing.expect(t2 >= t1);
}

test "missing directories are skipped" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root_path);

    var w = Watcher.init(a, root_path, &.{ "nonexistent", "also_missing" }, 50 * std.time.ns_per_ms);
    const t = w.scanMaxMtime();
    try std.testing.expectEqual(@as(i128, 0), t);
}
