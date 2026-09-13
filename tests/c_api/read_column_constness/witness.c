/* The compilation witness of engine-c-api.md 5.5.
 *
 * As published it compiles. Built with -DWELD_ASSIGN_THROUGH_READ_COLUMN it
 * must NOT: the one line that changes takes a mutable pointer to a column the
 * query declared read-only, which discards a qualifier.
 *
 * The two halves live in one file on purpose. A separate "bad" file could drift
 * from the good one until the refusal it demonstrates is no longer the refusal
 * the good one relies on; here the only difference is the line under the
 * macro. */

#include "weld_query_chunk.h"

typedef struct { float x, y, z; } WeldVec3;

/* A plugin's query callback: read the velocities, write the positions.
 * Velocity was declared READ and Transform WRITE at query_create, so they are
 * reached through their own index spaces. */
void weld_witness_move_system(const WeldQueryChunk* chunk, void* user_data)
{
    const float dt = *(const float*)user_data;

    /* The READ column. `const void*` initialises a `const WeldVec3*` with no
     * cast and no diagnostic — this is the shape a correct plugin writes. */
    const WeldVec3* velocities = chunk->reads[0];

    /* The WRITE column. `void* const*` yields a `void*`, which initialises a
     * mutable `WeldVec3*`. */
    WeldVec3* positions = chunk->writes[0];

#ifdef WELD_ASSIGN_THROUGH_READ_COLUMN
    /* THE COUNTER-PROOF, one line. Taking a mutable pointer to a read column
     * discards `const`: a constraint violation the compiler reports, and an
     * error under -Werror. Nothing about the author's discipline is involved. */
    WeldVec3* writable_velocities = chunk->reads[0];
    writable_velocities[0].x = 0.0f;
#endif

    for (uint32_t i = 0; i < chunk->count; i++) {
        positions[i].x += velocities[i].x * dt;
        positions[i].y += velocities[i].y * dt;
        positions[i].z += velocities[i].z * dt;
    }
}
