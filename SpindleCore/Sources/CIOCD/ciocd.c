#include "include/ciocd.h"

#include <errno.h>
#include <sys/ioctl.h>

static int result(int rc) {
    return rc == -1 ? errno : 0;
}

int ciocd_read(int fd, dk_cd_read_t *rd) {
    return result(ioctl(fd, DKIOCCDREAD, rd));
}

int ciocd_read_toc(int fd, dk_cd_read_toc_t *toc) {
    return result(ioctl(fd, DKIOCCDREADTOC, toc));
}

int ciocd_read_disc_info(int fd, dk_cd_read_disc_info_t *info) {
    return result(ioctl(fd, DKIOCCDREADDISCINFO, info));
}

int ciocd_set_speed(int fd, uint16_t kbps) {
    return result(ioctl(fd, DKIOCCDSETSPEED, &kbps));
}

int ciocd_get_speed(int fd, uint16_t *kbps) {
    return result(ioctl(fd, DKIOCCDGETSPEED, kbps));
}
