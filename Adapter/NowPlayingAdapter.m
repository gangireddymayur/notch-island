// NowPlayingAdapter — tiny bridge to Apple's private MediaRemote framework.
//
// Why this exists: since macOS 15.4 only Apple-signed processes may read
// "Now Playing" info. /usr/bin/perl is Apple-signed, so the app runs
//   /usr/bin/perl adapter.pl NowPlayingAdapter.dylib stream|command
// and perl loads this library. Everything here is read-only except
// nis_command, which sends play/pause/next/previous — nothing else.
//
// Stream output: one JSON line per change:
//   {"active": "<bundle id macOS considers current>",
//    "players": [{"bundleId", "title", "artist", ..., "artworkId", "artwork"?}, ...]}
// Artwork bytes (base64) are only included when they changed for that player.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef id (*MRGetLocalOriginFn)(void);
typedef CFStringRef (*MRClientGetStringFn)(id);
typedef void (*MRResolvePathFn)(id, dispatch_queue_t, void (^)(id, NSError *));
typedef void (*MRGetInfoForPlayerFn)(id, void *, dispatch_queue_t, void (^)(CFDictionaryRef, id));
typedef void (*MRGetStateForPlayerFn)(id, dispatch_queue_t, void (^)(unsigned));
typedef void (*MRSendToPlayerFn)(int, CFDictionaryRef, id, unsigned, dispatch_queue_t, void (^)(id));
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRRegisterFn)(dispatch_queue_t);

static MRGetClientsFn getClients;
static MRGetClientFn getActiveClient;
static MRGetLocalOriginFn getLocalOrigin;
static MRClientGetStringFn clientBundleId;
static MRClientGetStringFn clientParentBundleId;
static MRResolvePathFn resolvePath;
static MRGetInfoForPlayerFn getInfoForPlayer;
static MRGetStateForPlayerFn getStateForPlayer;
static MRSendToPlayerFn sendToPlayer;
static MRSendCommandFn sendCommand;
static MRRegisterFn registerForNotifications;

static dispatch_queue_t stateQueue;   // owns all mutable state below
static NSString *lastKey;
static NSMutableDictionary<NSString *, NSString *> *lastArtworkIds;
static BOOL refreshRunning, refreshAgain;

static BOOL load(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) return NO;
    getClients = (MRGetClientsFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClients");
    getActiveClient = (MRGetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    getLocalOrigin = (MRGetLocalOriginFn)dlsym(mr, "MRMediaRemoteGetLocalOrigin");
    clientBundleId = (MRClientGetStringFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundleId = (MRClientGetStringFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    resolvePath = (MRResolvePathFn)dlsym(mr, "MRMediaRemoteNowPlayingResolvePlayerPath");
    getInfoForPlayer = (MRGetInfoForPlayerFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    getStateForPlayer = (MRGetStateForPlayerFn)dlsym(mr, "MRMediaRemoteGetPlaybackStateForPlayer");
    sendToPlayer = (MRSendToPlayerFn)dlsym(mr, "MRMediaRemoteSendCommandToPlayer");
    sendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    registerForNotifications = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    return getClients && getLocalOrigin && clientBundleId && resolvePath && getInfoForPlayer
        && getStateForPlayer && NSClassFromString(@"MRPlayerPath");
}

static NSString *bundleIdOf(id client) {
    if (!client) return nil;
    NSString *parent = clientParentBundleId ? (__bridge NSString *)clientParentBundleId(client) : nil;
    return parent.length ? parent : (__bridge NSString *)clientBundleId(client);
}

/// Builds a player path for a client and asks MediaRemote to resolve it to the
/// app's real player. Calls back on an arbitrary queue (nil on failure).
static void resolvedPathFor(id client, void (^done)(id path)) {
    Class PP = NSClassFromString(@"MRPlayerPath");
    id path = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        [PP alloc], @selector(initWithOrigin:client:player:), getLocalOrigin(), client, nil);
    if (!path) { done(nil); return; }
    resolvePath(path, dispatch_queue_create(NULL, NULL), ^(id resolved, NSError *err) {
        done(resolved ?: path);
    });
}

static id jsonSafe(id v) { return v ?: [NSNull null]; }

static NSMutableDictionary *playerJSON(NSString *bundleId, NSDictionary *info, unsigned state) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"bundleId"] = bundleId;
    out[@"title"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    out[@"artist"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    out[@"album"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    out[@"duration"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
    out[@"elapsed"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
    out[@"rate"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
    NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    out[@"timestamp"] = [ts isKindOfClass:[NSDate class]] ? @([ts timeIntervalSince1970]) : [NSNull null];
    out[@"playing"] = @(state == 1);  // 1 playing, 2 paused, 3 stopped
    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    BOOL hasArt = [art isKindOfClass:[NSData class]] && art.length > 0;
    out[@"artworkId"] = hasArt ? [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash] : @"";
    if (hasArt) out[@"_art"] = art;  // stripped before output
    return out;
}

static void emit(NSArray<NSMutableDictionary *> *players, NSString *active) {
    // Stable order so the UI tabs don't jump around.
    NSArray *sorted = [players sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"bundleId"] compare:b[@"bundleId"]];
    }];
    NSMutableArray *forKey = [NSMutableArray array];
    for (NSDictionary *p in sorted) {
        NSMutableDictionary *c = [p mutableCopy];
        [c removeObjectForKey:@"_art"];
        [forKey addObject:c];
    }
    NSDictionary *keyObj = @{@"active": jsonSafe(active), @"players": forKey};
    NSData *keyJson = [NSJSONSerialization dataWithJSONObject:keyObj options:NSJSONWritingSortedKeys error:nil];
    NSString *key = [[NSString alloc] initWithData:keyJson encoding:NSUTF8StringEncoding];
    if ([key isEqualToString:lastKey]) return;
    lastKey = key;

    NSMutableArray *outPlayers = [NSMutableArray array];
    NSMutableDictionary *newArtIds = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *p in sorted) {
        NSData *art = p[@"_art"];
        [p removeObjectForKey:@"_art"];
        NSString *bid = p[@"bundleId"], *artId = p[@"artworkId"];
        if (art && ![artId isEqualToString:lastArtworkIds[bid]]) {
            p[@"artwork"] = [art base64EncodedStringWithOptions:0];
        }
        newArtIds[bid] = artId;
        [outPlayers addObject:p];
    }
    lastArtworkIds = newArtIds;

    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"active": jsonSafe(active), @"players": outPlayers}
                                                   options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void);

static void finishRefresh(NSArray *players, NSString *active) {
    dispatch_async(stateQueue, ^{
        emit(players, active);
        refreshRunning = NO;
        if (refreshAgain) { refreshAgain = NO; refresh(); }
    });
}

/// Must be called on stateQueue. Never blocks: everything is callback-driven.
static void refresh(void) {
    if (refreshRunning) { refreshAgain = YES; return; }
    refreshRunning = YES;

    dispatch_queue_t work = dispatch_queue_create(NULL, NULL);
    getClients(work, ^(CFArrayRef cfClients) {
        NSArray *clients = [(__bridge NSArray *)cfClients copy] ?: @[];
        NSMutableArray *players = [NSMutableArray array];
        NSObject *lock = [NSObject new];
        __block NSString *active = nil;
        dispatch_group_t group = dispatch_group_create();

        if (getActiveClient) {
            dispatch_group_enter(group);
            getActiveClient(dispatch_queue_create(NULL, NULL), ^(id client) {
                active = bundleIdOf(client);
                dispatch_group_leave(group);
            });
        }

        for (id client in clients) {
            NSString *bid = bundleIdOf(client);
            if (!bid.length) continue;
            dispatch_group_enter(group);
            resolvedPathFor(client, ^(id path) {
                if (!path) { dispatch_group_leave(group); return; }
                getInfoForPlayer(path, (void *)1 /* include artwork */, dispatch_queue_create(NULL, NULL), ^(CFDictionaryRef cfInfo, id err) {
                    NSDictionary *info = [(__bridge NSDictionary *)cfInfo copy] ?: @{};
                    getStateForPlayer(path, dispatch_queue_create(NULL, NULL), ^(unsigned state) {
                        if ([info[@"kMRMediaRemoteNowPlayingInfoTitle"] length] > 0) {
                            @synchronized (lock) { [players addObject:playerJSON(bid, info, state)]; }
                        }
                        dispatch_group_leave(group);
                    });
                });
            });
        }

        // Never hang the stream if one app doesn't answer.
        __block BOOL finished = NO;
        void (^complete)(void) = ^{
            @synchronized (lock) {
                if (finished) return;
                finished = YES;
                finishRefresh([players copy], active);
            }
        };
        dispatch_group_notify(group, work, complete);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), work, complete);
    });
}

// perl calls XSUBs as fn(PerlInterpreter*, CV*); we ignore both arguments.

__attribute__((visibility("default")))
void nis_stream(void *perl, void *cv) {
    if (!load()) { fprintf(stderr, "MediaRemote unavailable\n"); exit(2); }
    stateQueue = dispatch_queue_create("notchisland.adapter", DISPATCH_QUEUE_SERIAL);
    pid_t parent = getppid();

    if (registerForNotifications) registerForNotifications(dispatch_queue_create(NULL, NULL));
    NSArray *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification",
        @"_MRMediaRemotePlayerNowPlayingInfoDidChangeNotification",
    ];
    for (NSString *name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *n) {
            dispatch_async(stateQueue, ^{ refresh(); });
        }];
    }

    // Backup check every 2.5 s (changes normally arrive as notifications);
    // output is deduped. Also exits if the app went away.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, stateQueue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2500 * NSEC_PER_MSEC, 500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (getppid() != parent) exit(0);
        refresh();
    });
    dispatch_resume(timer);

    CFRunLoopRun();
}

// Commands: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
// NIS_CMD = command, NIS_PLAYER = bundle id of the target app (optional).
__attribute__((visibility("default")))
void nis_command(void *perl, void *cv) {
    if (!load()) exit(2);
    const char *arg = getenv("NIS_CMD");
    if (!arg) exit(1);
    int cmd = atoi(arg);
    if (cmd != 0 && cmd != 1 && cmd != 2 && cmd != 4 && cmd != 5) exit(1);

    const char *target = getenv("NIS_PLAYER");
    if (!target || !*target || !sendToPlayer) {
        if (sendCommand) sendCommand(cmd, NULL);
        exit(0);
    }
    NSString *want = [NSString stringWithUTF8String:target];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(3); });
    getClients(dispatch_queue_create(NULL, NULL), ^(CFArrayRef cfClients) {
        for (id client in (__bridge NSArray *)cfClients) {
            if (![bundleIdOf(client) isEqualToString:want]) continue;
            resolvedPathFor(client, ^(id path) {
                if (!path) exit(4);
                sendToPlayer(cmd, NULL, path, 0, dispatch_queue_create(NULL, NULL), ^(id result) { exit(0); });
            });
            return;
        }
        exit(4);  // that app is no longer playing anything
    });
    CFRunLoopRun();
}
