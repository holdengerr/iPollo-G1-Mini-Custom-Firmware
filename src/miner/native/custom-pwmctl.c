#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define PWM_SET_PERIOD 0x40044101
#define PWM_SET_DUTY   0x40044102
#define PWM_ENABLE     0x40044103

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <percent 30-100>\n", argv[0]);
    return 2;
  }

  int percent = atoi(argv[1]);
  if (percent < 30) percent = 30;
  if (percent > 100) percent = 100;

  int period = 40000;
  int duty = (percent * period) / 100;

  for (int i = 1; i <= 4; i++) {
    char path[32];
    snprintf(path, sizeof(path), "/dev/pwm%d", i);

    int fd = open(path, O_RDWR);
    if (fd < 0) {
      perror(path);
      return 1;
    }

    if (ioctl(fd, PWM_SET_PERIOD, period) < 0) perror("PWM_SET_PERIOD");
    if (ioctl(fd, PWM_SET_DUTY, duty) < 0) perror("PWM_SET_DUTY");
    if (ioctl(fd, PWM_ENABLE, 1) < 0) perror("PWM_ENABLE");

    close(fd);
  }

  printf("set fans to %d%% duty=%d period=%d\n", percent, duty, period);
  return 0;
}
