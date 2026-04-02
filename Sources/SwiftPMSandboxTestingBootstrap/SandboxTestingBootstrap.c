// swiftpm-sandbox-testing
//
// Drop this file into a SwiftPM executable or test target (under Sources/<Target>/ or Tests/<Target>/).
// It bootstraps a dev/test safety boundary for direct `swift run` / `swift test` executions:
//   - redirects HOME/TMP into a repo-local sandbox root
//   - applies a Seatbelt write-guard profile via sandbox_init_with_parameters
//   - logs filesystem mutation attempts (operation, path, backtrace) into JSONL
//
// Notes:
//   - This uses deprecated/private sandbox APIs (libsandbox / Seatbelt). Treat as a *dev/test guardrail*.
//   - Keep the constructor path C/POSIX-only (no Foundation / Swift runtime assumptions).

#if defined(__APPLE__)

#include <sandbox.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

// sandbox_init_with_parameters is available in libsystem_sandbox, but is not always declared in the public SDK headers.
// Signature matches Chromium's usage.
extern int sandbox_init_with_parameters(const char *profile,
                                        uint64_t flags,
                                        const char *const parameters[],
                                        char **errorbuf);

// sandbox_check is available in libsystem_sandbox, but is not always declared in the public SDK headers.
// Chromium treats sandbox_check(getpid(), NULL, SANDBOX_FILTER_NONE) as the canonical "is sandboxed" check.
// See: chromium/src sandbox/mac/seatbelt.cc
// (We keep the signature minimal and avoid non-portable constants.)
//
// Return semantics used by common tools:
//   - rc == 0 => allowed
//   - rc != 0 => denied
// See: Karol Mazurek, "Sandbox Validator" (uses sandbox_check to validate operations).

enum swiftpmst_sandbox_filter_type {
    SWIFTPMST_SANDBOX_FILTER_NONE = 0,
    SWIFTPMST_SANDBOX_FILTER_PATH = 1,
};

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);

// -----------------------------
// Configuration (env-driven)
// -----------------------------

typedef enum {
    SWIFTPMST_MODE_STRICT = 0,
    SWIFTPMST_MODE_REDIRECT = 1,
    SWIFTPMST_MODE_REPORT_ONLY = 2,
} swiftpmst_mode_t;

static swiftpmst_mode_t swiftpmst_parse_mode(void) {
    const char *s = getenv("SWIFTPM_SANDBOX_MODE");
    if (!s || !*s) return SWIFTPMST_MODE_STRICT;
    if (strcmp(s, "strict") == 0) return SWIFTPMST_MODE_STRICT;
    if (strcmp(s, "redirect") == 0) return SWIFTPMST_MODE_REDIRECT;
    if (strcmp(s, "report-only") == 0) return SWIFTPMST_MODE_REPORT_ONLY;
    return SWIFTPMST_MODE_STRICT;
}

static bool swiftpmst_is_disabled(void) {
    const char *s = getenv("SWIFTPM_SANDBOX_DISABLE");
    return (s && *s && strcmp(s, "0") != 0);
}

static bool swiftpmst_allow_unenforced(void) {
    const char *s = getenv("SWIFTPM_SANDBOX_ALLOW_UNENFORCED");
    return (s && *s && strcmp(s, "0") != 0);
}

static bool swiftpmst_selftest_enabled(void) {
    const char *s = getenv("SWIFTPM_SANDBOX_SELFTEST");
    return (s && *s && strcmp(s, "0") != 0);
}

static bool swiftpmst_verbose(void) {
    const char *s = getenv("SWIFTPM_SANDBOX_LOG_LEVEL");
    return (s && strcmp(s, "verbose") == 0);
}

static bool swiftpmst_allow_system_tmp(void) {
    const char *s = getenv("SWIFTPM_SANDBOX_ALLOW_SYSTEM_TMP");
    return (s && *s && strcmp(s, "0") != 0);
}

static bool swiftpmst_tripwire_enabled(void) {
    const char *s = getenv("SWIFTPM_SANDBOX_TRIPWIRE");
    if (!s || !*s) return true;
    return strcmp(s, "0") != 0;
}

// -----------------------------
// Global state
// -----------------------------

static char g_workspace_root[PATH_MAX] = {0};
static char g_sandbox_root[PATH_MAX] = {0};
static char g_fake_home[PATH_MAX] = {0};
static char g_fake_tmp[PATH_MAX] = {0};
static char g_log_path[PATH_MAX] = {0};
static char g_orig_home[PATH_MAX] = {0};

static swiftpmst_mode_t g_mode = SWIFTPMST_MODE_STRICT;

static bool g_allow_system_tmp = false;
static bool g_tripwire_enabled = true;
static bool g_tripwire_active = false;

static _Thread_local int g_in_hook = 0;

// Real function pointers (resolved with dlsym(RTLD_NEXT, ...))
static int (*real_open)(const char *path, int oflag, ...) = NULL;
static int (*real_openat)(int fd, const char *path, int oflag, ...) = NULL;
static int (*real_creat)(const char *path, mode_t mode) = NULL;
static int (*real_unlink)(const char *path) = NULL;
static int (*real_rename)(const char *old, const char *newp) = NULL;
static int (*real_mkdir)(const char *path, mode_t mode) = NULL;
static int (*real_rmdir)(const char *path) = NULL;
static int (*real_truncate)(const char *path, off_t length) = NULL;
static int (*real_ftruncate)(int fd, off_t length) = NULL;

static void swiftpmst_resolve_real_functions(void) {
    if (real_open) return;
    real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    real_creat = (int (*)(const char *, mode_t))dlsym(RTLD_NEXT, "creat");
    real_unlink = (int (*)(const char *))dlsym(RTLD_NEXT, "unlink");
    real_rename = (int (*)(const char *, const char *))dlsym(RTLD_NEXT, "rename");
    real_mkdir = (int (*)(const char *, mode_t))dlsym(RTLD_NEXT, "mkdir");
    real_rmdir = (int (*)(const char *))dlsym(RTLD_NEXT, "rmdir");
    real_truncate = (int (*)(const char *, off_t))dlsym(RTLD_NEXT, "truncate");
    real_ftruncate = (int (*)(int, off_t))dlsym(RTLD_NEXT, "ftruncate");
}

// -----------------------------
// Small utilities
// -----------------------------

static void swiftpmst_stderr(const char *prefix, const char *msg) {
    if (!prefix) prefix = "swiftpm-sandbox-testing";
    if (!msg) msg = "";
    fprintf(stderr, "[%s] %s\n", prefix, msg);
}

static bool swiftpmst_path_exists(const char *p) {
    struct stat st;
    return (p && *p && stat(p, &st) == 0);
}

static bool swiftpmst_is_dir(const char *p) {
    struct stat st;
    if (!p || !*p) return false;
    if (stat(p, &st) != 0) return false;
    return S_ISDIR(st.st_mode);
}

static bool swiftpmst_mkdir_p(const char *path, mode_t mode) {
    if (!path || !*path) return false;
    if (swiftpmst_is_dir(path)) return true;

    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s", path);

    size_t len = strlen(tmp);
    if (len == 0) return false;
    if (tmp[len - 1] == '/') tmp[len - 1] = 0;

    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (!swiftpmst_is_dir(tmp)) {
                if (real_mkdir(tmp, mode) != 0 && errno != EEXIST) return false;
            }
            *p = '/';
        }
    }
    if (real_mkdir(tmp, mode) != 0 && errno != EEXIST) return false;
    return true;
}

static bool swiftpmst_find_workspace_root_from(const char *start_dir, char out[PATH_MAX]) {
    if (!start_dir || !*start_dir) return false;

    char cur[PATH_MAX];
    snprintf(cur, sizeof(cur), "%s", start_dir);

    for (int depth = 0; depth < 12; depth++) {
        char candidate[PATH_MAX];
        snprintf(candidate, sizeof(candidate), "%s/Package.swift", cur);
        if (swiftpmst_path_exists(candidate)) {
            snprintf(out, PATH_MAX, "%s", cur);
            return true;
        }

        // Walk up one directory.
        char *slash = strrchr(cur, '/');
        if (!slash || slash == cur) break;
        *slash = 0;
    }

    return false;
}

static bool swiftpmst_determine_workspace_root(char out[PATH_MAX]) {
    const char *override_root = getenv("SWIFTPM_SANDBOX_WORKSPACE_ROOT");
    if (override_root && *override_root) {
        snprintf(out, PATH_MAX, "%s", override_root);
        return true;
    }

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) == NULL) return false;
    return swiftpmst_find_workspace_root_from(cwd, out);
}

static void swiftpmst_build_run_id(char out[64]) {
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    pid_t pid = getpid();

    snprintf(out, 64, "%04d%02d%02d-%02d%02d%02d-pid%d",
             tmv.tm_year + 1900,
             tmv.tm_mon + 1,
             tmv.tm_mday,
             tmv.tm_hour,
             tmv.tm_min,
             tmv.tm_sec,
             (int)pid);
}

static bool swiftpmst_is_write_open_flags(int oflag) {
    if ((oflag & O_ACCMODE) == O_WRONLY) return true;
    if ((oflag & O_ACCMODE) == O_RDWR) return true;
    if (oflag & O_CREAT) return true;
    if (oflag & O_TRUNC) return true;
    return false;
}

static bool swiftpmst_is_within_prefix(const char *path, const char *prefix) {
    if (!path || !prefix) return false;
    size_t n = strlen(prefix);
    if (n == 0) return false;
    if (strncmp(path, prefix, n) != 0) return false;
    // Ensure directory boundary ("/foo" matches "/foo" or "/foo/bar", not "/foobar").
    return (path[n] == 0 || path[n] == '/');
}

static bool swiftpmst_write_allowed_path_string(const char *abs_path) {
    if (!abs_path || !*abs_path) return false;

    // Allow common harmless sinks.
    if (strcmp(abs_path, "/dev/null") == 0) return true;

    // Allowed: repo-local sandbox root and repo workspace.
    if (g_sandbox_root[0] && swiftpmst_is_within_prefix(abs_path, g_sandbox_root)) return true;
    if (g_workspace_root[0] && swiftpmst_is_within_prefix(abs_path, g_workspace_root)) return true;

    // Optional compatibility loosening: allow common system temp locations.
    // Disabled by default to preserve the “workspace-only writes” guarantee.
    if (g_allow_system_tmp) {
        if (swiftpmst_is_within_prefix(abs_path, "/tmp")) return true;
        if (swiftpmst_is_within_prefix(abs_path, "/private/tmp")) return true;
        if (swiftpmst_is_within_prefix(abs_path, "/var/tmp")) return true;
        if (swiftpmst_is_within_prefix(abs_path, "/private/var/tmp")) return true;
        if (swiftpmst_is_within_prefix(abs_path, "/var/folders")) return true;
        if (swiftpmst_is_within_prefix(abs_path, "/private/var/folders")) return true;
    }

    return false;
}

static bool swiftpmst_make_abs_path(const char *path, char out[PATH_MAX]) {
    if (!path || !*path) return false;
    if (path[0] == '/') {
        snprintf(out, PATH_MAX, "%s", path);
        return true;
    }

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) == NULL) return false;
    snprintf(out, PATH_MAX, "%s/%s", cwd, path);
    return true;
}

static void swiftpmst_json_escape_fd(int fd, const char *s) {
    if (!s) return;
    for (const char *p = s; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '"' || c == '\\') {
            dprintf(fd, "\\%c", c);
        } else if (c == '\n') {
            dprintf(fd, "\n");
        } else if (c == '\r') {
            dprintf(fd, "\r");
        } else if (c == '	') {
            dprintf(fd, "\t");
        } else if (c < 0x20) {
            dprintf(fd, "\\u%04x", (unsigned)c);
        } else {
            dprintf(fd, "%c", c);
        }
    }
}

static void swiftpmst_log_json_event(
    const char *op,
    const char *path,
    const char *decision,
    int err
) {
    if (g_log_path[0] == 0) return;

    // Avoid recursion (logging uses open/write).
    if (g_in_hook) return;
    g_in_hook = 1;

    swiftpmst_resolve_real_functions();

    int fd = real_open(g_log_path, O_CREAT | O_APPEND | O_WRONLY, 0644);
    if (fd >= 0) {
        void *frames[64];
        int nframes = backtrace(frames, 64);
        char **symbols = backtrace_symbols(frames, nframes);

        long long ts = (long long)time(NULL);
        pid_t pid = getpid();

        dprintf(fd, "{\"ts\":%lld,\"pid\":%d,", ts, (int)pid);

        dprintf(fd, "\"op\":");
        if (op) {
            dprintf(fd, "\"");
            swiftpmst_json_escape_fd(fd, op);
            dprintf(fd, "\"");
        } else {
            dprintf(fd, "null");
        }

        dprintf(fd, ",\"path\":");
        if (path) {
            dprintf(fd, "\"");
            swiftpmst_json_escape_fd(fd, path);
            dprintf(fd, "\"");
        } else {
            dprintf(fd, "null");
        }

        dprintf(fd, ",\"decision\":");
        if (decision) {
            dprintf(fd, "\"");
            swiftpmst_json_escape_fd(fd, decision);
            dprintf(fd, "\"");
        } else {
            dprintf(fd, "null");
        }

        dprintf(fd, ",\"errno\":%d,\"bt\":[", err);

        if (symbols) {
            for (int i = 0; i < nframes; i++) {
                if (i) dprintf(fd, ",");
                dprintf(fd, "\"");
                swiftpmst_json_escape_fd(fd, symbols[i] ? symbols[i] : "");
                dprintf(fd, "\"");
            }
        }

        dprintf(fd, "]}\n");
        if (symbols) free(symbols);
        close(fd);
    }

    g_in_hook = 0;
}

// -----------------------------
// SBPL profile
// -----------------------------

// Write-guard profile:
// - allow everything by default
// - allow file-write* only under WORKSPACE_ROOT / SANDBOX_ROOT / system temp
// - deny all other file-write*
//
// NOTE: SBPL evaluation and rule precedence are subtle; keep this profile simple.
// SBPL profile:
// - Start permissive (allow default) to avoid needing an enormous allowlist for reads/frameworks.
// - Deny all file-write* by default.
// - Re-allow file-write* only for workspace and sandbox roots (and optionally system temp if enabled).
//
// NOTE: Rule ordering matters in practice for SBPL. A common working pattern is
// "broad deny, then allow exceptions".
static const char *kSwiftpmstProfileStrict =
    "(version 1)\n"
    "(allow default)\n"
    "(deny file-write*)\n"
    // Allow writing to /dev/null (common sink used by libraries).
    "(allow file-write-data (require-all (path \"/dev/null\") (vnode-type CHARACTER-DEVICE)))\n"
    "(allow file-write*\n"
    "  (subpath (param \"WORKSPACE_ROOT\"))\n"
    "  (subpath (param \"SANDBOX_ROOT\"))\n"
    ")\n";

static const char *kSwiftpmstProfileCompat =
    "(version 1)\n"
    "(allow default)\n"
    "(deny file-write*)\n"
    "(allow file-write-data (require-all (path \"/dev/null\") (vnode-type CHARACTER-DEVICE)))\n"
    "(allow file-write*\n"
    "  (subpath (param \"WORKSPACE_ROOT\"))\n"
    "  (subpath (param \"SANDBOX_ROOT\"))\n"
    "  (subpath \"/tmp\")\n"
    "  (subpath \"/private/tmp\")\n"
    "  (subpath \"/var/tmp\")\n"
    "  (subpath \"/private/var/tmp\")\n"
    "  (subpath \"/var/folders\")\n"
    "  (subpath \"/private/var/folders\")\n"
    ")\n";

static void swiftpmst_apply_seatbelt_or_fail(void) {
    // Apply sandbox profile.
    const char *params[] = {
        "WORKSPACE_ROOT", g_workspace_root,
        "SANDBOX_ROOT", g_sandbox_root,
        NULL
    };

    char *errbuf = NULL;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const char *profile = g_allow_system_tmp ? kSwiftpmstProfileCompat : kSwiftpmstProfileStrict;
    int rc = sandbox_init_with_parameters(profile, 0, params, &errbuf);
#pragma clang diagnostic pop

    if (rc != 0) {
        if (errbuf) {
            swiftpmst_stderr("swiftpm-sandbox-testing", errbuf);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            sandbox_free_error(errbuf);
#pragma clang diagnostic pop
        } else {
            swiftpmst_stderr("swiftpm-sandbox-testing", "sandbox_init_with_parameters failed");
        }

        if (!swiftpmst_allow_unenforced()) {
            // Fail closed by default (a silent failure defeats the purpose).
            _exit(197);
        }
    }
}

// -----------------------------
// Self-test (safe: uses sandbox_check)
// -----------------------------

static void swiftpmst_run_selftest(void) {
    // 1) Confirm sandbox is present.
    int is_sandboxed = sandbox_check(getpid(), NULL, SWIFTPMST_SANDBOX_FILTER_NONE);
    if (is_sandboxed == 0) {
        swiftpmst_stderr("swiftpm-sandbox-testing", "SELFTEST FAILED: process is not sandboxed");
        _exit(198);
    }

    // 2) Confirm file-write* is allowed for the sandbox root (the guard would be unusable otherwise).
    {
        int rc = sandbox_check(getpid(), "file-write*", SWIFTPMST_SANDBOX_FILTER_PATH, g_sandbox_root);
        if (rc != 0) {
            swiftpmst_stderr("swiftpm-sandbox-testing", "SELFTEST FAILED: file-write* appears denied for sandbox root");
            _exit(199);
        }
    }

    // 2) If we have an original HOME, confirm file-write* to that path is denied.
    if (g_orig_home[0]) {
        int rc = sandbox_check(getpid(), "file-write*", SWIFTPMST_SANDBOX_FILTER_PATH, g_orig_home);
        if (rc == 0) {
            swiftpmst_stderr("swiftpm-sandbox-testing", "SELFTEST FAILED: file-write* appears allowed for original HOME");
            _exit(199);
        }
    }

    if (swiftpmst_verbose()) {
        swiftpmst_stderr("swiftpm-sandbox-testing", "SELFTEST OK");
    }
}

// -----------------------------
// Path redirection for redirect mode
// -----------------------------

static void swiftpmst_basename(const char *path, char out[NAME_MAX]) {
    if (!path || !*path) {
        snprintf(out, NAME_MAX, "file");
        return;
    }
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    if (!*base) base = "file";
    snprintf(out, NAME_MAX, "%s", base);
}

static uint64_t swiftpmst_fnv1a64(const char *s) {
    // Simple, dependency-free hash for redirect-path disambiguation.
    const uint64_t prime = 1099511628211ULL;
    uint64_t h = 1469598103934665603ULL;
    if (!s) return h;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        h ^= (uint64_t)(*p);
        h *= prime;
    }
    return h;
}

static void swiftpmst_hex64(uint64_t v, char out[17]) {
    static const char *hex = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        int shift = (15 - i) * 4;
        out[i] = hex[(v >> shift) & 0xF];
    }
    out[16] = 0;
}

static bool swiftpmst_make_redirect_path(const char *orig_abs, char out[PATH_MAX]) {
    if (!g_sandbox_root[0]) return false;

    char base[NAME_MAX];
    swiftpmst_basename(orig_abs, base);

    char hex[17];
    swiftpmst_hex64(swiftpmst_fnv1a64(orig_abs), hex);

    // Keep the basename for readability; prefix with a stable hash to avoid collisions.
    snprintf(out, PATH_MAX, "%s/redirect/%s-%s", g_sandbox_root, hex, base);

    // Ensure parent exists.
    char parent[PATH_MAX];
    snprintf(parent, sizeof(parent), "%s/redirect", g_sandbox_root);
    if (!swiftpmst_mkdir_p(parent, 0755)) return false;
    return true;
}

// -----------------------------
// Interposed functions// -----------------------------
// Interposed functions
// -----------------------------

static int swiftpmst_open_impl(const char *path, int oflag, mode_t mode, bool has_mode) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) {
        if (has_mode) return real_open(path, oflag, mode);
        return real_open(path, oflag);
    }

    if (!g_tripwire_active || !g_tripwire_enabled) {
        if (has_mode) return real_open(path, oflag, mode);
        return real_open(path, oflag);
    }

    g_in_hook = 1;

    const bool is_write = swiftpmst_is_write_open_flags(oflag);
    char abs[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(path, abs);

    if (is_write && abs_ok && !swiftpmst_write_allowed_path_string(abs)) {
        swiftpmst_log_json_event("open", abs, (g_mode == SWIFTPMST_MODE_REDIRECT) ? "redirect" : "deny", EPERM);

        if (g_mode == SWIFTPMST_MODE_REPORT_ONLY) {
            // Fall through.
        } else if (g_mode == SWIFTPMST_MODE_REDIRECT) {
            char redir[PATH_MAX];
            if (swiftpmst_make_redirect_path(abs, redir)) {
                int r;
                if (has_mode) r = real_open(redir, oflag, mode);
                else r = real_open(redir, oflag);
                g_in_hook = 0;
                return r;
            }
        } else {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }

        if (swiftpmst_verbose()) {
            fprintf(stderr, "[swiftpm-sandbox-testing] deny open(write): %s\n", abs);
        }
    }

    int r;
    if (has_mode) r = real_open(path, oflag, mode);
    else r = real_open(path, oflag);

    g_in_hook = 0;
    return r;
}

int swiftpmst_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    bool has_mode = false;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        has_mode = true;
    }
    return swiftpmst_open_impl(path, oflag, mode, has_mode);
}

int swiftpmst_openat(int fd, const char *path, int oflag, ...) {
    swiftpmst_resolve_real_functions();

    mode_t mode = 0;
    bool has_mode = false;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        has_mode = true;
    }

    if (g_in_hook) {
        if (has_mode) return real_openat(fd, path, oflag, mode);
        return real_openat(fd, path, oflag);
    }

    if (!g_tripwire_active || !g_tripwire_enabled) {
        if (has_mode) return real_openat(fd, path, oflag, mode);
        return real_openat(fd, path, oflag);
    }

    g_in_hook = 1;

    const bool is_write = swiftpmst_is_write_open_flags(oflag);
    // Best-effort resolution: if relative, treat as cwd-relative (dirfd-specific resolution is complex).
    char abs[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(path, abs);

    if (is_write && abs_ok && !swiftpmst_write_allowed_path_string(abs)) {
        swiftpmst_log_json_event("openat", abs, (g_mode == SWIFTPMST_MODE_REDIRECT) ? "redirect" : "deny", EPERM);

        if (g_mode == SWIFTPMST_MODE_REDIRECT) {
            char redir[PATH_MAX];
            if (swiftpmst_make_redirect_path(abs, redir)) {
                int r;
                if (has_mode) r = real_openat(fd, redir, oflag, mode);
                else r = real_openat(fd, redir, oflag);
                g_in_hook = 0;
                return r;
            }
        } else if (g_mode == SWIFTPMST_MODE_STRICT) {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }

        if (swiftpmst_verbose()) {
            fprintf(stderr, "[swiftpm-sandbox-testing] deny openat(write): %s\n", abs);
        }
    }

    int r;
    if (has_mode) r = real_openat(fd, path, oflag, mode);
    else r = real_openat(fd, path, oflag);

    g_in_hook = 0;
    return r;
}

int swiftpmst_creat(const char *path, mode_t mode) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) return real_creat(path, mode);
    if (!g_tripwire_active || !g_tripwire_enabled) return real_creat(path, mode);
    g_in_hook = 1;

    char abs[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(path, abs);

    if (abs_ok && !swiftpmst_write_allowed_path_string(abs)) {
        swiftpmst_log_json_event("creat", abs, (g_mode == SWIFTPMST_MODE_REDIRECT) ? "redirect" : "deny", EPERM);

        if (g_mode == SWIFTPMST_MODE_REDIRECT) {
            char redir[PATH_MAX];
            if (swiftpmst_make_redirect_path(abs, redir)) {
                int r = real_creat(redir, mode);
                g_in_hook = 0;
                return r;
            }
        } else if (g_mode == SWIFTPMST_MODE_STRICT) {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }
    }

    int r = real_creat(path, mode);
    g_in_hook = 0;
    return r;
}

int swiftpmst_unlink(const char *path) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) return real_unlink(path);
    if (!g_tripwire_active || !g_tripwire_enabled) return real_unlink(path);
    g_in_hook = 1;

    char abs[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(path, abs);

    if (abs_ok && !swiftpmst_write_allowed_path_string(abs)) {
        swiftpmst_log_json_event("unlink", abs, "deny", EPERM);
        if (g_mode == SWIFTPMST_MODE_STRICT) {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }
    }

    int r = real_unlink(path);
    g_in_hook = 0;
    return r;
}

int swiftpmst_rename(const char *old, const char *newp) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) return real_rename(old, newp);
    if (!g_tripwire_active || !g_tripwire_enabled) return real_rename(old, newp);
    g_in_hook = 1;

    char abs_new[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(newp, abs_new);

    if (abs_ok && !swiftpmst_write_allowed_path_string(abs_new)) {
        swiftpmst_log_json_event("rename", abs_new, "deny", EPERM);
        if (g_mode == SWIFTPMST_MODE_STRICT) {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }
    }

    int r = real_rename(old, newp);
    g_in_hook = 0;
    return r;
}

int swiftpmst_mkdir(const char *path, mode_t mode) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) return real_mkdir(path, mode);
    if (!g_tripwire_active || !g_tripwire_enabled) return real_mkdir(path, mode);
    g_in_hook = 1;

    char abs[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(path, abs);

    if (abs_ok && !swiftpmst_write_allowed_path_string(abs)) {
        swiftpmst_log_json_event("mkdir", abs, "deny", EPERM);
        if (g_mode == SWIFTPMST_MODE_STRICT) {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }
    }

    int r = real_mkdir(path, mode);
    g_in_hook = 0;
    return r;
}

int swiftpmst_rmdir(const char *path) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) return real_rmdir(path);
    if (!g_tripwire_active || !g_tripwire_enabled) return real_rmdir(path);
    g_in_hook = 1;

    char abs[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(path, abs);

    if (abs_ok && !swiftpmst_write_allowed_path_string(abs)) {
        swiftpmst_log_json_event("rmdir", abs, "deny", EPERM);
        if (g_mode == SWIFTPMST_MODE_STRICT) {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }
    }

    int r = real_rmdir(path);
    g_in_hook = 0;
    return r;
}

int swiftpmst_truncate(const char *path, off_t length) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) return real_truncate(path, length);
    if (!g_tripwire_active || !g_tripwire_enabled) return real_truncate(path, length);
    g_in_hook = 1;

    char abs[PATH_MAX];
    bool abs_ok = swiftpmst_make_abs_path(path, abs);

    if (abs_ok && !swiftpmst_write_allowed_path_string(abs)) {
        swiftpmst_log_json_event("truncate", abs, "deny", EPERM);
        if (g_mode == SWIFTPMST_MODE_STRICT) {
            errno = EPERM;
            g_in_hook = 0;
            return -1;
        }
    }

    int r = real_truncate(path, length);
    g_in_hook = 0;
    return r;
}

int swiftpmst_ftruncate(int fd, off_t length) {
    swiftpmst_resolve_real_functions();

    if (g_in_hook) return real_ftruncate(fd, length);
    if (!g_tripwire_active || !g_tripwire_enabled) return real_ftruncate(fd, length);
    g_in_hook = 1;

    // For simplicity, do not attempt to map fd -> path; rely on Seatbelt for true enforcement.
    // Still log the mutation attempt.
    swiftpmst_log_json_event("ftruncate", "<fd>", (g_mode == SWIFTPMST_MODE_STRICT) ? "allow" : "allow", 0);

    int r = real_ftruncate(fd, length);
    g_in_hook = 0;
    return r;
}

// dyld interposing table
struct swiftpmst_interpose {
    const void *replacement;
    const void *replacee;
};

#define SWIFTPMST_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static const struct swiftpmst_interpose swiftpmst_interpose_##_replacee \
        __attribute__((section("__DATA,__interpose"))) = { \
            (const void *)(unsigned long)&_replacement, \
            (const void *)(unsigned long)&_replacee \
        };

SWIFTPMST_INTERPOSE(swiftpmst_open, open)
SWIFTPMST_INTERPOSE(swiftpmst_openat, openat)
SWIFTPMST_INTERPOSE(swiftpmst_creat, creat)
SWIFTPMST_INTERPOSE(swiftpmst_unlink, unlink)
SWIFTPMST_INTERPOSE(swiftpmst_rename, rename)
SWIFTPMST_INTERPOSE(swiftpmst_mkdir, mkdir)
SWIFTPMST_INTERPOSE(swiftpmst_rmdir, rmdir)
SWIFTPMST_INTERPOSE(swiftpmst_truncate, truncate)
SWIFTPMST_INTERPOSE(swiftpmst_ftruncate, ftruncate)

// -----------------------------
// Bootstrap (constructor)
// -----------------------------

__attribute__((constructor))
static void swiftpmst_bootstrap(void) {
    if (swiftpmst_is_disabled()) return;

    swiftpmst_resolve_real_functions();

    g_mode = swiftpmst_parse_mode();
    g_allow_system_tmp = swiftpmst_allow_system_tmp();
    g_tripwire_enabled = swiftpmst_tripwire_enabled();

    // Determine workspace root.
    if (!swiftpmst_determine_workspace_root(g_workspace_root)) {
        swiftpmst_stderr("swiftpm-sandbox-testing", "could not determine workspace root (Package.swift not found). Set SWIFTPM_SANDBOX_WORKSPACE_ROOT to override.");
        if (!swiftpmst_allow_unenforced()) _exit(196);
        return;
    }

    // Capture original HOME before redirecting.
    const char *home = getenv("HOME");
    if (home && *home) snprintf(g_orig_home, sizeof(g_orig_home), "%s", home);

    // Build sandbox root under .build.
    char run_id[64];
    swiftpmst_build_run_id(run_id);
    snprintf(g_sandbox_root, sizeof(g_sandbox_root), "%s/.build/swiftpm-sandbox-testing/%s", g_workspace_root, run_id);
    snprintf(g_fake_home, sizeof(g_fake_home), "%s/home", g_sandbox_root);
    snprintf(g_fake_tmp, sizeof(g_fake_tmp), "%s/tmp", g_sandbox_root);
    snprintf(g_log_path, sizeof(g_log_path), "%s/logs/events.jsonl", g_sandbox_root);

    // Create directories (before applying sandbox).
    if (!swiftpmst_mkdir_p(g_sandbox_root, 0755) ||
        !swiftpmst_mkdir_p(g_fake_home, 0755) ||
        !swiftpmst_mkdir_p(g_fake_tmp, 0755)) {
        swiftpmst_stderr("swiftpm-sandbox-testing", "failed to create sandbox directories under .build");
        if (!swiftpmst_allow_unenforced()) _exit(195);
        return;
    }
    {
        char logs_dir[PATH_MAX];
        snprintf(logs_dir, sizeof(logs_dir), "%s/logs", g_sandbox_root);
        (void)swiftpmst_mkdir_p(logs_dir, 0755);
    }

    // Redirect home and temp.
    setenv("HOME", g_fake_home, 1);
    setenv("CFFIXED_USER_HOME", g_fake_home, 1);
    setenv("TMPDIR", g_fake_tmp, 1);

    if (swiftpmst_verbose()) {
        fprintf(stderr, "[swiftpm-sandbox-testing] workspace=%s\n", g_workspace_root);
        fprintf(stderr, "[swiftpm-sandbox-testing] sandbox=%s\n", g_sandbox_root);
    }

        // Activate tripwire enforcement for subsequent filesystem mutations.
    g_tripwire_active = true;

    // Apply Seatbelt sandbox (kernel write-guard).
    swiftpmst_apply_seatbelt_or_fail();

    // Always emit a startup marker so the sandbox root is discoverable.
    swiftpmst_log_json_event("bootstrap", g_sandbox_root, "ok", 0);

    // Optional self-test (safe: sandbox_check only).
    if (swiftpmst_selftest_enabled()) {
        swiftpmst_run_selftest();
    }
}

#else

// Non-Apple platforms: no-op.
__attribute__((constructor))
static void swiftpmst_bootstrap_nonapple(void) {}

#endif

// Linker anchor:
// SwiftPM compiles C targets into static libraries, and the linker will only pull in
// object files that satisfy referenced symbols. The sandbox bootstrap is driven by a
// constructor in this translation unit, so we expose a tiny symbol that Swift code
// can reference to force this object file to be linked in.
void swiftpmst_force_link(void) {}
