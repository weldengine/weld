//! M0.2 / E6 — types fondamentaux C de l'API plugin Tier 3 et
//! descripteur de plugin.
//!
//! Layout cohérent `engine-c-api.md` §2 (types fondamentaux) + §3
//! (plugin lifecycle). Les types sont `extern` ou alias d'entiers
//! C — ABI-compatible avec les plugins compilés en C / C++ /
//! Rust / etc. via le header `include/weld_api.h` (généré en
//! Phase 3, brief § Out-of-scope).
//!
//! Toutes les déclarations sont des **signatures finales gelées**
//! au sens du freeze partiel C0.5 (cf. brief § Scope). Aucun
//! câblage runtime — `Loader` ne fait que charger le `.so` /
//! `.dll`, lire le descripteur, et logger les capacités
//! déclarées. L'enforcement runtime des capabilities (filesystem,
//! network, threading) est Phase 3 (cf. brief § Out-of-scope).

const std = @import("std");

/// Version majeure de l'API plugin Weld. Incrémentée à chaque
/// rupture binaire (suppression / renommage de fonction,
/// changement de signature, changement de layout de struct).
/// Cf. `engine-c-api.md` §1.1.
pub const WELD_API_VERSION_MAJOR: u32 = 0;
/// Version mineure. Incrémentée à chaque ajout binairement
/// compatible (nouvelle fonction en fin de table, nouveau champ
/// en fin de struct).
pub const WELD_API_VERSION_MINOR: u32 = 1;
/// Version patch. Incrémentée pour bug fixes sans changement de
/// surface.
pub const WELD_API_VERSION_PATCH: u32 = 0;

// -- Types scalaires ABI-stable (cf. engine-c-api.md §2.1) ------------

/// Handle d'entité opaque, ABI-équivalent à `uint64_t`. Encode
/// `index` (32 bits bas) + `generation` (32 bits hauts).
pub const WeldEntity = u64;
/// Handle d'asset opaque, ABI-équivalent à `uint64_t`.
pub const WeldAssetHandle = u64;
/// Identifiant de type composant, ABI-équivalent à `uint32_t`.
pub const WeldComponentId = u32;
/// Identifiant de type resource, ABI-équivalent à `uint32_t`.
pub const WeldResourceId = u32;
/// Identifiant de type event, ABI-équivalent à `uint32_t`.
pub const WeldEventId = u32;
/// Identifiant de système ECS, ABI-équivalent à `uint32_t`.
pub const WeldSystemId = u32;
/// Identifiant de service Tier 1, ABI-équivalent à `uint32_t`.
pub const WeldServiceId = u32;
/// Tag hiérarchique compact, ABI-équivalent à `uint64_t`.
pub const WeldTagId = u64;

/// Sentinel "no entity" (cf. `engine-c-api.md` §2.1).
pub const WELD_ENTITY_NULL: WeldEntity = 0;

// -- Types math (cf. engine-c-api.md §2.2) ----------------------------

/// 2-component float vector. ABI = `struct { float x, y; }`.
pub const WeldVec2 = extern struct { x: f32 = 0, y: f32 = 0 };
/// 3-component float vector.
pub const WeldVec3 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };
/// 4-component float vector.
pub const WeldVec4 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 0 };
/// Quaternion (x, y, z, w).
pub const WeldQuat = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 1 };
/// 3×3 column-major matrix.
pub const WeldMat3 = extern struct { m: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
/// 4×4 column-major matrix.
pub const WeldMat4 = extern struct { m: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
/// RGBA float color (linear space).
pub const WeldColor = extern struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };

// -- String view + slice (cf. engine-c-api.md §2.3 + §2.4) ------------

/// Non-owning UTF-8 view. ABI = `struct { const char* ptr;
/// uint32_t len; }`. Pas garanti NUL-terminé.
pub const WeldStr = extern struct {
    ptr: ?[*]const u8 = null,
    len: u32 = 0,

    /// Construit un `WeldStr` à partir d'une slice Zig. Le caller
    /// est responsable de la durée de vie du buffer pointé.
    pub fn fromSlice(s: []const u8) WeldStr {
        return .{ .ptr = s.ptr, .len = @intCast(s.len) };
    }

    /// Vue Zig sur le `WeldStr`. Slice vide si `ptr == null`.
    pub fn slice(self: WeldStr) []const u8 {
        if (self.ptr) |p| return p[0..self.len];
        return &.{};
    }
};

/// Vue sur un tableau arbitraire (`const void* ptr; uint32_t
/// count; uint32_t stride;`). Utilisé pour les retours batched.
pub const WeldSlice = extern struct {
    ptr: ?*const anyopaque = null,
    count: u32 = 0,
    stride: u32 = 0,
};

// -- Opaque handles (cf. engine-c-api.md §2.5) ------------------------

/// Handle opaque vers le `World` ECS. Le plugin reçoit le
/// pointeur via `WeldAPI.world` et le passe aux callbacks ECS.
pub const WeldWorldHandle = ?*anyopaque;
/// Handle opaque vers une query ECS construite par
/// `WeldEcsAPI.query_create`.
pub const WeldQueryHandle = ?*anyopaque;
/// Handle opaque vers un allocateur Weld.
pub const WeldAllocatorHandle = ?*anyopaque;
/// Handle opaque vers le contexte éditeur (`null` en mode
/// runtime sans éditeur).
pub const WeldEditorCtxHandle = ?*anyopaque;

// -- Codes erreur (cf. engine-c-api.md §2.6) --------------------------

/// Résultat d'une opération API plugin. `0 == WELD_OK`,
/// négatif réservé pour erreurs futures.
pub const WeldResult = enum(c_int) {
    /// Opération réussie.
    WELD_OK = 0,
    /// Ressource non trouvée (entité morte, handle stale,
    /// composant non enregistré, etc.).
    WELD_ERR_NOT_FOUND = 1,
    /// Tentative d'ajout d'une ressource déjà présente.
    WELD_ERR_ALREADY_EXISTS = 2,
    /// `WeldEntity` invalide (generation mismatch).
    WELD_ERR_INVALID_ENTITY = 3,
    /// `WeldComponentId` inconnu.
    WELD_ERR_INVALID_COMPONENT = 4,
    /// `WeldResourceId` inconnu.
    WELD_ERR_INVALID_RESOURCE = 5,
    /// Type mismatch (entre signature attendue et données
    /// fournies).
    WELD_ERR_TYPE_MISMATCH = 6,
    /// Allocation impossible (allocateur saturé).
    WELD_ERR_OUT_OF_MEMORY = 7,
    /// Capability non déclarée dans `WeldPluginCaps`.
    WELD_ERR_PERMISSION_DENIED = 8,
    /// Service Tier 1 demandé mais non chargé (dégradation
    /// gracieuse côté plugin).
    WELD_ERR_SERVICE_UNAVAILABLE = 9,
    /// Version d'API incompatible.
    WELD_ERR_VERSION_MISMATCH = 10,
    /// Fonctionnalité déclarée mais pas encore câblée — M0.2
    /// retourne ce code pour 100 % des callbacks des 7 sous-APIs
    /// (cf. brief § Out-of-scope, câblage Phase 3).
    WELD_ERR_NOT_IMPLEMENTED = 11,
};

// -- Plugin capabilities (cf. engine-c-api.md §3.2) -------------------

/// Capacités déclarées par le plugin au chargement. M0.2 LIT ces
/// déclarations et les logue ; AUCUNE vérification runtime n'est
/// effectuée — l'enforcement (refus de `component_get` sur un
/// composant non déclaré dans `reads_components`, etc.) est
/// Phase 3 (brief § Out-of-scope).
pub const WeldPluginCaps = extern struct {
    // ECS
    reads_components: ?[*]const WeldStr = null,
    reads_components_count: u32 = 0,
    writes_components: ?[*]const WeldStr = null,
    writes_components_count: u32 = 0,
    reads_resources: ?[*]const WeldStr = null,
    reads_resources_count: u32 = 0,
    writes_resources: ?[*]const WeldStr = null,
    writes_resources_count: u32 = 0,

    // Services requis / optionnels
    required_services: ?[*]const WeldStr = null,
    required_services_count: u32 = 0,
    optional_services: ?[*]const WeldStr = null,
    optional_services_count: u32 = 0,

    // Platform — review manuelle si l'un de ces flags est true.
    needs_filesystem: bool = false,
    needs_network: bool = false,
    needs_threading: bool = false,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
};

// -- Plugin lifecycle callbacks (cf. engine-c-api.md §3.3) ------------

/// Lifecycle callbacks du plugin. Tous optionnels (`null` =
/// ignoré). M0.2 stub plugin laisse tous les callbacks `null`.
///
/// Les callbacks reçoivent `*const anyopaque` plutôt que le
/// concret `*const WeldAPI` (défini dans `api.zig`) — c'est le
/// pointeur opaque vers la table API que le plugin downcaste à
/// l'entrée via `@ptrCast`. Cela évite la dépendance cyclique
/// `desc.zig ↔ api.zig` tout en préservant la signature ABI
/// (au niveau C, tous les pointeurs sont des `void*`).
pub const WeldPluginCallbacks = extern struct {
    /// Appelé une fois à `loadPlugin`. Le plugin enregistre ses
    /// composants / resources / systèmes / events ici.
    on_load: ?*const fn (api: *const anyopaque) callconv(.c) WeldResult = null,
    /// Appelé après que TOUS les plugins sont chargés. Le plugin
    /// peut maintenant query les services des autres modules.
    on_init: ?*const fn (api: *const anyopaque) callconv(.c) WeldResult = null,
    /// Appelé chaque frame (uniquement si le plugin l'a déclaré).
    /// La plupart des plugins n'en ont pas besoin — ils
    /// utilisent des systèmes ECS.
    on_update: ?*const fn (api: *const anyopaque, dt: f32) callconv(.c) void = null,
    /// Appelé au `unloadPlugin`. Le plugin libère ses resources
    /// internes (les composants ECS sont gérés par le moteur).
    on_shutdown: ?*const fn (api: *const anyopaque) callconv(.c) void = null,
};

// -- Plugin descriptor (cf. engine-c-api.md §3.1) ---------------------

/// Descripteur retourné par le point d'entrée unique du plugin
/// (`weld_plugin_entry`). Identité + capacités + callbacks.
pub const WeldPluginDesc = extern struct {
    /// Nom court du plugin (`"advanced-animation-framework"`).
    name: WeldStr = .{},
    /// Nom affiché par l'éditeur (`"Advanced Animation Framework"`).
    display_name: WeldStr = .{},
    /// Version semver du plugin (`"1.2.0"`).
    version: WeldStr = .{},
    /// `WELD_API_VERSION_MAJOR` minimum supporté. Le loader
    /// refuse de charger si cette valeur excède la version
    /// majeure compilée dans Weld (`error.ApiVersionTooNew`).
    api_version_min: u32 = 0,
    _pad: u32 = 0,
    /// Capacités déclarées (cf. `WeldPluginCaps`).
    caps: WeldPluginCaps = .{},
    /// Lifecycle callbacks (cf. `WeldPluginCallbacks`).
    callbacks: WeldPluginCallbacks = .{},
};

/// Signature du point d'entrée unique exporté par le plugin. Le
/// loader résout `dlsym("weld_plugin_entry")` et appelle cette
/// fonction avec un pointeur opaque vers la `WeldAPI` du runtime
/// (cf. `api.zig` pour le type concret). Comme pour les
/// callbacks, le plugin downcaste `*const anyopaque → *const
/// WeldAPI` à l'entrée.
pub const WeldPluginEntryFn = *const fn (api: *const anyopaque) callconv(.c) *const WeldPluginDesc;
