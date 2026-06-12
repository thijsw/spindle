#ifndef CIOCD_H
#define CIOCD_H

#include <stdint.h>
#include <IOKit/storage/IOCDMediaBSDClient.h>

// Thin wrappers around the IOCDMedia BSD client ioctls. Swift cannot call the
// variadic ioctl(2) directly; each wrapper returns 0 on success or errno.

int ciocd_read(int fd, dk_cd_read_t *rd);
int ciocd_read_toc(int fd, dk_cd_read_toc_t *toc);
int ciocd_read_disc_info(int fd, dk_cd_read_disc_info_t *info);
int ciocd_set_speed(int fd, uint16_t kbps);
int ciocd_get_speed(int fd, uint16_t *kbps);

#endif
