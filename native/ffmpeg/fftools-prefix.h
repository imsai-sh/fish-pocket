// Included ahead of every fftools source file (scripts/build-ffmpeg.sh), so
// ffmpeg and ffprobe can run inside the app, one after another, as functions:
//
//   - their globals go to sections of their own, which tool.c puts back to how
//     they were at load before each run: every run starts as a fresh program;
//   - stdin, stdout and stderr are the running command's streams, not the app's;
//   - exit() returns to tool.c instead of ending the app;
//   - log lines go through tool.c's callback to the command's stderr.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#pragma clang section bss = "__DATA,__dsh_ff_bss" data = "__DATA,__dsh_ff_data"

extern FILE *dsh_ffmpeg_stdio[3];
#undef stdin
#undef stdout
#undef stderr
#define stdin (dsh_ffmpeg_stdio[0])
#define stdout (dsh_ffmpeg_stdio[1])
#define stderr (dsh_ffmpeg_stdio[2])
#define printf(...) fprintf(stdout, __VA_ARGS__)
#define vprintf(format, arguments) vfprintf(stdout, format, arguments)
#define putchar(c) fputc(c, stdout)
#define puts(s) (fputs(s, stdout) < 0 ? EOF : fputc('\n', stdout))
#define getchar() fgetc(stdin)

// The programs' entry points under the names tool.c calls (the patch renames main).
int dsh_ffmpeg_main(int argc, char **argv);
int dsh_ffprobe_main(int argc, char **argv);
void dsh_ffmpeg_signal(int sig);

_Noreturn void dsh_ffmpeg_exit(int code);
#define exit(code) dsh_ffmpeg_exit(code)

// -report's callback passes lines on to the default one, which writes to the app's stderr.
#define av_log_default_callback dsh_ffmpeg_log
