//! ansi-demo — render everything `ansi.zig` can emit, so a terminal can be
//! judged by eye.
//!
//! ```
//! zig build ansi-demo
//! ```
//!
//! ## What it is for
//!
//! Escape sequences are the part of a TUI that cannot be unit-tested: a test
//! can assert that `setTruecolorFg` emits `\x1B[38;2;…m`, and that says nothing
//! about whether the terminal in front of you renders it. **This is the test
//! that has to be run by a person**, and it answers a question that comes up
//! for real in this repo — hub's TUI is read over SSH, in Terminal.app, and
//! occasionally through a serial console, and those three do not agree about
//! italics, truecolor, or the alternate buffer.
//!
//! Run it wherever a TUI is about to be run. What renders badly here will
//! render badly there.
//!
//! ## Deliberately not using the alternate buffer
//!
//! `ansi.useAlternateBuffer` exists and hub uses it, but a *report* you want to
//! scroll back through is the one thing it is wrong for: the alternate buffer
//! is discarded on exit, taking the output with it. An application that owns
//! the screen wants it; a tool that prints and exits does not.
//!
//! ## The last section is the one to read
//!
//! Padding by byte length is the alignment bug this repo has hit twice, and it
//! is invisible until a non-ASCII character appears in a column. The demo makes
//! it visible.

const std = @import("std");
const ansi = @import("ansi");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &fw.interface;

    try styles(out);
    try colours(out);
    try truecolor(out);
    try cursorMoves(out);
    try paddingTrap(out);

    // Leaves line-feed mode and the cursor as it found them. A demo that
    // exited with the cursor hidden would be a small disaster for the next
    // command the user types.
    try ansi.reset(out);
}

fn styles(out: *std.Io.Writer) !void {
    try out.print("\n{s}-- styles{s}\n", .{ ansi.style.bold, ansi.style.reset });

    // Italic and dim are the two most commonly unimplemented. If they look
    // identical to plain text, that is the terminal, not this code.
    const each = [_]struct { name: []const u8, code: []const u8 }{
        .{ .name = "bold", .code = ansi.style.bold },
        .{ .name = "dim", .code = ansi.style.dim },
        .{ .name = "italic", .code = ansi.style.italic },
        .{ .name = "underline", .code = ansi.style.underline },
        .{ .name = "reverse", .code = ansi.style.reverse },
    };
    for (each) |s| {
        try out.print("  {s}{s}{s}  ", .{ s.code, s.name, ansi.style.reset });
    }
    try out.writeAll("\n");
}

fn colours(out: *std.Io.Writer) !void {
    try out.print("\n{s}-- 16 colours{s}\n", .{ ansi.style.bold, ansi.style.reset });

    const fgs = [_]struct { name: []const u8, code: []const u8 }{
        .{ .name = "black", .code = ansi.fg.black },
        .{ .name = "red", .code = ansi.fg.red },
        .{ .name = "green", .code = ansi.fg.green },
        .{ .name = "yellow", .code = ansi.fg.yellow },
        .{ .name = "blue", .code = ansi.fg.blue },
        .{ .name = "magenta", .code = ansi.fg.magenta },
        .{ .name = "cyan", .code = ansi.fg.cyan },
        .{ .name = "grey", .code = ansi.fg.grey },
        .{ .name = "white", .code = ansi.fg.white },
    };
    const brights = [_]struct { name: []const u8, code: []const u8 }{
        .{ .name = "red", .code = ansi.fg.bright_red },
        .{ .name = "green", .code = ansi.fg.bright_green },
        .{ .name = "yellow", .code = ansi.fg.bright_yellow },
        .{ .name = "blue", .code = ansi.fg.bright_blue },
        .{ .name = "magenta", .code = ansi.fg.bright_magenta },
        .{ .name = "cyan", .code = ansi.fg.bright_cyan },
        .{ .name = "grey", .code = ansi.fg.bright_grey },
    };

    try out.writeAll("  fg      ");
    for (fgs) |c| try out.print("{s}{s} ", .{ c.code, c.name });
    try out.print("{s}\n", .{ansi.style.reset});

    try out.writeAll("  bright  ");
    for (brights) |c| try out.print("{s}{s} ", .{ c.code, c.name });
    try out.print("{s}\n", .{ansi.style.reset});

    // Backgrounds as blocks rather than words: a background colour is judged by
    // the block, and dark text on a dark background proves nothing.
    try out.writeAll("  bg      ");
    for ([_][]const u8{
        ansi.bg.black, ansi.bg.red,     ansi.bg.green, ansi.bg.yellow,
        ansi.bg.blue,  ansi.bg.magenta, ansi.bg.cyan,  ansi.bg.grey,
        ansi.bg.white,
    }) |c| {
        try out.print("{s}   ", .{c});
    }
    try out.print("{s}\n", .{ansi.style.reset});
}

fn truecolor(out: *std.Io.Writer) !void {
    try out.print("\n{s}-- 24-bit colour{s}  (smooth = truecolor; banded = 256-colour only)\n", .{
        ansi.style.bold,
        ansi.style.reset,
    });

    // A 64-step ramp is the discriminator: a terminal that quantises to the
    // 256-colour cube shows visible steps, and one that does not is smooth.
    try out.writeAll("  ");
    for (0..64) |i| {
        const t: u8 = @intCast(i * 4);
        try ansi.setTruecolorBg(out, t, 0, @as(u8, 255) - t);
        try out.writeAll(" ");
    }
    try out.print("{s}\n", .{ansi.style.reset});

    try out.writeAll("  ");
    for (0..64) |i| {
        const t: u8 = @intCast(i * 4);
        try ansi.setTruecolorFg(out, 0, t, @as(u8, 255) - t);
        try out.writeAll("#");
    }
    try out.print("{s}\n", .{ansi.style.reset});
}

fn cursorMoves(out: *std.Io.Writer) !void {
    try out.print("\n{s}-- cursor addressing{s}\n", .{ ansi.style.bold, ansi.style.reset });

    // Write a line, then go back and overwrite part of it in place. This is how
    // a TUI redraws one field without repainting the screen, and it is the
    // thing that breaks first over a serial console.
    try out.writeAll("  status: ....................");
    try ansi.setCol(out, 11); // column 1 is the left margin, so 11 is after "  status: "
    try ansi.erase(out, .right);
    try out.print("{s}rewritten in place{s}\n", .{ ansi.fg.green, ansi.style.reset });

    try out.writeAll("  three columns:");
    for (0..3) |i| {
        try ansi.setCol(out, @intCast(20 + i * 12));
        try out.print("{s}col {d}{s}", .{ ansi.fg.cyan, i, ansi.style.reset });
    }
    try out.writeAll("\n");

    // Up-then-back, which is how a progress line is updated without scrolling.
    try out.writeAll("  this line gets a tick added\n");
    try ansi.cursorMove(out, .up, 1);
    try ansi.setCol(out, 32);
    try out.print("{s}<- added afterwards{s}\n", .{ ansi.fg.yellow, ansi.style.reset });
}

fn paddingTrap(out: *std.Io.Writer) !void {
    try out.print("\n{s}-- why padding by bytes goes wrong{s}\n", .{ ansi.style.bold, ansi.style.reset });

    // Each of these is 6 *characters* wide on screen. The second and third are
    // more than 6 bytes, because `—` is 3 bytes in UTF-8 and `é` is 2.
    const cells = [_][]const u8{ "plain", "a—b", "café" };

    try out.writeAll("  {s:<10} padding, by BYTE length:\n");
    for (cells) |c| {
        // `{s:<10}` counts bytes, so a multi-byte cell is padded short and the
        // column edge moves left. Diagnosed twice from hardware screenshots
        // before it was understood. Pad by display column, not by byte.
        try out.print("    |{s:<10}|  {d} bytes, {d} codepoints\n", .{
            c,
            c.len,
            std.unicode.utf8CountCodepoints(c) catch c.len,
        });
    }

    try out.writeAll("  padding by CODEPOINT count:\n");
    for (cells) |c| {
        const width = std.unicode.utf8CountCodepoints(c) catch c.len;
        try out.print("    |{s}", .{c});
        // Pad to the same 10 columns, counting what the terminal counts.
        for (width..10) |_| try out.writeByte(' ');
        try out.writeAll("|\n");
    }

    // Codepoints are right for this text and wrong in general: a CJK glyph
    // occupies two columns and a combining mark none. Said plainly, because the
    // fix above looks more complete than it is.
    try out.print(
        "  {s}Codepoints are only the right unit while every character is one column wide.{s}\n",
        .{ ansi.fg.grey, ansi.style.reset },
    );
}
