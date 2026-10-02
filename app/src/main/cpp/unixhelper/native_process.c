#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <android/log.h>

#define TAG "NativeProcess"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static int set_cloexec(int fd, int cloexec) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    if (cloexec)
        flags |= FD_CLOEXEC;
    else
        flags &= ~FD_CLOEXEC;
    return fcntl(fd, F_SETFD, flags);
}

#ifndef __NR_close_range
#define __NR_close_range 436
#endif
#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif

/*
 * Mark every fd >= min_fd close-on-exec instead of closing it. The child is a
 * fork of a multithreaded ART process: its fd table is full of descriptors
 * owned by the runtime (binder, ashmem, ParcelFileDescriptors, ...), and
 * calling close() on them -- bionic's close(), which fdsan checks against each
 * fd's owner tag -- is exactly what must not happen between fork() and exec().
 * Flagging them costs no close() at all; the kernel drops them inside execve.
 * Returns 0 for close_range(), else the upper bound of the fcntl() fallback
 * (kernels before 5.11).
 */
static long mark_fds_cloexec_from(int min_fd) {
    if (syscall(__NR_close_range, (unsigned int) min_fd, ~0U,
                CLOSE_RANGE_CLOEXEC) == 0)
        return 0;
    struct rlimit rl;
    long max_fd = 1024;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY)
        max_fd = (long) rl.rlim_cur;
    for (long fd = min_fd; fd < max_fd; fd++)
        fcntl((int) fd, F_SETFD, FD_CLOEXEC);
    return max_fd;
}

/*
 * Child-side breadcrumbs for nativeForkExec. Between fork() and execve() the
 * child is a copy of a multithreaded ART process, so only async-signal-safe
 * calls are allowed: no malloc, no stdio, no __android_log_print. Each line is
 * built on the stack and handed to a single write(), so it lands whole in the
 * child's stderr pipe -- the stream the app already captures for the process.
 */
#define CRUMB_PREFIX "[nativeForkExec child] "

static size_t crumb_append(char *buf, size_t pos, size_t cap, const char *s) {
    while (*s && pos < cap) buf[pos++] = *s++;
    return pos;
}

static size_t crumb_append_int(char *buf, size_t pos, size_t cap, long v) {
    char tmp[24];
    size_t n = 0;
    unsigned long u = v < 0 ? (unsigned long) -v : (unsigned long) v;
    do {
        tmp[n++] = (char) ('0' + u % 10);
        u /= 10;
    } while (u && n < sizeof(tmp));
    if (v < 0 && pos < cap) buf[pos++] = '-';
    while (n && pos < cap) buf[pos++] = tmp[--n];
    return pos;
}

/*
 * "<prefix><msg>[<num>]\n"; pass has_num = 0 to leave the number out. Written to
 * fd (the child's stderr pipe) and, when trace_fd >= 0, also to the append-only
 * trace file -- one write() each, so a line lands whole in both.
 */
static void crumb(int fd, int trace_fd, const char *msg, int has_num, long num) {
    char buf[256];
    size_t cap = sizeof(buf) - 1, pos = 0;
    pos = crumb_append(buf, pos, cap, CRUMB_PREFIX);
    pos = crumb_append(buf, pos, cap, msg);
    if (has_num) pos = crumb_append_int(buf, pos, cap, num);
    buf[pos++] = '\n';
    ssize_t r = write(fd, buf, pos);
    if (trace_fd >= 0) r = write(trace_fd, buf, pos);
    (void) r;
}

/*
 * Second sink for the breadcrumbs: the app only shows a process's stderr once a
 * VM gets far enough, so a child that dies before then leaves nothing visible.
 * This file is appended to, never truncated, so repeated attempts accumulate:
 * <dir>/forkexec-trace.log when a working directory is given, else the path
 * below (the app's run directory, where the VM sockets also live).
 */
#define FORKEXEC_TRACE_NAME "forkexec-trace.log"
#define FORKEXEC_TRACE_FALLBACK "/data/data/cn.classfun.droidvm/run/" FORKEXEC_TRACE_NAME

/* Parent side, before fork(): O_CLOEXEC so it never reaches the exec'd program. */
static int open_forkexec_trace(const char *dir) {
    char path[4096];
    if (dir && *dir)
        snprintf(path, sizeof(path), "%s/%s", dir, FORKEXEC_TRACE_NAME);
    else
        snprintf(path, sizeof(path), "%s", FORKEXEC_TRACE_FALLBACK);
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        LOGW("forkexec trace: open(%s) failed: %s", path, strerror(errno));
    return fd;
}

#define JNI_PREFIX(name) \
    Java_cn_classfun_droidvm_lib_natives_NativeProcess_##name

JNIEXPORT jintArray JNICALL
JNI_PREFIX(nativeForkExec)(
    JNIEnv *env, jclass clazz,
    jobjectArray jargv,
    jobjectArray jenvp,
    jstring jdir,
    jintArray jpreserveFds,
    jlongArray jrlimits
) {
    (void) clazz;
    int argc = (*env)->GetArrayLength(env, jargv);
    if (argc <= 0) {
        LOGE("argv is empty");
        return NULL;
    }
    char **argv = calloc(argc + 1, sizeof(char *));
    if (!argv) return NULL;
    for (int i = 0; i < argc; i++) {
        jstring js = (*env)->GetObjectArrayElement(env, jargv, i);
        const char *s = (*env)->GetStringUTFChars(env, js, NULL);
        argv[i] = strdup(s);
        (*env)->ReleaseStringUTFChars(env, js, s);
        (*env)->DeleteLocalRef(env, js);
    }
    argv[argc] = NULL;
    char **envp = NULL;
    int envc = 0;
    if (jenvp) {
        envc = (*env)->GetArrayLength(env, jenvp);
        envp = calloc(envc + 1, sizeof(char *));
        if (!envp) {
            for (int i = 0; i < argc; i++) free(argv[i]);
            free(argv);
            return NULL;
        }
        for (int i = 0; i < envc; i++) {
            jstring js = (*env)->GetObjectArrayElement(env, jenvp, i);
            const char *s = (*env)->GetStringUTFChars(env, js, NULL);
            envp[i] = strdup(s);
            (*env)->ReleaseStringUTFChars(env, js, s);
            (*env)->DeleteLocalRef(env, js);
        }
        envp[envc] = NULL;
    }
    const char *dir_cstr = NULL;
    if (jdir) dir_cstr = (*env)->GetStringUTFChars(env, jdir, NULL);
    int preserve_count = 0;
    jint *preserve_raw = NULL;
    if (jpreserveFds) {
        preserve_count = (*env)->GetArrayLength(env, jpreserveFds);
        if (preserve_count > 0)
            preserve_raw = (*env)->GetIntArrayElements(env, jpreserveFds, NULL);
    }
    int rlimit_count = 0;
    jlong *rlimits_raw = NULL;
    if (jrlimits) {
        int rlimits_len = (*env)->GetArrayLength(env, jrlimits);
        if (rlimits_len > 0 && rlimits_len % 3 == 0) {
            rlimit_count = rlimits_len / 3;
            rlimits_raw = (*env)->GetLongArrayElements(env, jrlimits, NULL);
        }
    }
    int trace_fd = open_forkexec_trace(dir_cstr);
    int pipe_stdin[2] = {-1, -1};
    int pipe_stdout[2] = {-1, -1};
    int pipe_stderr[2] = {-1, -1};
    if (pipe(pipe_stdin) < 0 ||
        pipe(pipe_stdout) < 0 ||
        pipe(pipe_stderr) < 0) {
        LOGE("pipe() failed: %s", strerror(errno));
        goto fail;
    }
    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork() failed: %s", strerror(errno));
        goto fail;
    }
    if (pid > 0 && trace_fd >= 0) {
        /* Ties the child's lines (which carry its pid) to what it was meant to run. */
        char when[32] = "?";
        time_t now = time(NULL);
        struct tm tm;
        if (localtime_r(&now, &tm))
            strftime(when, sizeof(when), "%Y-%m-%d %H:%M:%S", &tm);
        dprintf(trace_fd, "[nativeForkExec parent] forked pid=%d argv0=%s at %s\n",
                pid, argv[0], when);
        close(trace_fd);
        trace_fd = -1;
    }
    if (pid == 0) {
        /* Before the dup2s fd 2 is still the parent's stderr: aim at the pipe. */
        crumb(pipe_stderr[1], trace_fd, "start pid=", 1, (long) getpid());
        if (dup2(pipe_stdin[0], STDIN_FILENO) < 0)
            crumb(pipe_stderr[1], trace_fd, "dup2(stdin) failed errno=", 1, errno);
        if (dup2(pipe_stdout[1], STDOUT_FILENO) < 0)
            crumb(pipe_stderr[1], trace_fd, "dup2(stdout) failed errno=", 1, errno);
        if (dup2(pipe_stderr[1], STDERR_FILENO) < 0)
            crumb(pipe_stderr[1], trace_fd, "dup2(stderr) failed errno=", 1, errno);
        crumb(STDERR_FILENO, trace_fd, "after dup2", 0, 0);
        /*
         * Signals first: dispositions back to default and the mask emptied
         * (ART blocks e.g. SIGQUIT on its threads, and a blocked mask would
         * otherwise survive execve into the new program).
         */
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        for (int s = 1; s < NSIG; s++)
            sigaction(s, &sa, NULL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        crumb(STDERR_FILENO, trace_fd, "after signal reset", 0, 0);
        long swept = mark_fds_cloexec_from(3);
        if (swept)
            crumb(STDERR_FILENO, trace_fd, "marked fds cloexec via fcntl, up to ", 1, swept);
        else
            crumb(STDERR_FILENO, trace_fd, "marked fds cloexec via close_range", 0, 0);
        for (int i = 0; i < preserve_count; i++)
            set_cloexec((int) preserve_raw[i], 0);
        crumb(STDERR_FILENO, trace_fd, "after clearing cloexec on preserved fds, count=", 1,
              preserve_count);
        if (dir_cstr && chdir(dir_cstr) < 0) {
            crumb(STDERR_FILENO, trace_fd, "chdir failed, exiting 127, errno=", 1, errno);
            _exit(127);
        }
        crumb(STDERR_FILENO, trace_fd, "after chdir", 0, 0);
        for (int i = 0; i < rlimit_count; i++) {
            int resource = (int) rlimits_raw[i * 3];
            struct rlimit rl;
            rl.rlim_cur = (rlim_t) rlimits_raw[i * 3 + 1];
            rl.rlim_max = (rlim_t) rlimits_raw[i * 3 + 2];
            if (setrlimit(resource, &rl) < 0) {
                crumb(STDERR_FILENO, trace_fd, "setrlimit failed, exiting 126, resource=", 1,
                      resource);
                crumb(STDERR_FILENO, trace_fd, "setrlimit errno=", 1, errno);
                _exit(126);
            }
        }
        crumb(STDERR_FILENO, trace_fd, "after rlimits, count=", 1, rlimit_count);
        crumb(STDERR_FILENO, trace_fd, "calling execve", 0, 0);
        if (envp)
            execve(argv[0], argv, envp);
        else
            execv(argv[0], argv);
        crumb(STDERR_FILENO, trace_fd, "execve failed, exiting 127, errno=", 1, errno);
        _exit(127);
    }
    close(pipe_stdin[0]);
    close(pipe_stdout[1]);
    close(pipe_stderr[1]);
    set_cloexec(pipe_stdin[1], 1);
    set_cloexec(pipe_stdout[0], 1);
    set_cloexec(pipe_stderr[0], 1);
    jintArray result = (*env)->NewIntArray(env, 4);
    if (result) {
        jint buf[4] = {pid, pipe_stdin[1], pipe_stdout[0], pipe_stderr[0]};
        (*env)->SetIntArrayRegion(env, result, 0, 4, buf);
    }
    LOGI("Forked child pid=%d  stdin-wr=%d  stdout-rd=%d  stderr-rd=%d",
         pid, pipe_stdin[1], pipe_stdout[0], pipe_stderr[0]);
    if (preserve_raw)
        (*env)->ReleaseIntArrayElements(env, jpreserveFds, preserve_raw, JNI_ABORT);
    if (rlimits_raw)
        (*env)->ReleaseLongArrayElements(env, jrlimits, rlimits_raw, JNI_ABORT);
    if (dir_cstr)
        (*env)->ReleaseStringUTFChars(env, jdir, dir_cstr);
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    if (envp) {
        for (int i = 0; i < envc; i++) free(envp[i]);
        free(envp);
    }
    return result;
    fail:
    if (trace_fd >= 0) close(trace_fd);
    for (int i = 0; i < 2; i++) {
        if (pipe_stdin[i] >= 0) close(pipe_stdin[i]);
        if (pipe_stdout[i] >= 0) close(pipe_stdout[i]);
        if (pipe_stderr[i] >= 0) close(pipe_stderr[i]);
    }
    if (preserve_raw)
        (*env)->ReleaseIntArrayElements(env, jpreserveFds, preserve_raw, JNI_ABORT);
    if (rlimits_raw)
        (*env)->ReleaseLongArrayElements(env, jrlimits, rlimits_raw, JNI_ABORT);
    if (dir_cstr)
        (*env)->ReleaseStringUTFChars(env, jdir, dir_cstr);
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    if (envp) {
        for (int i = 0; i < envc; i++) free(envp[i]);
        free(envp);
    }
    return NULL;
}

JNIEXPORT jint JNICALL
JNI_PREFIX(nativeWaitPid)(
    JNIEnv *env, jclass clazz, jint pid
) {
    (void) env;
    (void) clazz;
    int status = 0;
    while (1) {
        int ret = waitpid((pid_t) pid, &status, 0);
        if (ret < 0) {
            if (errno == EINTR) continue;
            LOGW("waitpid(%d) failed: %s", pid, strerror(errno));
            return -1;
        }
        break;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return -WTERMSIG(status);
    return -1;
}

JNIEXPORT jint JNICALL
JNI_PREFIX(nativeTryWaitPid)(
    JNIEnv *env, jclass clazz, jint pid
) {
    (void) env;
    (void) clazz;
    int status = 0;
    int ret = waitpid((pid_t) pid, &status, WNOHANG);
    if (ret == 0) return (jint) 0x80000000;
    if (ret < 0) {
        if (errno == ECHILD) return -1;
        return (jint) 0x80000000;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return -WTERMSIG(status);
    return -1;
}

JNIEXPORT void JNICALL
JNI_PREFIX(nativeKill)(
    JNIEnv *env, jclass clazz, jint pid, jint sig
) {
    (void) env;
    (void) clazz;
    if (kill((pid_t) pid, (int) sig) < 0)
        LOGW("kill(%d, %d) failed: %s", pid, sig, strerror(errno));
}
