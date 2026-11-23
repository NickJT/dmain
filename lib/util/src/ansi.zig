const std = @import("std");

pub const ESC = "\x1B[";

// Text Styles
pub const style = struct {
    pub const reset = "\x1B[0m";
    pub const wrap = "\x1B[=7h";
    pub const bold = "\x1B[1m";
    pub const dim = "\x1B[2m";
    pub const italic = "\x1B[3m";
    pub const underline = "\x1B[4m";
    /// Swaps foreground and background. The one emphasis that cannot be
    /// illegible: it uses the terminal's own two colours, so it works on a
    /// light theme and a dark one without knowing which it is.
    pub const reverse = "\x1B[7m";
};

pub const control = struct {
    // tell the terminal that a Line Feed (\n) should automatically imply a Carriage Return (\r
    pub const newLineMode = "\x1B[20h";
    // Hard reset
    pub const resetIniitalState = "\x1B[c";
};

// Foreground Colors
pub const fg = struct {
    pub const black = ESC ++ "30m";
    pub const red = ESC ++ "31m";
    pub const green = ESC ++ "32m";
    pub const yellow = ESC ++ "33m";
    pub const blue = ESC ++ "34m";
    pub const magenta = ESC ++ "35m";
    pub const cyan = ESC ++ "36m";
    pub const grey = ESC ++ "90m";
    pub const white = ESC ++ "97m";
    pub const bright_red = ESC ++ "91m";
    pub const bright_green = ESC ++ "92m";
    pub const bright_yellow = ESC ++ "93m";
    pub const bright_blue = ESC ++ "94m";
    pub const bright_magenta = ESC ++ "95m";
    pub const bright_cyan = ESC ++ "96m";
    pub const bright_grey = ESC ++ "37m";
};

// Background Colors
pub const bg = struct {
    pub const black = ESC ++ "40m";
    pub const red = ESC ++ "41m";
    pub const green = ESC ++ "42m";
    pub const yellow = ESC ++ "43m";
    pub const blue = ESC ++ "44m";
    pub const magenta = ESC ++ "45m";
    pub const cyan = ESC ++ "46m";
    pub const grey = ESC ++ "100m";
    pub const white = ESC ++ "107m";
    pub const bright_red = ESC ++ "101m";
    pub const bright_green = ESC ++ "102m";
    pub const bright_yellow = ESC ++ "103m";
    pub const bright_blue = ESC ++ "104m";
    pub const bright_magenta = ESC ++ "105m";
    pub const bright_cyan = ESC ++ "106m";
    pub const bright_grey = ESC ++ "47m";
};

pub const Direction = enum(u8) {
    up = 'A',
    down = 'B',
    right = 'C',
    left = 'D',
};

pub const EraseScope = enum(u8) {
    right = '0',
    left = '1',
    line = '2',
};

/// Reset terminal
pub fn reset(out: anytype) !void {
    try out.writeAll(control.newLineMode);
    try showCursor(out, true);
    //  try clear(out);
    try out.flush();
}

/// Clear screen and home cursor
pub fn clear(out: anytype) !void {
    try out.writeAll("\x1B[H\x1B[2J");
}

/// Dynamic cursor movement writing directly to the output stream
pub fn cursor(out: anytype, x: u32, y: u32) !void {
    if (x <= 1 and y <= 1) {
        try out.writeAll("\x1B[H");
        return;
    }
    try out.print("{s}{d};{d}H", .{ ESC, y, x });
}

pub fn cursorMove(out: anytype, d: Direction, steps: u32) !void {
    if (steps == 0) return;
    try out.print("{s}{d}{c}", .{ ESC, steps, @backingInt(d) });
}

pub fn setCol(out: anytype, col: u32) !void {
    if (col == 0) return;
    try out.print("{s}{d}G", .{ ESC, col });
}

pub fn erase(out: anytype, scope: EraseScope) !void {
    try out.print("{s}{c}K", .{ ESC, @backingInt(scope) });
}

/// Switches between the main terminal buffer and the clean alternate screen buffer.
/// Call with `true` at application start, and `false` during clean shutdown.
pub fn useAlternateBuffer(out: anytype, enable: bool) !void {
    if (enable) {
        try out.writeAll("\x1B[?1049h"); // Enter alternate buffer
    } else {
        try out.writeAll("\x1B[?1049l"); // Exit alternate buffer
    }
}

/// Toggles whether the terminal cursor block/bar is visible.
/// Hide the cursor at startup or before a draw cycle, and show it again on exit.
pub fn showCursor(out: anytype, show: bool) !void {
    if (show) {
        try out.writeAll("\x1B[?25h");
    } else {
        try out.writeAll("\x1B[?25l");
    }
}

/// Sets a custom foreground text color using precise 24-bit RGB values.
pub fn setTruecolorFg(out: anytype, r: u8, g: u8, b: u8) !void {
    try out.print("\x1B[38;2;{d};{d};{d}m", .{ r, g, b });
}

/// Sets a custom background cell color using precise 24-bit RGB values.
pub fn setTruecolorBg(out: anytype, r: u8, g: u8, b: u8) !void {
    try out.print("\x1B[48;2;{d};{d};{d}m", .{ r, g, b });
}

/// Dynamically updates the title of the terminal tab or window window.
pub fn setWindowTitle(out: anytype, title: []const u8) !void {
    try out.print("\x1B]0;{s}\x07", .{title});
}

/// Restricts terminal vertical scrolling to a strict window of rows.
/// Pass `0, 0` to reset scrolling back to the entire terminal window.
pub fn setScrollRegion(out: anytype, top_row: u32, bottom_row: u32) !void {
    if (top_row == 0 and bottom_row == 0) {
        try out.writeAll("\x1B[r");
    } else {
        try out.print("\x1B[{d};{d}r", .{ top_row, bottom_row });
    }
}

test "Force Semantic Check" {
    // This built-in function forces the compiler to look at
    // EVERY single struct, function, and variable in this file,
    // completely bypassing lazy analysis during 'zig build test'.
    std.testing.refAllDecls(@This());
}
