// Swift concurrency executor for iOS: every job runs on the main queue.
//
// Replaces Embedded Swift's default cooperative executor, whose drain loop
// would never return to UIKit's run loop. Running everything on the main
// thread also matches the Embedded concurrency runtime, which assumes a
// single thread.
//
// Unlike Backend.m, this file is compiled for the bare-metal armv7 target,
// like the Swift runtime that calls it: the hooks use the Swift calling
// convention and pass executor references by value. It only calls into iOS
// through SwiftUIBackend.h, with pointers and `unsigned long`.

#include <stdbool.h>
#include <stdint.h>
#include "SwiftUIBackend.h"

// From the toolchain's swift/ExecutorImpl.h, which needs a C library.
typedef struct SwiftJob SwiftJob;
typedef struct SwiftHeapObject SwiftHeapObject;
typedef struct {
    SwiftHeapObject *identity;
    uintptr_t implementation;
} SwiftExecutorRef;
typedef unsigned long long SwiftJobDelay;

#define SWIFT_CC_SWIFT __attribute__((swiftcall))

extern void _swift_job_run_c(SwiftJob *job, SwiftExecutorRef executor);
extern bool _swift_task_invokeSwiftCheckIsolated_c(SwiftExecutorRef executor);
extern int8_t _swift_task_invokeSwiftIsIsolatingCurrentContext_c(SwiftExecutorRef executor);

static const SwiftExecutorRef SUIGenericExecutor = { 0, 0 };

static void SUIRunJob(void *job) {
    _swift_job_run_c((SwiftJob *)job, SUIGenericExecutor);
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalImpl(SwiftJob *job) {
    sui_dispatch_main(SUIRunJob, job);
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalWithDelayImpl(SwiftJobDelay delay, SwiftJob *job) {
    // Nanoseconds, rounded up to whole milliseconds.
    unsigned long long milliseconds = (delay + 999999) / 1000000;
    sui_dispatch_main_after(milliseconds > 0xFFFFFFFFull ? 0xFFFFFFFFul : (unsigned long)milliseconds, SUIRunJob, job);
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalWithDeadlineImpl(long long sec, long long nsec,
                                                             long long tsec, long long tnsec,
                                                             int clock, SwiftJob *job) {
    // Deadlines come from clocks, which Embedded Swift doesn't have yet.
    sui_dispatch_main(SUIRunJob, job);
}

SWIFT_CC_SWIFT void swift_task_enqueueMainExecutorImpl(SwiftJob *job) {
    sui_dispatch_main(SUIRunJob, job);
}

SWIFT_CC_SWIFT void swift_task_checkIsolatedImpl(SwiftExecutorRef executor) {
    _swift_task_invokeSwiftCheckIsolated_c(executor);
}

SWIFT_CC_SWIFT int8_t swift_task_isIsolatingCurrentContextImpl(SwiftExecutorRef executor) {
    return _swift_task_invokeSwiftIsIsolatingCurrentContext_c(executor);
}

// The global executor is the main queue, so they share the generic executor.
SWIFT_CC_SWIFT SwiftExecutorRef swift_task_getMainExecutorImpl(void) {
    return SUIGenericExecutor;
}

SWIFT_CC_SWIFT bool swift_task_isMainExecutorImpl(SwiftExecutorRef executor) {
    return executor.identity == 0;
}

// An async `main` would drain this queue, but `App.main()` runs UIKit's run
// loop instead, and nothing may block the main thread waiting for a task.
__attribute__((noreturn)) SWIFT_CC_SWIFT void swift_task_asyncMainDrainQueueImpl(void) {
    __builtin_trap();
}

SWIFT_CC_SWIFT void swift_task_donateThreadToGlobalExecutorUntilImpl(bool (*condition)(void *), void *context) {
    __builtin_trap();
}
