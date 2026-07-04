#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define I2C_SLAVE 0x0703
#define MCU_SLAVE 0x7e
#define CRC_POLY 0x04c11db7U

#define REG_APP_CODE_CRC    0x4f000200U
#define REG_APP_DATA_CRC    0x4f000204U
#define REG_LOADER_CODE_CRC 0x4f000208U
#define REG_LOADER_DATA_CRC 0x4f00020cU
#define REG_DDR_RAW         0x40000108U
#define REG_DDR_DERIVED     0x40000120U

struct fw_map {
  uint32_t code_start;
  uint32_t code_end;
  uint32_t data_start;
  uint32_t data_end;
};

struct fw_image {
  const char *path;
  unsigned char *data;
  size_t len;
  struct fw_map map;
  uint32_t code_crc;
  uint32_t data_crc;
};

struct mcu {
  int fd;
  int bus;
};

static int verbose = 1;
static unsigned int reset_delay_ms = 200;
static unsigned int probe_window_ms = 2500;
static unsigned int entry_retry_ms = 0;
static int reopen_after_reset = 0;
static int skip_gpio_prep = 0;
static int stock_write_compat = 0;

static int load_mcu(struct mcu *m, const struct fw_image *app, const struct fw_image *loader);

static void msleep(unsigned int ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
}

static int parse_u32(const char *s, uint32_t *out) {
  char *end = NULL;
  unsigned long v;
  if (!s || !*s) return 0;
  errno = 0;
  v = strtoul(s, &end, 0);
  if (errno || !end || v > 0xffffffffUL) return 0;
  while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n') end++;
  if (*end) return 0;
  *out = (uint32_t)v;
  return 1;
}

static int read_full(int fd, unsigned char *buf, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = read(fd, buf + done, len - done);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    done += (size_t)n;
  }
  return 0;
}

static int write_full(int fd, const unsigned char *buf, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, buf + done, len - done);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    done += (size_t)n;
  }
  return 0;
}

static uint32_t get_le32(const unsigned char *p) {
  return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint32_t fw_crc_words(const unsigned char *p, uint32_t words) {
  uint32_t crc = 0xffffffffU;
  for (uint32_t i = 0; i < words; i++) {
    uint32_t word = get_le32(p + (size_t)i * 4);
    uint32_t mask = 0x80000000U;
    for (int bit = 0; bit < 32; bit++) {
      if (crc & 0x80000000U) crc = (crc << 1) ^ CRC_POLY;
      else crc <<= 1;
      if (word & mask) crc ^= CRC_POLY;
      mask >>= 1;
    }
  }
  return crc;
}

static int load_file(const char *path, unsigned char **data, size_t *len) {
  int fd = -1;
  struct stat st;
  unsigned char *buf = NULL;
  fd = open(path, O_RDONLY);
  if (fd < 0) {
    fprintf(stderr, "open %s: %s\n", path, strerror(errno));
    return -1;
  }
  if (fstat(fd, &st) < 0 || st.st_size <= 0) {
    fprintf(stderr, "stat %s: %s\n", path, strerror(errno));
    close(fd);
    return -1;
  }
  buf = (unsigned char *)malloc((size_t)st.st_size);
  if (!buf) {
    fprintf(stderr, "malloc %s: %s\n", path, strerror(errno));
    close(fd);
    return -1;
  }
  if (read_full(fd, buf, (size_t)st.st_size) < 0) {
    fprintf(stderr, "read %s: %s\n", path, strerror(errno));
    free(buf);
    close(fd);
    return -1;
  }
  close(fd);
  *data = buf;
  *len = (size_t)st.st_size;
  return 0;
}

static int load_map(const char *path, struct fw_map *m) {
  FILE *f = fopen(path, "r");
  char line[128];
  uint32_t vals[4];
  int n = 0;
  if (!f) {
    fprintf(stderr, "open %s: %s\n", path, strerror(errno));
    return -1;
  }
  while (n < 4 && fgets(line, sizeof(line), f)) {
    if (parse_u32(line, &vals[n])) n++;
  }
  fclose(f);
  if (n != 4 || vals[1] < vals[0] || vals[3] < vals[2]) {
    fprintf(stderr, "invalid map %s\n", path);
    return -1;
  }
  m->code_start = vals[0];
  m->code_end = vals[1];
  m->data_start = vals[2];
  m->data_end = vals[3];
  return 0;
}

static int prepare_image(struct fw_image *img, const char *bin, const char *txt, int app_layout) {
  uint32_t code_size, data_size, code_off, data_off;
  img->path = bin;
  if (load_file(bin, &img->data, &img->len) < 0) return -1;
  if (load_map(txt, &img->map) < 0) return -1;

  code_size = img->map.code_end - img->map.code_start;
  data_size = img->map.data_end - img->map.data_start;
  code_off = app_layout ? (img->map.code_start - img->map.data_start) : 0;
  data_off = app_layout ? 0 : (img->map.data_start - img->map.code_start);

  if ((code_size & 3) || (data_size & 3) ||
      (size_t)code_off + code_size > img->len ||
      (size_t)data_off + data_size > img->len) {
    fprintf(stderr, "invalid image layout for %s\n", bin);
    return -1;
  }
  img->code_crc = fw_crc_words(img->data + code_off, code_size >> 2);
  img->data_crc = fw_crc_words(img->data + data_off, data_size >> 2);
  return 0;
}

static int mcu_open_bus(int bus, struct mcu *m) {
  char path[32];
  snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
  m->fd = open(path, O_RDWR);
  m->bus = bus;
  if (m->fd < 0) return -1;
  if (ioctl(m->fd, I2C_SLAVE, MCU_SLAVE) < 0) {
    close(m->fd);
    m->fd = -1;
    return -1;
  }
  return 0;
}

static void mcu_close(struct mcu *m) {
  if (m->fd >= 0) close(m->fd);
  m->fd = -1;
}

static int mcu_read(struct mcu *m, uint32_t reg, uint32_t *value) {
  unsigned char addr[4] = {
    (unsigned char)(reg >> 24), (unsigned char)(reg >> 16),
    (unsigned char)(reg >> 8), (unsigned char)reg
  };
  unsigned char data[4];
  for (int attempt = 0; attempt < 3; attempt++) {
    if (write_full(m->fd, addr, sizeof(addr)) == 0 &&
        read_full(m->fd, data, sizeof(data)) == 0) {
      *value = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16) |
               ((uint32_t)data[2] << 8) | (uint32_t)data[3];
      return 0;
    }
    msleep(1);
  }
  return -1;
}

static int mcu_write_strict(struct mcu *m, uint32_t reg, uint32_t value) {
  unsigned char data[8] = {
    (unsigned char)(reg >> 24), (unsigned char)(reg >> 16),
    (unsigned char)(reg >> 8), (unsigned char)reg,
    (unsigned char)(value >> 24), (unsigned char)(value >> 16),
    (unsigned char)(value >> 8), (unsigned char)value
  };
  return write_full(m->fd, data, sizeof(data));
}

static int mcu_write(struct mcu *m, uint32_t reg, uint32_t value) {
  unsigned char data[8] = {
    (unsigned char)(reg >> 24), (unsigned char)(reg >> 16),
    (unsigned char)(reg >> 8), (unsigned char)reg,
    (unsigned char)(value >> 24), (unsigned char)(value >> 16),
    (unsigned char)(value >> 8), (unsigned char)value
  };
  if (stock_write_compat) {
    ssize_t n;
    errno = 0;
    n = write(m->fd, data, sizeof(data));
    if (n != (ssize_t)sizeof(data) && verbose) {
      fprintf(stderr, "stock-write-compat write reg=0x%08x value=0x%08x n=%ld errno=%d %s\n",
              reg, value, (long)n, errno, strerror(errno));
    }
    return errno == ETIMEDOUT ? -1 : 0;
  }
  return write_full(m->fd, data, sizeof(data));
}

static int mcu_write_block4_strict(struct mcu *m, uint32_t reg, const unsigned char *p) {
  unsigned char data[8] = {
    (unsigned char)(reg >> 24), (unsigned char)(reg >> 16),
    (unsigned char)(reg >> 8), (unsigned char)reg,
    p[3], p[2], p[1], p[0]
  };
  return write_full(m->fd, data, sizeof(data));
}

static int mcu_write_block4(struct mcu *m, uint32_t reg, const unsigned char *p) {
  unsigned char data[8] = {
    (unsigned char)(reg >> 24), (unsigned char)(reg >> 16),
    (unsigned char)(reg >> 8), (unsigned char)reg,
    p[3], p[2], p[1], p[0]
  };
  if (stock_write_compat) {
    ssize_t n;
    errno = 0;
    n = write(m->fd, data, sizeof(data));
    if (n != (ssize_t)sizeof(data) && verbose) {
      fprintf(stderr, "stock-write-compat block reg=0x%08x n=%ld errno=%d %s\n",
              reg, (long)n, errno, strerror(errno));
    }
    return errno == ETIMEDOUT ? -1 : 0;
  }
  return mcu_write_block4_strict(m, reg, p);
}

static int mcu_write_checked(struct mcu *m, uint32_t reg, uint32_t value, const char *tag) {
  if (mcu_write(m, reg, value) < 0) {
    fprintf(stderr, "write failed %s reg=0x%08x value=0x%08x errno=%d %s\n",
            tag, reg, value, errno, strerror(errno));
    return -1;
  }
  if (verbose) fprintf(stderr, "write ok %s reg=0x%08x value=0x%08x\n", tag, reg, value);
  return 0;
}

static int looks_like_crc(uint32_t v) {
  return v != 0U && v != 0xffffffffU && v != 0xaaaaaaaaU;
}

static int detect_mcu(struct mcu *m, int bus_override, int allow_probe_write) {
  int start = bus_override >= 0 ? bus_override : 0;
  int end = bus_override >= 0 ? bus_override : 2;
  for (int bus = start; bus <= end; bus++) {
    uint32_t v = 0;
    uint32_t c0 = 0, c1 = 0;
    if (mcu_open_bus(bus, m) < 0) continue;
    errno = 0;
    if (allow_probe_write &&
        mcu_write(m, 0x4f000230U, 0xaaaaaaaaU) == 0 &&
        mcu_read(m, 0x4f000230U, &v) == 0 && v == 0xaaaaaaaaU) {
      if (verbose) fprintf(stderr, "mcu bus=%d slave=0x%02x\n", bus, MCU_SLAVE);
      return 0;
    }
    if (!allow_probe_write &&
        mcu_read(m, REG_APP_CODE_CRC, &c0) == 0 &&
        mcu_read(m, REG_LOADER_CODE_CRC, &c1) == 0 &&
        looks_like_crc(c0) && looks_like_crc(c1)) {
      if (verbose) fprintf(stderr, "mcu bus=%d slave=0x%02x\n", bus, MCU_SLAVE);
      return 0;
    }
    mcu_close(m);
  }
  fprintf(stderr, "no MCU I2C downloader found\n");
  return -1;
}

static void set_thread_name_for_bus(int bus) {
  char name[16];
  snprintf(name, sizeof(name), "%d/MCUDownloader", bus);
  (void)prctl(PR_SET_NAME, name, 0, 0, 0);
}

static int run_reset_echo(int reset, int value) {
  char cmd[160];
  FILE *fp;
  snprintf(cmd, sizeof(cmd), "echo %d > /sys/class/leds/reset%d/brightness", value, reset);
  if (verbose) fprintf(stderr, "reset%d=%d\n", reset, value);
  fp = popen(cmd, "r");
  if (!fp) {
    if (verbose) fprintf(stderr, "warning: popen failed: %s: %s\n", cmd, strerror(errno));
    return -1;
  }
  if (pclose(fp) < 0) {
    if (verbose) fprintf(stderr, "warning: pclose failed: %s: %s\n", cmd, strerror(errno));
    return -1;
  }
  return 0;
}

static int write_text_file(const char *path, const char *text) {
  int fd = open(path, O_WRONLY);
  size_t len = strlen(text);
  if (fd < 0) return -1;
  if (write_full(fd, (const unsigned char *)text, len) < 0) {
    close(fd);
    return -1;
  }
  close(fd);
  return 0;
}

static int read_gpio_value(int gpio) {
  char path[80];
  char buf[4] = {0, 0, 0, 0};
  int fd;
  snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/value", gpio);
  fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  if (read(fd, buf, 3) < 0) {
    close(fd);
    return -1;
  }
  close(fd);
  return atoi(buf);
}

static void stock_gpio_probe_prep(void) {
  static const int gpios[] = {96, 97, 98};
  char text[16], path[80];
  if (skip_gpio_prep) return;
  for (unsigned int i = 0; i < sizeof(gpios) / sizeof(gpios[0]); i++) {
    int gpio = gpios[i];
    snprintf(text, sizeof(text), "%d", gpio);
    if (write_text_file("/sys/class/gpio/unexport", text) < 0 && verbose) {
      fprintf(stderr, "gpio%d unexport skipped/failed: %s\n", gpio, strerror(errno));
    }
    usleep(1000);
    if (write_text_file("/sys/class/gpio/export", text) < 0 && verbose) {
      fprintf(stderr, "gpio%d export skipped/failed: %s\n", gpio, strerror(errno));
    }
    snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/direction", gpio);
    if (write_text_file(path, "in") < 0 && verbose) {
      fprintf(stderr, "gpio%d direction=in failed: %s\n", gpio, strerror(errno));
    }
    usleep(0x2710);
    if (verbose) fprintf(stderr, "gpio%d value=%d\n", gpio, read_gpio_value(gpio));
  }
}

static int led_reset_pulse(int bus) {
  int reset = bus + 1;
  set_thread_name_for_bus(bus);
  run_reset_echo(reset, 0);
  msleep(reset_delay_ms);
  run_reset_echo(reset, 1);
  msleep(reset_delay_ms);
  return 0;
}

static void led_reset_pulse_range(int bus_override) {
  if (bus_override >= 0) {
    led_reset_pulse(bus_override);
    return;
  }
  for (int bus = 0; bus <= 2; bus++) led_reset_pulse(bus);
}

static int crcs_match(struct mcu *m, const struct fw_image *app, const struct fw_image *loader) {
  uint32_t a0 = 0, a1 = 0, l0 = 0, l1 = 0;
  if (mcu_read(m, REG_APP_CODE_CRC, &a0) < 0 || mcu_read(m, REG_APP_DATA_CRC, &a1) < 0 ||
      mcu_read(m, REG_LOADER_CODE_CRC, &l0) < 0 || mcu_read(m, REG_LOADER_DATA_CRC, &l1) < 0) {
    return 0;
  }
  printf("crc live app_code=0x%08x app_data=0x%08x loader_code=0x%08x loader_data=0x%08x\n",
         a0, a1, l0, l1);
  printf("crc want app_code=0x%08x app_data=0x%08x loader_code=0x%08x loader_data=0x%08x\n",
         app->code_crc, app->data_crc, loader->code_crc, loader->data_crc);
  return a0 == app->code_crc && a1 == app->data_crc &&
         l0 == loader->code_crc && l1 == loader->data_crc;
}

static int detect_downloader_with_stock_reset(struct mcu *m, int bus_override) {
  int start = bus_override >= 0 ? bus_override : 0;
  int end = bus_override >= 0 ? bus_override : 2;

  stock_gpio_probe_prep();

  for (int bus = start; bus <= end; bus++) {
    uint32_t v = 0;
    if (mcu_open_bus(bus, m) < 0) {
      if (verbose) fprintf(stderr, "bus %d open/ioctl failed: %s\n", bus, strerror(errno));
      continue;
    }

    led_reset_pulse(bus);
    if (reopen_after_reset) {
      mcu_close(m);
      msleep(20);
      if (mcu_open_bus(bus, m) < 0) {
        if (verbose) fprintf(stderr, "bus %d reopen after reset failed: %s\n", bus, strerror(errno));
        continue;
      }
    }
    for (unsigned int elapsed = 0; elapsed <= probe_window_ms; elapsed += 50) {
      errno = 0;
      if (mcu_write(m, 0x4f000230U, 0xaaaaaaaaU) == 0 &&
          mcu_read(m, 0x4f000230U, &v) == 0) {
        if (verbose) fprintf(stderr, "bus %d scratch=0x%08x after %ums\n", bus, v, elapsed);
        if (v == 0xaaaaaaaaU) {
          if (verbose) fprintf(stderr, "mcu downloader bus=%d slave=0x%02x\n", bus, MCU_SLAVE);
          return 0;
        }
      } else if (verbose && elapsed == 0) {
        fprintf(stderr, "bus %d scratch probe failed: %s\n", bus, strerror(errno));
      }
      msleep(50);
    }

    mcu_close(m);
  }

  fprintf(stderr, "no MCU I2C downloader found after stock reset/probe sequence\n");
  return -1;
}

static int try_load_after_stock_reset(int bus_override, const struct fw_image *app,
                                      const struct fw_image *loader) {
  int start = bus_override >= 0 ? bus_override : 0;
  int end = bus_override >= 0 ? bus_override : 2;

  stock_gpio_probe_prep();

  for (int bus = start; bus <= end; bus++) {
    uint32_t scratch = 0;
    struct mcu trial = {-1, -1};
    if (mcu_open_bus(bus, &trial) < 0) {
      if (verbose) fprintf(stderr, "bus %d open/ioctl failed before load try: %s\n", bus, strerror(errno));
      continue;
    }

    led_reset_pulse(bus);
    if (reopen_after_reset) {
      mcu_close(&trial);
      msleep(20);
      if (mcu_open_bus(bus, &trial) < 0) {
        if (verbose) fprintf(stderr, "bus %d reopen after reset failed before load try: %s\n", bus, strerror(errno));
        continue;
      }
    }

    if (mcu_write(&trial, 0x4f000230U, 0xaaaaaaaaU) == 0 &&
        mcu_read(&trial, 0x4f000230U, &scratch) == 0) {
      if (verbose) fprintf(stderr, "bus %d scratch before load=0x%08x\n", bus, scratch);
    } else if (verbose) {
      fprintf(stderr, "bus %d scratch before load failed; trying load anyway: %s\n", bus, strerror(errno));
    }

    if (load_mcu(&trial, app, loader) == 0) {
      printf("firmware loaded on bus %d after reset\n", bus);
      mcu_close(&trial);
      return 0;
    }
    if (verbose) fprintf(stderr, "bus %d load attempt failed\n", bus);
    mcu_close(&trial);
  }

  return -1;
}

static int write_app(struct mcu *m, const struct fw_image *img) {
  uint32_t code_off = img->map.code_start - img->map.data_start;
  uint32_t code_addr = img->map.code_start;
  uint32_t data_addr = img->map.data_start;
  uint32_t data_size = img->map.data_end - img->map.data_start;
  if (verbose) fprintf(stderr, "writing app code/data from %s\n", img->path);
  for (uint32_t off = code_off; off < img->len; off += 4) {
    if (mcu_write_block4(m, data_addr + off, img->data + off) < 0) return -1;
    if (verbose && ((off - code_off) % 0x4000U) == 0) fprintf(stderr, ".");
  }
  for (uint32_t off = 0; off < data_size; off += 4) {
    if (mcu_write_block4(m, data_addr + off, img->data + off) < 0) return -1;
  }
  (void)code_addr;
  if (verbose) fprintf(stderr, "\n");
  return 0;
}

static int write_loader(struct mcu *m, const struct fw_image *img) {
  uint32_t code_size = img->map.code_end - img->map.code_start;
  uint32_t data_off = img->map.data_start - img->map.code_start;
  if (verbose) fprintf(stderr, "writing loader code/data from %s\n", img->path);
  for (uint32_t off = 0; off < code_size; off += 4) {
    if (mcu_write_block4(m, img->map.code_start + off, img->data + off) < 0) return -1;
  }
  for (uint32_t off = data_off; off < img->len; off += 4) {
    if (mcu_write_block4(m, img->map.code_start + off, img->data + off) < 0) return -1;
    if (verbose && ((off - data_off) % 0x4000U) == 0) fprintf(stderr, ".");
  }
  if (verbose) fprintf(stderr, "\n");
  return 0;
}

static int load_mcu(struct mcu *m, const struct fw_image *app, const struct fw_image *loader) {
  uint32_t app_code_size = app->map.code_end - app->map.code_start;
  uint32_t app_data_size = app->map.data_end - app->map.data_start;
  uint32_t loader_code_size = loader->map.code_end - loader->map.code_start;
  uint32_t loader_data_size = loader->map.data_end - loader->map.data_start;
  uint32_t v = 0;

  if (entry_retry_ms > 0) {
    unsigned int elapsed;
    int ok = 0;
    for (elapsed = 0; elapsed <= entry_retry_ms; elapsed += 10) {
      errno = 0;
      if (mcu_write_strict(m, 0x40000080U, 0x00008413U) == 0) {
        if (verbose) fprintf(stderr, "write ok entry reg=0x40000080 value=0x00008413 after %ums\n", elapsed);
        ok = 1;
        break;
      }
      if (verbose && elapsed == 0) {
        fprintf(stderr, "entry retry initial failure errno=%d %s\n", errno, strerror(errno));
      }
      usleep(10000);
    }
    if (!ok) {
      fprintf(stderr, "write failed entry reg=0x40000080 value=0x00008413 after retry %ums errno=%d %s\n",
              entry_retry_ms, errno, strerror(errno));
      return -1;
    }
  } else if (mcu_write_checked(m, 0x40000080U, 0x00008413U, "entry") < 0) return -1;
  if (mcu_write_checked(m, 0x400000a4U, 0xffff0000U, "mask") < 0) return -1;
  if (mcu_write_checked(m, 0x400000a0U, 0x00000fefU, "boot0") < 0) return -1;
  if (mcu_write_checked(m, 0x400000a0U, 0x00001fefU, "boot1") < 0) return -1;
  if (mcu_write_checked(m, 0x4f000210U, app_code_size >> 2, "app_code_words") < 0) return -1;
  if (mcu_write_checked(m, 0x4f000214U, app_data_size >> 2, "app_data_words") < 0) return -1;
  if (mcu_write_checked(m, 0x4f000218U, loader_code_size >> 2, "loader_code_words") < 0) return -1;
  if (mcu_write_checked(m, 0x4f00021cU, loader_data_size >> 2, "loader_data_words") < 0) return -1;
  if (mcu_write_checked(m, 0x4f000220U, 0x00000fefU, "app_start") < 0) return -1;
  if (mcu_write_checked(m, 0x4f000224U, 0x00001fefU, "loader_start") < 0) return -1;
  if (mcu_write_checked(m, 0x4f000228U, 1, "load_enable") < 0) return -1;
  if (mcu_write_checked(m, 0x4f00022cU, 0, "load_status") < 0) return -1;

  if (write_app(m, app) < 0) return -1;
  if (write_loader(m, loader) < 0) return -1;

  if (mcu_read(m, 0x1000U, &v) == 0) printf("loader[0x1000]=0x%08x\n", v);
  if (mcu_read(m, 0x1f000U, &v) == 0) printf("loader[0x1f000]=0x%08x\n", v);

  mcu_write(m, 0x400000a0U, 0x00001fffU);
  sleep(4);
  return crcs_match(m, app, loader) ? 0 : -1;
}

static void usage(const char *prog) {
  fprintf(stderr,
          "usage: %s [--bus N] [--firmware-dir DIR] [--no-reset] [--status|--load]\n"
          "          [--reset-delay-ms N] [--probe-window-ms N] [--reopen-after-reset]\n"
          "          [--entry-retry-ms N] [--stock-write-compat]\n"
          "          [--app-mode-load] [--force-load] [--skip-gpio-prep]\n"
          "default firmware dir: /root\n", prog);
}

int main(int argc, char **argv) {
  const char *fwdir = "/root";
  int bus_override = -1;
  int do_load = 0;
  int no_reset = 0;
  int app_mode_load = 0;
  int force_load = 0;
  char app_bin[256], app_txt[256], loader_bin[256], loader_txt[256];
  struct fw_image app = {0}, loader = {0};
  struct mcu m = {-1, -1};
  uint32_t ddr = 0, ddr2 = 0;
  int rc = 1;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--status")) do_load = 0;
    else if (!strcmp(argv[i], "--load")) do_load = 1;
    else if (!strcmp(argv[i], "--no-reset")) no_reset = 1;
    else if (!strcmp(argv[i], "--quiet")) verbose = 0;
    else if (!strcmp(argv[i], "--bus") && i + 1 < argc) bus_override = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--firmware-dir") && i + 1 < argc) fwdir = argv[++i];
    else if (!strcmp(argv[i], "--reset-delay-ms") && i + 1 < argc) reset_delay_ms = (unsigned int)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--probe-window-ms") && i + 1 < argc) probe_window_ms = (unsigned int)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--entry-retry-ms") && i + 1 < argc) entry_retry_ms = (unsigned int)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--reopen-after-reset")) reopen_after_reset = 1;
    else if (!strcmp(argv[i], "--stock-write-compat")) stock_write_compat = 1;
    else if (!strcmp(argv[i], "--app-mode-load")) app_mode_load = 1;
    else if (!strcmp(argv[i], "--force-load")) force_load = 1;
    else if (!strcmp(argv[i], "--skip-gpio-prep")) skip_gpio_prep = 1;
    else {
      usage(argv[0]);
      return 2;
    }
  }

  snprintf(app_bin, sizeof(app_bin), "%s/Mini-G22.bin", fwdir);
  snprintf(app_txt, sizeof(app_txt), "%s/Mini-G22.txt", fwdir);
  snprintf(loader_bin, sizeof(loader_bin), "%s/Mini-G22-Loader.bin", fwdir);
  snprintf(loader_txt, sizeof(loader_txt), "%s/Mini-G22-Loader.txt", fwdir);

  if (prepare_image(&app, app_bin, app_txt, 1) < 0 ||
      prepare_image(&loader, loader_bin, loader_txt, 0) < 0) {
    goto out;
  }
  printf("expected app_code=0x%08x app_data=0x%08x loader_code=0x%08x loader_data=0x%08x\n",
         app.code_crc, app.data_crc, loader.code_crc, loader.data_crc);

  if (do_load) {
    if (app_mode_load) {
      if (detect_mcu(&m, bus_override, 0) < 0) goto out;
    } else if (!no_reset) {
      if (!force_load && detect_mcu(&m, bus_override, 0) == 0 && crcs_match(&m, &app, &loader)) {
        printf("firmware already current\n");
        goto after_load;
      }
      mcu_close(&m);
      if (try_load_after_stock_reset(bus_override, &app, &loader) < 0) {
        fprintf(stderr, "firmware load/verify failed on all reset buses\n");
        goto out;
      }
      if (detect_mcu(&m, bus_override, 0) < 0) goto out;
      goto after_load;
    } else {
      if (detect_mcu(&m, bus_override, 1) < 0) goto out;
    }
    if (force_load || !crcs_match(&m, &app, &loader)) {
      if (load_mcu(&m, &app, &loader) < 0) {
        fprintf(stderr, "firmware load/verify failed\n");
        goto out;
      }
    } else {
      printf("firmware already current\n");
    }
  } else {
    if (detect_mcu(&m, bus_override, 0) < 0) goto out;
    (void)crcs_match(&m, &app, &loader);
  }

after_load:
  if (mcu_read(&m, REG_DDR_RAW, &ddr) == 0 && mcu_read(&m, REG_DDR_DERIVED, &ddr2) == 0) {
    printf("ddr raw=0x%08x displayed=%u derived=0x%08x\n", ddr, ddr * 12U, ddr2);
  }
  rc = 0;

out:
  mcu_close(&m);
  free(app.data);
  free(loader.data);
  return rc;
}
