#ifndef SMC_BRIDGE_H
#define SMC_BRIDGE_H

double SMC_ReadSystemPower(void);   // 整机总功耗 W，失败 -1
double SMC_ReadCPUPower(void);      // CPU 功耗 W，失败 -1

#endif
