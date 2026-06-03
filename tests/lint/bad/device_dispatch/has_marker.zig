//! Fixture: a file carrying the forbidden `WELD_LEGACY_VK_DISPATCH` marker.
//!
//! WELD_LEGACY_VK_DISPATCH — the grandfather escape is banned (M0.5 item 4).
//! `weld_lint lint` must flag this file's header marker with a non-zero exit,
//! even though the file itself uses no `vk.device_dispatch` access.

const placeholder = 0;
