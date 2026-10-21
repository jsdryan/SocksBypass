//
//  DeviceIdentifier.m
//  SOCKS
//

#import "DeviceIdentifier.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

#define QUERY_TIMEOUT_MS 1500

// 送出一個 UDP 查詢並等待回覆，回傳收到的位元組數（失敗回 -1）
static ssize_t udpQuery(const char *ip, int port, const uint8_t *query, size_t queryLen, uint8_t *reply, size_t replyCap) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct timeval tv = {QUERY_TIMEOUT_MS / 1000, (QUERY_TIMEOUT_MS % 1000) * 1000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);
    ssize_t n = -1;
    if (sendto(fd, query, queryLen, 0, (struct sockaddr *)&addr, sizeof(addr)) == (ssize_t)queryLen) {
        n = recv(fd, reply, replyCap, 0);
    }
    close(fd);
    return n;
}

// 解析 DNS 名稱（支援壓縮指標），回傳名稱之後的位移；失敗回 -1
static int readDNSName(const uint8_t *msg, int len, int off, NSMutableString *out) {
    int end = -1;
    for (int jumps = 0; jumps < 16 && off < len; jumps++) {
        uint8_t l = msg[off];
        if (l == 0) {
            return end >= 0 ? end : off + 1;
        }
        if ((l & 0xC0) == 0xC0) {
            if (off + 1 >= len) return -1;
            if (end < 0) end = off + 2;
            off = ((l & 0x3F) << 8) | msg[off + 1];
            continue;
        }
        if (off + 1 + l > len) return -1;
        if (out.length) [out appendString:@"."];
        NSString *label = [[NSString alloc] initWithBytes:msg + off + 1 length:l encoding:NSUTF8StringEncoding];
        [out appendString:label ?: @"?"];
        off += 1 + l;
    }
    return -1;
}

// Bonjour 反查：對該 IP 的 5353 埠問「這個位址叫什麼名字」
static NSString *mdnsName(NSString *ip) {
    NSArray<NSString *> *octets = [ip componentsSeparatedByString:@"."];
    if (octets.count != 4) return nil;
    uint8_t q[512] = {0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0};
    int off = 12;
    for (NSString *octet in octets.reverseObjectEnumerator) {
        q[off++] = octet.length;
        memcpy(q + off, octet.UTF8String, octet.length);
        off += octet.length;
    }
    const char *suffix = "\x07" "in-addr" "\x04" "arpa";
    memcpy(q + off, suffix, strlen(suffix) + 1);
    off += strlen(suffix) + 1;
    uint8_t typeClass[] = {0, 12, 0, 1};    // PTR, IN
    memcpy(q + off, typeClass, 4);
    off += 4;

    uint8_t r[2048];
    int n = (int)udpQuery(ip.UTF8String, 5353, q, off, r, sizeof(r));
    if (n < 12) return nil;
    int qd = (r[4] << 8) | r[5];
    int an = (r[6] << 8) | r[7];
    if (an == 0) return nil;
    int p = 12;
    for (int i = 0; i < qd && p > 0; i++) {
        p = readDNSName(r, n, p, nil);
        if (p > 0) p += 4;
    }
    for (int i = 0; i < an && p > 0 && p + 10 <= n; i++) {
        p = readDNSName(r, n, p, nil);
        if (p < 0 || p + 10 > n) return nil;
        int type = (r[p] << 8) | r[p + 1];
        int rdlen = (r[p + 8] << 8) | r[p + 9];
        p += 10;
        if (type == 12) {
            NSMutableString *name = [NSMutableString string];
            if (readDNSName(r, n, p, name) < 0) return nil;
            if ([name hasSuffix:@".local"]) [name deleteCharactersInRange:NSMakeRange(name.length - 6, 6)];
            return name.length ? name : nil;
        }
        p += rdlen;
    }
    return nil;
}

// 網路芳鄰名稱查詢（NBSTAT）：Windows 會回傳電腦名稱，名稱清單後面附上網卡 MAC 位址
static NSString *netbiosName(NSString *ip, NSString **mac) {
    uint8_t q[50] = {0x56, 0x78, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x20, 'C', 'K'};
    memset(q + 15, 'A', 30);
    q[45] = 0;
    uint8_t typeClass[] = {0, 0x21, 0, 1};  // NBSTAT, IN
    memcpy(q + 46, typeClass, 4);

    uint8_t r[2048];
    int n = (int)udpQuery(ip.UTF8String, 137, q, sizeof(q), r, sizeof(r));
    int off = 12 + 34 + 10;                 // 標頭 + 名稱 + type/class/ttl/rdlength
    if (n < off + 1 + 18 || r[off] == 0) return nil;
    const uint8_t *entry = r + off + 1;     // 第一筆就是電腦名稱，15 字元以空白補齊
    NSString *name = [[NSString alloc] initWithBytes:entry length:15 encoding:NSASCIIStringEncoding];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    int macOff = off + 1 + r[off] * 18;
    if (n >= macOff + 6) {
        const uint8_t *m = r + macOff;
        if (m[0] | m[1] | m[2] | m[3] | m[4] | m[5]) {
            *mac = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X", m[0], m[1], m[2], m[3], m[4], m[5]];
        }
    }
    return name.length ? name : nil;
}

static NSString *appleKind(NSString *name) {
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"iphone"]) return @"iPhone";
    if ([lower containsString:@"ipad"]) return @"iPad";
    for (NSString *hint in @[@"mac", @"mbp", @"mba", @"imac", @"mini", @"studio"]) {
        if ([lower containsString:hint]) return @"Mac";
    }
    return @"Apple 裝置";
}

@implementation DeviceIdentifier

+ (void)identifyIP:(NSString *)ip completion:(void (^)(NSString *, NSString *, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *mac = nil;
        NSString *name = mdnsName(ip);
        NSString *kind = name ? appleKind(name) : nil;
        if (!name) {
            name = netbiosName(ip, &mac);
            kind = name ? @"Windows" : @"未知裝置";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(name, kind, mac);
        });
    });
}

@end
