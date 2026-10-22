#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// NVMe SMART / Identify 快照。`available == 0` 表示本机未暴露或读取失败（常见于部分环境）。
typedef struct MacInspectNVMeSMARTSnapshot {
    int available;

    uint8_t criticalWarning;
    double temperatureC;
    uint8_t availableSpare;
    uint8_t availableSpareThreshold;
    uint8_t percentageUsed;

    /// NVMe 计数单位为 1000 × 512B；此处已换算为字节（取 128-bit 低 64 位，验机展示足够）。
    uint64_t dataUnitsReadBytes;
    uint64_t dataUnitsWrittenBytes;
    uint64_t powerOnHours;
    uint64_t powerCycles;
    uint64_t unsafeShutdowns;
    uint64_t mediaErrors;

    char model[64];
    char serial[32];
    char firmware[16];
} MacInspectNVMeSMARTSnapshot;

/// 读取第一块 NVMe SMART Capable 设备。成功返回 1 并填充 out；失败返回 0。
int MacInspectReadNVMeSMART(MacInspectNVMeSMARTSnapshot *out);

#ifdef __cplusplus
}
#endif
