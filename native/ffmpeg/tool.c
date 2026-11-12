// ffmpeg and ffprobe as functions, inside FFmpeg.framework (scripts/build-ffmpeg.sh
// links this file with FFmpeg's libraries and its patched fftools).
//
// fftools are programs: they keep their state in globals and expect a process
// of their own. Here they get the next best thing, one run at a time:
//
//   - their globals (fftools-prefix.h puts them in sections of their own) are
//     put back to their values at load before each run;
//   - the library settings they change for the whole process (log level and
//     flags, CPU flags, allocation limit) are reset too;
//   - stdin, stdout, stderr and pipe:0/1/2 are the run's descriptors;
//   - exit() jumps back here (ffprobe calls it on some errors);
//   - instead of signals, which the app keeps to itself, dsh_ffmpeg_interrupt
//     calls ffmpeg's own handler; ffprobe has none and runs to its end.
//
// FFmpeg's own threads (ffmpeg runs demuxing, decoding, filtering, encoding and
// muxing on threads of their own) are all joined before ffmpeg returns.
#include "dsh_ffmpeg.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libavutil/cpu.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

int dsh_ffmpeg_main(int argc, char **argv);
int dsh_ffprobe_main(int argc, char **argv);
void dsh_ffmpeg_signal(int sig);

FILE *dsh_ffmpeg_stdio[3];
static int runFds[3] = {-1, -1, -1};

static pthread_mutex_t turn = PTHREAD_MUTEX_INITIALIZER;
static pthread_t runThread;
static jmp_buf exitJump;
static int exitCode;
static _Atomic long currentId;
static _Atomic int currentTool = -1;

// ---- the run's descriptors and streams ----------------------------------------

/** pipe:N in the run: its own stdin, stdout or stderr for 0, 1 and 2. */
int dsh_ffmpeg_fd(int fd) { return fd >= 0 && fd < 3 && runFds[fd] >= 0 ? runFds[fd] : fd; }

static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
static int printPrefix = 1;

/** av_log's callback while a run is on: its lines go to the run's stderr. */
void dsh_ffmpeg_log(void *context, int level, const char *format, va_list arguments) {
  if ((level & 0xff) > av_log_get_level()) return;
  char line[2048];
  pthread_mutex_lock(&logLock);
  int length = av_log_format_line2(context, level, format, arguments, line, sizeof line, &printPrefix);
  FILE *err = dsh_ffmpeg_stdio[2];
  if (err != NULL && length > 0) fputs(line, err);
  pthread_mutex_unlock(&logLock);
}

_Noreturn void dsh_ffmpeg_exit(int code) {
  exitCode = code;
  if (pthread_equal(pthread_self(), runThread)) longjmp(exitJump, 1);
  // No fftools thread calls exit(); if one ever does, it ends only itself.
  pthread_exit(NULL);
}

// ---- fresh globals -------------------------------------------------------------

static void *pristine;  // __dsh_ff_data as loaded

static void restoreGlobals(void) {
  Dl_info info;
  if (dladdr((const void *)dsh_ffmpeg_run, &info) == 0 || info.dli_fbase == NULL) abort();
  const struct mach_header_64 *image = info.dli_fbase;
  unsigned long size = 0;
  uint8_t *data = getsectiondata(image, "__DATA", "__dsh_ff_data", &size);
  if (data != NULL && size > 0) {
    if (pristine == NULL) {
      // The first run: nothing has written them yet.
      if ((pristine = malloc(size)) == NULL) abort();
      memcpy(pristine, data, size);
    } else {
      memcpy(data, pristine, size);
    }
  }
  uint8_t *bss = getsectiondata(image, "__DATA", "__dsh_ff_bss", &size);
  if (bss != NULL) memset(bss, 0, size);

  av_log_set_level(AV_LOG_INFO);
  av_log_set_flags(0);
  av_log_set_callback(dsh_ffmpeg_log);
  av_force_cpu_flags(-1);
  av_max_alloc(INT_MAX);
  printPrefix = 1;
}

// ---- runs ----------------------------------------------------------------------

static FILE *stream(int fd, const char *mode) {
  int copy = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  if (copy < 0) return NULL;
  FILE *file = fdopen(copy, mode);
  if (file == NULL) close(copy);
  return file;
}

int dsh_ffmpeg_run(long id, int tool, int argc, char **argv, const int fds[3], const volatile int *cancelled) {
  pthread_mutex_lock(&turn);
  if (cancelled != NULL && *cancelled) {
    pthread_mutex_unlock(&turn);
    return 255;
  }
  restoreGlobals();
  memcpy(runFds, fds, sizeof runFds);
  dsh_ffmpeg_stdio[0] = stream(fds[0], "r");
  dsh_ffmpeg_stdio[1] = stream(fds[1], "w");
  dsh_ffmpeg_stdio[2] = stream(fds[2], "w");
  int code = 1;
  if (dsh_ffmpeg_stdio[0] != NULL && dsh_ffmpeg_stdio[1] != NULL && dsh_ffmpeg_stdio[2] != NULL) {
    setvbuf(dsh_ffmpeg_stdio[2], NULL, _IONBF, 0);
    runThread = pthread_self();
    atomic_store(&currentTool, tool);
    atomic_store(&currentId, id);
    if (setjmp(exitJump) == 0) {
      code = tool == DSH_FFPROBE ? dsh_ffprobe_main(argc, argv) : dsh_ffmpeg_main(argc, argv);
    } else {
      code = exitCode;
    }
    atomic_store(&currentId, 0);
    atomic_store(&currentTool, -1);
  }
  pthread_mutex_lock(&logLock);
  for (int i = 0; i < 3; i++) {
    if (dsh_ffmpeg_stdio[i] != NULL) fclose(dsh_ffmpeg_stdio[i]);
    dsh_ffmpeg_stdio[i] = NULL;
    runFds[i] = -1;
  }
  pthread_mutex_unlock(&logLock);
  pthread_mutex_unlock(&turn);
  return code & 0xff;
}

int dsh_ffmpeg_interrupt(long id, int sig) {
  if (id == 0 || atomic_load(&currentId) != id) return 0;
  // ffmpeg's handler only sets flags its loops check: safe from any thread.
  if (atomic_load(&currentTool) == DSH_FFMPEG) dsh_ffmpeg_signal(sig);
  return 1;
}
