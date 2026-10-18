/*
The functions of the WASI shim (wasi.c) for the canister's entry points.
*/
#pragma once

/* Prints, with ic0.debug_print, what stdout and stderr have written since their last newline.
   Also forgets the last line of stderr (see wasi_ic0_trap): call it at the end of a message. */
void wasi_ic0_flush(void);

/* Prints what stdout and stderr have written since their last newline. Then traps, with `what`
   and the start of the last line that stderr printed since wasi_ic0_flush and that is not
   empty, if there is one. */
_Noreturn void wasi_ic0_trap(char const * what);

/* How often clock_time_get has called ic0.time. */
extern unsigned long wasi_ic0_time_calls;
