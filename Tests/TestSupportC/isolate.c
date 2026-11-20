// Isolates the whole test process as it loads, before any test of any target runs: no test can read the user's own
// ~/.kelp, ~/.claude, ~/.codex, keychain or git config, whichever target runs first or alone. (Swift has no load-time
// code; a C constructor runs when the test bundle is loaded.)
#include "TestSupportC.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char root[64];

// A step that didn't take ends the tests before any runs: they'd go on against the user's own ~/.kelp and the rest.
static void need(int ok, const char *what) {
    if (ok) return;
    fprintf(stderr, "test isolation: %s failed\n", what);
    abort();
}

static void set(const char *key, const char *value) { need(setenv(key, value, 1) == 0, key); }

static void put(const char *key, const char *dir) {
    char v[PATH_MAX];
    snprintf(v, sizeof v, "%s%s", root, dir);
    set(key, v);
}

// What KelpKit keeps per Mac in UserDefaults and reads as an app starts, where the last value changes what a test sees:
// the agents the last check found. The process's defaults are the test helper's, kept across runs and shared by every
// run on this Mac, so one run (or one test) would hand them to the next. Masked for this process alone: the argument
// domain comes first and no write changes it.
static void mask_defaults(void) {
    id defaults = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSUserDefaults"), sel_registerName("standardUserDefaults"));
    need(defaults != NULL, "UserDefaults");
    CFStringRef domain = CFSTR("NSArgumentDomain");
    CFDictionaryRef had = (CFDictionaryRef)((id (*)(id, SEL, CFStringRef))objc_msgSend)(
        defaults, sel_registerName("volatileDomainForName:"), domain);
    CFMutableDictionaryRef masked = had ? CFDictionaryCreateMutableCopy(NULL, 0, had)
        : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef none = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(masked, CFSTR("agents.available"), none);
    ((void (*)(id, SEL, CFStringRef))objc_msgSend)(defaults, sel_registerName("removeVolatileDomainForName:"), domain);
    ((void (*)(id, SEL, CFDictionaryRef, CFStringRef))objc_msgSend)(
        defaults, sel_registerName("setVolatileDomain:forName:"), masked, domain);
    CFRelease(none);
    CFRelease(masked);
}

__attribute__((constructor)) static void kelp_isolate(void) {
    // Short: a Unix socket path inside it has to fit in 104 bytes. Removed when the process exits (TestIsolation).
    snprintf(root, sizeof root, "/tmp/kr-XXXXXX");
    need(mkdtemp(root) != NULL, "mkdtemp");
    put("KELP_HOME", "/home");
    put("CLAUDE_CONFIG_DIR", "/claude");
    put("CODEX_HOME", "/codex");
    put("KELP_TRASH", "/trash");   // Trash.move: never the user's own Trash
    need(mkdir(getenv("KELP_TRASH"), 0700) == 0, "mkdir trash");   // there to look in before anything went to it
    put("ZDOTDIR", "");   // `zsh -c` reads no ~/.zshenv of the user's: the folder has none
    // Stand-ins named once, here, as no test can set one while others run (setenv races every getenv). Each is written
    // by the tests that use it (DaemonTests' localSSH, GitHubHandlerTests); until then the program isn't there, never
    // the user's own ssh, gh or glab with their hosts and logins. Android's SDK is a test's own folder, passed in.
    char bin[PATH_MAX];
    snprintf(bin, sizeof bin, "%s/bin", root);
    need(mkdir(bin, 0700) == 0, "mkdir bin");
    put("KELP_SSH", "/bin/ssh");
    put("KELP_GH", "/bin/gh");
    put("KELP_GLAB", "/bin/glab");
    unsetenv("KELP_SESSION"); unsetenv("KELP_SOCKET");   // run from a Kelp terminal: not one of its sessions here
    const char *path = getenv("PATH");
    set("KELP_LOGIN_PATH", path ? path : "/usr/bin:/bin");   // no login shell, so no profile runs
    set("TMUX_TMPDIR", root); unsetenv("TMUX");   // a tmux server of the tests' own, never the user's sessions
    char service[96];
    snprintf(service, sizeof service, "dev.kelp.tests.%s.%d", root + 8, (int)getpid());
    set("KELP_KEYCHAIN_SERVICE", service);
    set("GIT_CONFIG_GLOBAL", "/dev/null");
    set("GIT_CONFIG_NOSYSTEM", "1");
    // Who the tests' commits are by, with no config to say it.
    set("GIT_AUTHOR_NAME", "t"); set("GIT_AUTHOR_EMAIL", "t@t");
    set("GIT_COMMITTER_NAME", "t"); set("GIT_COMMITTER_EMAIL", "t@t");
    mask_defaults();
    set("KELP_TEST_ISOLATED", "1");
    // A kelpd a test starts ends with this process (kelpd/main.swift): a test killed midway skips the atexit that
    // removes the folder, and the daemon in it stayed for good.
    char pid[16];
    snprintf(pid, sizeof pid, "%d", (int)getpid());
    set("KELP_TEST_PID", pid);
    // In-process daemons take this test process for Kelp's window (only it may trust a project's commands).
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof exe;
    need(_NSGetExecutablePath(exe, &size) == 0 && realpath(exe, real), "finding the test runner");
    set("KELP_APP_EXECUTABLE", real);
    // Sessions start through the kelp built beside this bundle (…/debug/KelpPackageTests.xctest/Contents/MacOS/…), as
    // under kelpd: the terminal is theirs, so they get the hangup if this process dies before its daemons stop.
    Dl_info info;
    if (dladdr((const void *)kelp_isolate, &info) && info.dli_fname && realpath(info.dli_fname, real)) {
        for (int i = 0; i < 4; i++) { char *slash = strrchr(real, '/'); if (slash) *slash = 0; }
        char kelp[PATH_MAX];
        snprintf(kelp, sizeof kelp, "%s/kelp", real);
        if (access(kelp, X_OK) == 0) set("KELP_TRAMPOLINE", kelp);
    }
}

const char *kelp_test_root(void) { return root; }
