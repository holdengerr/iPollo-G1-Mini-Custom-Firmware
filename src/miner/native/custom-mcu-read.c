#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define I2C_SLAVE 0x0703
#define MCU_SLAVE 0x7e

static int parse_u32(const char *s, uint32_t *out) {
  char *end = NULL;
  unsigned long v = strtoul(s, &end, 0);
  if (!s || !*s || !end || *end != '\0' || v > 0xffffffffUL) return 0;
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

static int read_reg_on_bus(int bus, uint32_t reg, uint32_t *value, char *err, size_t err_len) {
  char path[32];
  int fd;

  snprintf(path, sizeof(path), "/dev/i2c-%d", bus);
  fd = open(path, O_RDWR);
  if (fd < 0) {
    snprintf(err, err_len, "open %s: %s", path, strerror(errno));
    return -1;
  }

  if (ioctl(fd, I2C_SLAVE, MCU_SLAVE) < 0) {
    snprintf(err, err_len, "ioctl I2C_SLAVE 0x%02x on %s: %s", MCU_SLAVE, path, strerror(errno));
    close(fd);
    return -1;
  }

  for (int attempt = 1; attempt <= 3; attempt++) {
    unsigned char addr[4] = {
      (unsigned char)((reg >> 24) & 0xff),
      (unsigned char)((reg >> 16) & 0xff),
      (unsigned char)((reg >> 8) & 0xff),
      (unsigned char)(reg & 0xff),
    };
    unsigned char data[4] = {0, 0, 0, 0};

    if (write_full(fd, addr, sizeof(addr)) == 0 && read_full(fd, data, sizeof(data)) == 0) {
      *value = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16) | ((uint32_t)data[2] << 8) | (uint32_t)data[3];
      close(fd);
      return 0;
    }

    snprintf(err, err_len, "attempt %d on %s reg=0x%08x failed: %s", attempt, path, reg, strerror(errno));
    usleep(50000);
  }

  close(fd);
  return -1;
}

int main(int argc, char **argv) {
  int bus_override = -1;
  uint32_t reg = 0;
  int reg_arg = 1;

  if (argc == 4 && strcmp(argv[1], "--bus") == 0) {
    bus_override = atoi(argv[2]);
    reg_arg = 3;
  } else if (argc != 2) {
    fprintf(stderr, "usage: %s [--bus N] <register>\n", argv[0]);
    return 2;
  }

  if (!parse_u32(argv[reg_arg], &reg)) {
    fprintf(stderr, "invalid register: %s\n", argv[reg_arg]);
    return 2;
  }

  if (bus_override >= 0) {
    uint32_t value = 0;
    char err[160] = "";
    if (read_reg_on_bus(bus_override, reg, &value, err, sizeof(err)) == 0) {
      printf("bus=%d reg=0x%08x value=0x%08x\n", bus_override, reg, value);
      return 0;
    }
    fprintf(stderr, "bus=%d reg=0x%08x error=%s\n", bus_override, reg, err);
    return 1;
  }

  for (int bus = 0; bus <= 2; bus++) {
    uint32_t value = 0;
    char err[160] = "";
    if (read_reg_on_bus(bus, reg, &value, err, sizeof(err)) == 0) {
      printf("bus=%d reg=0x%08x value=0x%08x\n", bus, reg, value);
      return 0;
    }
    fprintf(stderr, "bus=%d reg=0x%08x error=%s\n", bus, reg, err);
  }

  return 1;
}
