#include "NVMeSMARTBridge.h"

#include <string.h>
#include <sys/types.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

static uint64_t nvme_counter_low(const uint64_t words[2]) {
    return words[0];
}

static uint64_t nvme_data_units_to_bytes(uint64_t units) {
    // NVMe：1 data unit = 1000 × 512 bytes
    if (units > UINT64_MAX / 512000ULL) {
        return UINT64_MAX;
    }
    return units * 512000ULL;
}

static void copy_trimmed(char *dst, size_t dstLen, const uint8_t *src, size_t srcLen) {
    if (dstLen == 0) return;
    size_t n = srcLen < dstLen - 1 ? srcLen : dstLen - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
    // 去尾部空格（Identify 字段为 space-padded）
    for (ssize_t i = (ssize_t)n - 1; i >= 0; i--) {
        if (dst[i] == ' ' || dst[i] == '\0') {
            dst[i] = '\0';
        } else {
            break;
        }
    }
}

int MacInspectReadNVMeSMART(MacInspectNVMeSMARTSnapshot *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));

    CFMutableDictionaryRef matching = IOServiceMatching("IOBlockStorageDevice");
    if (!matching) return 0;

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }

    int ok = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(
            service, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault, 0);
        if (!capable) {
            IOObjectRelease(service);
            continue;
        }
        CFRelease(capable);

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kern_return_t kr = IOCreatePlugInInterfaceForService(
            service,
            kIONVMeSMARTUserClientTypeID,
            kIOCFPlugInInterfaceID,
            &plugin,
            &score);
        if (kr != KERN_SUCCESS || plugin == NULL) {
            IOObjectRelease(service);
            continue;
        }

        IONVMeSMARTInterface **smart = NULL;
        HRESULT hr = (*plugin)->QueryInterface(
            plugin,
            CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
            (LPVOID *)&smart);
        if (hr != S_OK || smart == NULL) {
            IODestroyPlugInInterface(plugin);
            IOObjectRelease(service);
            continue;
        }

        NVMeSMARTData data;
        memset(&data, 0, sizeof(data));
        IOReturn rr = (*smart)->SMARTReadData(smart, &data);
        if (rr == kIOReturnSuccess) {
            out->available = 1;
            out->criticalWarning = data.CRITICAL_WARNING;
            // NVMe SMART 复合温度为开尔文
            out->temperatureC = data.TEMPERATURE > 0 ? ((double)data.TEMPERATURE - 273.15) : 0;
            out->availableSpare = data.AVAILABLE_SPARE;
            out->availableSpareThreshold = data.AVAILABLE_SPARE_THRESHOLD;
            out->percentageUsed = data.PERCENTAGE_USED;
            out->dataUnitsReadBytes = nvme_data_units_to_bytes(nvme_counter_low(data.DATA_UNITS_READ));
            out->dataUnitsWrittenBytes = nvme_data_units_to_bytes(nvme_counter_low(data.DATA_UNITS_WRITTEN));
            out->powerOnHours = nvme_counter_low(data.POWER_ON_HOURS);
            out->powerCycles = nvme_counter_low(data.POWER_CYCLES);
            out->unsafeShutdowns = nvme_counter_low(data.UNSAFE_SHUTDOWNS);
            out->mediaErrors = nvme_counter_low(data.MEDIA_ERRORS);

            NVMeIdentifyControllerStruct identify;
            memset(&identify, 0, sizeof(identify));
            if ((*smart)->GetIdentifyData(smart, &identify, 0) == kIOReturnSuccess) {
                copy_trimmed(out->model, sizeof(out->model),
                             identify.MODEL_NUMBER, kNVMeIdentifyControllerModelNumberLen);
                copy_trimmed(out->serial, sizeof(out->serial),
                             identify.SERIAL_NUMBER, kNVMeIdentifyControllerSerialNumberLen);
                copy_trimmed(out->firmware, sizeof(out->firmware),
                             identify.FW_REVISION, kNVMeIdentifyControllerFirmwareRevisionLen);
            }
            ok = 1;
        }

        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(service);
        if (ok) break;
    }

    IOObjectRelease(iterator);
    return ok;
}
