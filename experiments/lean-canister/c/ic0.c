/*
The C side of Ic0.lean: its `@[extern]` functions, implemented with the System API (ic0.h).

They follow Lean's calling conventions (lean.h). A `BaseIO` function takes no world and returns
its result directly, `lean_box(0)` for `Unit`. An argument that Ic0.lean marks with `@&` is
borrowed (b_lean_obj_arg), another is owned (lean_obj_arg), and a result is owned.
*/
#include <lean/lean.h>
#include "ic0.h"

LEAN_EXPORT lean_obj_res cistern_ic0_msg_arg_data(void) {
    size_t size = ic0_msg_arg_data_size();
    lean_object * data = lean_alloc_sarray(1, size, size);
    ic0_msg_arg_data_copy(lean_sarray_cptr(data), 0, size);
    return data;
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
