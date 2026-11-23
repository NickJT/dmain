const std = @import("std");
const Allocator = std.mem.Allocator;

/// Queries the operating system terminal driver for the current window boundaries.
/// Falls back to a standard conservative grid if stdout is redirected or unqueryable.
pub const TerminalSize = struct {
    width: u32,
    height: u32,
};

pub const Section = enum(u2) {
    section_1 = 0, // e.g., Lights Column
    section_2 = 1, // e.g., Temperature Column
    section_3 = 2, // e.g., Motion Column
    section_4 = 3, // e.g., Full-Width Scroll Region
};

/// Which top-panel column geometry is active. Row math (title, headers,
/// mid-divider, scroll area) is identical in both modes — only the
/// number and width of top-panel columns changes.
pub const LayoutMode = enum {
    three_col, // Current default: three side-by-side columns
    wide_single, // One full-width pane, one line per row
};

pub const Layout = struct {
    // --- Named Structural Constants  ---
    pub const ROW_TITLE: u32 = 1;
    pub const ROW_TOP_BORDER: u32 = 2;
    pub const ROW_COL_HEADERS: u32 = 3;
    pub const ROW_HEADER_DIVIDER: u32 = 4;

    // Fixed structural rows: Title (1), Top Border (1), Headers (1), Header Divider (1),
    // Mid Divider (1), Scroll Label (1), Bottom Border (1).
    pub const TOTAL_ROW_OVERHEAD: u32 = 7;

    pub const DEFAULT_LEFT_PADDING: u32 = 2;

    // --- Policy Constraints (Set via Percentages) ---
    mode: LayoutMode,
    col_percentages: [3]u8, // Only col_percentages[0..active_columns] are meaningful
    top_height_percentage: u8,

    // --- Dynamically Computed Geometry (Read-Only to External Modules) ---
    sec_widths: [4]u32,
    active_columns: u32,
    sec_height: u32,
    scroll_height: u32,
    left_col: u32,
    total_width: u32,

    last_width: u32,
    last_height: u32,

    /// Initializes the layout strategy for a given column mode. In
    /// `.three_col` mode, col_pcts must sum to 100 and describes the
    /// three top-panel column widths; in `.wide_single` mode col_pcts is
    /// unused (the single pane always takes the full available width).
    pub fn init(mode: LayoutMode, col_pcts: [3]u8, top_panel_pct: u8) Layout {
        std.debug.assert(top_panel_pct <= 100);

        var self: Layout = .{
            .mode = mode,
            .col_percentages = col_pcts,
            .top_height_percentage = top_panel_pct,
            .sec_widths = .{ 0, 0, 0, 0 },
            .active_columns = 0, // set below by setMode
            .sec_height = 0,
            .scroll_height = 0,
            .left_col = DEFAULT_LEFT_PADDING,
            .total_width = 0,
            .last_width = 0,
            .last_height = 0,
        };
        self.setMode(mode, col_pcts);
        return self;
    }

    /// Switches the active column geometry — e.g. in response to a
    /// digit-key view change. Forces the next redrawNeeded() check to
    /// recalculate and redraw regardless of whether the terminal size
    /// actually changed, since the column count/widths did.
    /// Resizes the top panel as a percentage of the available height, and
    /// forces the next `redrawNeeded` check to repaint.
    ///
    /// Screens differ in how much room they want: a device table is happy
    /// sharing with a big scrolling log, while the help screen is a wall of
    /// text that gets silently truncated at `sec_height` if it can't have
    /// most of the window.
    pub fn setTopPercentage(self: *Layout, pct: u8) void {
        std.debug.assert(pct <= 100);
        if (self.top_height_percentage == pct) return;
        self.top_height_percentage = pct;
        self.last_width = 0;
        self.last_height = 0;
    }

    pub fn setMode(self: *Layout, mode: LayoutMode, col_pcts: [3]u8) void {
        switch (mode) {
            .three_col => std.debug.assert(col_pcts[0] + col_pcts[1] + col_pcts[2] == 100),
            .wide_single => {},
        }

        self.mode = mode;
        self.col_percentages = col_pcts;
        self.active_columns = switch (mode) {
            .three_col => 3,
            .wide_single => 1,
        };
        self.last_width = 0;
        self.last_height = 0;
    }

    /// Recalculates exact cell boundaries based on terminal grid size transformations.
    pub fn recalculate(self: *Layout, term_w: u32, term_h: u32) void {
        self.total_width = term_w;

        // 1. Compute Horizontal Grid Column Widths
        // Vertical frame lines needed = one wall per column, plus one
        // extra for the final right-hand wall (e.g. 3 columns -> 4 walls,
        // 1 column -> 2 walls).
        const dividers = self.active_columns + 1;
        const available_width = if (term_w > dividers) term_w - dividers else 0;

        switch (self.mode) {
            .three_col => {
                const w0 = (available_width * self.col_percentages[0]) / 100;
                const w1 = (available_width * self.col_percentages[1]) / 100;
                // Snap remainder to the final column to eliminate layout drift due to integer division
                const w2 = available_width - (w0 + w1);

                self.sec_widths[0] = w0;
                self.sec_widths[1] = w1;
                self.sec_widths[2] = w2;
            },
            .wide_single => {
                self.sec_widths[0] = available_width;
                self.sec_widths[1] = 0;
                self.sec_widths[2] = 0;
            },
        }
        self.sec_widths[3] = term_w; // Section 4 (scroll area) always occupies full interface width

        // 2. Compute Vertical Split Heights (identical in both column modes)
        const available_height = if (term_h > TOTAL_ROW_OVERHEAD) term_h - TOTAL_ROW_OVERHEAD else 0;

        const sec_h = (available_height * self.top_height_percentage) / 100;
        const scroll_h = available_height - sec_h;

        self.sec_height = sec_h;
        self.scroll_height = scroll_h;
    }

    pub fn redrawNeeded(self: *Layout, current_size: TerminalSize) bool {
        if (current_size.width != self.last_width or current_size.height != self.last_height) {
            self.last_width = current_size.width;
            self.last_height = current_size.height;

            // Policy Update: Recalculate column allocations dynamically
            self.recalculate(current_size.width, current_size.height);
            return true;
        }
        return false;
    }

    // --- Absolute Cell Coordinate Mapping Layout Helpers ---

    pub inline fn sectionLeft(self: *const Layout, sec: Section) u32 {
        return switch (sec) {
            .section_1 => self.left_col,
            .section_2 => self.left_col + self.sec_widths[0] + 1,
            .section_3 => self.left_col + self.sec_widths[0] + 1 + self.sec_widths[1] + 1,
            .section_4 => self.left_col,
        };
    }

    pub inline fn sectionTop(self: *const Layout) u32 {
        _ = self;
        return ROW_HEADER_DIVIDER + 1;
    }

    pub inline fn midDividerRow(self: *const Layout) u32 {
        return self.sectionTop() + self.sec_height;
    }

    pub inline fn scrollLabelRow(self: *const Layout) u32 {
        return self.midDividerRow() + 1;
    }

    pub inline fn scrollContentTop(self: *const Layout) u32 {
        return self.scrollLabelRow() + 1;
    }

    pub inline fn scrollContentBottom(self: *const Layout) u32 {
        return self.scrollContentTop() + self.scroll_height - 1;
    }

    pub inline fn totalWidth(self: *const Layout) u32 {
        return self.total_width;
    }
};

test "Semantic Check" {
    std.testing.refAllDecls(@This());
}
