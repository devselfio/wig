const std = @import("std");
const Allocator = std.mem.Allocator;

/// Watches project source directories for changes by polling mtimes.
///
/// The poll interval acts as a natural debounce window — rapid saves
/// within a single poll cycle are collapsed into one change event.
/// The API (init / start / waitForChange / stop) is implementation-
/// agnostic; a native backend (FSEvents, inotify) can replace the
/// polling loop without changing consumers.
pub const Watcher = struct {
    allocator: Allocator,
    io: std.Io,
    root_path: []const u8,
    watch_dirs: []const []const u8,
    poll_ns: u64,

    change_event: std.Io.Semaphore = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    last_max_mtime: std.Io.Timestamp = .{ .nanoseconds = 0 },

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        root_path: []const u8,
        watch_dirs: []const []const u8,
        poll_ns: u64,
    ) Watcher {
        return .{
            .allocator = allocator,
            .io = io,
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
        self.change_event.waitUncancelable(self.io);
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
            std.Io.sleep(self.io, .{ .nanoseconds = @intCast(self.poll_ns) }, .awake) catch {};
            if (self.stop_flag.load(.acquire)) break;

            const current = self.scanMaxMtime();
            if (current.nanoseconds > self.last_max_mtime.nanoseconds) {
                self.last_max_mtime = current;
                self.change_event.post(self.io);
            }
        }
    }

    fn scanMaxMtime(self: *Watcher) std.Io.Timestamp {
        var max: std.Io.Timestamp = .{ .nanoseconds = 0 };
        for (self.watch_dirs) |rel| {
            const full = std.fs.path.join(self.allocator, &.{ self.root_path, rel }) catch continue;
            defer self.allocator.free(full);

            var dir = std.Io.Dir.openDirAbsolute(self.io, full, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            self.walkMtime(dir, &max);
        }
        return max;
    }


    fn walkMtime(self: *Watcher, dir: std.Io.Dir, max: *std.Io.Timestamp) void {
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            switch (entry.kind) {
                .file => {
                    const stat = std.Io.Dir.statFile(dir, self.io, entry.name, .{}) catch continue;
                    if (stat.mtime.nanoseconds > max.nanoseconds) max.* = stat.mtime;
                },
                .directory => {
                    var sub = std.Io.Dir.openDir(dir, self.io, entry.name, .{ .iterate = true }) catch continue;
                    defer sub.close(self.io);
                    self.walkMtime(sub, max);
                },
                else => {},
            }
        }
    }
};

test "scanMaxMtime detects file changes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.createDirPath(tmp.dir, io, "pages");
    {
        var f = try std.Io.Dir.createFile(tmp.dir, io, "pages/index.html", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<h1>hello</h1>");
    }

    const root_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", a);
    defer a.free(root_path);

    var w = Watcher.init(a, io, root_path, &.{"pages"}, 50 * std.time.ns_per_ms);
    const t1 = w.scanMaxMtime();
    try std.testing.expect(t1.nanoseconds > 0);

    std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};

    {
        var f = try std.Io.Dir.createFile(tmp.dir, io, "pages/index.html", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<h1>updated</h1>");
    }

    const t2 = w.scanMaxMtime();
    try std.testing.expect(t2.nanoseconds >= t1.nanoseconds);
}

test "missing directories are skipped" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", a);
    defer a.free(root_path);

    var w = Watcher.init(a, io, root_path, &.{ "nonexistent", "also_missing" }, 50 * std.time.ns_per_ms);
    const t = w.scanMaxMtime();
    try std.testing.expectEqual(@as(i128, 0), t.nanoseconds);
}
