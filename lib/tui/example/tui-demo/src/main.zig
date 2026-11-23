//! tui-demo — a whole dashboard, driven by fake data, in one file.
//!
//! ```
//! zig build tui-demo              # runs ~18 seconds, then restores the terminal
//! zig build tui-demo -- 60        # or run it for a stated number of seconds
//! ```
//!
//! ## What it is for
//!
//! **Answering "how do I use this library" without reading an application.**
//! `hub` and `dmain` are both real callers, but finding the render loop in
//! either means picking it out of 700 lines of Zigbee or house collation, and
//! then working out which half of what you found was the library's. This is the
//! same loop with the domain taken out.
//!
//! It is also the honest answer to "which of these two modules does what",
//! which is the first thing a reader of a two-module package wants:
//!
//!   * **`layout` owns every number.** Column widths, section heights, row
//!     offsets, whether a resize means anything. It touches no terminal.
//!   * **`view` owns every byte written.** It asks `layout` where things go and
//!     never computes a position itself — that separation is load-bearing.
//!
//! **Resize the window while it runs.** That is the one behaviour worth seeing
//! rather than reading about: `redrawFrameIfNeeded` notices, `layout`
//! recomputes, and the frame repaints on the next tick.
//!
//! ## The shape to copy
//!
//! The loop below is the whole contract, and both applications have exactly
//! this shape underneath their domain code:
//!
//! ```zig
//! while (running) {
//!     const redrew = try view.redrawFrameIfNeeded(); // resize handling
//!     try view.renderLog(log_tail);                  // scrolling area
//!     if (redrew or data_changed) {                  // expensive part, gated
//!         switch (plan) {
//!             .three_col => |c| try view.render(c.left, c.centre, c.right),
//!             .single => |rows| try view.renderRows(rows),
//!         }
//!     }
//! }
//! ```
//!
//! Two things about it are worth stating, because both were bugs once:
//!
//!   * **`redrawFrameIfNeeded` is called every tick**, not only when data
//!     changed. Gating it behind a data update means a resize does nothing
//!     until something else happens to move.
//!   * **It returns whether it repainted**, and the caller must honour that: a
//!     repaint clears the screen, so the rows and the log have to be drawn
//!     again even if neither changed.
//!
//! ## What it deliberately does not do
//!
//! **No keyboard.** `view` contains no input code at all — raw mode, key
//! decoding and the command line's *contents* belong to the application, which
//! is why `renderCommandLine` takes text it never parses. This demo scripts
//! itself instead, so it stays a demonstration of the library rather than of
//! termios.
//!
//! **No screens table.** `hub` owns a `ViewSpec`/`RenderPlan`
//! table mapping a mode to its layout and a collate function. That pattern is
//! worth copying and is deliberately *not* in the library: a pattern is
//! cheaper to re-type than to abstract.

const std = @import("std");
const Layout = @import("layout").Layout;
const view_mod = @import("view");
const View = view_mod.View;
const Row = view_mod.Row;
const WriteStyle = view_mod.WriteStyle;

const default_seconds: u64 = 18;
const tick_ms: u64 = 100;

/// Fake readings, so the panels have something that moves. A real caller reads
/// its model here — under a mutex, into an arena, exactly as `hub` does.
const Sensor = struct {
    name: []const u8,
    room: []const u8,
    reading: f32,
    alarm: bool = false,
};

var sensors = [_]Sensor{
    .{ .name = "porch", .room = "outside", .reading = 11.5 },
    .{ .name = "kitchen", .room = "ground", .reading = 20.0 },
    .{ .name = "landing", .room = "first", .reading = 18.25 },
    .{ .name = "loft — north", .room = "second", .reading = 9.0 },
    .{ .name = "cellar", .room = "below", .reading = 13.75, .alarm = true },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const seconds: u64 = if (args.len > 1)
        try std.fmt.parseInt(u64, args[1], 10)
    else
        default_seconds;

    var out_buf: [16 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &fw.interface;

    // 1. Geometry first. Three columns at 40/30/30 percent, with the top panel
    //    taking 55% of the height and the scrolling log the rest.
    var layout = Layout.init(.three_col, .{ 40, 30, 30 }, 55);
    const size = view_mod.getTerminalSize();
    layout.recalculate(size.width, size.height);

    // 2. Then the view over it. It borrows the layout — one owner, one source
    //    of geometry.
    var view = View.init(gpa, io, &layout, out);
    // `deinit` also restores the screen, which matters: without it the terminal
    // is left in the alternate buffer with a hidden cursor.
    defer view.deinit();

    view.headers = .{ "Sensors", "Rooms", "Log tail" };

    // No explicit `clearScreen`/`drawFramework` here on purpose. `layout`
    // starts with no remembered size, so the loop's first
    // `redrawFrameIfNeeded` paints the frame — the same path that handles
    // every later resize. One painter, not two that can get out of step.

    var log: LogRing = .{};
    log.push("tui-demo started — resize the window to watch the frame repaint");

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const ticks = seconds * 1000 / tick_ms;
    var tick: u64 = 0;
    while (tick < ticks) : (tick += 1) {
        // A fresh arena per frame: every row below is scratch, and freeing it
        // is one reset rather than a destructor per string. Both applications
        // do this, and it is why `Row` can hold borrowed slices safely.
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();

        // --- the loop proper ------------------------------------------------
        const redrew = try view.redrawFrameIfNeeded();

        // Data changes every 5th tick; the frame does not. Gating the
        // expensive half on that is the point of the `redrew or` below.
        const data_changed = tick % 5 == 0;
        if (data_changed) stepReadings(tick);

        // A mode switch every 6 seconds, to show `.three_col` and
        // `.wide_single` being the same loop with a different plan.
        const wide = (tick / (6000 / tick_ms)) % 2 == 1;
        if (tick % (6000 / tick_ms) == 0 and tick > 0) {
            if (wide) {
                layout.setMode(.wide_single, .{ 0, 0, 0 });
                view.headers = .{ "All sensors, one wide panel", "", "" };
                log.push("switched to .wide_single — one flat list of rows");
            } else {
                layout.setMode(.three_col, .{ 40, 30, 30 });
                view.headers = .{ "Sensors", "Rooms", "Log tail" };
                log.push("switched to .three_col — three independent sections");
            }
            // `setMode` resets the tracked size, so the next
            // `redrawFrameIfNeeded` repaints the furniture for the new shape.
        }

        if (tick % 20 == 0) log.push(try arena.print(
            "[tick {d}] a log line with an em-dash — 3 bytes, 1 column",
            .{tick},
        ));

        try view.renderLog(log.tail());

        if (redrew or data_changed) {
            if (wide) {
                try view.renderRows(try wideRows(arena, &layout));
            } else {
                const cols = try threeColumns(arena, &layout);
                try view.render(cols.left, cols.centre, cols.right);
            }
        }

        // The command line is drawn, never interpreted — the text is whatever
        // the application says it is.
        try view.renderCommandLine("(demo — no keyboard; input belongs to the app)");

        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(tick_ms), std.Io.Clock.real);
    }
}

/// Nudges the fake readings so something visibly moves.
fn stepReadings(tick: u64) void {
    for (&sensors, 0..) |*s, i| {
        const wobble: f32 = @floatFromInt((tick + i * 7) % 11);
        s.reading = 9.0 + wobble * 1.5;
        s.alarm = s.reading > 21.0;
    }
}

const ThreeCols = struct { left: []const Row, centre: []const Row, right: []const Row };

/// Content for the three-column layout. Note what the library does NOT do: it
/// has no idea a sensor exists. Turning a model into `Row`s is the caller's
/// whole job, and in a real application it lives in a `screens.zig`.
fn threeColumns(arena: std.mem.Allocator, layout: *Layout) !ThreeCols {
    var left: std.ArrayList(Row) = .empty;
    var centre: std.ArrayList(Row) = .empty;
    var right: std.ArrayList(Row) = .empty;

    for (sensors) |s| {
        // `renderColumns` pads and truncates by DISPLAY COLUMN. "loft — north"
        // is 12 columns but 14 bytes, and `{s:<12}` would leave this row two
        // columns short of its neighbours' — the bug this repo found twice.
        const text = try view_mod.renderColumns(
            arena,
            &.{ s.name, try arena.print("{d:.2}C", .{s.reading}) },
            &.{ 14, 8 },
        );
        try left.append(arena, .{
            .text = text,
            // A style per row, chosen by the caller. `alarm` is one of three
            // the library ships; any `WriteStyle` will do.
            .style = if (s.alarm) WriteStyle.alarm else null,
        });

        try centre.append(arena, .{
            .text = try view_mod.padToColumns(arena, s.room, layout.sec_widths[1]),
        });
    }

    try right.append(arena, .{ .text = "sections clip their own", .style = null });
    try right.append(arena, .{ .text = "content, so a row that is", .style = null });
    try right.append(arena, .{ .text = "too long cannot spill into", .style = null });
    try right.append(arena, .{ .text = "the column beside it.", .style = null });

    return .{ .left = left.items, .centre = centre.items, .right = right.items };
}

/// Content for `.wide_single`: one flat list of full-width rows, with a header
/// row built from the same widths as the data so the two cannot drift.
fn wideRows(arena: std.mem.Allocator, layout: *Layout) ![]const Row {
    const widths = [_]usize{ 14, 10, 10, 8 };
    var rows: std.ArrayList(Row) = .empty;

    try rows.append(arena, .{
        .text = try view_mod.padToColumns(
            arena,
            try view_mod.renderColumns(arena, &.{ "SENSOR", "ROOM", "READING", "STATE" }, &widths),
            layout.sec_widths[0],
        ),
        .style = WriteStyle.highlight,
    });

    for (sensors) |s| {
        try rows.append(arena, .{
            .text = try view_mod.renderColumns(arena, &.{
                s.name,
                s.room,
                try arena.print("{d:.2}C", .{s.reading}),
                if (s.alarm) "ALARM" else "ok",
            }, &widths),
            .style = if (s.alarm) WriteStyle.alarm else null,
        });
    }
    return rows.items;
}

/// A fixed-size ring of log lines, standing in for whatever a real application
/// keeps — hub has a bounded deque in its model.
///
/// `renderLog` takes the tail and shows as much of it as `layout.scroll_height`
/// allows, so a caller can hand it more than fits.
/// **It owns its text.** The lines pushed here are formatted into the per-frame
/// arena, which is reset on the next tick — storing the slices would leave the
/// ring holding freed memory, and the log is the one thing that outlives a
/// frame. Copying into fixed storage is the cheap fix at this size.
const LogRing = struct {
    const capacity = 32;
    const line_max = 96;

    storage: [capacity][line_max]u8 = @splat(@splat(0)),
    lens: [capacity]usize = @splat(0),
    slices: [capacity][]const u8 = @splat(""),
    len: usize = 0,

    fn push(self: *LogRing, line: []const u8) void {
        if (self.len == capacity) {
            // Oldest out. Copying the text rather than rotating indices keeps
            // `tail()` a plain contiguous slice, which is what `renderLog`
            // wants.
            for (1..capacity) |i| {
                self.storage[i - 1] = self.storage[i];
                self.lens[i - 1] = self.lens[i];
            }
            self.len -= 1;
        }
        const n = @min(line.len, line_max);
        @memcpy(self.storage[self.len][0..n], line[0..n]);
        self.lens[self.len] = n;
        self.len += 1;
    }

    fn tail(self: *LogRing) [][]const u8 {
        for (0..self.len) |i| self.slices[i] = self.storage[i][0..self.lens[i]];
        return self.slices[0..self.len];
    }
};
