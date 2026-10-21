//
//  DeviceIdentifier.h
//  SOCKS
//
//  查出連線裝置的名稱與種類：
//  - Apple 裝置（Mac、iPhone、iPad）會回應 Bonjour（mDNS）反查，得到「名稱.local」
//  - Windows 會回應網路芳鄰（NetBIOS）名稱查詢，得到電腦名稱與 MAC 位址
//  種類依回應的協定與名稱中的線索判斷。iOS 不讓 App 讀其他裝置的 MAC，
//  所以只有 Windows 拿得到；Apple 裝置連熱點時本來就用隨機的私密位址。
//

#import <Foundation/Foundation.h>

@interface DeviceIdentifier : NSObject

// completion 在主執行緒呼叫；查不到時 name 為 nil、kind 為「未知裝置」；mac 只有 Windows 會有
+ (void)identifyIP:(NSString *)ip completion:(void (^)(NSString *name, NSString *kind, NSString *mac))completion;

@end
