//! Validateur d'`ApiDescription` (squelette M0.2 / E5).
//!
//! Vérifie la cohérence interne d'une description avant émission :
//! refs de types résolues, pas de cycles non gérés, annotations
//! cohérentes (cf. `engine-c-bindings.md` §9.2). Exécuté par
//! `tools/bindgen/main.zig` après chaque adapter et avant
//! `emitter`.
//!
//! Statut M0.2 : **squelette**. Les adapters `vk_xml` et
//! `wayland_xml` court-circuitent le pipeline `.api.zig` →
//! `emitter` en M0.2 (décision technique E5 (i)), donc le
//! validateur n'a pas de description complète à vérifier sur ce
//! milestone. Le squelette est en place pour les adapters Phase
//! 1+ qui consommeront `ApiDescription` comme input canonique.

const std = @import("std");
const api = @import("api_description.zig");

/// Erreurs surfacées par `validate`. Encadrées au niveau du
/// squelette M0.2 ; le contenu réel sera étoffé quand un premier
/// adapter Phase 1 produit une `ApiDescription` exerçant les
/// règles.
pub const ValidationError = error{
    UnresolvedTypeRef,
    UnsupportedCycle,
    InconsistentAnnotations,
    NameCollision,
};

/// Vérifie la cohérence interne d'une `ApiDescription`. Squelette
/// M0.2 — `Ok` systématique. Les vérifications réelles
/// (résolution de refs, détection de cycles, cohérence ownership)
/// sont introduites par les premiers adapters Phase 1+ qui
/// consomment `ApiDescription`.
pub fn validate(desc: api.ApiDescription) ValidationError!void {
    // Garde-fou minimaliste : un nom vide est un signal qu'on
    // n'utilise pas le format. Préfère lever explicitement plutôt
    // que de laisser une description incohérente filer vers
    // l'emitter.
    if (desc.name.len == 0) return error.NameCollision;
}

test "validate accepts a minimal description" {
    const desc = api.ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{
            .name = .{ .runtime = .{
                .linux = "libvulkan.so",
                .windows = "vulkan-1",
                .macos = "libvulkan",
            } },
        },
    };
    try validate(desc);
}

test "validate rejects empty name" {
    const desc = api.ApiDescription{
        .name = "",
        .version = .{ .major = 0, .minor = 0, .patch = 0 },
        .source = .manual,
        .link = .{ .name = .{ .runtime = .{ .linux = "", .windows = "", .macos = "" } } },
    };
    try std.testing.expectError(error.NameCollision, validate(desc));
}
