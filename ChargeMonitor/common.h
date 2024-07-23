#ifndef common_h
#define common_h

#define PRODUCT         "ChargeMonitor"
#define GSERV_PORT      1230
NSString* log_prefix = @(PRODUCT "Logger");

bool is_port_open(int port);
NSString* getSysVer();
NSString* getDevMdoel();
int get_sys_boottime();

#endif /* common_h */
