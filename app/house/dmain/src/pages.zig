//! The phone pages, embedded so the program needs nothing beside it.

pub const index_html = @embedFile("web/index.html");
pub const motion_html = @embedFile("web/motion.html");
pub const rooms_html = @embedFile("web/rooms.html");
pub const style_css = @embedFile("web/style.css");
pub const common_js = @embedFile("web/common.js");
pub const manifest = @embedFile("web/manifest.webmanifest");
pub const icon_192 = @embedFile("web/icon-192.png");
pub const icon_512 = @embedFile("web/icon-512.png");
