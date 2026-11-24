// glibc needs _LARGEFILE64_SOURCE for miniz's 64-bit file functions (fopen64 and so on). Darwin
// has none of them: its fopen/ftello/stat are already 64-bit, miniz's default branch.
#if !defined(__APPLE__)
#define _LARGEFILE64_SOURCE 1
#endif
#include <stdlib.h>
#include <string.h>
#include "miniz.h"
