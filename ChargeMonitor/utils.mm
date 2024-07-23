
#include <arpa/inet.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>

#import <Foundation/Foundation.h>

bool is_port_open(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in ip4;
    memset(&ip4, 0, sizeof(struct sockaddr_in));
    ip4.sin_len = sizeof(ip4);
    ip4.sin_family = AF_INET;
    ip4.sin_port = htons(port);
    inet_aton("127.0.0.1", &ip4.sin_addr);
    int so_error = -1;
    struct timeval tv;
    fd_set fdset;
    fcntl(sock, F_SETFL, O_NONBLOCK);
    connect(sock, (struct sockaddr*)&ip4, sizeof(ip4));
    FD_ZERO(&fdset);
    FD_SET(sock, &fdset);
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    if (select(sock + 1, NULL, &fdset, NULL, &tv) == 1) {
        socklen_t len = sizeof(so_error);
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
    }
    close(sock);
    return 0 == so_error;
}

NSString* getSysVer() {
    static NSString* ver = nil;
    if (ver == nil) {
        NSOperatingSystemVersion ver_ = NSProcessInfo.processInfo.operatingSystemVersion;
        ver = [NSString stringWithFormat:@"%d.%d", (int)ver_.majorVersion, (int)ver_.minorVersion];
    }
    return ver;
}

NSString* getDevMdoel() {
    static NSString* model = nil;
    if (model == nil) {
        struct utsname name;
        uname(&name);
        model = @(name.machine);
    }
    return model;
}

int get_sys_boottime() {
    static int ts = 0;
    if (ts == 0) {
        int mib[] = {CTL_KERN, KERN_BOOTTIME};
        struct timeval boottime;
        size_t sz = sizeof(boottime);
        sysctl(mib, 2, &boottime, &sz, 0, 0);
        ts = (int)boottime.tv_sec;
    }
    return ts;
}


