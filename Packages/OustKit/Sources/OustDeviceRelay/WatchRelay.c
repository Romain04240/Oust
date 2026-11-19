#include "OustDeviceRelay.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

// This target is linked only into oust-cli, never the application or root helper.
// Private MobileDevice symbols are optional at runtime. There is deliberately no
// pairing, unpairing, forwarding, diagnostics, filesystem or activation API here.
typedef void *Device;
typedef struct { Device device; uint32_t message; } Notice;
typedef struct {
    int (*connect)(Device), (*disconnect)(Device), (*paired)(Device), (*validate)(Device);
    int (*startSession)(Device), (*stopSession)(Device);
    CFTypeRef (*copyValue)(Device, CFStringRef, CFStringRef);
    CFStringRef (*copyID)(Device);
    int (*startService)(Device, CFStringRef, void *, void **);
    uint64_t (*send)(void *, CFPropertyListRef, CFPropertyListFormat);
    uint64_t (*receive)(void *, CFPropertyListRef *, CFPropertyListFormat *);
    void (*invalidate)(void *);
    int (*subscribe)(void (*)(Notice *, void *), uint32_t, uint32_t, void *, void **, CFDictionaryRef);
    int (*unsubscribe)(void *);
} API;
typedef struct {
    API api; CFMutableArrayRef samples;
    CFMutableSetRef phones, readingPhones, completedPhones;
    bool failed;
    pthread_mutex_t guard; atomic_bool active;
} Read;

static void deadline(int signalNumber) { (void)signalNumber; _exit(124); }

static CFStringRef identifier(CFStringRef raw, const char *prefix) {
    if (!raw || CFGetTypeID(raw) != CFStringGetTypeID()) return NULL;
    char text[129];
    if (!CFStringGetCString(raw, text, sizeof(text), kCFStringEncodingUTF8)) return NULL;
    size_t count = strlen(text);
    if (count < 16 || count > 128) return NULL;
    for (size_t i = 0; i < count; i++) {
        if (!isxdigit((unsigned char)text[i]) && text[i] != '-') return NULL;
        text[i] = (char)tolower((unsigned char)text[i]);
    }
    char joined[180];
    size_t prefixLength = strlen(prefix);
    if (prefixLength + count >= sizeof(joined)) return NULL;
    memcpy(joined, prefix, prefixLength); memcpy(joined + prefixLength, text, count);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(joined, (CC_LONG)(prefixLength + count), digest);
    const char hex[] = "0123456789abcdef";
    char encoded[65];
    for (int i = 0; i < 32; i++) { encoded[2*i] = hex[digest[i] >> 4]; encoded[2*i+1] = hex[digest[i] & 15]; }
    encoded[64] = 0;
    return CFStringCreateWithCString(NULL, encoded, kCFStringEncodingASCII);
}

static CFDictionaryRef exchange(Read *read, Device phone, CFDictionaryRef request) {
    void *service = NULL;
    int status = read->api.startService(phone, CFSTR("com.apple.companion_proxy"), NULL, &service);
    if (status || !service) {
        if (service) { read->api.invalidate(service); CFRelease(service); }
        return NULL;
    }
    CFPropertyListRef result = NULL;
    CFPropertyListFormat format = 0;
    bool ok = !read->api.send(service, request, kCFPropertyListXMLFormat_v1_0)
        && !read->api.receive(service, &result, &format);
    read->api.invalidate(service); CFRelease(service);
    if (!ok || !result || CFGetTypeID(result) != CFDictionaryGetTypeID()) {
        if (result) CFRelease(result);
        return NULL;
    }
    return (CFDictionaryRef)result;
}

static CFArrayRef watches(Read *read, Device phone) {
    const void *keys[] = { CFSTR("Command") }, *values[] = { CFSTR("GetDeviceRegistry") };
    CFDictionaryRef request = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef result = exchange(read, phone, request); CFRelease(request);
    if (!result) return NULL;
    CFTypeRef array = CFDictionaryGetValue(result, CFSTR("PairedDevicesArray"));
    CFArrayRef copy = array && CFGetTypeID(array) == CFArrayGetTypeID() && CFArrayGetCount(array) <= 6 ? CFRetain(array) : NULL;
    if (!copy && CFEqual(CFDictionaryGetValue(result, CFSTR("Error")) ?: CFSTR(""), CFSTR("NoPairedWatches")))
        copy = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    CFRelease(result); return copy;
}

static CFTypeRef value(Read *read, Device phone, CFStringRef watch, CFStringRef key) {
    const void *keys[] = { CFSTR("Command"), CFSTR("GetValueGizmoUDIDKey"), CFSTR("GetValueKeyKey") };
    const void *values[] = { CFSTR("GetValueFromRegistry"), watch, key };
    CFDictionaryRef request = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef result = exchange(read, phone, request); CFRelease(request);
    if (!result) return NULL;
    CFTypeRef dictionary = CFDictionaryGetValue(result, CFSTR("RetrievedValueDictionary"));
    CFTypeRef item = dictionary && CFGetTypeID(dictionary) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(dictionary, key) : NULL;
    if (item) CFRetain(item);
    CFRelease(result); return item;
}

static bool text(CFTypeRef object, CFIndex limit) {
    return object && CFGetTypeID(object) == CFStringGetTypeID() && CFStringGetLength(object) > 0 && CFStringGetLength(object) <= limit;
}

static bool readWatch(Read *read, Device phone, CFStringRef phoneID, CFStringRef rawWatchID) {
    CFStringRef watchID = identifier(rawWatchID, "oust.watch.relay.watch:");
    if (!watchID || CFArrayGetCount(read->samples) >= 6) { if (watchID) CFRelease(watchID); return false; }
    CFTypeRef name = value(read, phone, rawWatchID, CFSTR("DeviceName"));
    CFTypeRef product = value(read, phone, rawWatchID, CFSTR("ProductType"));
    CFTypeRef battery = value(read, phone, rawWatchID, CFSTR("BatteryCurrentCapacity"));
    CFTypeRef currentName = value(read, phone, rawWatchID, CFSTR("DeviceName"));
    int level = -1;
    bool ok = text(name, 128) && text(product, 32) && text(currentName, 128) && CFEqual(name, currentName)
        && battery && CFGetTypeID(battery) == CFNumberGetTypeID() && !CFNumberIsFloatType(battery)
        && CFNumberGetValue(battery, kCFNumberIntType, &level) && level >= 0 && level <= 100;
    if (ok) {
        const void *keys[] = { CFSTR("watchID"), CFSTR("phoneID"), CFSTR("name"), CFSTR("productType"), CFSTR("level") };
        const void *values[] = { watchID, phoneID, name, product, battery };
        CFDictionaryRef sample = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(read->samples, sample); CFRelease(sample);
    }
    if (name) CFRelease(name); if (product) CFRelease(product); if (battery) CFRelease(battery);
    if (currentName) CFRelease(currentName); CFRelease(watchID);
    return ok;
}

static void observedLocked(Notice *notice, void *context) {
    Read *read = context;
    if (!notice || notice->message != 1 || read->failed) return;
    Device phone = notice->device;
    CFStringRef rawPhoneID = read->api.copyID(phone);
    CFStringRef phoneID = identifier(rawPhoneID, "oust.watch.relay.phone:");
    if (rawPhoneID) CFRelease(rawPhoneID);
    if (!phoneID) { read->failed = true; return; }
    if (CFSetContainsValue(read->readingPhones, phoneID) || CFSetContainsValue(read->completedPhones, phoneID)) {
        CFRelease(phoneID); return;
    }
    if (!CFSetContainsValue(read->phones, phoneID) && CFSetGetCount(read->phones) >= 16) {
        read->failed = true; CFRelease(phoneID); return;
    }
    // Bound distinct phones independently from attempts. A failed transport
    // must not permanently reserve its iPhone and hide another available one.
    CFSetAddValue(read->phones, phoneID);
    // Reserve before every native call and keep this reservation through
    // cleanup, so recursive USB/Wi-Fi notices cannot open a nested session.
    CFSetAddValue(read->readingPhones, phoneID);
    bool connected = false, session = false, completed = false;
    if (read->api.connect(phone)) goto cleanup;
    connected = true;
    if (read->api.paired(phone) != 1 || read->api.validate(phone) || read->api.startSession(phone)) goto cleanup;
    session = true;
    CFTypeRef kind = read->api.copyValue(phone, NULL, CFSTR("DeviceClass"));
    if (!text(kind, 32) || !CFEqual(kind, CFSTR("iPhone"))) {
        // A readable non-iPhone is terminal; an unreadable class can retry on
        // another transport, without producing a sample from this attempt.
        completed = text(kind, 32);
        if (kind) CFRelease(kind);
        goto cleanup;
    }
    CFRelease(kind);
    if (!read->failed) {
        CFArrayRef initial = watches(read, phone);
        if (!initial) read->failed = true;
        if (initial) {
            for (CFIndex i = 0; i < CFArrayGetCount(initial) && !read->failed; i++) {
                CFTypeRef uid = CFArrayGetValueAtIndex(initial, i);
                if (!text(uid, 128) || !readWatch(read, phone, phoneID, uid)) read->failed = true;
            }
            CFArrayRef current = watches(read, phone);
            if (!current || !CFEqual(initial, current)) read->failed = true;
            if (current) CFRelease(current); CFRelease(initial);
        }
    }
    completed = !read->failed;
cleanup:
    if (session) read->api.stopSession(phone);
    if (connected) read->api.disconnect(phone);
    if (completed && !read->failed) CFSetAddValue(read->completedPhones, phoneID);
    CFSetRemoveValue(read->readingPhones, phoneID);
    CFRelease(phoneID);
}

static void observed(Notice *notice, void *context) {
    Read *read = context;
    if (!atomic_load(&read->active)) return;
    pthread_mutex_lock(&read->guard);
    if (atomic_load(&read->active)) observedLocked(notice, context);
    pthread_mutex_unlock(&read->guard);
}

int oust_watch_relay_snapshot(void) {
    static atomic_bool invoked = false;
    if (atomic_exchange(&invoked, true)) return 2;
    // Even standalone invocation has a hard process deadline if a native API hangs.
    signal(SIGALRM, deadline); alarm(6);
    void *framework = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/MobileDevice", RTLD_LAZY | RTLD_LOCAL);
    if (!framework) return 2;
    // Stable callback storage survives late native notifications until exit.
    static Read read;
#define LOAD(field, symbol) do { *(void **)(&read.api.field) = dlsym(framework, symbol); if (!read.api.field) { dlclose(framework); return 2; } } while (0)
    LOAD(connect, "AMDeviceConnect"); LOAD(disconnect, "AMDeviceDisconnect"); LOAD(paired, "AMDeviceIsPaired");
    LOAD(validate, "AMDeviceValidatePairing"); LOAD(startSession, "AMDeviceStartSession"); LOAD(stopSession, "AMDeviceStopSession");
    LOAD(copyValue, "AMDeviceCopyValue"); LOAD(copyID, "AMDeviceCopyDeviceIdentifier"); LOAD(startService, "AMDeviceSecureStartService");
    LOAD(send, "AMDServiceConnectionSendMessage"); LOAD(receive, "AMDServiceConnectionReceiveMessage"); LOAD(invalidate, "AMDServiceConnectionInvalidate");
    LOAD(subscribe, "AMDeviceNotificationSubscribeWithOptions"); LOAD(unsubscribe, "AMDeviceNotificationUnsubscribe");
#undef LOAD
    read.samples = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    read.phones = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    read.readingPhones = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    read.completedPhones = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    pthread_mutexattr_t attributes; pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&read.guard, &attributes); pthread_mutexattr_destroy(&attributes);
    atomic_store(&read.active, true);
    const void *keys[] = { CFSTR("NotificationOptionSearchForPairedDevices") }, *values[] = { kCFBooleanTrue };
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    void *token = NULL;
    int status = read.api.subscribe(observed, 0, 0, &read, &token, options); CFRelease(options);
    if (!status) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.5, false); }
    atomic_store(&read.active, false);
    if (!status) read.api.unsubscribe(token);
    pthread_mutex_lock(&read.guard);
    int result = 2;
    if (!status && !read.failed) {
        int version = 1; CFNumberRef schema = CFNumberCreate(NULL, kCFNumberIntType, &version);
        const void *k[] = { CFSTR("schema"), CFSTR("samples") }, *v[] = { schema, read.samples };
        CFDictionaryRef snapshot = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDataRef data = CFPropertyListCreateData(NULL, snapshot, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
        if (data && CFDataGetLength(data) <= 32768) {
            CFIndex offset = 0, length = CFDataGetLength(data);
            while (offset < length) {
                ssize_t count = write(STDOUT_FILENO, CFDataGetBytePtr(data) + offset, (size_t)(length - offset));
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                offset += count;
            }
            if (offset == length) result = 0;
        }
        if (data) CFRelease(data); CFRelease(snapshot); CFRelease(schema);
    }
    CFRelease(read.samples); CFRelease(read.phones);
    CFRelease(read.readingPhones); CFRelease(read.completedPhones);
    pthread_mutex_unlock(&read.guard);
    // Native framework internals can outlive unsubscription. Process exit owns
    // their final cleanup; don't unload code used by its callback threads.
    alarm(0);
    return result;
}
