//! Format canonique `.api.zig` consommé par le générateur unifié
//! Weld bindgen (cf. `engine-c-bindings.md` §3).
//!
//! Statut M0.2 / E5 : **squelette structurel**. Le format est posé
//! et figé pour les adapters Phase 1+ (Opus, Assimp, KTX/Basis,
//! libdatachannel, ACL compresseur, HarfBuzz, ONNX). En M0.2, les
//! deux adapters effectifs — `vk_xml` et `wayland_xml` — portent
//! le pipeline 1:1 depuis l'ancien `tools/vk_gen/` /
//! `tools/wayland_gen/` et écrivent directement le Zig idiomatique
//! sans passer par cette `ApiDescription` intermédiaire. La
//! décision technique E5 (i) trace ce contournement pragmatique
//! pour préserver le critère « diff vide » non-négociable.
//!
//! Le format défini ici est destiné à devenir l'**input
//! canonique** de `core/emitter.zig` pour les futurs adapters et
//! les bindings manuels (`bindings/manual/*.api.zig`). Les
//! `bindings/generated/*.api.zig` produits par les adapters M0.2
//! contiennent une `ApiDescription` minimale renseignant `name` /
//! `version` / `source` — assez pour distinguer une description
//! manuelle d'une description générée et préserver l'auditabilité
//! du pipeline. Le contrat complet (types, fonctions, ownership,
//! stratégies de chargement) sera exercé par les premiers keepers
//! Phase 1.

const std = @import("std");

/// Versioning sémantique d'une API. Informational — utilisé pour
/// les diff de description et les warnings de migration.
pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
};

/// Origine des définitions C / Objective-C / XML d'une description.
pub const Source = union(enum) {
    /// Headers C consommés via `addTranslateC` (keepers via
    /// `.api.zig` manuel).
    c_headers: []const []const u8,
    /// XML Khronos consommé par un adapter dédié (vk.xml, xr.xml).
    xml_khronos: []const u8,
    /// XML Wayland / freedesktop.
    xml_wayland: []const u8,
    /// Bridge Objective-C runtime (libobjc + frameworks Apple).
    objc_runtime: struct {
        framework: []const u8,
        platform_filter: PlatformFilter,
    },
    /// Pas de source — sortie pure (export Tier 3 C API Weld).
    output_only,
    /// Description rédigée manuellement (keepers Phase 1+ via
    /// `bindings/manual/*.api.zig`).
    manual,
};

/// Filtre plateforme pour les sources `objc_runtime`. `both` =
/// macOS + iOS, mêmes selectors et même framework.
pub const PlatformFilter = enum { macos, ios, both };

/// Stratégie de chargement d'une lib. 4 variantes exposées en
/// M0.2 (cf. `engine-c-bindings.md` §4.6) ; seule
/// `dlopen_loader_pattern` est effectivement exercée par les
/// adapters M0.2 (Vulkan + Wayland).
pub const Strategy = enum {
    /// dlopen + dlsym par fonction. Défaut des keepers C.
    dlopen,
    /// Pattern Khronos : dlopen du loader, puis getProcAddr par
    /// fonction. Imposé par l'architecture du standard (Vulkan,
    /// OpenGL, OpenXR, Wayland).
    dlopen_loader_pattern,
    /// Framework Apple — link build-time via `-framework`,
    /// résolution rpath au runtime.
    framework,
    /// Linkage statique build-time (consoles PS5/Xbox/Switch,
    /// iOS si exigé par App Store).
    static_link,
};

/// Comportement de l'init du module si la lib est absente.
pub const Requirement = enum {
    /// Échec à l'init = échec du module qui consomme le binding.
    hard,
    /// Échec à l'init = la feature est désactivée, le moteur
    /// continue avec un `isAvailable() == false`.
    soft,
};

/// Nom de la lib par plateforme. Variants couvrent les chemins
/// dlopen et les overrides build-time (console static archive,
/// framework Apple).
pub const LibName = union(enum) {
    runtime: struct {
        linux: []const u8,
        windows: []const u8,
        macos: []const u8,
    },
    static_archive: []const u8,
    framework: []const u8,
};

/// Bloc de chargement complet d'une lib. Combine nom +
/// stratégie + requirement + versions ABI cibles.
pub const Link = struct {
    name: LibName,
    strategy: Strategy = .dlopen,
    requirement: Requirement = .hard,
    soname_versions: []const []const u8 = &.{},
};

/// Catégorie d'une déclaration de type émise par l'adapter.
pub const TypeKind = enum {
    opaque_handle,
    extern_struct,
    alias,
    enum_tag,
    function_ptr,
    tagged_union,
};

/// Déclaration de type minimaliste — détails seront étoffés
/// quand un premier adapter consommera l'`ApiDescription` comme
/// input réel.
pub const TypeDecl = struct {
    name: []const u8,
    c_name: ?[]const u8 = null,
    kind: TypeKind,
};

/// Déclaration de fonction minimaliste — squelette pour
/// adapters Phase 1+.
pub const FunctionDecl = struct {
    zig_name: []const u8,
    c_name: []const u8,
};

/// Annotations de génération (overrides, hints) — squelette.
pub const Pragmas = struct {
    rename: []const RenameRule = &.{},
    skip: []const []const u8 = &.{},
    force_inline: []const []const u8 = &.{},
};

/// Règle de renommage d'un identifiant.
pub const RenameRule = struct {
    from: []const u8,
    to: []const u8,
};

/// Racine du format `.api.zig`. Une description complète d'une
/// surface C / Objective-C / XML consommée par Weld.
pub const ApiDescription = struct {
    name: []const u8,
    version: Version,
    source: Source,
    link: Link,
    types: []const TypeDecl = &.{},
    functions: []const FunctionDecl = &.{},
    pragmas: Pragmas = .{},
};

test "ApiDescription is comptime constructible" {
    // Sanity check — the format compiles and a minimal description
    // can be built at comptime.
    const desc = ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{
            .name = .{ .runtime = .{
                .linux = "libvulkan.so",
                .windows = "vulkan-1",
                .macos = "libvulkan",
            } },
            .strategy = .dlopen_loader_pattern,
            .requirement = .hard,
        },
    };
    try std.testing.expectEqualStrings("vulkan", desc.name);
    try std.testing.expectEqual(@as(u16, 1), desc.version.major);
}
