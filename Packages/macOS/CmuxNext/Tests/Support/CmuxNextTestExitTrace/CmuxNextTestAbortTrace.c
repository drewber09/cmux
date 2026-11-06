// DIAGNOSTIC ONLY (fix/freed-pointer-diag-nomerge, never merged): the Swift runtime's task allocator
// aborts the test helper with "freed pointer was not the last allocation" and no stack on some
// macOS 27 minis. This prints the aborting thread's stack (symbol and image offset per frame) and
// the current Swift task, then re-raises SIGABRT so ReportCrash still writes its .ips report.
#include "CmuxNextTestExitTrace.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern void *swift_task_getCurrent(void) __attribute__((weak_import));
int cmux_next_test_lists_tests(void);

static void put(const char *text) { (void)write(STDERR_FILENO, text, strlen(text)); }

static void abort_trace(int signal) {
    char line[1024];
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    char name[64] = {0};
    pthread_getname_np(pthread_self(), name, sizeof name);
    void *task = swift_task_getCurrent ? swift_task_getCurrent() : NULL;
    snprintf(line, sizeof line, "FREED-POINTER-DIAG: SIGABRT on thread %llu '%s' main=%d, swift task %p; stack:\n",
             (unsigned long long)tid, name, pthread_main_np(), task);
    put(line);
    void *frames[128];
    int count = backtrace(frames, 128);
    for (int index = 0; index < count; index++) {
        Dl_info info;
        memset(&info, 0, sizeof info);
        if (dladdr(frames[index], &info) && info.dli_fname) {
            const char *image = strrchr(info.dli_fname, '/');
            snprintf(line, sizeof line, "FREED-POINTER-DIAG: #%-3d %s +0x%lx  %s + %ld\n", index, image ? image + 1 : info.dli_fname,
                     (unsigned long)((uintptr_t)frames[index] - (uintptr_t)info.dli_fbase),
                     info.dli_sname ? info.dli_sname : "?",
                     info.dli_saddr ? (long)((uintptr_t)frames[index] - (uintptr_t)info.dli_saddr) : 0L);
        } else {
            snprintf(line, sizeof line, "FREED-POINTER-DIAG: #%-3d %p\n", index, frames[index]);
        }
        put(line);
    }
    put("FREED-POINTER-DIAG: end of stack\n");
    raise(signal);
}

__attribute__((constructor)) static void cmux_next_test_abort_trace_install(void) {
    if (cmux_next_test_lists_tests()) return;
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = abort_trace;
    action.sa_flags = SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    sigaction(SIGABRT, &action, NULL);
}
