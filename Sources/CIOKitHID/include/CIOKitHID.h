#ifndef CIOKitHID_h
#define CIOKitHID_h

#include <CoreFoundation/CoreFoundation.h>

// ---------------------------------------------------------------------------
//  Símbolos PRIVADOS de IOKit (IOHIDEventSystemClient)
// ---------------------------------------------------------------------------
//  En Apple Silicon (M1..M5) los sensores térmicos se exponen como servicios
//  HID. Estas funciones NO están en las cabeceras públicas del SDK, pero sí
//  están exportadas por IOKit.framework y se pueden llamar SIN entitlements
//  especiales y SIN root.
//
//  Los tres handles "…Ref" son objetos CoreFoundation opacos, así que los
//  declaramos como CFTypeRef. De este modo el importador de Swift trata cada
//  función Create/Copy como si devolviera un Unmanaged<CFTypeRef>, que
//  resolvemos en Swift con .takeRetainedValue().
//
//  En SwiftPM este header se expone como el módulo `CIOKitHID` (equivalente al
//  bridging header que usaría un proyecto Xcode).
// ---------------------------------------------------------------------------

typedef CFTypeRef IOHIDEventSystemClientRef;
typedef CFTypeRef IOHIDServiceClientRef;
typedef CFTypeRef IOHIDEventRef;

/// Crea el cliente del sistema de eventos HID usado para enumerar sensores.
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);

/// Instala el diccionario de matching (PrimaryUsagePage / PrimaryUsage).
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matches);

/// Devuelve el array de IOHIDServiceClientRef que cumplen el matching.
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);

/// Lee una propiedad del servicio (p. ej. "Product", "DeviceName").
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);

/// Copia el último evento del tipo indicado (15 == temperatura) de un servicio.
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);

/// Extrae el valor en coma flotante (°C en un evento de temperatura).
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// ---------------------------------------------------------------------------
//  Potencia (IOReport, grupo "Energy Model") y ventiladores (SMC)
// ---------------------------------------------------------------------------
//  Estas dos fuentes usan APIs privadas (IOReport) y semipúblicas (AppleSMC vía
//  IOConnectCallStructMethod). Para no arrastrar sus structs/bloques feos a
//  Swift, toda la fontanería vive en shim.c y aquí se exponen funciones C
//  limpias. Igual que los sensores HID: sin root ni entitlements.

/// Consumo instantáneo por bloque del SoC, en vatios. Se calcula a partir de la
/// energía acumulada (grupo "Energy Model" de IOReport) entre esta llamada y la
/// anterior. `valid` es 0 hasta tener dos muestras (la primera llamada hace un
/// muestreo interno corto para devolver ya un valor).
typedef struct {
    double cpu;    // vatios de CPU (E+P cores)
    double gpu;    // vatios de GPU
    double ane;    // vatios del Neural Engine
    double dram;   // vatios de la memoria (DRAM)
    double total;  // suma de los anteriores
    int    valid;  // 1 si la medida es fiable
} NovaPower;

/// Lee la potencia actual. Mantiene estado interno (muestra + tiempo previos)
/// entre llamadas; pensada para invocarse periódicamente (p. ej. cada 2 s).
NovaPower NovaReadPower(void);

/// Número de ventiladores del equipo (0 en Macs sin ventilador, como los
/// MacBook Air). Devuelve -1 si el SMC no está accesible.
int NovaFanCount(void);

/// Revoluciones por minuto actuales del ventilador `index` (0-based).
/// Devuelve -1.0 si no se puede leer.
double NovaFanRPM(int index);

#endif /* CIOKitHID_h */
