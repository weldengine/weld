//! Émetteur Zig idiomatique commun (squelette M0.2 / E5).
//!
//! Consomme une `ApiDescription` (déjà validée + résolue) et
//! produit le wrapper Zig `<name>_binding.zig` au format
//! `engine-c-bindings.md` §4. Émet le code dlopen pour les 4
//! stratégies (`dlopen`, `dlopen_loader_pattern`, `framework`,
//! `static_link`, cf. `engine-c-bindings.md` §4.6).
//!
//! Statut M0.2 : **squelette structurel**. Les adapters
//! `vk_xml` et `wayland_xml` portent leurs propres pipelines
//! d'émission 1:1 depuis `tools/vk_gen/` / `tools/wayland_gen/`
//! et écrivent directement le Zig idiomatique sans passer par
//! cet émetteur commun (décision technique E5 (i) du brief —
//! préservation du critère « diff vide » non-négociable).
//!
//! Cet émetteur sera exercé par les premiers keepers Phase 1+
//! (Opus, Assimp, KTX/Basis, libdatachannel, ACL compresseur,
//! HarfBuzz, ONNX) qui décrivent leur surface dans
//! `bindings/manual/*.api.zig` et n'ont aucune contrainte de
//! `diff vide` rétroactive.

const std = @import("std");
const api = @import("api_description.zig");

/// Erreurs surfacées par `emit`. Squelette M0.2.
pub const EmitError = error{
    UnsupportedStrategy,
    UnsupportedTypeKind,
    OutOfMemory,
};

/// Émet le wrapper Zig idiomatique pour `desc` dans `out`.
/// Squelette M0.2 : écrit un placeholder commenté précisant que
/// l'émission réelle est court-circuitée par les adapters
/// `vk_xml` et `wayland_xml` ; les premiers adapters Phase 1+
/// remplaceront ce corps par l'émission complète des 4
/// stratégies dlopen.
pub fn emit(
    desc: api.ApiDescription,
    out: *std.Io.Writer,
) EmitError!void {
    out.print(
        "//! AUTO-GENERATED placeholder for {s} v{d}.{d}.{d}.\n",
        .{ desc.name, desc.version.major, desc.version.minor, desc.version.patch },
    ) catch return error.OutOfMemory;
    out.writeAll(
        "//! M0.2 / E5 — emitter skeleton. The vk_xml and wayland_xml\n" ++
            "//! adapters short-circuit this stage and write Zig directly\n" ++
            "//! (decision technique E5 (i), brief § Notes). Phase 1+ keepers\n" ++
            "//! will exercise this emitter for real.\n",
    ) catch return error.OutOfMemory;
}

test "emit writes a placeholder for a minimal description" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw = buf.writer(gpa).adaptToNewApi(&.{});
    const desc = api.ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{ .name = .{ .runtime = .{ .linux = "", .windows = "", .macos = "" } } },
    };
    try emit(desc, &aw.new_interface);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "vulkan") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "skeleton") != null);
}
