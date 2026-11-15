#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// -1 when no lifted code is linked into this build.
int bt3_lifted_function_count(void);
unsigned int bt3_lifted_text_base(void);
#ifdef __cplusplus
}
#endif
