// Keeps the lifted runtime's C++ headers (u8/u32 typedefs etc.) out of the Objective-C++ shell.
#include "BT3Bridge.h"

#if __has_include("bt3_funcs.h") && __has_include("ee_runtime.h")
#include "bt3_funcs.h"
int bt3_lifted_function_count(void) {
    ee_register_functions();                       // only fills the dispatch table; runs no guest code
    int n = 0;
    for (u32 i = 0; i < ee_text_words; i++) if (ee_ftab[i]) n++;
    return n;
}
unsigned int bt3_lifted_text_base(void) { return ee_text_base; }
#else
int bt3_lifted_function_count(void) { return -1; }
unsigned int bt3_lifted_text_base(void) { return 0; }
#endif
