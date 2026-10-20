/*
The functions of the Internet Computer's System API (the Wasm module "ic0") that this canister
imports, from the interface specification
(https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md):

  ic0.msg_arg_data_size : () -> I
  ic0.msg_arg_data_copy : (dst : I, offset : I, size : I) -> ()
  ic0.msg_reply_data_append : (src : I, size : I) -> ()
  ic0.msg_reply : () -> ()
  ic0.msg_reject : (src : I, size : I) -> ()
  ic0.msg_caller_size : () -> I
  ic0.msg_caller_copy : (dst : I, offset : I, size : I) -> ()
  ic0.msg_reject_code : () -> i32
  ic0.msg_reject_msg_size : () -> I
  ic0.msg_reject_msg_copy : (dst : I, offset : I, size : I) -> ()
  ic0.msg_deadline : () -> i64
  ic0.msg_cycles_refunded128 : (dst : I) -> ()
  ic0.canister_self_size : () -> I
  ic0.canister_self_copy : (dst : I, offset : I, size : I) -> ()
  ic0.canister_liquid_cycle_balance128 : (dst : I) -> ()
  ic0.call_new : (callee_src : I, callee_size : I, name_src : I, name_size : I,
                  reply_fun : I, reply_env : I, reject_fun : I, reject_env : I) -> ()
  ic0.call_on_cleanup : (fun : I, env : I) -> ()
  ic0.call_data_append : (src : I, size : I) -> ()
  ic0.call_with_best_effort_response : (timeout_seconds : i32) -> ()
  ic0.call_cycles_add128 : (amount_high : i64, amount_low : i64) -> ()
  ic0.call_perform : () -> (err_code : i32)
  ic0.cost_call : (method_name_size : i64, payload_size : i64, dst : I) -> ()
  ic0.time : () -> (timestamp : i64)
  ic0.performance_counter : (counter_type : i32) -> (counter : i64)
  ic0.debug_print : (src : I, size : I) -> ()
  ic0.trap : (src : I, size : I) -> ()

I is i32 on wasm32 (and i64 on wasm64), as are pointers and size_t. Calling one of these where
the specification does not allow it, for example msg_reply in canister_init, traps. The 128-bit
values (cycles) are 16 bytes at dst, little-endian: the low 64 bits first. A callback's `fun` is
the index of a function of type (env : I) -> () in the module's function table, which is what a
function pointer is on wasm32 (see ic0.c).
*/
#pragma once
#include <stddef.h>
#include <stdint.h>

#define IC0_IMPORT(name) __attribute__((import_module("ic0"), import_name(#name)))

IC0_IMPORT(msg_arg_data_size) size_t ic0_msg_arg_data_size(void);
IC0_IMPORT(msg_arg_data_copy) void ic0_msg_arg_data_copy(void * dst, size_t offset, size_t size);
IC0_IMPORT(msg_reply_data_append) void ic0_msg_reply_data_append(void const * src, size_t size);
IC0_IMPORT(msg_reply) void ic0_msg_reply(void);
IC0_IMPORT(msg_reject) void ic0_msg_reject(void const * src, size_t size);
IC0_IMPORT(msg_caller_size) size_t ic0_msg_caller_size(void);
IC0_IMPORT(msg_caller_copy) void ic0_msg_caller_copy(void * dst, size_t offset, size_t size);
IC0_IMPORT(msg_reject_code) uint32_t ic0_msg_reject_code(void);
IC0_IMPORT(msg_reject_msg_size) size_t ic0_msg_reject_msg_size(void);
IC0_IMPORT(msg_reject_msg_copy) void ic0_msg_reject_msg_copy(void * dst, size_t offset, size_t size);
IC0_IMPORT(msg_deadline) uint64_t ic0_msg_deadline(void);
IC0_IMPORT(msg_cycles_refunded128) void ic0_msg_cycles_refunded128(void * dst);
IC0_IMPORT(canister_self_size) size_t ic0_canister_self_size(void);
IC0_IMPORT(canister_self_copy) void ic0_canister_self_copy(void * dst, size_t offset, size_t size);
IC0_IMPORT(canister_liquid_cycle_balance128) void ic0_canister_liquid_cycle_balance128(void * dst);
IC0_IMPORT(call_new) void ic0_call_new(void const * callee_src, size_t callee_size,
                                       void const * name_src, size_t name_size,
                                       size_t reply_fun, size_t reply_env,
                                       size_t reject_fun, size_t reject_env);
IC0_IMPORT(call_on_cleanup) void ic0_call_on_cleanup(size_t fun, size_t env);
IC0_IMPORT(call_data_append) void ic0_call_data_append(void const * src, size_t size);
IC0_IMPORT(call_with_best_effort_response) void ic0_call_with_best_effort_response(uint32_t timeout_seconds);
IC0_IMPORT(call_cycles_add128) void ic0_call_cycles_add128(uint64_t amount_high, uint64_t amount_low);
IC0_IMPORT(call_perform) uint32_t ic0_call_perform(void);
IC0_IMPORT(cost_call) void ic0_cost_call(uint64_t method_name_size, uint64_t payload_size, void * dst);
IC0_IMPORT(time) uint64_t ic0_time(void);
IC0_IMPORT(performance_counter) uint64_t ic0_performance_counter(uint32_t counter_type);
IC0_IMPORT(debug_print) void ic0_debug_print(void const * src, size_t size);
IC0_IMPORT(trap) _Noreturn void ic0_trap(void const * src, size_t size);
