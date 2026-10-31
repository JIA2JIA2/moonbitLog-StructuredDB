/*
 * Native file-system stub for the MoonBit append-only log backend.
 *
 * The MoonBit side passes file paths as UTF-8 `Bytes` and data buffers as
 * `Bytes`; lengths are read from the MoonBit object header via
 * `Moonbit_array_length`. Errors are reported as negative return values.
 */

#include <moonbit.h>

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
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