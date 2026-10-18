/*
The functions of the Internet Computer's System API (the Wasm module "ic0") that this canister
imports, from the interface specification
(https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md):

  ic0.msg_arg_data_size : () -> I
  ic0.msg_arg_data_copy : (dst : I, offset : I, size : I) -> ()
  ic0.msg_reply_data_append : (src : I, size : I) -> ()
  ic0.msg_reply : () -> ()
  ic0.msg_reject : (src : I, size : I) -> ()
  ic0.time : () -> (timestamp : i64)
  ic0.performance_counter : (counter_type : i32) -> (counter : i64)
  ic0.debug_print : (src : I, size : I) -> ()
  ic0.trap : (src : I, size : I) -> ()

I is i32 on wasm32 (and i64 on wasm64), as are pointers and size_t. Calling one of these where
the specification does not allow it, for example msg_reply in canister_init, traps.
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
IC0_IMPORT(time) uint64_t ic0_time(void);
IC0_IMPORT(performance_counter) uint64_t ic0_performance_counter(uint32_t counter_type);
IC0_IMPORT(debug_print) void ic0_debug_print(void const * src, size_t size);
IC0_IMPORT(trap) _Noreturn void ic0_trap(void const * src, size_t size);
