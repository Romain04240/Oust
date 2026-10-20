#include "OustAPFS.h"
#include <sys/attr.h>
#include <sys/snapshot.h>
#include <unistd.h>
#include <errno.h>

// Les attributs lus par Utilitaire de disque : le nom, le XID, les dates,
// l'UUID, le tidemark et surtout la taille privée APFS (20/10/2026).
int oust_snapshot_list(int directory, void *buffer, size_t size) {
    struct attrlist attributes = {
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_NAME | ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR
            | ATTR_CMN_OBJID | ATTR_CMN_CRTIME | ATTR_CMN_UUID,
        .fileattr = ATTR_FILE_DATAALLOCSIZE,
        .forkattr = ATTR_CMNEXT_PRIVATESIZE
    };
    return fs_snapshot_list(directory, &attributes, buffer, size, 0);
}

// Lecture d'une plage de transactions, identique à celle d'Utilitaire de disque
// sur macOS 26/27. Interface APFS non documentée : l'appelant borne les versions,
// les XID et le résultat ; toute erreur rend la mesure indisponible. Aucun autre
// code fsctl ni chemin ne peut être fourni, et aucune écriture n'est demandée.
int oust_snapshot_space(uint64_t first_xid, uint64_t last_xid, uint64_t *bytes) {
    if (!bytes || !first_xid || first_xid > last_xid) { errno = EINVAL; return -1; }
    struct { uint64_t first, last, bytes; } request = { first_xid, last_xid, 0 };
    int result = fsctl("/System/Volumes/Data", 0xc0184a13UL, &request, 0);
    if (result == 0) *bytes = request.bytes;
    return result;
}
