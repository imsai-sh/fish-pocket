// What FFmpeg.framework (scripts/build-ffmpeg.sh) offers the app: ffmpeg and
// ffprobe as functions. tool.c implements this inside the framework; the app's
// binding (binding.c) runs them on threads of their own.
#ifndef DSH_FFMPEG_H
#define DSH_FFMPEG_H

enum { DSH_FFMPEG = 0, DSH_FFPROBE = 1 };

/**
 * Run ffmpeg or ffprobe with `argv` on the calling thread and return its exit
 * code. `fds` are its stdin, stdout and stderr; they stay the caller's (they
 * are duplicated). The programs keep their state in globals, so runs take
 * turns: this waits for the one before it. `id` names the run for
 * dsh_ffmpeg_interrupt; when `cancelled` is set once its turn comes, it does
 * not start and returns 255.
 */
int dsh_ffmpeg_run(long id, int tool, int argc, char **argv, const int fds[3], const volatile int *cancelled);

/** Ask run `id` to stop, as SIGINT or SIGTERM would. Whether it was running. */
int dsh_ffmpeg_interrupt(long id, int sig);

#endif
