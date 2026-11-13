// ffmpeg and ffprobe for the engine. iOS has no fork/exec, so they are linked
// into the app (FFmpeg.framework, scripts/build-ffmpeg.sh) and a "process" is
// a thread running one of them as a function (tool.c), as Python's are
// (native/python):
//
//   - its stdin, stdout and stderr are pipes; the engine reads and writes the
//     other ends (engine/runtime/ffmpeg), so output streams while it runs;
//   - its working directory is its own (DshRoot's dsh_root_enter), shared by
//     the threads FFmpeg starts; FFmpeg.framework depends on DshRoot, so it
//     opens files in the engine's view;
//   - fftools keep their state in globals, so runs take turns: a second one
//     waits for the first to finish.
//
// Registered as the linked binding `dsh_ffmpeg`:
//   spawn({ argv, cwd }, onExit(code, signal)) -> { pid, stdin, stdout, stderr }
//   kill(pid, signal) -> whether the process was still running
#include <errno.h>
#include <fcntl.h>
#include <node_api.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../root/root.h"
#include "dsh_ffmpeg.h"

typedef struct Process {
  int pid;
  int tool;
  int argc;
  char **argv;
  char *cwd;
  int fds[3];  // the program's side of stdin, stdout, stderr
  volatile int cancelled;
  int killedWith;
  int exitCode;
  bool done;
  int references;
  pthread_mutex_t lock;
  napi_threadsafe_function onExit;  // NULL once the engine that asked for it is gone
  // The engine's teardown hook holds a reference until it runs or the exit callback removes it.
  bool hooked;
  struct Process *next;
} Process;

static pthread_mutex_t tableLock = PTHREAD_MUTEX_INITIALIZER;
static Process *table;
static int nextPid = 30000;

static void freeStrings(char **strings) {
  if (strings == NULL) return;
  for (char **s = strings; *s != NULL; s++) free(*s);
  free(strings);
}

static void release(Process *process) {
  pthread_mutex_lock(&process->lock);
  int left = --process->references;
  pthread_mutex_unlock(&process->lock);
  if (left > 0) return;
  freeStrings(process->argv);
  free(process->cwd);
  pthread_mutex_destroy(&process->lock);
  free(process);
}

/** The process `pid`, retained; NULL when there is none. */
static Process *find(int pid) {
  pthread_mutex_lock(&tableLock);
  Process *found = table;
  while (found != NULL && found->pid != pid) found = found->next;
  if (found != NULL) {
    pthread_mutex_lock(&found->lock);
    found->references++;
    pthread_mutex_unlock(&found->lock);
  }
  pthread_mutex_unlock(&tableLock);
  return found;
}

static void unlist(Process *process) {
  pthread_mutex_lock(&tableLock);
  for (Process **at = &table; *at != NULL; at = &(*at)->next) {
    if (*at == process) {
      *at = process->next;
      break;
    }
  }
  pthread_mutex_unlock(&tableLock);
}

/**
 * The engine that started the process is going away (its worker is replaced
 * when a plugin change needs a restart). Node frees the exit callback right
 * after this hook, so the process thread must not reach it any more.
 */
static void engineGone(void *value) {
  Process *process = value;
  pthread_mutex_lock(&process->lock);
  process->onExit = NULL;
  bool hooked = process->hooked;
  process->hooked = false;
  pthread_mutex_unlock(&process->lock);
  if (hooked) release(process);
}

static void callExit(napi_env env, napi_value callback, void *context, void *data) {
  Process *process = data;
  if (env != NULL) {
    pthread_mutex_lock(&process->lock);
    bool hooked = process->hooked;
    process->hooked = false;
    pthread_mutex_unlock(&process->lock);
    if (hooked) {
      napi_remove_env_cleanup_hook(env, engineGone, process);
      release(process);
    }
  }
  if (env != NULL && callback != NULL) {
    napi_value arguments[2], global;
    pthread_mutex_lock(&process->lock);
    int code = process->exitCode, signal = process->killedWith;
    pthread_mutex_unlock(&process->lock);
    if (signal != 0) {
      napi_get_null(env, &arguments[0]);
      napi_create_int32(env, signal, &arguments[1]);
    } else {
      napi_create_int32(env, code, &arguments[0]);
      napi_get_null(env, &arguments[1]);
    }
    napi_get_global(env, &global);
    napi_call_function(env, global, callback, 2, arguments, NULL);
  }
  release(process);
}

static void *runProcess(void *value) {
  Process *process = value;
  if (dsh_root_enter(process->cwd) != 0) dsh_root_enter("/");
  int code = dsh_ffmpeg_run(process->pid, process->tool, process->argc, process->argv, process->fds, &process->cancelled);
  dsh_root_leave();
  // Closing the pipes is what the engine sees as end of output.
  for (int i = 0; i < 3; i++) close(process->fds[i]);
  // The exit callback is used under the lock: the engine's teardown (`engineGone`) takes it
  // too, so the callback is either reached before Node frees it or not at all.
  pthread_mutex_lock(&process->lock);
  process->exitCode = code;
  process->done = true;
  napi_threadsafe_function onExit = process->onExit;
  process->onExit = NULL;
  bool delivered = false;
  if (onExit != NULL) {
    // The queue is unbounded, so this never waits.
    delivered = napi_call_threadsafe_function(onExit, process, napi_tsfn_nonblocking) == napi_ok;
    napi_release_threadsafe_function(onExit, napi_tsfn_release);
  }
  pthread_mutex_unlock(&process->lock);
  unlist(process);  // the table's reference goes to the exit callback, or goes now if there is none
  if (!delivered) release(process);
  release(process);  // the thread's reference
  return NULL;
}

// ---- N-API -----------------------------------------------------------------

static napi_value throwError(napi_env env, const char *message) {
  napi_throw_error(env, NULL, message);
  return NULL;
}

static char *property(napi_env env, napi_value object, const char *name) {
  napi_value value;
  napi_valuetype type;
  size_t length;
  if (napi_get_named_property(env, object, name, &value) != napi_ok || napi_typeof(env, value, &type) != napi_ok ||
      type != napi_string || napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) {
    return NULL;
  }
  char *result = malloc(length + 1);
  if (result != NULL) napi_get_value_string_utf8(env, value, result, length + 1, &length);
  return result;
}

static char **stringArray(napi_env env, napi_value object, const char *name, int *count) {
  napi_value array;
  bool isArray = false;
  uint32_t length = 0;
  if (napi_get_named_property(env, object, name, &array) != napi_ok || napi_is_array(env, array, &isArray) != napi_ok || !isArray ||
      napi_get_array_length(env, array, &length) != napi_ok) {
    return NULL;
  }
  char **strings = calloc(length + 1, sizeof *strings);
  for (uint32_t i = 0; strings != NULL && i < length; i++) {
    napi_value item;
    size_t size;
    if (napi_get_element(env, array, i, &item) != napi_ok || napi_get_value_string_utf8(env, item, NULL, 0, &size) != napi_ok ||
        (strings[i] = malloc(size + 1)) == NULL) {
      freeStrings(strings);
      return NULL;
    }
    napi_get_value_string_utf8(env, item, strings[i], size + 1, &size);
  }
  *count = (int)length;
  return strings;
}

static napi_value spawnProcess(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) return throwError(env, "spawn(spec, onExit)");
  // A write to a pipe the engine closed must fail, not end the app.
  struct sigaction current;
  if (sigaction(SIGPIPE, NULL, &current) == 0 && current.sa_handler == SIG_DFL) signal(SIGPIPE, SIG_IGN);

  Process *process = calloc(1, sizeof *process);
  if (process == NULL) return throwError(env, "spawn: out of memory");
  pthread_mutex_init(&process->lock, NULL);
  process->references = 2;  // the table's and the thread's
  process->argv = stringArray(env, argv[0], "argv", &process->argc);
  process->cwd = property(env, argv[0], "cwd");
  if (process->argv == NULL || process->argc == 0 || process->cwd == NULL) {
    process->references = 1;
    release(process);
    return throwError(env, "spawn: argv and cwd are required");
  }
  const char *name = strrchr(process->argv[0], '/');
  name = name ? name + 1 : process->argv[0];
  process->tool = strncmp(name, "ffprobe", 7) == 0 ? DSH_FFPROBE : DSH_FFMPEG;

  int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
  napi_value result = NULL;
  if (pipe(in) != 0 || pipe(out) != 0 || pipe(err) != 0) {
    throwError(env, strerror(errno));
  } else {
    int ends[6] = {in[0], in[1], out[0], out[1], err[0], err[1]};
    for (int i = 0; i < 6; i++) {
      fcntl(ends[i], F_SETFD, FD_CLOEXEC);
      fcntl(ends[i], F_SETNOSIGPIPE, 1);
    }
    process->fds[0] = in[0];
    process->fds[1] = out[1];
    process->fds[2] = err[1];
    napi_value label;
    napi_create_string_utf8(env, "ffmpeg exit", NAPI_AUTO_LENGTH, &label);
    bool started = false;
    if (napi_create_threadsafe_function(env, argv[1], NULL, label, 0, 1, NULL, NULL, NULL, callExit, &process->onExit) == napi_ok) {
      pthread_mutex_lock(&tableLock);
      process->pid = nextPid++;
      process->next = table;
      table = process;
      pthread_mutex_unlock(&tableLock);
      pthread_attr_t attributes;
      pthread_attr_init(&attributes);
      pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
      pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
      pthread_t thread;
      started = pthread_create(&thread, &attributes, runProcess, process) == 0;
      pthread_attr_destroy(&attributes);
      if (!started) {
        unlist(process);
        napi_release_threadsafe_function(process->onExit, napi_tsfn_abort);
      }
    }
    if (!started) {
      throwError(env, "spawn: cannot start the process");
    } else {
      // Called on the engine's thread, so the engine cannot be torn down before the hook is in.
      pthread_mutex_lock(&process->lock);
      process->references++;
      process->hooked = true;
      pthread_mutex_unlock(&process->lock);
      napi_add_env_cleanup_hook(env, engineGone, process);
      napi_value pid, stdinEnd, stdoutEnd, stderrEnd;
      napi_create_object(env, &result);
      napi_create_int32(env, process->pid, &pid);
      napi_create_int32(env, in[1], &stdinEnd);
      napi_create_int32(env, out[0], &stdoutEnd);
      napi_create_int32(env, err[0], &stderrEnd);
      napi_set_named_property(env, result, "pid", pid);
      napi_set_named_property(env, result, "stdin", stdinEnd);
      napi_set_named_property(env, result, "stdout", stdoutEnd);
      napi_set_named_property(env, result, "stderr", stderrEnd);
      return result;
    }
  }
  int leftovers[6] = {in[0], in[1], out[0], out[1], err[0], err[1]};
  for (int i = 0; i < 6; i++) if (leftovers[i] >= 0) close(leftovers[i]);
  process->references = 1;
  release(process);
  return result;
}

/**
 * Ask a process to stop: ffmpeg stops at its next check, as on SIGINT or
 * SIGTERM, and still writes out what it has. ffprobe has no such check and
 * runs to its end. A process still waiting for its turn never starts.
 */
static napi_value killProcess(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2], result;
  int32_t pid = 0, sig = SIGTERM;
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 1 || napi_get_value_int32(env, argv[0], &pid) != napi_ok) return throwError(env, "kill(pid, signal)");
  if (argc > 1) napi_get_value_int32(env, argv[1], &sig);
  Process *process = find(pid);
  bool running = false;
  if (process != NULL) {
    pthread_mutex_lock(&process->lock);
    running = !process->done;
    if (running && sig != 0) {
      process->cancelled = 1;
      process->killedWith = sig;
    }
    pthread_mutex_unlock(&process->lock);
    if (running && sig != 0) dsh_ffmpeg_interrupt(pid, sig == SIGINT ? SIGINT : SIGTERM);
    release(process);
  }
  napi_get_boolean(env, running, &result);
  return result;
}

static napi_value init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"spawn", NULL, spawnProcess, NULL, NULL, NULL, napi_default, NULL},
      {"kill", NULL, killProcess, NULL, NULL, NULL, napi_default, NULL},
  };
  napi_define_properties(env, exports, sizeof properties / sizeof *properties, properties);
  return exports;
}

static napi_module module = {1, 0, __FILE__, init, "dsh_ffmpeg", NULL, {0}};
__attribute__((constructor)) static void registerModule(void) { napi_module_register(&module); }
