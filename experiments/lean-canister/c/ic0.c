/*
The C side of Ic0.lean: its `@[extern]` functions, implemented with the System API (ic0.h), and
the callbacks of the calls to other canisters.

They follow Lean's calling conventions (lean.h). A `BaseIO` function takes no world and returns
its result directly: an object, `lean_box(0)` for `Unit`, or a C scalar for a `UInt32` or a
`UInt64`. An argument that Ic0.lean marks with `@&` is borrowed (b_lean_obj_arg), another is owned
(lean_obj_arg), and a result is owned.

Calls. cistern_ic0_call assembles a call with ic0.call_new, call_on_cleanup, call_data_append,
call_cycles_add128, call_with_best_effort_response and call_perform. The callbacks that the IC
runs with the response are on_response, for a reply and for a reject alike (ic0.msg_reject_code
tells them apart), and on_cleanup, which the IC calls by their indices in the module's function
table: that is what a function pointer is on wasm32 (clang emits the index, and wasm-ld fills
the table, which the IC exports itself when it instruments the module). Their environment, the
`env` that the IC passes back, is the Lean `IO.Promise` that Ic0.lean created for the call: its
address, which does not change, as Lean objects do not move. The IC keeps that reference until a
callback has run. on_response resolves the promise with the response, which queues the Lean
tasks that wait on it (the task manager is cooperative, see canister.c: nothing runs inside
`resolve`), runs the queue with lean_run_pending_tasks, which is the rest of the handler up to
its reply or its next call, and then releases the promise. on_cleanup runs instead if
on_response trapped, on the memory as it was before: it discards the promise with
lean_io_promise_discard, which frees what waits on it without running or queuing it (resolving
or releasing the promise would queue it, for the next message that runs the queue, where it
could neither reply nor call), and releases it. It runs no Lean code, and does not run the
queue: that is empty between messages, as every entry point and callback runs it before
returning.
*/
#include <inttypes.h>
#include <stdio.h>
#include <lean/lean.h>
#include "canister.h"
#include "ic0.h"
#include "wasi.h"

/* `IO.Promise.resolve`, which lean.h does not declare: the value is owned, the promise borrowed,
   and the result is `lean_box(0)`. */
lean_object * lean_io_promise_resolve(lean_object * value, lean_object * promise);

/* Ic0.lean's `Response.make`: a `Response` of the reject code, 0 for a reply, and the reply or
   the reject message, so that this file need not know the structure's layout. */
lean_object * cistern_ic0_mk_response(uint32_t code, lean_object * data);

/* The bytes that a pair of System API functions gives: their size, and a copy. */
static lean_object * bytes(size_t size, void (*copy)(void *, size_t, size_t)) {
    lean_object * data = lean_alloc_sarray(1, size, size);
    copy(lean_sarray_cptr(data), 0, size);
    return data;
}

LEAN_EXPORT lean_obj_res cistern_ic0_msg_arg_data(void) {
    return bytes(ic0_msg_arg_data_size(), ic0_msg_arg_data_copy);
}

LEAN_EXPORT lean_obj_res cistern_ic0_msg_reply_data_append(b_lean_obj_arg data) {
    ic0_msg_reply_data_append(lean_sarray_cptr(data), lean_sarray_size(data));
    return lean_box(0);
}

LEAN_EXPORT lean_obj_res cistern_ic0_msg_reply(void) {
    ic0_msg_reply();
    return lean_box(0);
}

LEAN_EXPORT lean_obj_res cistern_ic0_msg_reject(b_lean_obj_arg message) {
    // lean_string_size counts the terminating NUL.
    ic0_msg_reject(lean_string_cstr(message), lean_string_size(message) - 1);
    return lean_box(0);
}

LEAN_EXPORT lean_obj_res cistern_ic0_canister_self(void) {
    return bytes(ic0_canister_self_size(), ic0_canister_self_copy);
}

LEAN_EXPORT lean_obj_res cistern_ic0_msg_caller(void) {
    return bytes(ic0_msg_caller_size(), ic0_msg_caller_copy);
}

LEAN_EXPORT uint64_t cistern_ic0_msg_deadline(void) {
    return ic0_msg_deadline();
}

/* (high, low) : UInt64 × UInt64 of a 128-bit value that the System API wrote at `value`,
   little-endian. Prod's fields are polymorphic, so they are boxed. */
static lean_object * pair_of_u128(uint64_t const value[2]) {
    lean_object * pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, lean_box_uint64(value[1]));
    lean_ctor_set(pair, 1, lean_box_uint64(value[0]));
    return pair;
}

LEAN_EXPORT lean_obj_res cistern_ic0_cost_call(uint64_t method_name_size, uint64_t payload_size) {
    uint64_t value[2];
    ic0_cost_call(method_name_size, payload_size, value);
    return pair_of_u128(value);
}

LEAN_EXPORT lean_obj_res cistern_ic0_canister_liquid_cycle_balance128(void) {
    uint64_t value[2];
    ic0_canister_liquid_cycle_balance128(value);
    return pair_of_u128(value);
}

LEAN_EXPORT lean_obj_res cistern_ic0_msg_cycles_refunded128(void) {
    uint64_t value[2];
    ic0_msg_cycles_refunded128(value);
    return pair_of_u128(value);
}

LEAN_EXPORT lean_obj_res cistern_ic0_count_instructions(lean_obj_arg f, b_lean_obj_arg a) {
    lean_inc(a); // f consumes its argument, and a stays the caller's
    uint64_t before = ic0_performance_counter(0);
    lean_object * b = lean_apply_1(f, a);
    uint64_t after = ic0_performance_counter(0);
    // (b, after - before) : β × UInt64. Prod's fields are polymorphic, so the UInt64 is boxed.
    lean_object * result = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(result, 0, b);
    lean_ctor_set(result, 1, lean_box_uint64(after - before));
    return result;
}

/* Calls */

/* The calls made (ic0.call_perform returned 0) whose callback has not run yet. canister.c refuses
   an upgrade while there are some. */
static uint32_t g_outstanding;

LEAN_EXPORT uint32_t cistern_ic0_outstanding_calls(void) {
    return g_outstanding;
}

/* The reply and reject callback: resolves the call's promise, `env`, with the response, runs
   what waits on it (see above), and ends like an entry point (canister.c), with the
   instructions of the whole call context (ic0.performance_counter(1)) among the details. */
static void on_response(uint32_t env) {
    unsigned long time_calls = wasi_ic0_time_calls;
    lean_object * promise = (lean_object *)(uintptr_t)env;
    uint32_t code = ic0_msg_reject_code();
    lean_object * data = code == 0 ? bytes(ic0_msg_arg_data_size(), ic0_msg_arg_data_copy)
                                   : bytes(ic0_msg_reject_msg_size(), ic0_msg_reject_msg_copy);
    lean_dec(lean_io_promise_resolve(cistern_ic0_mk_response(code, data), promise));
    // The handler's continuation, which resolving queued: the rest of it, its reply or next call.
    lean_run_pending_tasks();
    lean_dec(promise);
    g_outstanding--;
    char details[96];
    snprintf(details, sizeof details, " (call context %" PRIu64 ", outstanding calls %" PRIu32 ")",
             ic0_performance_counter(1), g_outstanding);
    canister_finish(code == 0 ? "reply callback" : "reject callback", time_calls, details);
}

/* The cleanup callback: on_response trapped, and the IC discarded what it changed, so the
   promise is as it was before, unresolved, with the handler's continuation waiting on it. Only a
   few System API functions may be called here, among them ic0.debug_print and
   ic0.performance_counter, so the continuation is discarded, with lean_io_promise_discard, which
   runs no Lean code; the queue is not run (see above). */
static void on_cleanup(uint32_t env) {
    unsigned long time_calls = wasi_ic0_time_calls;
    lean_object * promise = (lean_object *)(uintptr_t)env;
    lean_dec(lean_io_promise_discard(promise));
    lean_dec(promise);
    g_outstanding--;
    char details[64];
    snprintf(details, sizeof details, " (outstanding calls %" PRIu32 ")", g_outstanding);
    canister_finish("cleanup callback", time_calls, details);
}

/* What follows ic0.call_new: the argument, the cycles if there are any, the timeout if there is
   one (`some seconds`, an `Option UInt32`), and ic0.call_perform, whose code this returns. */
static uint32_t perform(b_lean_obj_arg arg, uint64_t cycles_high, uint64_t cycles_low,
                        b_lean_obj_arg timeout) {
    if (lean_sarray_size(arg) > 0) ic0_call_data_append(lean_sarray_cptr(arg), lean_sarray_size(arg));
    if (cycles_high != 0 || cycles_low != 0) ic0_call_cycles_add128(cycles_high, cycles_low);
    if (!lean_is_scalar(timeout)) {
        ic0_call_with_best_effort_response(lean_unbox_uint32(lean_ctor_get(timeout, 0)));
    }
    return ic0_call_perform();
}

LEAN_EXPORT uint32_t cistern_ic0_call(b_lean_obj_arg callee, b_lean_obj_arg method,
                                      b_lean_obj_arg arg, uint64_t cycles_high, uint64_t cycles_low,
                                      b_lean_obj_arg timeout, lean_obj_arg promise) {
    size_t env = (size_t)(uintptr_t)promise;
    size_t response = (size_t)(uintptr_t)on_response;
    ic0_call_new(lean_sarray_cptr(callee), lean_sarray_size(callee),
                 lean_string_cstr(method), lean_string_size(method) - 1,
                 response, env, response, env);
    ic0_call_on_cleanup((size_t)(uintptr_t)on_cleanup, env);
    uint32_t code = perform(arg, cycles_high, cycles_low, timeout);
    if (code == 0) {
        g_outstanding++; // the IC holds the promise, through env, until a callback has run
    } else {
        lean_dec(promise); // no callback will run
    }
    return code;
}

/* An index that the function table does not have, for a call whose response is to be dropped:
   the IC traps, harmlessly, where it would run the callback, as it does for ic_cdk's one-way
   calls. */
#define NO_CALLBACK ((size_t)-1)

LEAN_EXPORT uint32_t cistern_ic0_call_oneway(b_lean_obj_arg callee, b_lean_obj_arg method,
                                             b_lean_obj_arg arg, uint64_t cycles_high,
                                             uint64_t cycles_low, b_lean_obj_arg timeout) {
    ic0_call_new(lean_sarray_cptr(callee), lean_sarray_size(callee),
                 lean_string_cstr(method), lean_string_size(method) - 1,
                 NO_CALLBACK, NO_CALLBACK, NO_CALLBACK, NO_CALLBACK);
    return perform(arg, cycles_high, cycles_low, timeout);
}
