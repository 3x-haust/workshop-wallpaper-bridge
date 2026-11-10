// SPDX-License-Identifier: GPL-2.0-only
#include <fcntl.h>
#include <sys/types.h>

// Darwin arm64 puts variadic arguments on the stack. Expose fixed signatures
// rather than invoking open/openat's variadic mode argument through P/Invoke.
int wwb_open(const char *path, int flags, int mode) {
    return open(path, flags, (mode_t)mode);
}
int wwb_openat(int directory, const char *path, int flags, int mode) {
    return openat(directory, path, flags, (mode_t)mode);
}
