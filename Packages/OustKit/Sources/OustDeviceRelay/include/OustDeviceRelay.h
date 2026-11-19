#ifndef OUST_DEVICE_RELAY_H
#define OUST_DEVICE_RELAY_H
/// Read-only, process-isolated entry point for the internal signed CLI mode.
/// Writes one small versioned plist, with hashed identifiers, or returns failure.
int oust_watch_relay_snapshot(void);
#endif
