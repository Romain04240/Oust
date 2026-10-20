#ifndef OUST_APFS_H
#define OUST_APFS_H
#include <stddef.h>
#include <stdint.h>
int oust_snapshot_list(int directory, void *buffer, size_t size);
int oust_snapshot_space(uint64_t first_xid, uint64_t last_xid, uint64_t *bytes);
#endif
