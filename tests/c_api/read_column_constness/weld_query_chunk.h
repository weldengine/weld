/* The C mirror of `WeldQueryChunk` (engine-c-api.md 5.5).
 *
 * Hand-written, because the unified binding generator that is meant to emit
 * `weld_api.h` does not exist in this tree yet. What keeps it from drifting
 * away from `src/core/plugin_loader/api.zig` is the static assertions at the
 * bottom of this file, mirrored member for member by a Zig test that pins the
 * same offsets on the other side. Two independent pins on one layout: either
 * declaration moving alone turns one of them red.
 *
 * The point of the file is the CONSTNESS. A component declared read is reached
 * through `const void* const*`; taking a `void*` to it discards a qualifier and
 * the plugin author's own compiler refuses the program. That is what carries
 * ARCH-030 across a boundary where no comptime view exists. */

#ifndef WELD_QUERY_CHUNK_H
#define WELD_QUERY_CHUNK_H

#include <stdint.h>
#include <stddef.h>

typedef uint64_t WeldEntity;

typedef struct {
    uint32_t            struct_size;
    uint32_t            count;
    const WeldEntity*   entities;

    /* reads[i] : the i-th component declared READ at query_create.
     * Doubly const: the slot is not assignable, and the data behind it is not
     * writable. Either qualifier alone leaves half the hole open. */
    const void* const*  reads;
    uint32_t            read_count;
    /* writes[i] : the i-th component declared WRITE. The slot is const, the
     * data is not. */
    void* const*        writes;
    uint32_t            write_count;

    const uint32_t*     read_sizes;
    const uint32_t*     write_sizes;
} WeldQueryChunk;

/* THE DRIFT PIN. Written in terms of `sizeof` rather than as literals so the
 * file says the same thing on a 32-bit target, and mirrored by
 * `tests/c_api/chunk_layout_test.zig` on the Zig side. */
_Static_assert(offsetof(WeldQueryChunk, struct_size) == 0,
               "struct_size must lead the struct (ARCH-018)");
_Static_assert(offsetof(WeldQueryChunk, count) == sizeof(uint32_t),
               "count follows struct_size");
_Static_assert(offsetof(WeldQueryChunk, entities) == sizeof(void*),
               "entities is the first pointer-aligned member");
_Static_assert(offsetof(WeldQueryChunk, reads) == 2 * sizeof(void*),
               "the read index space follows entities");
_Static_assert(offsetof(WeldQueryChunk, writes) == 4 * sizeof(void*),
               "the write index space follows the read one and its count");
_Static_assert(sizeof(WeldQueryChunk) == 8 * sizeof(void*),
               "eight pointer-sized slots: the two counts pack beside their pointers");

#endif /* WELD_QUERY_CHUNK_H */
