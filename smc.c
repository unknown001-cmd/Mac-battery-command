// SMC 系统总功耗读取 (PSTR key)，供 Swift 调用
#include <stdint.h>
#include <string.h>
#include <IOKit/IOKitLib.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_KEYINFO  9
#define SMC_CMD_READ_BYTES    5

static io_connect_t g_conn = 0;
static int g_tried = 0;

static kern_return_t SMCCall(int index, SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(g_conn, index, in, sizeof(SMCKeyData), out, &outSize);
}

static uint32_t fourcc(const char *s) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v += ((uint32_t)(uint8_t)s[i] << ((3 - i) * 8));
    return v;
}

static int smc_ensure_open(void) {
    if (g_conn) return 1;
    if (g_tried) return 0;          // 失败过就不再反复尝试
    g_tried = 1;
    io_service_t dev = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("AppleSMC"));
    if (!dev) return 0;
    kern_return_t kr = IOServiceOpen(dev, mach_task_self(), 0, &g_conn);
    IOObjectRelease(dev);
    if (kr != KERN_SUCCESS) { g_conn = 0; return 0; }
    return 1;
}

static int smc_read(uint32_t key, SMCKeyData *val) {
    SMCKeyData in, ki;
    memset(&in, 0, sizeof(in));
    memset(&ki, 0, sizeof(ki));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (SMCCall(KERNEL_INDEX_SMC, &in, &ki) != KERN_SUCCESS) return 0;
    if (ki.keyInfo.dataSize == 0) return 0;
    in.keyInfo.dataSize = ki.keyInfo.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    memset(val, 0, sizeof(*val));
    if (SMCCall(KERNEL_INDEX_SMC, &in, val) != KERN_SUCCESS) return 0;
    return (int)ki.keyInfo.dataSize;
}

// 整机总功耗，单位 W。失败返回 -1。
double SMC_ReadSystemPower(void) {
    if (!smc_ensure_open()) return -1.0;
    SMCKeyData v;
    int size = smc_read(fourcc("PSTR"), &v);
    if (size != 2) return -1.0;
    // sp78: 高字节整数部分(有符号), 低字节小数部分
    double w = (double)(int8_t)v.bytes[0] + (double)v.bytes[1] / 256.0;
    if (w < 0 || w > 300) return -1.0;
    return w;
}

// CPU 封装功耗 (PCPT)，单位 W。失败返回 -1。
double SMC_ReadCPUPower(void) {
    if (!smc_ensure_open()) return -1.0;
    SMCKeyData v;
    int size = smc_read(fourcc("PCPT"), &v);
    if (size != 2) return -1.0;
    double w = (double)(int8_t)v.bytes[0] + (double)v.bytes[1] / 256.0;
    if (w < 0 || w > 200) return -1.0;
    return w;
}
