const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-2 error
/// vertical end-to-end — the builtin `Error { message, code, source }` +
/// `ErrorCode` (part1 §10.2), the flag+branch try/catch desugar, and the
/// `throws`-fn out-param propagation:
///
/// - `direct_throw` throws an `Error` with an INTERPOLATED message inside a
///   `try` (the throw sets the in-flight Error at the same logical point as
///   the interpreter's `thrown` signal); the catch matches `err.code`
///   (qualified enum patterns) into `caught_code` and reads
///   `err.message.len()` into `msg_len`.
/// - `fn_throw` calls `risky(2)` (returns 20, assigned to `ok_val`) then
///   `risky(5)` (throws `invalid_arg` ACROSS the fn boundary — interp: the
///   `thrown` signal crosses `callFn`; codegen: the hidden `__err` out-param
///   + post-call check). The second assignment never runs; the catch maps
///   the code into `fn_code`.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `Acc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc" },
        } },
    },
};

/// After 1 tick: `caught_code == 7` (network_timeout arm), `msg_len == 10`
/// ("limit is 3"), `fn_code == 9` (invalid_arg arm), `ok_val == 20` (the
/// pre-throw `risky(2)` result; `risky(5)`'s binding never lands) —
/// identical in both backends.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Acc", .fields = &[_]driver.FieldSpec{
                .{ .name = "caught_code", .value = .{ .int_ = 7 } },
                .{ .name = "msg_len", .value = .{ .int_ = 10 } },
                .{ .name = "fn_code", .value = .{ .int_ = 9 } },
                .{ .name = "ok_val", .value = .{ .int_ = 20 } },
            } },
        } },
    },
};
