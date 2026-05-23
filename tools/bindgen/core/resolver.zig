//! Résolveur d'imports cross-api (squelette M0.2 / E5).
//!
//! Résout les références de types entre `.api.zig` distinctes
//! (e.g. `openxr.api.zig` importe `VkInstance` de
//! `vulkan.api.zig` — cf. `engine-c-bindings.md` §3.5
//! `ImportDecl`). Construit la table de mapping `C name → Zig
//! qualified name` consommée par l'emitter.
//!
//! Statut M0.2 : **squelette**. Aucun adapter M0.2 ne traverse
//! d'import inter-API (Vulkan et Wayland sont autonomes). Le
//! squelette est posé pour la première adoption Phase 1+ (par
//! exemple OpenXR Phase 4 qui réutilise les types Vulkan, ou un
//! keeper qui dépend d'un autre via `ImportDecl`).

const std = @import("std");
const api = @import("api_description.zig");

/// Référence résolue d'un type cross-api : `(api_name, type_name)`.
pub const ResolvedRef = struct {
    api_name: []const u8,
    type_name: []const u8,
};

/// Erreurs surfacées par `resolveImports`. Squelette M0.2.
pub const ResolverError = error{
    UnknownImport,
    AmbiguousTypeName,
    CircularImport,
};

/// Résout les imports d'une `ApiDescription` contre une slice
/// d'autres descriptions disponibles. Squelette M0.2 — retourne
/// systématiquement `Ok` faute d'adapter à exercer.
pub fn resolveImports(
    desc: api.ApiDescription,
    available: []const api.ApiDescription,
) ResolverError!void {
    _ = desc;
    _ = available;
    // Sera étoffé par le premier adapter Phase 1+ qui exerce un
    // `ImportDecl`.
}

test "resolveImports is a no-op skeleton in M0.2" {
    const desc = api.ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{ .name = .{ .runtime = .{ .linux = "", .windows = "", .macos = "" } } },
    };
    try resolveImports(desc, &.{});
}
