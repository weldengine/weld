//! S5 codegen error set per `briefs/S5-etch-codegen-zig.md` Scope —
//! "Codegen surface published as `weld_etch.codegen_zig` with a stable entry
//! point ... plus minimal error type `CodegenError` covering
//! `UnsupportedConstruct`, `NonPodComponent`, `InternalCodegenBug`".
//!
//! The codegen is fed an AST that has already passed the S3 two-pass type-
//! checker, so structural and POD violations should never reach this layer.
//! They are listed for completeness — the codegen surfaces them as errors
//! rather than panicking so a malformed AST cannot crash the caller.

const std = @import("std");

/// Closed error set surfaced by the Etch → Zig codegen. Each variant
/// names a precise failure mode reachable from the lowering pass.
pub const CodegenError = error{
    /// A construct outside the S5 subset (`component`, `resource`, `rule`,
    /// `when`, arithmetic expressions, `get`/`get_mut`/`has` accessors)
    /// reached the lowering pass. Should be impossible after S3 type-check,
    /// but reported here as a typed error rather than a panic.
    UnsupportedConstruct,
    /// A component declaration contains a non-POD field type. The S3
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
