//
//  ViewController.m
//  SOCKS
//
//  Created by Robert Xiao on 8/19/18.
//  Copyright © 2018 Robert Xiao. All rights reserved.
//

#import "ViewController.h"
#import "AppDelegate.h"
#import "DeviceIdentifier.h"
#include <stdio.h>
#include <unistd.h>
#include <stdarg.h>
#include <pthread.h>

typedef NS_ENUM(NSInteger, ServerState) {
    ServerStateStarting,
    ServerStateRunning,
    ServerStateNoNetwork,
    ServerStateFailed,
};

@interface ViewController ()

@property (assign, nonatomic) ServerState serverState;
@property (copy, nonatomic) NSString *ipAddress;
@property (assign, nonatomic) int port;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSNumber *> *activeClients; // IP → 連線數
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *deviceInfo; // IP → 名稱與種類

@property (strong, nonatomic) UIView *statusDot;
@property (strong, nonatomic) UILabel *statusTitleLabel;
@property (strong, nonatomic) UILabel *statusDetailLabel;
@property (strong, nonatomic) UILabel *addressValueLabel;
@property (strong, nonatomic) UILabel *portValueLabel;
@property (strong, nonatomic) UILabel *uploadSpeedLabel;
@property (strong, nonatomic) UILabel *downloadSpeedLabel;
@property (strong, nonatomic) UILabel *uploadTotalLabel;
@property (strong, nonatomic) UILabel *downloadTotalLabel;
@property (strong, nonatomic) UIStackView *deviceListStack;
@property (strong, nonatomic) UIButton *logToggleButton;

@end

@implementation ViewController

extern int socks_main(int argc, const char** argv);
extern void custom_log(const char *format, ...);
extern void update_traffic_stats_ui(uint64_t uploadBytes, uint64_t downloadBytes);
extern void client_connected(const char *clientIP);
extern void client_disconnected(const char *clientIP);
static ViewController *sharedInstance = nil;

#define MAX_LOG_LINES 1000

static uint64_t lastUploadBytes = 0;
static uint64_t lastDownloadBytes = 0;
static NSDate *lastUpdateTime = nil;
static NSTimer *statsUpdateTimer;
static uint64_t pending_upload_bytes = 0;
static uint64_t pending_download_bytes = 0;
static pthread_mutex_t pending_stats_mutex = PTHREAD_MUTEX_INITIALIZER;

- (NSString *)formatBytes:(uint64_t)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes/1024.0];
    if (bytes < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes/(1024.0*1024.0)];
    return [NSString stringWithFormat:@"%.1f GB", bytes/(1024.0*1024.0*1024.0)];
}

- (NSString *)formatSpeed:(double)bytesPerSecond {
    if (bytesPerSecond < 1024) return [NSString stringWithFormat:@"%.0f B/s", bytesPerSecond];
    if (bytesPerSecond < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB/s", bytesPerSecond/1024.0];
    if (bytesPerSecond < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB/s", bytesPerSecond/(1024.0*1024.0)];
    return [NSString stringWithFormat:@"%.1f GB/s", bytesPerSecond/(1024.0*1024.0*1024.0)];
}

+ (void)updateTrafficStats:(uint64_t)uploadBytes downloadBytes:(uint64_t)downloadBytes {
    if (sharedInstance) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [sharedInstance updateStatsWithUpload:uploadBytes download:downloadBytes];
        });
    }
}

- (void)updateStatsWithUpload:(uint64_t)uploadBytes download:(uint64_t)downloadBytes {
    NSDate *now = [NSDate date];
    NSTimeInterval elapsed = [now timeIntervalSinceDate:lastUpdateTime ?: now];

    if (lastUpdateTime && elapsed > 0) {
        double uploadSpeed = (uploadBytes - lastUploadBytes) / elapsed;
        double downloadSpeed = (downloadBytes - lastDownloadBytes) / elapsed;

        self.uploadSpeedLabel.text = [NSString stringWithFormat:@"%.2f MB/s", uploadSpeed / (1024.0 * 1024.0)];
        self.downloadSpeedLabel.text = [NSString stringWithFormat:@"%.2f MB/s", downloadSpeed / (1024.0 * 1024.0)];
        self.uploadTotalLabel.text = [NSString stringWithFormat:@"累計 %.2f GB", uploadBytes / (1024.0 * 1024.0 * 1024.0)];
        self.downloadTotalLabel.text = [NSString stringWithFormat:@"累計 %.2f GB", downloadBytes / (1024.0 * 1024.0 * 1024.0)];
    }

    lastUploadBytes = uploadBytes;
    lastDownloadBytes = downloadBytes;
    lastUpdateTime = now;
}

void update_traffic_stats_ui(uint64_t uploadBytes, uint64_t downloadBytes) {
    pthread_mutex_lock(&pending_stats_mutex);
    pending_upload_bytes = uploadBytes;
    pending_download_bytes = downloadBytes;
    pthread_mutex_unlock(&pending_stats_mutex);
}

void client_connected(const char *clientIP) {
    NSString *ip = [NSString stringWithUTF8String:clientIP];
    dispatch_async(dispatch_get_main_queue(), ^{
        ViewController *vc = sharedInstance;
        vc.activeClients[ip] = @(vc.activeClients[ip].integerValue + 1);
        // 查不到的裝置 30 秒後再試（例如第一次查詢時還沒允許「區域網路」權限）
        NSDate *retryAfter = vc.deviceInfo[ip][@"retryAfter"];
        if (!vc.deviceInfo[ip] || (retryAfter && retryAfter.timeIntervalSinceNow < 0)) {
            vc.deviceInfo[ip] = @{@"kind": @"辨識中…"};
            [DeviceIdentifier identifyIP:ip completion:^(NSString *name, NSString *kind, NSString *mac) {
                NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:kind forKey:@"kind"];
                info[@"name"] = name;
                info[@"mac"] = mac;
                if (!name) info[@"retryAfter"] = [NSDate dateWithTimeIntervalSinceNow:30];
                vc.deviceInfo[ip] = info;
                [vc refreshClients];
            }];
        }
        [vc refreshClients];
    });
}

void client_disconnected(const char *clientIP) {
    NSString *ip = [NSString stringWithUTF8String:clientIP];
    dispatch_async(dispatch_get_main_queue(), ^{
        ViewController *vc = sharedInstance;
        NSInteger count = vc.activeClients[ip].integerValue - 1;
        vc.activeClients[ip] = count > 0 ? @(count) : nil;
        [vc refreshClients];
    });
}

void custom_log(const char *format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);

    [ViewController logFromC:buffer];
    // Also write to stderr for Xcode console
    fprintf(stderr, "%s\n", buffer);
}

#pragma mark - 介面

- (UILabel *)labelWithStyle:(UIFontTextStyle)style color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIView *)cardWithTitle:(NSString *)title content:(UIView *)content {
    UILabel *header = [self labelWithStyle:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
    header.text = title;

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 14;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];

    UIStackView *section = [[UIStackView alloc] initWithArrangedSubviews:@[header, card]];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 6;
    return section;
}

- (UIStackView *)rowWithName:(NSString *)name value:(UILabel *)valueLabel {
    UILabel *nameLabel = [self labelWithStyle:UIFontTextStyleBody color:[UIColor labelColor]];
    nameLabel.text = name;
    valueLabel.textAlignment = NSTextAlignmentRight;
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, valueLabel]];
    row.spacing = 8;
    return row;
}

- (UIView *)separator {
    UIView *line = [UIView new];
    line.backgroundColor = [UIColor separatorColor];
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return line;
}

- (UIStackView *)trafficColumnWithTitle:(NSString *)title speed:(UILabel *)speed total:(UILabel *)total {
    UILabel *titleLabel = [self labelWithStyle:UIFontTextStyleSubheadline color:[UIColor secondaryLabelColor]];
    titleLabel.text = title;
    speed.font = [UIFont monospacedDigitSystemFontOfSize:24 weight:UIFontWeightSemibold];
    speed.text = @"0.00 MB/s";
    total.text = @"累計 0.00 GB";
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, speed, total]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 2;
    return column;
}

- (void)buildInterface {
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 狀態
    self.statusDot = [UIView new];
    self.statusDot.layer.cornerRadius = 7;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusDot.widthAnchor constraintEqualToConstant:14],
        [self.statusDot.heightAnchor constraintEqualToConstant:14],
    ]];
    self.statusTitleLabel = [self labelWithStyle:UIFontTextStyleTitle2 color:[UIColor labelColor]];
    self.statusTitleLabel.font = [UIFont systemFontOfSize:self.statusTitleLabel.font.pointSize weight:UIFontWeightBold];
    UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.statusTitleLabel]];
    titleRow.spacing = 10;
    titleRow.alignment = UIStackViewAlignmentCenter;
    self.statusDetailLabel = [self labelWithStyle:UIFontTextStyleSubheadline color:[UIColor secondaryLabelColor]];
    UIStackView *statusStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleRow, self.statusDetailLabel]];
    statusStack.axis = UILayoutConstraintAxisVertical;
    statusStack.spacing = 6;

    // 電腦端設定
    UILabel *typeValue = [self labelWithStyle:UIFontTextStyleBody color:[UIColor secondaryLabelColor]];
    typeValue.text = @"SOCKS5";
    self.addressValueLabel = [self labelWithStyle:UIFontTextStyleBody color:[UIColor systemBlueColor]];
    self.addressValueLabel.text = @"—";
    self.portValueLabel = [self labelWithStyle:UIFontTextStyleBody color:[UIColor systemBlueColor]];
    self.portValueLabel.text = @"—";
    UILabel *authValue = [self labelWithStyle:UIFontTextStyleBody color:[UIColor secondaryLabelColor]];
    authValue.text = @"不需要";
    UIStackView *addressRow = [self rowWithName:@"伺服器位址" value:self.addressValueLabel];
    UIStackView *portRow = [self rowWithName:@"連接埠" value:self.portValueLabel];
    [addressRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyAddress:)]];
    [portRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPort:)]];
    UILabel *setupHint = [self labelWithStyle:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
    setupHint.text = @"在電腦的代理伺服器設定填入以上資料。點藍字可以拷貝。";
    UIStackView *setupStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self rowWithName:@"代理類型" value:typeValue], [self separator],
        addressRow, [self separator],
        portRow, [self separator],
        [self rowWithName:@"帳號密碼" value:authValue], setupHint,
    ]];
    setupStack.axis = UILayoutConstraintAxisVertical;
    setupStack.spacing = 12;

    // 流量
    self.uploadSpeedLabel = [self labelWithStyle:UIFontTextStyleBody color:[UIColor labelColor]];
    self.downloadSpeedLabel = [self labelWithStyle:UIFontTextStyleBody color:[UIColor labelColor]];
    self.uploadTotalLabel = [self labelWithStyle:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
    self.downloadTotalLabel = [self labelWithStyle:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
    UIStackView *trafficStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self trafficColumnWithTitle:@"↓ 下載" speed:self.downloadSpeedLabel total:self.downloadTotalLabel],
        [self trafficColumnWithTitle:@"↑ 上傳" speed:self.uploadSpeedLabel total:self.uploadTotalLabel],
    ]];
    trafficStack.distribution = UIStackViewDistributionFillEqually;

    // 使用中的裝置
    self.deviceListStack = [UIStackView new];
    self.deviceListStack.axis = UILayoutConstraintAxisVertical;
    self.deviceListStack.spacing = 10;

    // 詳細記錄（預設收起）
    self.logToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.logToggleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.logToggleButton addTarget:self action:@selector(toggleLog) forControlEvents:UIControlEventTouchUpInside];
    self.logTextView = [UITextView new];
    self.logTextView.editable = NO;
    self.logTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.logTextView.layer.cornerRadius = 10;
    self.logTextView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0];
    self.logTextView.hidden = YES;
    [self.logTextView.heightAnchor constraintEqualToConstant:320].active = YES;
    [self updateLogToggleTitle];

    UILabel *footer = [self labelWithStyle:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
    footer.text = @"App 可以切到背景繼續運作，但不要從多工畫面把它滑掉。";

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self cardWithTitle:@"狀態" content:statusStack],
        [self cardWithTitle:@"電腦端設定" content:setupStack],
        [self cardWithTitle:@"目前速度" content:trafficStack],
        [self cardWithTitle:@"使用中的裝置" content:self.deviceListStack],
        footer,
        self.logToggleButton,
        self.logTextView,
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 24;
    [content setCustomSpacing:8 afterView:self.logToggleButton];
    content.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:content];
    [self.view addSubview:scrollView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [content.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [content.widthAnchor constraintLessThanOrEqualToConstant:600],
    ]];

    [self refreshStatus];
    [self refreshClients];
}

- (void)refreshStatus {
    UIColor *color;
    NSString *title, *detail;
    switch (self.serverState) {
        case ServerStateStarting:
            color = [UIColor systemGrayColor];
            title = @"啟動中…";
            detail = @"正在尋找網路介面";
            break;
        case ServerStateRunning:
            color = [UIColor systemGreenColor];
            title = @"運作中";
            detail = self.activeClients.count > 0
                ? [NSString stringWithFormat:@"有 %lu 台裝置正在透過這支 iPhone 上網", (unsigned long)self.activeClients.count]
                : @"等待電腦連線。請在電腦填入下方的設定。";
            break;
        case ServerStateNoNetwork:
            color = [UIColor systemRedColor];
            title = @"無法啟動";
            detail = @"找不到可用的網路。請先開啟「個人熱點」或連上 Wi-Fi，再重新打開 App。";
            break;
        case ServerStateFailed:
            color = [UIColor systemRedColor];
            title = @"已停止";
            detail = @"代理伺服器意外停止，請重新打開 App。";
            break;
    }
    self.statusDot.backgroundColor = color;
    self.statusTitleLabel.text = title;
    self.statusDetailLabel.text = detail;
    BOOL running = self.serverState == ServerStateRunning;
    self.addressValueLabel.text = running ? self.ipAddress : @"—";
    self.portValueLabel.text = running ? [NSString stringWithFormat:@"%d", self.port] : @"—";
}

- (void)refreshClients {
    for (UIView *view in self.deviceListStack.arrangedSubviews) {
        [view removeFromSuperview];
    }
    NSArray<NSString *> *ips = [self.activeClients.allKeys sortedArrayUsingSelector:@selector(compare:)];
    if (ips.count == 0) {
        UILabel *empty = [self labelWithStyle:UIFontTextStyleBody color:[UIColor secondaryLabelColor]];
        empty.text = @"目前沒有裝置連線";
        [self.deviceListStack addArrangedSubview:empty];
    }
    NSDictionary *icons = @{@"Mac": @"💻", @"Windows": @"🖥️", @"iPhone": @"📱", @"iPad": @"📱", @"Apple 裝置": @"🍎"};
    for (NSString *ip in ips) {
        NSDictionary *info = self.deviceInfo[ip];
        NSString *kind = info[@"kind"] ?: @"辨識中…";
        UILabel *icon = [UILabel new];
        icon.font = [UIFont systemFontOfSize:28];
        icon.text = icons[kind] ?: @"❔";
        [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *name = [self labelWithStyle:UIFontTextStyleBody color:[UIColor labelColor]];
        name.text = info[@"name"] ?: kind;
        UILabel *detail = [self labelWithStyle:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
        detail.text = [NSString stringWithFormat:@"%@%@ · %@ 條連線",
                       info[@"name"] ? [kind stringByAppendingString:@" · "] : @"", ip, self.activeClients[ip]];
        UILabel *mac = [self labelWithStyle:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
        if (info[@"mac"]) {
            mac.text = [@"MAC " stringByAppendingString:info[@"mac"]];
        } else if (info[@"name"]) {
            mac.text = @"MAC：Apple 裝置不提供";
        }
        mac.hidden = mac.text == nil;
        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[name, detail, mac]];
        text.axis = UILayoutConstraintAxisVertical;
        text.spacing = 2;
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, text]];
        row.spacing = 12;
        row.alignment = UIStackViewAlignmentCenter;
        [self.deviceListStack addArrangedSubview:row];
    }
    [self refreshStatus];
}

- (void)copyValue:(NSString *)value from:(UILabel *)label {
    if (self.serverState != ServerStateRunning) return;
    [UIPasteboard generalPasteboard].string = value;
    label.text = @"已拷貝 ✓";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshStatus];
    });
}

- (void)copyAddress:(UITapGestureRecognizer *)sender {
    [self copyValue:self.ipAddress from:self.addressValueLabel];
}

- (void)copyPort:(UITapGestureRecognizer *)sender {
    [self copyValue:[NSString stringWithFormat:@"%d", self.port] from:self.portValueLabel];
}

- (void)updateLogToggleTitle {
    [self.logToggleButton setTitle:self.logTextView.hidden ? @"顯示詳細記錄 ▾" : @"隱藏詳細記錄 ▴"
                          forState:UIControlStateNormal];
}

- (void)toggleLog {
    self.logTextView.hidden = !self.logTextView.hidden;
    [self updateLogToggleTitle];
    [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
}

#pragma mark - 生命週期

- (void)viewDidLoad {
    [super viewDidLoad];
    sharedInstance = self;
    self.activeClients = [NSMutableDictionary dictionary];
    self.deviceInfo = [NSMutableDictionary dictionary];
    self.serverState = ServerStateStarting;
    [self buildInterface];

    freopen("/dev/null", "w", stdout);
    dup2(STDOUT_FILENO, STDERR_FILENO);

    [self logMessage:@"[SOCKS] View controller loaded"];

    int port = 9876;
    self.port = port;
    [self logMessage:[NSString stringWithFormat:@"[SOCKS] Initializing SOCKS server on port %d", port]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char portbuf[32];
        snprintf(portbuf, sizeof(portbuf), "%d", port);
        const char *argv[] = {"microsocks", "-p", portbuf, NULL};

        NSString *ipAddress = [AppDelegate deviceIPAddress];
        if ([ipAddress isEqualToString:@"127.0.0.1"]) {
            [self logMessage:@"[SOCKS] No matching interface found, using fallback IP address"];
            [self logMessage:@"[SOCKS] Stopping server due to no valid interface"];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.serverState = ServerStateNoNetwork;
                [self refreshStatus];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [self.audioPlayer stop];
                    [[AVAudioSession sharedInstance] setActive:NO error:nil];
                });
            });
            return;
        }
        [self logMessage:[NSString stringWithFormat:@"[SOCKS] Starting server at %@:%d", ipAddress, port]];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.ipAddress = ipAddress;
            self.serverState = ServerStateRunning;
            [self refreshStatus];
        });

        int status = socks_main(3, argv);
        [self logMessage:[NSString stringWithFormat:@"[SOCKS] Server exited with status: %d", status]];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.serverState = ServerStateFailed;
            [self refreshStatus];
        });
    });

    [self logMessage:@"[SOCKS] Setting up background audio"];
    NSURL *url = [NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:@"blank" ofType:@"wav"]];
    if (url) {
        // AVAudioSession 啟用可能卡住數百毫秒，不要放在主執行緒
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
            if (error) {
                [self logMessage:[NSString stringWithFormat:@"[SOCKS] Error creating audio player: %@", error.localizedDescription]];
            } else {
                [self logMessage:@"[SOCKS] Successfully created audio player"];
                [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                               withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                                     error:&error];
                if (error) {
                    [self logMessage:[NSString stringWithFormat:@"[SOCKS] Error setting audio session category: %@", error.localizedDescription]];
                }

                [[AVAudioSession sharedInstance] setActive:YES error:&error];
                if (error) {
                    [self logMessage:[NSString stringWithFormat:@"[SOCKS] Error activating audio session: %@", error.localizedDescription]];
                }

                [self.audioPlayer setVolume:0.01];
                [self.audioPlayer setNumberOfLoops:-1];
                [self.audioPlayer prepareToPlay];
                BOOL playSuccess = [self.audioPlayer play];
                [self logMessage:[NSString stringWithFormat:@"[SOCKS] Background audio %@ start", playSuccess ? @"did" : @"failed to"]];
            }
        });
    } else {
        [self logMessage:@"[SOCKS] Error: Could not find blank.wav resource"];
    }

    // Add stats update timer
    statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(updateStatsDisplay)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [self logMessage:@"[SOCKS] Received memory warning"];
}

- (void)logMessage:(NSString *)message {
    NSLog(@"%@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                          dateStyle:NSDateFormatterNoStyle
                                                          timeStyle:NSDateFormatterMediumStyle];

        NSMutableAttributedString *attributedMessage = [[NSMutableAttributedString alloc] init];

        // Timestamp in gray
        NSAttributedString *timeString = [[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"[%@]", timestamp]
            attributes:@{NSForegroundColorAttributeName: [UIColor grayColor]}];
        [attributedMessage appendAttributedString:timeString];

        // Message with color based on content
        UIColor *messageColor;
        if ([message containsString:@"Error"] || [message containsString:@"Failed"] || [message containsString:@"failed"]) {
            messageColor = [UIColor redColor];
        } else if ([message containsString:@"connected"] || [message containsString:@"Successfully"]) {
            messageColor = [UIColor greenColor];
        } else if ([message containsString:@"disconnected"]) {
            messageColor = [UIColor orangeColor];
        } else {
            messageColor = [UIColor whiteColor];
        }

        NSAttributedString *contentString = [[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@\n", message]
            attributes:@{NSForegroundColorAttributeName: messageColor}];
        [attributedMessage appendAttributedString:contentString];

        NSMutableAttributedString *currentText = [[NSMutableAttributedString alloc]
            initWithAttributedString:self.logTextView.attributedText ?: [[NSAttributedString alloc] init]];
        [currentText appendAttributedString:attributedMessage];

        // 為整個文本設置字體
        [currentText addAttribute:NSFontAttributeName
                           value:[UIFont fontWithName:@"Menlo-Regular" size:9.0]
                           range:NSMakeRange(0, currentText.length)];

        // 檢查並限制行數
        NSArray *lines = [currentText.string componentsSeparatedByString:@"\n"];
        if (lines.count > MAX_LOG_LINES) {
            NSRange deleteRange = [currentText.string rangeOfString:
                [[lines subarrayWithRange:NSMakeRange(0, lines.count - MAX_LOG_LINES)] componentsJoinedByString:@"\n"]];
            [currentText deleteCharactersInRange:deleteRange];
        }

        self.logTextView.attributedText = currentText;
        if (!self.logTextView.hidden) {
            [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
        }
    });
}

+ (void)logMessage:(NSString *)message {
    if (sharedInstance) {
        [sharedInstance logMessage:message];
    } else {
        NSLog(@"%@", message);
    }
}

+ (void)logFromC:(const char *)message {
    if (message) {
        NSString *nsMessage = [NSString stringWithUTF8String:message];
        [ViewController logMessage:nsMessage];
    }
}

- (void)updateStatsDisplay {
    pthread_mutex_lock(&pending_stats_mutex);
    uint64_t uploadBytes = pending_upload_bytes;
    uint64_t downloadBytes = pending_download_bytes;
    pthread_mutex_unlock(&pending_stats_mutex);

    [self updateStatsWithUpload:uploadBytes download:downloadBytes];
}

@end
