//! Fixture — `named_types` indexed by a type node's data outside `ast.zig`. Rule
//! `no_raw_named_type_read` must fire: a non-`.named` node's data indexes
//! another slab.

/// The name of a type node, read the way the rule forbids.
pub fn nameOf(ast: anytype, node: anytype) u32 {
    return ast.named_types.items[ast.typeNodeData(node)].name;
}
