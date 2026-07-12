// Implementación en C de las fuentes que usan APIs privadas/semipúblicas:
//   - Potencia por bloque del SoC vía IOReport (grupo "Energy Model").
//   - RPM de ventiladores vía AppleSMC (IOConnectCallStructMethod).
//
// Las funciones IOHID* (sensores de temperatura) sólo se DECLARAN en el header y
// se resuelven en enlace contra IOKit.framework; aquí no hacen falta.
#include "CIOKitHID.h"
#include <IOKit/IOKitLib.h>
#include <os/lock.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Los lectores de potencia (IOReport) y de ventiladores (SMC) mantienen estado
// estático NO reentrante. Se leen desde la cola de fondo del ViewModel cada 2 s,
// pero también desde el hilo principal al generar el diagnóstico (botón 🩺), así
// que cada API pública se serializa con su propio lock.
static os_unfair_lock gPowerLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gSMCLock = OS_UNFAIR_LOCK_INIT;

// ===========================================================================
//  IOReport — potencia ("Energy Model")
// ===========================================================================
// Símbolos privados de /usr/lib/libIOReport.dylib (enlazado con -lIOReport).

typedef CFTypeRef IOReportSubscriptionRef;

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup,
                                                          uint64_t a, uint64_t b, uint64_t c);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef channels,
                                                          CFMutableDictionaryRef *outChannels,
                                                          uint64_t channelCnt, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub,
                                             CFMutableDictionaryRef channels, CFTypeRef c);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef c);
extern void IOReportIterate(CFDictionaryRef samples, int (^callback)(CFDictionaryRef ch));
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t index);

// Estado persistente entre llamadas: suscripción, canales y muestra previa.
static IOReportSubscriptionRef gSub = NULL;
static CFMutableDictionaryRef gChannels = NULL;
static CFDictionaryRef gPrevSample = NULL;
static double gPrevTime = 0.0;

static double monotonicSeconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// Convierte un valor entero de energía a julios según su etiqueta de unidad.
static double energyToJoules(int64_t value, CFStringRef unit) {
    if (!unit) return 0.0;
    char buf[16] = {0};
    CFStringGetCString(unit, buf, sizeof(buf), kCFStringEncodingUTF8);
    // Etiquetas vistas: "nJ", "uJ"/"µJ", "mJ", "J".
    if (strstr(buf, "nJ")) return (double)value * 1e-9;
    if (strstr(buf, "uJ") || strstr(buf, "\xc2\xb5J")) return (double)value * 1e-6;
    if (strstr(buf, "mJ")) return (double)value * 1e-3;
    if (strstr(buf, "J"))  return (double)value;
    return 0.0;
}

static int ensureSubscription(void) {
    if (gSub && gChannels) return 0;
    CFMutableDictionaryRef chan = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!chan) return -1;
    CFMutableDictionaryRef subChan = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, chan, &subChan, 0, NULL);
    if (!sub) { CFRelease(chan); return -1; }
    gChannels = subChan ? subChan : chan;
    if (subChan) CFRelease(chan);
    gSub = sub;
    return 0;
}

// Acumula la energía (en julios) de la muestra delta en la estructura destino.
static void accumulate(CFDictionaryRef delta, NovaPower *out) {
    IOReportIterate(delta, ^int(CFDictionaryRef ch) {
        CFStringRef nameRef = IOReportChannelGetChannelName(ch);
        if (!nameRef) return 0;
        char name[64] = {0};
        CFStringGetCString(nameRef, name, sizeof(name), kCFStringEncodingUTF8);
        int64_t raw = IOReportSimpleGetIntegerValue(ch, 0);
        double j = energyToJoules(raw, IOReportChannelGetUnitLabel(ch));
        // Nombres agregados estables en Apple Silicon (M1..M5).
        if (strcmp(name, "CPU Energy") == 0)      out->cpu  += j;
        else if (strcmp(name, "GPU Energy") == 0) out->gpu  += j;
        else if (strcmp(name, "ANE Energy") == 0 || strcmp(name, "ANE") == 0) out->ane += j;
        else if (strcmp(name, "DRAM") == 0)       out->dram += j;
        return 0;
    });
}

// Toma dos muestras separadas `sleepUS` microsegundos y devuelve la potencia.
static NovaPower sampleOnce(useconds_t sleepUS) {
    NovaPower p = {0, 0, 0, 0, 0, 0};
    CFDictionaryRef s1 = IOReportCreateSamples(gSub, gChannels, NULL);
    if (!s1) return p;
    usleep(sleepUS);
    CFDictionaryRef s2 = IOReportCreateSamples(gSub, gChannels, NULL);
    if (!s2) { CFRelease(s1); return p; }
    CFDictionaryRef delta = IOReportCreateSamplesDelta(s1, s2, NULL);
    CFRelease(s1); CFRelease(s2);
    if (!delta) return p;
    double seconds = (double)sleepUS * 1e-6;
    NovaPower joules = {0, 0, 0, 0, 0, 0};
    accumulate(delta, &joules);
    CFRelease(delta);
    p.cpu = joules.cpu / seconds;
    p.gpu = joules.gpu / seconds;
    p.ane = joules.ane / seconds;
    p.dram = joules.dram / seconds;
    p.total = p.cpu + p.gpu + p.ane + p.dram;
    p.valid = 1;
    return p;
}

static NovaPower readPowerUnlocked(void) {
    NovaPower p = {0, 0, 0, 0, 0, 0};
    if (ensureSubscription() != 0) return p;

    double now = monotonicSeconds();
    CFDictionaryRef current = IOReportCreateSamples(gSub, gChannels, NULL);
    if (!current) return p;

    if (gPrevSample && gPrevTime > 0.0) {
        double seconds = now - gPrevTime;
        if (seconds > 0.001) {
            CFDictionaryRef delta = IOReportCreateSamplesDelta(gPrevSample, current, NULL);
            if (delta) {
                NovaPower joules = {0, 0, 0, 0, 0, 0};
                accumulate(delta, &joules);
                CFRelease(delta);
                p.cpu = joules.cpu / seconds;
                p.gpu = joules.gpu / seconds;
                p.ane = joules.ane / seconds;
                p.dram = joules.dram / seconds;
                p.total = p.cpu + p.gpu + p.ane + p.dram;
                p.valid = 1;
            }
        }
        CFRelease(gPrevSample);
    } else {
        // Primera llamada: aún no hay referencia previa. Hacemos un muestreo
        // interno corto para devolver ya un valor razonable.
        CFRelease(current);
        p = sampleOnce(120000); // 120 ms
        current = IOReportCreateSamples(gSub, gChannels, NULL);
        now = monotonicSeconds();
    }

    gPrevSample = current; // retenida; se libera en la siguiente llamada
    gPrevTime = now;
    return p;
}

NovaPower NovaReadPower(void) {
    os_unfair_lock_lock(&gPowerLock);
    NovaPower p = readPowerUnlocked();
    os_unfair_lock_unlock(&gPowerLock);
    return p;
}

// ===========================================================================
//  SMC — ventiladores (RPM)
// ===========================================================================
// AppleSMC se abre con IOServiceOpen y se consulta con IOConnectCallStructMethod
// (selector 2). Protocolo estándar usado por smcFanControl / exelban·stats.

typedef struct { unsigned char major, minor, build, reserved; unsigned short release; } SMCVersion;
typedef struct { unsigned short version, length; unsigned int cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { unsigned int dataSize; unsigned int dataType; unsigned char dataAttributes; } SMCKeyInfoData;
typedef struct {
    unsigned int  key;
    SMCVersion    vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    unsigned char result, status, data8;
    unsigned int  data32;
    unsigned char bytes[32];
} SMCKeyData_t;

enum { kSMCUserClientOpen = 0, kSMCHandleYPCEvent = 2 };
enum { kSMCReadKey = 5, kSMCGetKeyInfo = 9 };

static io_connect_t gSMC = 0;

static unsigned int smcKey(const char *s) {
    return ((unsigned int)s[0] << 24) | ((unsigned int)s[1] << 16) |
           ((unsigned int)s[2] << 8)  |  (unsigned int)s[3];
}

static int smcOpen(void) {
    if (gSMC) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &gSMC);
    IOObjectRelease(svc);
    return (kr == kIOReturnSuccess) ? 0 : -1;
}

static kern_return_t smcCall(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(*out);
    return IOConnectCallStructMethod(gSMC, kSMCHandleYPCEvent, in, sizeof(*in), out, &outSize);
}

// Lee una clave del SMC: primero su info (tamaño/tipo), luego los bytes.
static int smcRead(const char *key, SMCKeyData_t *val, SMCKeyInfoData *info) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = smcKey(key);
    in.data8 = kSMCGetKeyInfo;
    if (smcCall(&in, &out) != kIOReturnSuccess) return -1;
    *info = out.keyInfo;

    memset(&in, 0, sizeof(in));
    memset(val, 0, sizeof(*val));
    in.key = smcKey(key);
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = kSMCReadKey;
    if (smcCall(&in, val) != kIOReturnSuccess) return -1;
    return 0;
}

static int fanCountUnlocked(void) {
    if (smcOpen() != 0) return -1;
    SMCKeyData_t v; SMCKeyInfoData info;
    if (smcRead("FNum", &v, &info) != 0 || info.dataSize == 0) return 0;
    return (int)v.bytes[0];
}

// Los RPM de los ventiladores se guardan como "flt" (float, 4 B) en Apple
// Silicon (clave "F<i>Ac"). En Macs Intel antiguos era "fpe2"; aquí sólo damos
// soporte a Apple Silicon, y exigimos el tipo "flt " para no interpretar bytes
// arbitrarios de otro tipo como un float.
static double fanRPMUnlocked(int index) {
    if (smcOpen() != 0) return -1.0;
    char key[5];
    snprintf(key, sizeof(key), "F%dAc", index);
    SMCKeyData_t v; SMCKeyInfoData info;
    if (smcRead(key, &v, &info) != 0 || info.dataSize < 4) return -1.0;
    char type[5] = {0};
    memcpy(type, &info.dataType, 4);
    if (strncmp(type, "flt ", 4) != 0) return -1.0;
    float f;
    memcpy(&f, v.bytes, 4);
    return (double)f;
}

int NovaFanCount(void) {
    os_unfair_lock_lock(&gSMCLock);
    int n = fanCountUnlocked();
    os_unfair_lock_unlock(&gSMCLock);
    return n;
}

double NovaFanRPM(int index) {
    os_unfair_lock_lock(&gSMCLock);
    double rpm = fanRPMUnlocked(index);
    os_unfair_lock_unlock(&gSMCLock);
    return rpm;
}
