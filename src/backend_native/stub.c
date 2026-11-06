/*
 * Native file-system stub for the MoonBit append-only log backend.
 *
 * The MoonBit side passes file paths as UTF-8 `Bytes` and data buffers as
 * `Bytes`; lengths are read from the MoonBit object header via
 * `Moonbit_array_length`. Errors are reported as negative return values.
 */

#include <moonbit.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <dirent.h>
#include <sys/file.h>
#include <sys/stat.h>

static char *moonlog_c_path(moonbit_bytes_t path) {
  int32_t len = Moonbit_array_length(path);
  char *p = (char *)malloc((size_t)len + 1);
  if (p == NULL) {
    return NULL;
  }
  if (len > 0) {
    memcpy(p, path, (size_t)len);
  }
  p[len] = '\0';
  return p;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_open_rw(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  int fd = open(p, O_RDWR | O_CREAT, 0644);
  free(p);
  return fd;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_open_ro(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  int fd = open(p, O_RDONLY);
  free(p);
  return fd;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonlog_pread(int32_t fd, int64_t offset, int32_t len) {
  if (len < 0) {
    len = 0;
  }
  moonbit_bytes_t buf = moonbit_make_bytes_raw(len);
  if (len == 0) {
    return buf;
  }
  ssize_t n = pread(fd, buf, (size_t)len, (off_t)offset);
  if (n < 0) {
    n = 0;
  }
  if ((int32_t)n != len) {
    moonbit_bytes_t out = moonbit_make_bytes_raw((int32_t)n);
    if (n > 0) {
      memcpy(out, buf, (size_t)n);
    }
    return out;
  }
  return buf;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_pwrite(int32_t fd, int64_t offset, moonbit_bytes_t data) {
  int32_t len = Moonbit_array_length(data);
  ssize_t n = pwrite(fd, data, (size_t)len, (off_t)offset);
  return (int32_t)n;
}

MOONBIT_FFI_EXPORT
int64_t moonlog_size(int32_t fd) {
  struct stat st;
  if (fstat(fd, &st) != 0) {
    return -1;
  }
  return (int64_t)st.st_size;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_fsync(int32_t fd) {
  return (int32_t)fsync(fd);
}

MOONBIT_FFI_EXPORT
int32_t moonlog_close(int32_t fd) {
  return (int32_t)close(fd);
}

MOONBIT_FFI_EXPORT
int32_t moonlog_remove(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  int r = remove(p);
  free(p);
  return r;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_mkdir(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  int r = mkdir(p, 0755);
  free(p);
  return r;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_exists(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return 0;
  }
  int r = access(p, F_OK) == 0 ? 1 : 0;
  free(p);
  return r;
}

/*
 * Crash-recovery helpers.
 */

MOONBIT_FFI_EXPORT
int32_t moonlog_truncate(int32_t fd, int64_t size) {
  return (int32_t)ftruncate(fd, (off_t)size);
}

MOONBIT_FFI_EXPORT
int64_t moonlog_opendir(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  DIR *d = opendir(p);
  free(p);
  if (d == NULL) {
    return -1;
  }
  return (int64_t)(intptr_t)d;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonlog_readdir(int64_t handle) {
  DIR *d = (DIR *)handle;
  if (d == NULL) {
    return moonbit_make_bytes_raw(0);
  }
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    const char *name = ent->d_name;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
      continue;
    }
    size_t len = strlen(name);
    moonbit_bytes_t out = moonbit_make_bytes_raw((int32_t)len);
    memcpy(out, name, len);
    return out;
  }
  return moonbit_make_bytes_raw(0);
}

MOONBIT_FFI_EXPORT
int32_t moonlog_closedir(int64_t handle) {
  DIR *d = (DIR *)handle;
  if (d == NULL) {
    return 0;
  }
  return (int32_t)closedir(d);
}

/*
 * Whole-file helpers for persisted metadata (manifest / segment indexes).
 */

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonlog_read_file(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return moonbit_make_bytes_raw(0);
  }
  int fd = open(p, O_RDONLY);
  free(p);
  if (fd < 0) {
    return moonbit_make_bytes_raw(0);
  }
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size <= 0) {
    close(fd);
    return moonbit_make_bytes_raw(0);
  }
  int32_t len = (int32_t)st.st_size;
  moonbit_bytes_t buf = moonbit_make_bytes_raw(len);
  ssize_t n = read(fd, buf, (size_t)len);
  close(fd);
  if (n < 0) {
    return moonbit_make_bytes_raw(0);
  }
  if ((int32_t)n != len) {
    moonbit_bytes_t out = moonbit_make_bytes_raw((int32_t)n);
    if (n > 0) {
      memcpy(out, buf, (size_t)n);
    }
    return out;
  }
  return buf;
}

MOONBIT_FFI_EXPORT
int64_t moonlog_mtime_ns(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  struct stat st;
  if (stat(p, &st) != 0) {
    free(p);
    return -1;
  }
  free(p);
  return (int64_t)st.st_mtim.tv_sec * 1000000000 + (int64_t)st.st_mtim.tv_nsec;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_write_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  free(p);
  if (fd < 0) {
    return -1;
  }
  int32_t len = Moonbit_array_length(data);
  ssize_t n = write(fd, data, (size_t)len);
  int r = fsync(fd);
  close(fd);
  (void)r;
  if (n < 0 || (int32_t)n != len) {
    return -1;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  char *a = moonlog_c_path(from);
  char *b = moonlog_c_path(to);
  if (a == NULL || b == NULL) {
    free(a);
    free(b);
    return -1;
  }
  int r = rename(a, b);
  free(a);
  free(b);
  return r;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_flock(int32_t fd, int32_t exclusive) {
  int op = exclusive ? LOCK_EX : LOCK_SH;
  return (int32_t)flock(fd, op | LOCK_NB);
}

MOONBIT_FFI_EXPORT
int32_t moonlog_sleep_ms(int32_t ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  return (int32_t)nanosleep(&ts, NULL);
}

/*
 * Cold-tier support: a cold segment lives in another directory and the main
 * path becomes a symlink to it, so every existing reader keeps working.
 */

MOONBIT_FFI_EXPORT
int32_t moonlog_symlink(moonbit_bytes_t target, moonbit_bytes_t link_path) {
  char *t = moonlog_c_path(target);
  char *l = moonlog_c_path(link_path);
  if (t == NULL || l == NULL) {
    free(t);
    free(l);
    return -1;
  }
  int r = symlink(t, l);
  free(t);
  free(l);
  return r < 0 ? -1 : 0;
}

MOONBIT_FFI_EXPORT
int32_t moonlog_is_symlink(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return 0;
  }
  struct stat st;
  int r = lstat(p, &st);
  free(p);
  return (r == 0 && S_ISLNK(st.st_mode)) ? 1 : 0;
}

/*
 * Remove a path; when it is a symlink, also remove the file it points at
 * (used when a cold segment is pruned so the cold copy does not linger).
 */
MOONBIT_FFI_EXPORT
int32_t moonlog_remove_with_link(moonbit_bytes_t path) {
  char *p = moonlog_c_path(path);
  if (p == NULL) {
    return -1;
  }
  char target[4096];
  target[0] = 0;
  struct stat st;
  if (lstat(p, &st) == 0 && S_ISLNK(st.st_mode)) {
    ssize_t n = readlink(p, target, sizeof(target) - 1);
    if (n > 0) {
      target[n] = 0;
    }
  }
  int r = unlink(p);
  if (target[0] != 0) {
    unlink(target);
  }
  free(p);
  return r;
}