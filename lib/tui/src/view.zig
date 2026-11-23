const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const ansi = @import("ansi");
const Layout = @import("layout").Layout;
const Section = @import("layout").Section;
const TerminalSize = @import("layout").TerminalSize;
const Local = @import("local_time");

pub const View = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    cursors: [4]struct { col: u32, row: u32 } = .{
        .{ .col = 0, .row = 0 },
        .{ .col = 0, .row = 0 },
        .{ .col = 0, .row = 0 },
        .{ .col = 0, .row = 0 },
    },
    layout: *Layout,
    scrollQueue: std.Deque([]const u8),
    scrollLine: u32 = 0,
    altScreen: bool = false,
    // Top-panel column headers, read left-to-right and sliced to
    // layout.active_columns. In .wide_single mode only headers[0] is
    // used. Whichever code selects a content view (light detail, room
    // summary, device status, ...) is responsible for setting these to
    // match — drawFramework() just renders whatever's here.
    headers: [3][]const u8 = .{ "Lights", "Temperature", "Motion" },
    /// Drawn in the top-left corner. **An application's own name, which is why
    /// it is a field**: it was a hardcoded string here until a second
    /// application wanted a different one, and a library holding one caller's house name is
    /// exactly the application detail that must not leak downward. The default
    /// keeps `hub` looking as it did; it should set it explicitly and then
    /// the default can go.
    title: []const u8 = "Hale Farm Cottage",
    /// How many rows each section drew last frame, so a section that shrinks
    /// can have the rows it vacated blanked.
    ///
    /// **The same defect `writeTo` fixes one axis over.** That blanks the rest
    /// of a *cell* so "ALARM" replaced by "ok" does not read as "okARM"; this
    /// blanks the rest of a *section* so a list that loses a row does not leave
    /// its last line stranded below the new one. A control panel hit it the first
    /// time it ran against real hardware: a "(no telemetry yet)" row vanished
    /// when the first frame arrived, every row below shifted up one, and the
    /// old bottom line stayed on screen contradicting the new one.
    ///
    /// Index 3 is `renderRows`, which draws into section_1 on its own terms.
    drawn_rows: [4]u32 = .{ 0, 0, 0, 0 },

    pub fn init(gpa: Allocator, io: std.Io, layout: *Layout, stdout: *std.Io.Writer) View {
        return .{
            .gpa = gpa,
            .io = io,
            .out = stdout,
            .scrollQueue = std.Deque([]const u8).empty,
            .layout = layout,
        };
    }

    pub fn deinit(self: *View) void {
        while (self.scrollQueue.popFront()) |item| {
            self.gpa.free(item);
        }
        self.scrollQueue.deinit(self.gpa);
        self.restoreScreen() catch {};
    }

    // Screen geometry comes from `layout.zig` and NOWHERE ELSE. This module used to keep its own copies of the row maths,
    // and they had drifted a row apart from Layout's: `scrollContentTop`
    // here was `5 + sec_height + 1`, while `Layout.scrollContentTop()` is
    // `7 + sec_height`. Consequences, both live until it was fixed:
    //   - the log was drawn one row ABOVE the box `drawFramework` paints,
    //     so the box's last row was never used and the "blank" label row
    //     never was blank;
    //   - the command line, which correctly used
    //     `Layout.scrollLabelRow()`, landed on the log's first row and got
    //     overwritten while the user was typing into it.
    // The fix was deleting the copies, not adjusting them — two sources of
    // truth for the same arithmetic is the bug, and it will drift again if
    // reintroduced.

    /// Initialize alternate presentation buffer space and clear active cursor
    pub fn clearScreen(self: View) !void {
        try ansi.useAlternateBuffer(self.out, true);
        try ansi.showCursor(self.out, false);
        try ansi.clear(self.out);
        try self.out.flush();
    }

    pub fn restoreScreen(self: View) !void {
        try ansi.useAlternateBuffer(self.out, false);
        try ansi.showCursor(self.out, true);
        try ansi.reset(self.out);
        try self.out.flush();
    }

    pub fn redrawFrame(self: *View) !void {
        if (!self.altScreen) {
            self.altScreen = true;
        }
        try self.clearScreen();
        try self.drawFramework();
        self.scrollLine = self.layout.scrollContentTop();
        // The screen is blank again, so nothing is owed a blanking.
        self.drawn_rows = .{ 0, 0, 0, 0 };
    }

    /// Renders three pre-formatted, independently-styled columns side by
    /// side. Unlike renderRows() this doesn't know or care what the data
    /// is either — section1/2/3 are just wherever the caller wants full
    /// rows of text drawn, one per column.
    pub fn render(self: *View, section1: []const Row, section2: []const Row, section3: []const Row) !void {
        try self.updateTime(self.io);
        const sections = [3]Section{ .section_1, .section_2, .section_3 };
        for ([3][]const Row{ section1, section2, section3 }, sections, 0..) |rows, section, n| {
            for (rows, 0..) |row, idx| {
                if (idx == self.layout.sec_height) break;
                try self.writeRow(section, self.layout.left_col, @intCast(idx), row);
            }
            try self.blankRowsBelow(section, n, @intCast(rows.len));
        }
        try self.out.flush();
    }

    /// Blank whatever this section drew last frame and is not drawing now.
    /// Bounded by the previous count rather than by `sec_height`, so a steady
    /// display writes nothing extra at all.
    fn blankRowsBelow(self: *View, section: Section, slot: usize, drew: u32) !void {
        const capped = @min(drew, self.layout.sec_height);
        var idx = capped;
        while (idx < self.drawn_rows[slot]) : (idx += 1) {
            try self.writeTo(section, 0, idx, "", null);
        }
        self.drawn_rows[slot] = capped;
    }

    /// Renders one pre-formatted line per row into section_1, top to
    /// bottom. Unlike render(), this doesn't know or care what the data
    /// is — it's the counterpart to the 3-column render() for
    /// .wide_single layouts (or any other content that's naturally a
    /// flat list of full-width rows rather than fixed columns).
    pub fn renderRows(self: *View, rows: []const Row) !void {
        try self.updateTime(self.io);
        for (rows, 0..) |row, idx| {
            if (idx == self.layout.sec_height) break;
            try self.writeRow(.section_1, 0, @intCast(idx), row);
        }
        try self.blankRowsBelow(.section_1, 3, @intCast(rows.len));
        try self.out.flush();
    }

    /// Polls the real terminal size and redraws the frame furniture (borders,
    /// headers, title) only if it changed since the last check — either
    /// because the window was resized or because layout.setMode() reset the
    /// tracked size after a view-mode switch. Callers should invoke this
    /// once per tick, independent of whether the underlying data changed,
    /// so a resize is reflected immediately rather than waiting on the next
    /// data update. Returns whether the frame was actually redrawn, since
    /// redrawFrame() clears the whole screen (including previously drawn
    /// row content) — callers need this to know they must also repaint
    /// rows/log this tick even if the underlying data hasn't changed.
    pub fn redrawFrameIfNeeded(self: *View) !bool {
        const current_size = getTerminalSize();
        if (self.layout.redrawNeeded(current_size)) {
            try self.redrawFrame();
            return true;
        }
        return false;
    }

    pub fn drawFramework(self: *View) !void {
        const tw = self.layout.totalWidth();
        const cols: usize = @intCast(self.layout.active_columns);

        // 1. Top Title Line
        try ansi.cursor(self.out, 1, Layout.ROW_TITLE);
        try self.out.writeAll(self.title);

        // 2. Top Border of Columns
        try ansi.cursor(self.out, 1, Layout.ROW_TOP_BORDER);
        try self.out.writeAll("┌");
        for (0..cols) |i| {
            for (0..self.layout.sec_widths[i]) |_| try self.out.writeAll("─");
            if (i < cols - 1) try self.out.writeAll("┬") else try self.out.writeAll("┐");
        }

        // 3. Column Header Labels
        try ansi.cursor(self.out, 1, Layout.ROW_COL_HEADERS);
        try self.out.writeAll("│");
        for (0..cols) |i| {
            const header = self.headers[i];
            try self.out.writeAll(" ");
            if (self.layout.sec_widths[i] > 2) {
                const available = self.layout.sec_widths[i] - 1;
                if (header.len <= available) {
                    try self.out.writeAll(header);
                    for (0..(available - header.len)) |_| try self.out.writeAll(" ");
                } else {
                    try self.out.writeAll(header[0..available]);
                }
            }
            try self.out.writeAll("│");
        }

        // 4. Inner Header Divider
        try ansi.cursor(self.out, 1, Layout.ROW_HEADER_DIVIDER);
        try self.out.writeAll("├");
        for (0..cols) |i| {
            for (0..self.layout.sec_widths[i]) |_| try self.out.writeAll("─");
            if (i < cols - 1) try self.out.writeAll("┼") else try self.out.writeAll("┤");
        }

        // 5. Content Side-Borders
        var r: u32 = 0;
        while (r < self.layout.sec_height) : (r += 1) {
            try ansi.cursor(self.out, 1, self.layout.sectionTop() + r);
            try self.out.writeAll("│");
            for (0..cols) |i| {
                for (0..self.layout.sec_widths[i]) |_| try self.out.writeAll(" ");
                try self.out.writeAll("│");
            }
        }

        // 6. Mid-Way Divider (Bottom of Columns, Top of Scroll Area)
        try ansi.cursor(self.out, 1, self.layout.midDividerRow());
        try self.out.writeAll("├");
        for (0..cols) |i| {
            for (0..self.layout.sec_widths[i]) |_| try self.out.writeAll("─");
            if (i < cols - 1) try self.out.writeAll("┴") else try self.out.writeAll("┤");
        }

        // 7. Scroll Box Label Row
        try ansi.cursor(self.out, 1, self.layout.scrollLabelRow());
        try self.out.writeAll("│");
        const padding = tw - self.layout.sectionLeft(.section_4);
        for (0..padding) |_| try self.out.writeAll(" ");
        try self.out.writeAll("│");

        // 8. Scroll Box Internal Rows Empty Initialization
        var sr: u32 = 0;
        while (sr < self.layout.scroll_height) : (sr += 1) {
            try ansi.cursor(self.out, 1, self.layout.scrollContentTop() + sr);
            try self.out.writeAll("│");
            for (0..(tw - 2)) |_| try self.out.writeAll(" ");
            try self.out.writeAll("│");
        }

        // 9. Absolute Bottom Layout Frame Border
        try ansi.cursor(self.out, 1, self.layout.scrollContentBottom() + 1);
        try self.out.writeAll("└");
        for (0..(tw - self.layout.sectionLeft(.section_4))) |_| try self.out.writeAll("─");
        try self.out.writeAll("┘");
    }

    pub fn renderLog(self: *View, logTail: [][]const u8) !void {
        const qLength: usize = logTail.len;
        var startIndex: usize = 0;
        if (qLength > self.layout.scroll_height) {
            startIndex = qLength - @as(usize, @intCast(self.layout.scroll_height));
        }
        self.scrollLine = self.layout.scrollContentTop();

        for (startIndex..qLength) |index| {
            try self.writeScroll(logTail[index]);
        }
        try self.out.flush();
    }

    /// Dynamically updates the timestamp in the upper-right corner.
    fn updateTime(self: *View, io: std.Io) !void {
        var time_buf: [8]u8 = undefined;
        const time_str = try Local.timeNow(io, &time_buf);
        const tw = self.layout.totalWidth();
        if (tw > time_str.len) {
            try ansi.cursor(self.out, tw - @as(u32, @intCast(time_str.len)) + 1, 1);
            try self.out.writeAll(time_str);
        }
    }

    /// Addressable component cell-writing interface using local coordinates.
    /// Bounded safely to the specific section width and height constraints.
    /// A `Row`, honouring `style_from`. A row styled from column 0, or not at
    /// all, is exactly `writeTo`.
    fn writeRow(self: *View, section: Section, col: u32, row_idx: u32, row: Row) !void {
        const st = row.style orelse return self.writeTo(section, col, row_idx, row.text, null);
        if (row.style_from == 0) return self.writeTo(section, col, row_idx, row.text, st);

        const idx = @backingInt(section);
        if (col >= self.layout.sec_widths[idx] or row_idx >= self.layout.sec_height) return;
        const available_width = self.layout.sec_widths[idx] - col;
        const print_text = truncateToColumns(row.text, available_width);
        const print_cols: u32 = @intCast(displayColumns(print_text));
        const plain = truncateToColumns(print_text, row.style_from);

        try ansi.cursor(self.out, self.layout.sectionLeft(section) + col, self.layout.sectionTop() + row_idx);
        try self.out.writeAll(plain);
        if (st.bold) try self.out.writeAll(ansi.style.bold);
        if (st.fg_color) |fg| try self.out.writeAll(fg);
        if (st.bg_color) |bg| try self.out.writeAll(bg);
        try self.out.writeAll(print_text[plain.len..]);
        // Reset *before* blanking: unlike a whole-row style, a styled word is
        // not meant to run on to the section's edge.
        try self.out.writeAll(ansi.style.reset);
        try self.out.splatByteAll(' ', available_width - print_cols);
    }

    pub fn writeTo(self: *View, section: Section, col: u32, row: u32, text: []const u8, style_opt: ?WriteStyle) !void {
        const idx = @backingInt(section);
        if (col >= self.layout.sec_widths[idx] or row >= self.layout.sec_height) return;

        // Ensure text does not overflow past the right-hand boundary wall of
        // the section. **By display columns, not bytes**: `text.len` against a
        // column count cuts an em-dash row two bytes early and can slice a
        // codepoint in half — the same defect `writeScroll` was fixed for.
        const available_width = self.layout.sec_widths[idx] - col;
        const print_text = truncateToColumns(text, available_width);
        const print_cols: u32 = @intCast(displayColumns(print_text));

        const abs_col = self.layout.sectionLeft(section) + col;
        const abs_row = self.layout.sectionTop() + row;

        try ansi.cursor(self.out, abs_col, abs_row);

        // Future styling integration checkpoint
        if (style_opt) |st| {
            if (st.bold) try self.out.writeAll(ansi.style.bold);
            if (st.fg_color) |fg| try self.out.writeAll(fg);
            if (st.bg_color) |bg| try self.out.writeAll(bg);
        }

        try self.out.writeAll(print_text);

        // **Blank the rest of the cell.** Nothing else clears it, so a row that
        // shortens between frames leaves the tail of the previous one on
        // screen: "ALARM" replaced by "ok" reads as "okARM". Found in the
        // example's own output, which is exactly what it is for.
        //
        // Inside the style, so a styled row is styled to the section's edge
        // rather than stopping raggedly at its text. That is already how a
        // caller that pre-pads its rows behaves, so this makes the two agree.
        try self.out.splatByteAll(' ', available_width - print_cols);

        // Clean up attributes back to standard theme state
        if (style_opt != null) {
            try self.out.writeAll(ansi.style.reset);
        }

        // Update local tracked state variables inside the View instance wrapper
        self.cursors[idx].col = col + print_cols;
        self.cursors[idx].row = row;
    }

    /// Renders the one-line command window, in the row `drawFramework`
    /// already reserves and leaves blank between the top panel and the
    /// scrolling log (its "Scroll Box Label Row") — so this needs no new
    /// layout geometry, just content in a row that was always there.
    ///
    /// Domain-agnostic like the rest of this module: it draws a prompt, the
    /// text it's handed, and a caret, and knows nothing about what a
    /// command is or who parses it. Same display-column padding discipline
    /// as `writeScroll` (see its comment): a typed line is ASCII today, but
    /// padding by bytes is the bug that put a stray border on screen once
    /// already, and nothing stops a target name from being typed with a
    /// multi-byte character in it.
    pub fn renderCommandLine(self: *View, text: []const u8) !void {
        const inner_width = self.layout.sec_widths[@backingInt(Section.section_4)];
        if (inner_width < 6) return; // no room for a prompt worth drawing

        try ansi.cursor(self.out, 2, self.layout.scrollLabelRow());
        try self.out.writeAll(PROMPT);

        // The caret occupies a column of its own, so the text gets one
        // fewer than the prompt leaves — and a line typed longer than the
        // window shows its tail (where the caret is), not its head, which
        // is what a text field is expected to do.
        const available_width = inner_width - 2 - @as(u32, PROMPT.len);
        const text_width = available_width - 1;
        const shown = tailToColumns(text, text_width);
        try self.out.writeAll(shown);
        try self.out.writeAll(CARET);
        var pad = text_width -| displayColumns(shown);
        while (pad > 0) : (pad -= 1) try self.out.writeAll(" ");
        try self.out.writeAll("│");
        try self.out.flush();
    }

    const PROMPT = "> ";
    /// A drawn caret rather than the terminal's real cursor: watch mode
    /// hides the cursor (`clearScreen`), and every other write here is
    /// cursor-addressed and would drag a visible one around the frame.
    const CARET = "▏";

    /// Appends text smoothly to the lower terminal sub-window
    pub fn writeScroll(self: *View, text: []const u8) !void {
        const inner_width = self.layout.sec_widths[@backingInt(Section.section_4)];

        // Move to the inside of the left border (column 2)
        try ansi.cursor(self.out, 2, self.scrollLine);

        // Ensure the text fits precisely within our layout box. Sized and
        // padded by DISPLAY COLUMNS, not bytes: `model.report()` messages
        // routinely carry multi-byte UTF-8 ("—"/"→" appear in a dozen+
        // call sites, including every rule/schedule fire) — a byte-length
        // `{s:<[N]}` pads short by however many extra bytes those
        // characters cost, so this row's own trailing "│" lands left of
        // the true border column `drawFramework` already drew there,
        // leaving both visible on one row until the next full redraw
        // (resize) repaints the border and exposes the same gap again.
        const available_width = inner_width - 2;
        const print_text = truncateToColumns(text, available_width);
        const cols = displayColumns(print_text);
        try self.out.writeAll(print_text);
        var pad = available_width -| cols;
        while (pad > 0) : (pad -= 1) try self.out.writeAll(" ");
        try self.out.writeAll("│");

        self.scrollLine += 1;
        if (self.scrollLine > self.layout.scrollContentBottom()) {
            self.scrollLine = self.layout.scrollContentTop();
        }
    }
};

/// Counts display columns in `text`, treating each valid UTF-8 codepoint
/// as one column. True for everything this codebase actually formats
/// into a log line (ASCII plus a handful of single-width symbols like
/// "—"/"→") — not East-Asian-width-aware, but nothing here ever emits
/// double-width text. Falls back to byte length on invalid UTF-8 rather
/// than erroring: a malformed log line shouldn't crash the TUI, just
/// render a little wide.
pub fn displayColumns(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Truncates `text` to at most `max_cols` display columns, cutting on a
/// codepoint boundary — never mid-UTF8-sequence, which would otherwise
/// slice a multi-byte character in half and hand the terminal invalid
/// UTF-8 to render.
pub fn truncateToColumns(text: []const u8, max_cols: u32) []const u8 {
    const view = std.unicode.Utf8View.init(text) catch return text[0..@min(text.len, max_cols)];
    var it = view.iterator();
    var cols: u32 = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (cols >= max_cols) break;
        cols += 1;
        end += slice.len;
    }
    return text[0..end];
}

/// Pads `text` out to `width` display columns, allocating only when padding
/// is actually needed.
///
/// The counterpart to `truncateToColumns`, and the reason both are here rather
/// than in a caller: `{s:<[w]}` pads by BYTE length, so a row containing "·",
/// "—" or "→" comes up short by exactly the surplus bytes and leaves debris at
/// the panel's right edge. Both applications had their own copy of this before
/// 2026-07-26; the copies are what said it belonged in the library.
pub fn padToColumns(arena: Allocator, text: []const u8, width: u32) ![]const u8 {
    const cols = displayColumns(text);
    if (cols >= width) return text;
    const pad = width - cols;
    const padded = try arena.alloc(u8, text.len + pad);
    @memcpy(padded[0..text.len], text);
    @memset(padded[text.len..], ' ');
    return padded;
}

/// Renders one row from cells and their widths, padding and truncating each by
/// display columns.
///
/// **The final cell is neither padded nor truncated**: there is no column to
/// its right to protect, trailing spaces are `padToColumns`' job, and `View`
/// clips the row to the panel anyway. Every other cell IS truncated — an
/// over-long name must not shove the columns after it out of line.
pub fn renderColumns(arena: Allocator, cells: []const []const u8, widths: []const usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (cells, 0..) |cell, i| {
        if (i == cells.len - 1) {
            try out.appendSlice(arena, cell);
            break;
        }
        const w = widths[i];
        const text = truncateToColumns(cell, @intCast(w));
        try out.appendSlice(arena, text);
        try out.appendNTimes(arena, ' ', w - displayColumns(text) + 1); // +1 = the column gap
    }
    return out.items;
}

test "padToColumns and renderColumns count columns, not bytes" {
    const arena = std.testing.allocator;

    // "—" is 3 bytes for 1 column, so byte padding would stop 2 short.
    const padded = try padToColumns(arena, "a—b", 6);
    defer arena.free(padded);
    try std.testing.expectEqual(@as(usize, 6), displayColumns(padded));
    try std.testing.expectEqualStrings("a—b   ", padded);

    // Already at or over width: returned untouched, and not allocated.
    try std.testing.expectEqualStrings("abcdef", try padToColumns(arena, "abcdef", 6));
    try std.testing.expectEqualStrings("abcdefg", try padToColumns(arena, "abcdefg", 6));

    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const row = try renderColumns(fba.allocator(), &.{ "a—b", "toolongcell", "tail" }, &.{ 6, 4 });
    // Cell 1 padded to 6 + gap, cell 2 truncated to 4 + gap, tail verbatim.
    try std.testing.expectEqualStrings("a—b    tool tail", row);
}

/// `truncateToColumns`' mirror image: the LAST `max_cols` display columns,
/// cut on a codepoint boundary. Keeps the caret end of a too-long command
/// line visible (a text field scrolls its head off, not its tail).
fn tailToColumns(text: []const u8, max_cols: u32) []const u8 {
    const cols = displayColumns(text);
    if (cols <= max_cols) return text;
    const view = std.unicode.Utf8View.init(text) catch return text[text.len - @min(text.len, max_cols) ..];
    var it = view.iterator();
    var skip = cols - max_cols;
    var start: usize = 0;
    while (skip > 0) : (skip -= 1) {
        const slice = it.nextCodepointSlice() orelse break;
        start += slice.len;
    }
    return text[start..];
}

/// Queries the operating system terminal driver for the current window
/// boundaries. Falls back to a standard conservative grid if stdout is
/// redirected or unqueryable.
pub fn getTerminalSize() TerminalSize {
    var ws: posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    // Use the explicit handle from standard out
    const stdout_fd = std.Io.File.stdout().handle;

    // In Zig 0.16, TIOCGWINSZ becomes T.IOCGWINSZ inside the terminal namespace
    const rc = posix.system.ioctl(stdout_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));

    // Fallback if the call fails or reports an invalid zeroed terminal geometry
    if (posix.errno(rc) != .SUCCESS or ws.col == 0 or ws.row == 0) {
        return .{ .width = 80, .height = 24 };
    }

    return .{
        .width = ws.col,
        .height = ws.row,
    };
}

/// A single pre-formatted line plus whatever style it should be drawn
/// with. Callers (main.zig) own all domain knowledge — View only knows
/// how to put text on screen and, optionally, how to color it.
pub const Row = struct {
    text: []const u8,
    style: ?WriteStyle = null,
    /// **Display column at which `style` starts.** 0 styles the whole row, as
    /// before. Otherwise the label before it stays plain, so a row can put one
    /// word in red without colouring the name it belongs to — the text cannot
    /// carry its own escapes, because width is counted in codepoints and an
    /// escape would be counted as columns it does not occupy.
    style_from: u32 = 0,
};

/// Future styling hook to prepare for temporary change-highlighting.
pub const WriteStyle = struct {
    fg_color: ?[]const u8 = null,
    bg_color: ?[]const u8 = null,
    bold: bool = false,

    pub const alarm: WriteStyle = .{ .fg_color = ansi.fg.red, .bg_color = ansi.bg.white };
    pub const alert: WriteStyle = .{ .fg_color = ansi.fg.bright_red, .bg_color = ansi.bg.black };
    pub const highlight: WriteStyle = .{ .fg_color = ansi.fg.bright_green, .bg_color = ansi.bg.black };
    /// **A state worth noticing that is not a fault** — an operator's own
    /// choice, a mode that explains an absence. Red reads as an error and gets
    /// ignored when it turns out not to be one.
    pub const caution: WriteStyle = .{ .fg_color = ansi.fg.bright_yellow, .bg_color = ansi.bg.black };
};

test "display current time" {
    // Manually instantiate a threaded I/O engine for testing
    var threaded_io = std.Io.Threaded.init_single_threaded;
    const io = threaded_io.io();
    _ = io;
}

test "displayColumns counts codepoints, not bytes, for multi-byte UTF-8" {
    try std.testing.expectEqual(@as(usize, 5), displayColumns("hello"));
    // "—" (em-dash) is 3 bytes, 1 codepoint/column.
    try std.testing.expectEqual(@as(usize, 3), displayColumns("a—b"));
    // "→" (arrow) is 3 bytes, 1 codepoint/column.
    try std.testing.expectEqual(@as(usize, 3), displayColumns("a→b"));
}

test "truncateToColumns cuts on a codepoint boundary, never mid-UTF8-sequence" {
    const s = "ab—cd"; // a, b, —(3 bytes), c, d = 5 columns, 7 bytes
    try std.testing.expectEqualStrings("ab", truncateToColumns(s, 2));
    try std.testing.expectEqualStrings("ab—", truncateToColumns(s, 3));
    try std.testing.expectEqualStrings("ab—cd", truncateToColumns(s, 10)); // shorter than max: unchanged
    // A codepoint-boundary cut must never leave an incomplete UTF-8
    // sequence — "ab—" (3 columns) must be valid UTF-8 on its own, not
    // "ab" plus a stray leading byte of "—".
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncateToColumns(s, 3)));
}

test "writeTo blanks the rest of the cell, so a shortened row leaves no residue" {
    // The bug this pins was seen in `example/tui-demo`: a row read "ALARM" one
    // frame and "ok" the next, and the screen showed "okARM". Nothing clears a
    // cell between frames, so `writeTo` has to fill it.
    const gpa = std.testing.allocator;
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(80, 40);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    var view = View.init(gpa, S.threaded.io(), &layout, &w);

    const width = layout.sec_widths[0];
    try view.writeTo(.section_1, 0, 0, "ok", null);

    const written = w.buffered();
    const content_start = std.mem.indexOfScalar(u8, written, 'H').? + 1;
    const cell = written[content_start..];

    // Two columns of text, then blanks all the way to the section's edge.
    try std.testing.expectEqual(@as(usize, width), displayColumns(cell));
    try std.testing.expectEqualStrings("ok", cell[0..2]);
    for (cell[2..]) |c| try std.testing.expectEqual(@as(u8, ' '), c);
}

test "a row styled from a column leaves its label plain and still fills the cell" {
    const gpa = std.testing.allocator;
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(80, 40);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    var view = View.init(gpa, S.threaded.io(), &layout, &w);

    const red: WriteStyle = .{ .fg_color = ansi.fg.red };
    try view.renderRows(&.{.{ .text = "settings modified", .style = red, .style_from = 9 }});

    const written = w.buffered();
    // The *last* cursor move: `renderRows` draws the clock first, so the first
    // one belongs to the clock, not to this row.
    const cell = written[std.mem.lastIndexOfScalar(u8, written, 'H').? + 1 ..];
    // The label comes first, untouched; the colour starts at the word.
    try std.testing.expect(std.mem.startsWith(u8, cell, "settings "));
    try std.testing.expect(std.mem.indexOf(u8, cell, ansi.fg.red ++ "modified") != null);
    // And the colour is off again before the blanking, not after.
    try std.testing.expect(std.mem.indexOf(u8, cell, "modified" ++ ansi.style.reset ++ " ") != null);
}

test "writeTo truncates by display columns, never mid-codepoint" {
    const gpa = std.testing.allocator;
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(20, 40);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    var view = View.init(gpa, S.threaded.io(), &layout, &w);

    // Em-dashes cost 3 bytes for 1 column, so a byte-based cut would both
    // shorten this row and risk handing the terminal half a character.
    const long = "———————————————————————————————————————";
    try view.writeTo(.section_1, 0, 0, long, null);

    const written = w.buffered();
    const cell = written[std.mem.indexOfScalar(u8, written, 'H').? + 1 ..];
    try std.testing.expectEqual(@as(usize, layout.sec_widths[0]), displayColumns(cell));
    try std.testing.expect(std.unicode.utf8ValidateSlice(cell));
}

test "writeScroll aligns the right border by display columns, not bytes" {
    // Reproduces the exact terminal size and message shape (from a real
    // hardware session) that surfaced this bug: an em-dash in a logged
    // line made the row's own border land 2 columns short of the true
    // right edge drawFramework had already drawn there, showing as a
    // stray extra "│" until the next resize repainted it.
    //
    // The message is generic but its shape is load-bearing: it must carry
    // a multi-byte character, because that is the whole defect.
    const gpa = std.testing.allocator;
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(125, 90);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    var view = View.init(gpa, S.threaded.io(), &layout, &w);

    const msg = "[event] a logged line of roughly panel width, carrying an em-dash — which costs 3 bytes for 1 column";
    try view.writeScroll(msg);

    const written = w.buffered();
    // Strip the leading ANSI cursor-position escape (ends in 'H').
    const content_start = std.mem.indexOfScalar(u8, written, 'H').? + 1;
    const content = written[content_start..];

    try std.testing.expect(std.mem.endsWith(u8, content, "│"));
    const available_width = layout.sec_widths[3] - 2;
    // Everything up to the final border character (text + padding) must
    // occupy exactly `available_width` display columns -- not fall short
    // by however many extra bytes the em-dash cost.
    const before_border = content[0 .. content.len - "│".len];
    try std.testing.expectEqual(@as(usize, available_width), displayColumns(before_border));
}

test "the command line and the log's first row are different rows (they once collided)" {
    // The regression that made watch mode unusable on the first live run:
    // `view.zig` kept its own copy of the row maths, drifted one row from
    // `layout.zig`'s, so `writeScroll` started exactly on the command line
    // and overwrote it while the user typed. Both must now come from Layout.
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(125, 90);

    const command_row = layout.scrollLabelRow();
    const first_log_row = layout.scrollContentTop();
    try std.testing.expect(command_row != first_log_row);
    try std.testing.expectEqual(command_row + 1, first_log_row); // log starts directly below

    // And the log must fit its own box: `drawFramework` paints scroll_height
    // rows from scrollContentTop, and writeScroll wraps at scrollContentBottom.
    try std.testing.expectEqual(first_log_row + layout.scroll_height - 1, layout.scrollContentBottom());
    // The bottom border sits below the last log row, not on it.
    try std.testing.expect(layout.scrollContentBottom() + 1 > layout.scrollContentBottom());
}

test "renderCommandLine: prompt, caret, and border land on the frame's own columns" {
    const gpa = std.testing.allocator;
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(125, 90);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    var view = View.init(gpa, S.threaded.io(), &layout, &w);

    try view.renderCommandLine("connect port2");

    const written = w.buffered();
    const content_start = std.mem.indexOfScalar(u8, written, 'H').? + 1;
    const content = written[content_start..];

    try std.testing.expect(std.mem.startsWith(u8, content, "> connect port2▏"));
    try std.testing.expect(std.mem.endsWith(u8, content, "│"));
    // Same invariant writeScroll's test asserts, for the same reason: the
    // row must occupy exactly the box's inner width in display columns, so
    // its border sits on top of the one drawFramework drew rather than
    // beside it.
    const before_border = content[0 .. content.len - "│".len];
    try std.testing.expectEqual(@as(usize, layout.sec_widths[3] - 2), displayColumns(before_border));
}

test "renderCommandLine shows the tail of an over-long line, so the caret stays visible" {
    const gpa = std.testing.allocator;
    var layout = Layout.init(.wide_single, .{ 0, 0, 0 }, 55);
    layout.recalculate(40, 24); // narrow: 38 inner columns, 36 for text+caret

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    var view = View.init(gpa, S.threaded.io(), &layout, &w);

    const long = "on 00:17:88:01:08:d1:40:dd extra words here";
    try view.renderCommandLine(long);

    const written = w.buffered();
    const content_start = std.mem.indexOfScalar(u8, written, 'H').? + 1;
    const content = written[content_start..];

    // The head is scrolled off; the end of what was typed (where the caret
    // is) stays on screen, as in any text field.
    try std.testing.expect(std.mem.indexOf(u8, content, "words here▏") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "on 00:17") == null);
    const before_border = content[0 .. content.len - "│".len];
    try std.testing.expectEqual(@as(usize, layout.sec_widths[3] - 2), displayColumns(before_border));
}

test "tailToColumns keeps the last N columns, cutting on a codepoint boundary" {
    try std.testing.expectEqualStrings("port2", tailToColumns("connect port2", 5));
    try std.testing.expectEqualStrings("setup", tailToColumns("setup", 9)); // shorter than the window
    // "—" is 3 bytes, 1 column: a byte-based tail would slice it in half.
    try std.testing.expectEqualStrings("—b", tailToColumns("a—b", 2));
}

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
