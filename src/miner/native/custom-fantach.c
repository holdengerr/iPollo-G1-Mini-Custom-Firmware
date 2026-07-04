#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const int gpios[4] = {17, 16, 21, 20};

static void write_file(const char *path, const char *value) {
  int fd = open(path, O_WRONLY);
  if (fd < 0) return;
  write(fd, value, strlen(value));
  close(fd);
}

static void setup_gpio(int gpio) {
  char path[64];
  char value[16];

  snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d", gpio);
  if (access(path, F_OK) != 0) {
    snprintf(value, sizeof(value), "%d", gpio);
    write_file("/sys/class/gpio/export", value);
    usleep(100000);
  }

  snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/direction", gpio);
  write_file(path, "in");
}

static int open_gpio_value(int gpio) {
  char path[64];

  snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/value", gpio);
  return open(path, O_RDONLY);
}

static int read_gpio_fd(int fd) {
  char c = '0';

  if (fd < 0) return 0;
  lseek(fd, 0, SEEK_SET);
  if (read(fd, &c, 1) != 1) c = '0';
  return c == '1';
}

int main(int argc, char **argv) {
  const char *out_path = argc > 1 ? argv[1] : "/tmp/custom-fan-rpm.txt";
  char tmp_path[128];
  int prev[4] = {0, 0, 0, 0};
  int value_fd[4] = {-1, -1, -1, -1};

  snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", out_path);

  for (int i = 0; i < 4; i++) {
    setup_gpio(gpios[i]);
    value_fd[i] = open_gpio_value(gpios[i]);
    prev[i] = read_gpio_fd(value_fd[i]);
  }

  while (1) {
    int rising[4] = {0, 0, 0, 0};
    int changes[4] = {0, 0, 0, 0};

    for (int sample = 0; sample < 1000; sample++) {
      for (int i = 0; i < 4; i++) {
        int v = read_gpio_fd(value_fd[i]);
        if (v != prev[i]) changes[i]++;
        if (v && !prev[i]) rising[i]++;
        prev[i] = v;
      }
      usleep(1000);
    }

    FILE *f = fopen(tmp_path, "w");
    if (f) {
      fprintf(f, "%ld %d %d %d %d %d %d %d %d\n",
              (long)time(NULL),
              rising[0] * 25, rising[1] * 25, rising[2] * 25, rising[3] * 25,
              rising[0], rising[1], rising[2], rising[3]);
      fclose(f);
      rename(tmp_path, out_path);
    }
  }
}
