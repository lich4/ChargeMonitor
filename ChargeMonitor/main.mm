
#import <Foundation/Foundation.h>
#import <GCDWebServers/GCDWebServers.h>
#include <sqlite3.h>

#include "common.h"

static NSString* db_path = nil;
static NSString* conf_path = nil;
static NSDictionary* bat_info = nil;
static NSString* app_ver = @"1.0";
static int g_serv_boot = 0;

NSDictionary* handleReq(NSDictionary* nsreq);

static NSMutableDictionary* cache_kv = nil;

void initlocalKV() {
    if (cache_kv == nil) {
        cache_kv = [NSMutableDictionary dictionary];
    }
}

id getlocalKV(NSString* key) {
    if (cache_kv == nil) {
        cache_kv = [NSMutableDictionary dictionaryWithContentsOfFile:conf_path];
    }
    if (cache_kv == nil) {
        return nil;
    }
    return cache_kv[key];
}

void setlocalKV(NSString* key, id val) {
    if (cache_kv == nil) {
        cache_kv = [NSMutableDictionary dictionaryWithContentsOfFile:conf_path];
        if (cache_kv == nil) {
            cache_kv = [NSMutableDictionary new];
        }
    }
    cache_kv[key] = val;
    [cache_kv writeToFile:conf_path atomically:YES];
}

static io_service_t getIOPMPSServ() {
    static io_service_t serv = IO_OBJECT_NULL;
    if (serv == IO_OBJECT_NULL) {
        serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    }
    return serv;
}

static NSDictionary* getBatSlimInfo(NSDictionary* info) {
    NSMutableDictionary* filtered_info = [NSMutableDictionary dictionary];
    NSArray* keep = @[
        @"Amperage", @"AppleRawCurrentCapacity", @"BatteryInstalled", @"BootVoltage", @"CurrentCapacity", @"CycleCount", @"DesignCapacity", @"ExternalChargeCapable", @"ExternalConnected",
        @"InstantAmperage", @"IsCharging", @"NominalChargeCapacity", @"PostChargeWaitSeconds", @"PostDischargeWaitSeconds", @"Serial", @"Temperature",
        @"UpdateTime", @"Voltage"];
    for (NSString* key in info) {
        if ([keep containsObject:key]) {
            filtered_info[key] = info[key];
        }
    }
    if (filtered_info[@"NominalChargeCapacity"] == nil) {
        if (info[@"AppleRawMaxCapacity"] != nil) {
            filtered_info[@"NominalChargeCapacity"] = info[@"AppleRawMaxCapacity"];
        }
    }
    if (info[@"AdapterDetails"] != nil) {
        NSDictionary* adaptor_info = info[@"AdapterDetails"];
        NSMutableDictionary* filtered_adaptor_info = [NSMutableDictionary dictionary];
        keep = @[@"Current", @"Description", @"IsWireless", @"Manufacturer", @"Name", @"Voltage", @"Watts"];
        for (NSString* key in adaptor_info) {
            if ([keep containsObject:key]) {
                filtered_adaptor_info[key] = adaptor_info[key];
            }
        }
        if (filtered_adaptor_info[@"Voltage"] == nil) {
            if (adaptor_info[@"AdapterVoltage"] != nil) {
                filtered_adaptor_info[@"Voltage"] = adaptor_info[@"AdapterVoltage"];
            }
        }
        filtered_info[@"AdapterDetails"] = filtered_adaptor_info;
    }
    return filtered_info;
}

static int getBatInfoWithServ(io_service_t serv, NSDictionary* __strong* pinfo) {
    CFMutableDictionaryRef prop = nil;
    IORegistryEntryCreateCFProperties(serv, &prop, kCFAllocatorDefault, 0);
    if (prop == nil) {
        return -2;
    }
    NSMutableDictionary* info = (__bridge_transfer NSMutableDictionary*)prop;
    *pinfo = getBatSlimInfo(info);
    return 0;
}

static int getBatInfo(NSDictionary* __strong* pinfo, BOOL slim=YES) {
    io_service_t serv = getIOPMPSServ();
    if (serv == IO_OBJECT_NULL) {
        return -1;
    }
    CFMutableDictionaryRef prop = nil;
    IORegistryEntryCreateCFProperties(serv, &prop, kCFAllocatorDefault, 0);
    if (prop == nil) {
        return -2;
    }
    NSMutableDictionary* info = (__bridge_transfer NSMutableDictionary*)prop;
    if (slim) {
        *pinfo = getBatSlimInfo(info);
    } else {
        *pinfo = info;
    }
    return 0;
}

static sqlite3* db = NULL;
static void updateDBData(const char* tbl, int tid, NSDictionary* info) {
    @autoreleasepool {
        if (!db) {
            return;
        }
        NSData* jdata = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
        if (jdata == nil) {
            return;
        }
        NSString* jstr = [[NSString alloc] initWithData:jdata encoding:NSUTF8StringEncoding];
        char sql[256];
        sprintf(sql, "insert or ignore into %s values(:1, :2)", tbl);
        sqlite3_stmt* stmt = NULL;
        sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
        sqlite3_bind_int(stmt, 1, tid);
        sqlite3_bind_text(stmt, 2, jstr.UTF8String, -1, SQLITE_STATIC);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

static void initDB() {
    @autoreleasepool {
        sqlite3* cdb = NULL;
        if (sqlite3_open(db_path.UTF8String, &cdb) != SQLITE_OK) {
            return;
        }
        char* err;
        const char* tbls[] = {"min5", "hour", "day", "month", NULL};
        for (int i = 0; tbls[i]; i++) {
            char sql[256];
            sprintf(sql, "create table if not exists %s(id integer primary key, data text)", tbls[i]);
            if (sqlite3_exec(cdb, sql, NULL, NULL, &err) != SQLITE_OK) {
                sqlite3_close(cdb);
                return;
            }
        }
        db = cdb;
    }
}

static void uninitDB() {
    if (db != NULL) {
        sqlite3_close(db);
    }
}

static NSArray* getDBData(const char* tbl, int n, int last_id) {
    @autoreleasepool {
        if (!db) {
            return @[];
        }
        NSMutableArray* result = [NSMutableArray array];
        char sql[256];
        sprintf(sql, "select data from %s where id > %d order by id desc limit %d", tbl, last_id, n);
        sqlite3_stmt* stmt = NULL;
        sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char* jstr = (const char*)sqlite3_column_text(stmt, 0);
            NSData* jdata = [NSData dataWithBytes:(void*)jstr length:strlen(jstr)];
            NSDictionary* jobj = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:nil];
            if (jobj == nil) {
                continue;
            }
            [result addObject:jobj];
        }
        NSArray* result_ = [[result reverseObjectEnumerator] allObjects]; // order by id desc
        sqlite3_finalize(stmt);
        return result_;
    }
}

static NSMutableDictionary* getFilteredMDic(NSDictionary* dic, NSArray* filter) {
    NSMutableDictionary* mdic = [NSMutableDictionary new];
    for (NSString* key in filter) {
        if (dic[key] != nil) {
            mdic[key] = dic[key];
        }
    }
    return mdic;
}

static void updateStatistics() {
    int ts = (int)time(0);
    NSDictionary* info_h = getFilteredMDic(bat_info, @[
        @"Amperage", @"AppleRawCurrentCapacity", @"CurrentCapacity", @"ExternalChargeCapable", @"ExternalConnected",
        @"InstantAmperage", @"IsCharging", @"NominalChargeCapacity", @"Temperature", @"UpdateTime", @"Voltage"
    ]);
    updateDBData("min5", ts / 300, info_h);
    updateDBData("hour", ts / 3600, info_h);
    NSDictionary* info_d = getFilteredMDic(bat_info, @[
        @"CycleCount", @"DesignCapacity", @"NominalChargeCapacity", @"UpdateTime"
    ]);
    updateDBData("day", ts / 86400, info_d);
    updateDBData("month", ts / 2592000, info_d);
}

NSDictionary* handleReq(NSDictionary* nsreq) {
    NSString* api = nsreq[@"api"];
    if ([api isEqualToString:@"get_conf"]) {
        NSMutableDictionary* kv = [cache_kv mutableCopy];
        kv[@"ver"] = app_ver;
        kv[@"sysver"] = getSysVer();
        kv[@"devmodel"] = getDevMdoel();
        kv[@"serv_boot"] = @(g_serv_boot);
        kv[@"sys_boot"] = @(get_sys_boottime());
        return @{
            @"status": @0,
            @"data": kv,
        };
    } else if ([api isEqualToString:@"set_conf"]) {
        NSString* key = nsreq[@"key"];
        id val = nsreq[@"val"];
        setlocalKV(key, val);
    } else if ([api isEqualToString:@"get_bat_info"]) {
        return @{
            @"status": @0,
            @"data": bat_info,
        };
    } else if ([api isEqualToString:@"get_statistics"]) {
        NSDictionary* conf = nsreq[@"conf"];
        NSMutableDictionary* data = [NSMutableDictionary dictionary];
        for (NSString* tbl in conf) {
            NSDictionary* conf_for_tbl = conf[tbl];
            NSNumber* n = conf_for_tbl[@"n"];
            NSNumber* last_id = conf_for_tbl[@"last_id"];
            data[tbl] = getDBData(tbl.UTF8String, n.intValue, last_id.intValue);
        }
        return @{
            @"status": @0,
            @"data": data,
        };
    }
    return @{
        @"status": @-10
    };
}

@interface Service: NSObject
+ (instancetype)inst;
- (instancetype)init;
- (void)serve;
@end

@implementation Service
+ (instancetype)inst {
    static dispatch_once_t pred = 0;
    static Service* inst_ = nil;
    dispatch_once(&pred, ^{
        inst_ = [self new];
    });
    return inst_;
}
- (instancetype)init {
    self = super.init;
    return self;
}
- (void)serve {
    initlocalKV();
    initDB();
    static GCDWebServer* _webServer = nil;
    if (_webServer == nil) {
        if (is_port_open(GSERV_PORT)) {
            NSLog(@"%@ already served, exit", log_prefix);
            exit(0); // 服务已存在,退出
        }
        _webServer = [GCDWebServer new];
        NSString* html_root = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"www"];
        [_webServer addGETHandlerForBasePath:@"/" directoryPath:html_root indexFilename:@"index.html" cacheAge:1 allowRangeRequests:NO];
        [_webServer addDefaultHandlerForMethod:@"POST" requestClass:GCDWebServerDataRequest.class processBlock:^GCDWebServerResponse*(GCDWebServerDataRequest* request) {
            @autoreleasepool {
                NSDictionary* nsres = handleReq(request.jsonObject);
                return [GCDWebServerDataResponse responseWithJSONObject:nsres];
            }
        }];
        NSDictionary* options = @{
            @"Port": @(GSERV_PORT),
            @"BindToLocalhost": @YES,
        };
        BOOL status = [_webServer startWithOptions:options error:nil];
        if (!status) {
            NSLog(@"%@ serve failed, exit", log_prefix);
            exit(0);
        }
        getBatInfo(&bat_info);
        IONotificationPortRef port = IONotificationPortCreate(kIOMasterPortDefault);
        CFRunLoopSourceRef runSrc = IONotificationPortGetRunLoopSource(port);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runSrc, kCFRunLoopDefaultMode);
        io_service_t serv = getIOPMPSServ();
        if (serv != IO_OBJECT_NULL) {
            io_object_t noti = IO_OBJECT_NULL;
            IOServiceAddInterestNotification(port, serv, "IOGeneralInterest", [](void* refcon, io_service_t service, uint32_t type, void* args) {
                @synchronized (Service.inst) {
                    @autoreleasepool {
                        if (0 != getBatInfoWithServ(service, &bat_info)) {
                            return;
                        }
                        updateStatistics();
                    }
                }
            }, nil, &noti);
        }
    }
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc == 1) {
            g_serv_boot = (int)time(0);
            conf_path = [NSString stringWithFormat:@"%@/chargemonitor.conf", NSHomeDirectory()];
            db_path = [NSString stringWithFormat:@"%@/chargemonitor.db", NSHomeDirectory()];
            [Service.inst serve];
            atexit_b(^{
                uninitDB();
            });
            CFRunLoopRun();
        } else if (argc > 1) {
            if (0 == strcmp(argv[1], "watch_bat_info")) {
                while (true) {
                    BOOL slim = argc == 3;
                    getBatInfo(&bat_info, slim);
                    NSLog(@"%@", bat_info);
                    [NSThread sleepForTimeInterval:1.0];
                    system("clear");
                }
            }
        }
        return 0;
    }
}

