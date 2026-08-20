//! Inventory root for `zig build forge-asm-inventory`.
//!
//! `forge_3d/root.zig` is a re-export file: it declares types and constants and
//! almost no function bodies of its own. Zig is lazy, so compiling it directly
//! to an object emits nothing at all — measured, and caught by the scanner's
//! own non-vacuity guard, which reported `0 call sites examined` on all three
//! targets before this file existed. An empty listing that "contains no libm
//! call" is the exact shape of a harness reporting success without measuring
//! anything.
//!
//! This root forces the module's whole public surface into codegen, by taking
//! the ADDRESS of every public function reachable from `forge_3d`'s root
//! namespace, transitively through its public type declarations. Referencing a
//! function pointer defeats laziness; `export`ing the collector defeats
//! dead-code elimination.
//!
//! **Why reflection and not a hand-written list.** A list of entry points is a
//! list that drifts: the milestone that adds the next query entry, or the next
//! pipeline pass, has to remember to extend it, and forgetting produces a
//! GREEN inventory over a smaller surface — a false negative that looks exactly
//! like a pass. Reflection cannot forget. What it can do is silently cover less
//! than one thinks, which is why the scanner reports the number of call sites it
//! examined on every run and refuses a run that examined none.

const std = @import("std");
const forge_3d = @import("forge_3d");

/// Where the collected function addresses land.
///
/// A mutable global that the exported anchor RETURNS. Both halves are needed
/// and were arrived at by measurement: the first attempt wrote `_ = &f`, which
/// forces the function to be ANALYSED but not EMITTED — the resulting listing
/// carried 37 000 lines of debug records, one emitted function (the anchor) and
/// ZERO call instructions, which the scanner refused as vacuous. Summing the
/// addresses at RUNTIME, into a global whose value escapes through a return, is
/// what makes each address load a real reference to a real symbol.
var address_sink: usize = 0;

/// Recursively take the address of every public function in `T` and in its
/// public struct/union/enum declarations.
///
/// `depth` bounds the walk: the namespace graph has cycles (a type re-exported
/// by two namespaces, a package root that re-exports a sibling), and without a
/// bound the walk would not terminate. Eight is far past the module's actual
/// nesting — root → package → file → type → nested type is four.
///
/// GENERIC functions are skipped rather than instantiated: `&f` on a function
/// with a `comptime` or `anytype` parameter has no address to take, and picking
/// arguments for it here would be inventing a call the engine never makes. The
/// generic pipeline of `forge_3d` is reached anyway, through the `Real`-bound
/// aliases the root re-exports — which is the instantiation the engine actually
/// ships, and therefore the one worth inventorying.
fn referenceAll(comptime T: type, comptime depth: u8) void {
    if (depth == 0) return;
    const info = @typeInfo(T);
    const decls = switch (info) {
        .@"struct" => |s| s.decls,
        .@"union" => |u| u.decls,
        .@"enum" => |e| e.decls,
        .@"opaque" => |o| o.decls,
        else => return,
    };
    inline for (decls) |decl| {
        const field = @field(T, decl.name);
        const FieldType = @TypeOf(field);
        if (FieldType == type) {
            switch (@typeInfo(field)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => referenceAll(field, depth - 1),
                else => {},
            }
        } else if (@typeInfo(FieldType) == .@"fn") {
            // A generic function has no runtime address; skip it rather than
            // fail to compile, and say so in the doc comment above rather than
            // leave a reader to infer it from a `catch`-shaped silence.
            if (!@typeInfo(FieldType).@"fn".is_generic) {
                address_sink +%= @intFromPtr(&@field(T, decl.name));
            }
        }
    }
}

/// The object's single exported symbol, and the reason anything is emitted at
/// all: it walks the surface at runtime, so every address it takes is a
/// reference the backend must satisfy, and it returns the accumulator so the
/// whole walk cannot be proved dead.
export fn weld_forge_3d_asm_inventory_anchor() usize {
    referenceAll(forge_3d, 8);
    return address_sink;
}
