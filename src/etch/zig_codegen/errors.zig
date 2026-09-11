//! Codegen error set: the closed `CodegenError` covering
//! `UnsupportedConstruct`, `SparseStorageUnsupported`, `NonPodComponent` and
//! `InternalCodegenBug`.
//!
//! The codegen is fed an AST that has already passed the two-pass type-
//! checker, so structural and POD violations should never reach this layer.
//! They are listed for completeness — the codegen surfaces them as errors
//! rather than panicking so a malformed AST cannot crash the caller.

const std = @import("std");

/// Closed error set surfaced by the Etch → Zig codegen. Each variant
/// names a precise failure mode reachable from the lowering pass.
pub const CodegenError = error{
    /// A construct the lowering pass does not emit. The emitted subset is wider
    /// than a top-level list suggests — `component`, `resource`, `event`,
    /// `struct`, `enum`, top-level `fn`, `rule`/`when`, arithmetic expressions
    /// and the `get`/`get_mut`/`has` accessors — and this error is raised from
    /// INSIDE those emitters for the shapes they decline (a generic enum, a
    /// data-carrying variant, an impl method), so do not read it as "the
    /// declaration kind is unknown". Unreachable after a type-check, but
    /// reported here as a typed error rather than a panic.
    UnsupportedConstruct,
    /// A `component` declaration carries `@storage(.sparse)`.
    ///
    /// **Refused rather than served, and the alternative is a SILENT TABLE
    /// FALLBACK.** The emitted `comptime_query` resolves a component through
    /// cached per-archetype column offsets, so it can only see a table-stored
    /// one, and the emitted `register()` records no storage mode — a sparse
    /// declaration reaching it is registered `table`, giving a program whose
    /// ECS image contradicts its own source with nothing to say so. Parity is
    /// unimplemented.
    SparseStorageUnsupported,
    /// A component declaration contains a non-POD field type. The
    /// type-checker rejects these — the variant exists so a malformed AST
    /// (e.g. a future caller forgetting to type-check) surfaces a clean
    /// error instead of `@panic`.
    NonPodComponent,
    /// Internal invariant violated: an emitter received malformed inputs
    /// (e.g. a `field_access` whose receiver category is invalid). Indicates
    /// a bug in the codegen itself; the caller should report and abort.
    InternalCodegenBug,
    /// I/O failure while writing a generated file.
    Io,
    /// Memory allocation failure.
    OutOfMemory,
};

test "CodegenError variants compile and are addressable" {
    const v: CodegenError = CodegenError.UnsupportedConstruct;
    try std.testing.expectEqual(CodegenError.UnsupportedConstruct, v);
}
