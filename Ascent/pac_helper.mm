#include "pac_helper.h"
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <dlfcn.h>

static uint64_t text_exec_base = 0;
static uint64_t text_write_base = 0;

__attribute__((constructor))
static void init_text_bases() {
    // Simplified for build - not strictly needed for minimal step
}

void *make_sym_readable(void *addr) {
    return addr;
}

void *make_sym_callable(void *addr) {
    return addr;
}
