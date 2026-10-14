//
//  AppDelegate.m
//  SOCKS
//
//  Created by Robert Xiao on 8/19/18.
//  Copyright © 2018 Robert Xiao. All rights reserved.
//

#import "AppDelegate.h"
#import "ViewController.h"

#include "TargetConditionals.h"
#include <ifaddrs.h>
#include <arpa/inet.h>

@interface AppDelegate ()
@end

// iOS 27 SDK 起強制採用 UIScene 生命週期，否則啟動即閃退
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SceneDelegate

- (void)sceneWillResignActive:(UIScene *)scene {
    [ViewController logMessage:@"[SOCKS] Scene will resign active state"];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    [ViewController logMessage:@"[SOCKS] Scene entered background"];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    [ViewController logMessage:@"[SOCKS] Scene will enter foreground"];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [ViewController logMessage:@"[SOCKS] Scene became active"];
}

@end

@implementation AppDelegate

+ (NSString *)deviceIPAddress
{
    [ViewController logMessage:@"[SOCKS] Starting IP address detection"];
    NSString *address = @"error";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        [ViewController logMessage:@"[SOCKS] Successfully retrieved network interfaces"];
        temp_addr = interfaces;
        address = [NSString stringWithUTF8String:"127.0.0.1"];
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                [ViewController logMessage:[NSString stringWithFormat:@"[SOCKS] Checking interface: %@", interfaceName]];
                if ([interfaceName isEqualToString:@"bridge100"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    [ViewController logMessage:[NSString stringWithFormat:@"[SOCKS] Found IP address: %@", address]];
                } else if ([interfaceName isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    [ViewController logMessage:[NSString stringWithFormat:@"[SOCKS] Found IP address: %@", address]];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        if ([address isEqualToString:@"127.0.0.1"]) {
            [ViewController logMessage:@"[SOCKS] No matching interface found"];
        }
    } else {
        [ViewController logMessage:@"[SOCKS] Failed to get network interfaces"];
    }
    
    freeifaddrs(interfaces);
    return address;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [ViewController logMessage:@"[SOCKS] Application launched"];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [ViewController logMessage:@"[SOCKS] Application will resign active state"];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [ViewController logMessage:@"[SOCKS] Application entered background"];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [ViewController logMessage:@"[SOCKS] Application will enter foreground"];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [ViewController logMessage:@"[SOCKS] Application became active"];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [ViewController logMessage:@"[SOCKS] Application will terminate"];
}

@end
