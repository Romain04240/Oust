// Exercise the production reader with fictitious MobileDevice responses. The
// executable never calls its entry point or loads/accesses a real device.
#include "../../Sources/OustDeviceRelay/WatchRelay.c"
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    const char *id;
    int connectStatus, paired, validateStatus, sessionStatus;
} Transport;

typedef struct {
    Read read;
    Transport wifi, usb;
    int connects, disconnects, sessions, stops, registries, services, invalidations;
    bool reenterConnect, reenterStop, reenterDisconnect;
    bool unreadableClass, emptyRegistry, changedRegistry, invalidBattery;
} Fixture;

static Fixture *fixture;
static int tests;

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)

static void notify(Transport *transport) {
    Notice notice = { transport, 1 };
    observed(&notice, &fixture->read);
}

static CFStringRef copyIDMock(Device device) {
    Transport *transport = device;
    return CFStringCreateWithCString(NULL, transport->id, kCFStringEncodingASCII);
}

static int connectMock(Device device) {
    fixture->connects++;
    if (fixture->reenterConnect) {
        fixture->reenterConnect = false;
        notify(&fixture->usb);
    }
    return ((Transport *)device)->connectStatus;
}

static int disconnectMock(Device device) {
    (void)device;
    fixture->disconnects++;
    if (fixture->reenterDisconnect) {
        fixture->reenterDisconnect = false;
        notify(&fixture->usb);
    }
    return 0;
}

static int pairedMock(Device device) { return ((Transport *)device)->paired; }
static int validateMock(Device device) { return ((Transport *)device)->validateStatus; }
static int startSessionMock(Device device) {
    fixture->sessions++;
    return ((Transport *)device)->sessionStatus;
}
static int stopSessionMock(Device device) {
    (void)device;
    fixture->stops++;
    if (fixture->reenterStop) {
        fixture->reenterStop = false;
        notify(&fixture->usb);
    }
    return 0;
}

static CFTypeRef copyValueMock(Device device, CFStringRef domain, CFStringRef key) {
    (void)device;
    CHECK(domain == NULL && CFEqual(key, CFSTR("DeviceClass")));
    if (fixture->unreadableClass) return NULL;
    return CFRetain(CFSTR("iPhone"));
}

static int startServiceMock(Device device, CFStringRef name, void *options, void **service) {
    (void)device;
    CHECK(CFEqual(name, CFSTR("com.apple.companion_proxy")) && options == NULL);
    fixture->services++;
    *service = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    return 0;
}

static uint64_t sendMock(void *service, CFPropertyListRef request, CFPropertyListFormat format) {
    CHECK(format == kCFPropertyListXMLFormat_v1_0);
    CFDictionarySetValue(service, CFSTR("Request"), request);
    return 0;
}

static CFDictionaryRef dictionary(CFStringRef key, CFTypeRef value) {
    const void *keys[] = { key }, *values[] = { value };
    return CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static uint64_t receiveMock(void *service, CFPropertyListRef *result, CFPropertyListFormat *format) {
    CFDictionaryRef request = CFDictionaryGetValue(service, CFSTR("Request"));
    CFStringRef command = CFDictionaryGetValue(request, CFSTR("Command"));
    *format = kCFPropertyListXMLFormat_v1_0;
    if (CFEqual(command, CFSTR("GetDeviceRegistry"))) {
        fixture->registries++;
        CFStringRef rawID = fixture->changedRegistry && fixture->registries > 1
            ? CFSTR("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee") : CFSTR("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        const void *ids[] = { rawID };
        CFArrayRef registry = CFArrayCreate(NULL, ids, fixture->emptyRegistry ? 0 : 1, &kCFTypeArrayCallBacks);
        *result = dictionary(CFSTR("PairedDevicesArray"), registry);
        CFRelease(registry);
    } else {
        CHECK(CFEqual(command, CFSTR("GetValueFromRegistry")));
        CHECK(CFEqual(CFDictionaryGetValue(request, CFSTR("GetValueGizmoUDIDKey")), CFSTR("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
        CFStringRef key = CFDictionaryGetValue(request, CFSTR("GetValueKeyKey"));
        CFTypeRef value;
        if (CFEqual(key, CFSTR("DeviceName"))) value = CFRetain(CFSTR("Apple Watch Fixture"));
        else if (CFEqual(key, CFSTR("ProductType"))) value = CFRetain(CFSTR("Watch7,12"));
        else {
            CHECK(CFEqual(key, CFSTR("BatteryCurrentCapacity")));
            int level = fixture->invalidBattery ? 101 : 53;
            value = CFNumberCreate(NULL, kCFNumberIntType, &level);
        }
        CFDictionaryRef retrieved = dictionary(key, value);
        *result = dictionary(CFSTR("RetrievedValueDictionary"), retrieved);
        CFRelease(retrieved); CFRelease(value);
    }
    return 0;
}

static void invalidateMock(void *service) { CHECK(service != NULL); fixture->invalidations++; }

static void begin(Fixture *f) {
    memset(f, 0, sizeof(*f)); fixture = f;
    f->wifi = (Transport){ "0123456789abcdef0123456789abcdef", 0, 1, 0, 0 };
    f->usb = f->wifi;
    f->read.samples = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    f->read.phones = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    f->read.readingPhones = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    f->read.completedPhones = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    f->read.api = (API){ .connect = connectMock, .disconnect = disconnectMock, .paired = pairedMock,
        .validate = validateMock, .startSession = startSessionMock, .stopSession = stopSessionMock,
        .copyID = copyIDMock, .copyValue = copyValueMock, .startService = startServiceMock,
        .send = sendMock, .receive = receiveMock, .invalidate = invalidateMock };
    pthread_mutexattr_t attributes; pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    CHECK(pthread_mutex_init(&f->read.guard, &attributes) == 0);
    pthread_mutexattr_destroy(&attributes); atomic_store(&f->read.active, true);
}

static void finish(const char *name) {
    CHECK(CFSetGetCount(fixture->read.readingPhones) == 0);
    CHECK(fixture->services == fixture->invalidations);
    atomic_store(&fixture->read.active, false);
    CFRelease(fixture->read.samples); CFRelease(fixture->read.phones);
    CFRelease(fixture->read.readingPhones); CFRelease(fixture->read.completedPhones);
    CHECK(pthread_mutex_destroy(&fixture->read.guard) == 0);
    printf("PASS %s\n", name); tests++;
    fixture = NULL;
}

static void successfulSample(void) {
    CHECK(!fixture->read.failed);
    CHECK(CFArrayGetCount(fixture->read.samples) == 1);
    CHECK(CFSetGetCount(fixture->read.completedPhones) == 1);
    CFDictionaryRef sample = CFArrayGetValueAtIndex(fixture->read.samples, 0);
    int level = 0;
    CHECK(CFNumberGetValue(CFDictionaryGetValue(sample, CFSTR("level")), kCFNumberIntType, &level) && level == 53);
    CHECK(CFStringGetLength(CFDictionaryGetValue(sample, CFSTR("watchID"))) == 64);
    CHECK(CFStringGetLength(CFDictionaryGetValue(sample, CFSTR("phoneID"))) == 64);
}

int main(void) {
    // A regression in recursive callback handling must fail the suite instead
    // of leaving its isolated test worker blocked forever.
    alarm(10);
    Fixture f;
    begin(&f); f.wifi.connectStatus = 1;
    notify(&f.wifi); CHECK(f.connects == 1 && CFSetGetCount(f.read.completedPhones) == 0);
    notify(&f.usb); successfulSample();
    CHECK(f.connects == 2 && f.disconnects == 1 && f.sessions == 1 && f.stops == 1);
    finish("failed first connection retries available second transport");

    begin(&f); f.reenterConnect = f.reenterStop = f.reenterDisconnect = true;
    notify(&f.wifi); notify(&f.usb); successfulSample();
    CHECK(f.connects == 1 && f.sessions == 1 && f.stops == 1 && f.disconnects == 1);
    finish("reentrant connect and cleanup notices cannot nest or duplicate sessions");

    begin(&f); f.wifi.connectStatus = 1; f.reenterConnect = true;
    notify(&f.wifi); CHECK(f.connects == 1);
    notify(&f.usb); successfulSample(); CHECK(f.connects == 2);
    finish("reentrant notice is blocked during failed attempt, then retry is allowed");

    for (int failure = 0; failure < 3; failure++) {
        begin(&f);
        if (failure == 0) f.wifi.paired = 0;
        else if (failure == 1) f.wifi.validateStatus = 1;
        else f.wifi.sessionStatus = 1;
        f.reenterDisconnect = true;
        notify(&f.wifi);
        CHECK(f.connects == 1 && f.disconnects == 1 && f.stops == 0 && CFArrayGetCount(f.read.samples) == 0);
        notify(&f.usb); successfulSample();
        CHECK(f.connects == 2 && f.disconnects == 2 && f.stops == 1);
        CHECK(f.sessions == (failure == 2 ? 2 : 1));
        finish(failure == 0 ? "unavailable trust retries without pairing" : failure == 1
            ? "failed trust validation releases the in-progress reservation" : "failed session startup retries without stopping an unstarted session");
    }

    begin(&f); f.unreadableClass = true;
    notify(&f.wifi); CHECK(f.stops == 1 && f.disconnects == 1 && CFArrayGetCount(f.read.samples) == 0);
    f.unreadableClass = false; notify(&f.usb); successfulSample();
    CHECK(f.connects == 2 && f.stops == 2 && f.disconnects == 2);
    finish("unreadable device class can recover on the second transport");

    begin(&f); f.emptyRegistry = true;
    notify(&f.wifi); notify(&f.usb);
    CHECK(!f.read.failed && f.connects == 1 && f.registries == 2 && CFArrayGetCount(f.read.samples) == 0);
    CHECK(CFSetGetCount(f.read.completedPhones) == 1);
    finish("successful empty registry is not queried twice across transports");

    begin(&f); f.changedRegistry = true;
    notify(&f.wifi); CHECK(f.read.failed && CFSetGetCount(f.read.completedPhones) == 0);
    notify(&f.usb); CHECK(f.connects == 1);
    finish("registry identity change keeps the whole snapshot blocked");

    begin(&f); f.invalidBattery = true;
    notify(&f.wifi); CHECK(f.read.failed && CFArrayGetCount(f.read.samples) == 0);
    notify(&f.usb); CHECK(f.connects == 1);
    finish("invalid battery data keeps the whole snapshot blocked");

    begin(&f); char ids[17][33]; Transport phones[17];
    for (int i = 0; i < 16; i++) {
        snprintf(ids[i], sizeof(ids[i]), "%032x", i + 1);
        phones[i] = (Transport){ ids[i], 1, 1, 0, 0 }; notify(&phones[i]);
    }
    CHECK(!f.read.failed && f.connects == 16 && CFSetGetCount(f.read.phones) == 16);
    notify(&phones[0]); CHECK(!f.read.failed && f.connects == 17);
    snprintf(ids[16], sizeof(ids[16]), "%032x", 17);
    phones[16] = (Transport){ ids[16], 1, 1, 0, 0 }; notify(&phones[16]);
    CHECK(f.read.failed && f.connects == 17);
    finish("distinct phone limit is retained while a known failed phone may retry");

    printf("%d tests natifs, tous passés.\n", tests);
    alarm(0);
    return 0;
}
