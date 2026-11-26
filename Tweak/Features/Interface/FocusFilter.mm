#import "FocusFilter.h"
#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Settings/YTKACERootOptionsController.h"
#import "../../UI/Notice.h"

#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

// =========================================================================
// --- HARDCODED FOCUS FILTER + BLOCKED OVERLAY + SHORTS REDIRECT ---
// =========================================================================
// 1. Removes Home Screen recommendations (FEwhat_to_watch)
// 2. Removes Watch page related/suggested videos
// 3. Removes end screen recommendations & autonav endscreen
// 4. Redirects Shorts (reelWatchEndpoint) to the normal video player (watchEndpoint)
// 5. Shows a "Blocked" overlay (instead of deleting from Search) for:
//    - 59 blocked channels (exact match, case-insensitive)
//    - 20 blocked title keywords (case-insensitive)
//    - Disallowed YouTube categories via YouTube Data API v3 + 30-day cache
//      (Allowed only: 22 People & Blogs, 24 Entertainment, 26 Howto & Style,
//       27 Education, 28 Science & Technology)

#if __has_include("FocusAPIKey.local.h")
#import "FocusAPIKey.local.h"
#else
static NSString *const kYTBlockAPIKey = @"";
#endif
static const NSTimeInterval kYTBlockCacheTTL = 30.0 * 24.0 * 60.0 * 60.0; // 30 days
static const NSInteger kFocusBlockedOverlayTag = 0x464F4355;

static NSString *const kUserBlockedChannelsKey = @"YTKACE.Focus.UserBlockedChannels";
static NSString *const kBlockedChannelsKey = @"YTKACE.Focus.BlockedChannels";
static NSString *const kBlockedTitleKeywordsKey = @"YTKACE.Focus.BlockedTitleKeywords";
static NSString *const kBlockedCategoryIDsKey = @"YTKACE.Focus.BlockedCategoryIDs";
static NSString *const kBlockedTitleSeedVersionKey = @"YTKACE.Focus.TitleSeedVersion";
static NSString *const kFocusPasswordHashKey = @"YTKACE.Focus.PasswordHash";
static NSString *const kFocusCustomAPIKey = @"YTKACE.Focus.APIKey";
static NSString *const kUserBlockedVideoIDsKey = @"YTKACE.Focus.UserBlockedVideoIDs";
static NSString *const kUserBlockedVideoTitlesKey = @"YTKACE.Focus.UserBlockedVideoTitles";
static NSString *const kFocusBlocklistChangedNotification = @"YTKACEFocusBlocklistDidChangeNotification";

static os_unfair_lock gFocusCacheLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSDictionary *> *gFocusCache = nil;
static NSMutableSet<NSString *> *gFocusInFlightIDs = nil;
static NSMutableArray<NSString *> *gBlockedChannelsDisplay = nil;
static NSMutableSet<NSString *> *gBlockedChannelsLower = nil;
static NSMutableArray<NSString *> *gBlockedTitleKeywords = nil;
static NSMutableSet<NSString *> *gBlockedCategoryIDs = nil;
static NSMutableSet<NSString *> *gUserBlockedVideoIDs = nil;
static NSMutableSet<NSString *> *gUserBlockedVideoTitles = nil;
static BOOL gFocusCacheLoaded = NO;
static BOOL gFocusCacheDirty = NO;

static __weak id gActivePlayerController = nil;
static NSString *gActiveVideoID = nil;

static const void *kFocusBlockedVideoKey = &kFocusBlockedVideoKey;
static const void *kFocusCellReasonKey = &kFocusCellReasonKey;

static IMP OriginalPlayerPlay = NULL;
static IMP OriginalHasEndscreen = NULL;
static IMP OriginalEndscreen = NULL;
static IMP OriginalCreatorEndscreenShow = NULL;
static IMP OriginalCellLayoutSubviews = NULL;
static IMP OriginalCellPrepareForReuse = NULL;
static IMP OriginalCmdHandle5 = NULL;
static IMP OriginalCmdHandle4 = NULL;
static IMP OriginalCmdHandle3 = NULL;
static IMP OriginalCmdHandle1 = NULL;
static IMP OriginalMDCStartAnimating = NULL;
static IMP OriginalMDCDidMoveToWindow = NULL;
static IMP OriginalQTMStartAnimating = NULL;
static IMP OriginalUIActivityStartAnimating = NULL;
static IMP OriginalBrowseLayoutSubviews = NULL;

// Allowed YouTube Data API v3 category IDs:
// 22 = People & Blogs, 24 = Entertainment, 26 = Howto & Style,
// 27 = Education, 28 = Science & Technology
NSArray<NSDictionary<NSString *, NSString *> *> *YTKACEFocusAllCategories(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *cats = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cats = @[
            @{@"id": @"32", @"name": @"Action/Adventure"},
            @{@"id": @"31", @"name": @"Anime/Animation"},
            @{@"id": @"2",  @"name": @"Autos & Vehicles"},
            @{@"id": @"33", @"name": @"Classics"},
            @{@"id": @"23", @"name": @"Comedy"},
            @{@"id": @"35", @"name": @"Documentary"},
            @{@"id": @"36", @"name": @"Drama"},
            @{@"id": @"27", @"name": @"Education"},
            @{@"id": @"24", @"name": @"Entertainment"},
            @{@"id": @"37", @"name": @"Family"},
            @{@"id": @"1",  @"name": @"Film & Animation"},
            @{@"id": @"38", @"name": @"Foreign"},
            @{@"id": @"20", @"name": @"Gaming"},
            @{@"id": @"39", @"name": @"Horror"},
            @{@"id": @"26", @"name": @"Howto & Style"},
            @{@"id": @"34", @"name": @"Movie/Comedy"},
            @{@"id": @"30", @"name": @"Movies"},
            @{@"id": @"10", @"name": @"Music"},
            @{@"id": @"25", @"name": @"News & Politics"},
            @{@"id": @"29", @"name": @"Nonprofits & Activism"},
            @{@"id": @"22", @"name": @"People & Blogs"},
            @{@"id": @"15", @"name": @"Pets & Animals"},
            @{@"id": @"40", @"name": @"Sci-Fi/Fantasy"},
            @{@"id": @"28", @"name": @"Science & Technology"},
            @{@"id": @"18", @"name": @"Short Movies"},
            @{@"id": @"42", @"name": @"Shorts"},
            @{@"id": @"43", @"name": @"Shows"},
            @{@"id": @"17", @"name": @"Sports"},
            @{@"id": @"41", @"name": @"Thriller"},
            @{@"id": @"44", @"name": @"Trailers"},
            @{@"id": @"19", @"name": @"Travel & Events"},
            @{@"id": @"21", @"name": @"Videoblogging"}
        ];
    });
    return cats;
}

static NSSet<NSString *> *YTKACEDefaultBlockedCategoryIDs(void) {
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[@"22", @"24", @"26", @"27", @"28"]];
    NSMutableSet<NSString *> *blocked = [NSMutableSet set];
    for (NSDictionary<NSString *, NSString *> *cat in YTKACEFocusAllCategories()) {
        if (![allowed containsObject:cat[@"id"]]) {
            [blocked addObject:cat[@"id"]];
        }
    }
    return [blocked copy];
}

static NSArray<NSString *> *YTKACEDefaultBlockedChannels(void) {
    static NSArray<NSString *> *raw = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        raw = @[
            @"Adda247 Skills",
            @"Neon Man",
            @"TechLinked",
            @"GameLinked",
            @"Linus Tech Tips",
            @"Sillycorns",
            @"Tech Burner",
            @"Beebom",
            @"Marques Brownlee",
            @"Mrwhosetheboss",
            @"Techquickie",
            @"Samay Raina",
            @"About Celebrities",
            @"Krushna Abhishek",
            @"NeuzBoy",
            @"Abhi and Niyu",
            @"The Deshbhakt",
            @"Aono",
            @"TechWiser",
            @"Mohak Mangal",
            @"Light Raider",
            @"Asmongold TV",
            @"CarryisLive",
            @"CarryMinati",
            @"Thugesh Unfiltered",
            @"Thugesh",
            @"Real Thugesh",
            @"Triggered Insaan",
            @"Live Insaan",
            @"Nischay Malhan",
            @"Tanmay Bhat",
            @"REJECTED PIECE",
            @"Play Like Incognito",
            @"Three Angry Boys",
            @"You Roasted",
            @"Bhanu Max",
            @"phanumantu",
            @"Nela Ticket Batch Telugu - NTB",
            @"301 Diaries",
            @"SKR COUNTERS",
            @"Roasted By Surya",
            @"Karthifer",
            @"RODROAST",
            @"MemaPur",
            @"Shriman Shriwastav",
            @"Asmongold Clips",
            @"Tectone",
            @"Live Speedy",
            @"Speedy Boykins",
            @"PAYAL GAMING",
            @"MBG ARMY",
            @"IShowFF",
            @"Munna bhai gaming",
            @"TEAM MBG",
            @"StudyIQ IAS",
            @"Mr Techpedia",
            @"w h i t e",
            @"Dokokonut",
            @"Flonil"
        ];
    });
    return raw;
}

static NSArray<NSString *> *YTKACEDefaultBlockedTitleKeywords(void) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"music", @"lyrics", @"phonk", @"funny", @"remix", @"alan walker",
            @"meme", @"slowed", @"sped up", @"sofia ansari", @"samantha", @"hot fap",
            @"rashmika", @"nabha natesh", @"payal gaming", @"hot pics", @"hot shorts",
            @"hot videos", @"hot reels", @"sssniperwolf",
            @"reverb", @"bass boosted", @"nightcore", @"mashup", @"full song",
            @"official video", @"lyrical", @"lofi", @"status video", @"bgm",
            @"8d audio", @"unplugged", @"jukebox", @"ringtone",
            @"roast", @"roasted", @"roasting", @"reaction", @"reacts to", @"drama",
            @"controversy", @"exposed", @"beef", @"stand up comedy", @"standup comedy",
            @"prank", @"try not to laugh", @"troll", @"cringe",
            @"whatsapp status", @"instagram reels", @"attitude status", @"sigma",
            @"dank", @"shitpost", @"compilation", @"funny moments", @"gossip",
            @"paparazzi", @"spotted", @"bikini", @"photoshoot", @"bold scene", @"item song",
            @"gameplay", @"walkthrough", @"valorant", @"bgmi", @"free fire",
            @"gta 5", @"minecraft", @"live stream", @"twitch clips"
        ];
    });
    return keywords;
}

// MARK: - 30-Day Disk Cache & Editable Filter Store

static NSURL *YTKACEFocusCacheURL(void) {
    return [YTKACEApplicationSupportDirectory()
        URLByAppendingPathComponent:@"ytblock_api_cache.plist"];
}

static void YTKACEFocusLoadCacheIfNeeded(void) {
    os_unfair_lock_lock(&gFocusCacheLock);
    if (!gFocusCacheLoaded) {
        gFocusCacheLoaded = YES;
        gFocusInFlightIDs = [NSMutableSet set];
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfURL:YTKACEFocusCacheURL()];
        gFocusCache = [NSMutableDictionary dictionary];
        if ([disk isKindOfClass:NSDictionary.class]) {
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            for (NSString *vid in disk) {
                NSDictionary *entry = disk[vid];
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                NSTimeInterval ts = [entry[@"ts"] doubleValue];
                if (now - ts < kYTBlockCacheTTL) {
                    gFocusCache[vid] = entry;
                }
            }
        }

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

        NSArray *savedCats = [defaults arrayForKey:kBlockedCategoryIDsKey];
        if (savedCats != nil) {
            gBlockedCategoryIDs = [NSMutableSet set];
            for (id c in savedCats) {
                if ([c isKindOfClass:NSString.class]) [gBlockedCategoryIDs addObject:c];
            }
        } else {
            gBlockedCategoryIDs = [YTKACEDefaultBlockedCategoryIDs() mutableCopy];
            [defaults setObject:[gBlockedCategoryIDs allObjects] forKey:kBlockedCategoryIDsKey];
        }

        NSArray *savedTitles = [defaults arrayForKey:kBlockedTitleKeywordsKey];
        NSInteger seedVer = [defaults integerForKey:kBlockedTitleSeedVersionKey];
        gBlockedTitleKeywords = [NSMutableArray array];
        if (savedTitles != nil) {
            for (id item in savedTitles) {
                if ([item isKindOfClass:NSString.class] && ((NSString *)item).length > 0) {
                    NSString *lw = [(NSString *)item lowercaseString];
                    if (![gBlockedTitleKeywords containsObject:lw]) [gBlockedTitleKeywords addObject:lw];
                }
            }
            if (seedVer < 2) {
                for (NSString *kw in YTKACEDefaultBlockedTitleKeywords()) {
                    if (![gBlockedTitleKeywords containsObject:kw]) [gBlockedTitleKeywords addObject:kw];
                }
                [defaults setObject:[gBlockedTitleKeywords copy] forKey:kBlockedTitleKeywordsKey];
                [defaults setInteger:2 forKey:kBlockedTitleSeedVersionKey];
            }
        } else {
            [gBlockedTitleKeywords addObjectsFromArray:YTKACEDefaultBlockedTitleKeywords()];
            [defaults setObject:[gBlockedTitleKeywords copy] forKey:kBlockedTitleKeywordsKey];
            [defaults setInteger:2 forKey:kBlockedTitleSeedVersionKey];
        }

        NSArray *savedChannels = [defaults arrayForKey:kBlockedChannelsKey];
        gBlockedChannelsDisplay = [NSMutableArray array];
        gBlockedChannelsLower = [NSMutableSet set];
        NSArray *seedChannels = savedChannels ?: YTKACEDefaultBlockedChannels();
        for (id item in seedChannels) {
            if (![item isKindOfClass:NSString.class]) continue;
            NSString *clean = [(NSString *)item stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (clean.length == 0) continue;
            NSString *lw = [clean lowercaseString];
            if (![gBlockedChannelsLower containsObject:lw]) {
                [gBlockedChannelsLower addObject:lw];
                [gBlockedChannelsDisplay addObject:clean];
            }
        }
        for (id item in [defaults arrayForKey:kUserBlockedChannelsKey]) {
            if (![item isKindOfClass:NSString.class]) continue;
            NSString *clean = [(NSString *)item stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (clean.length == 0) continue;
            NSString *lw = [clean lowercaseString];
            if (![gBlockedChannelsLower containsObject:lw]) {
                [gBlockedChannelsLower addObject:lw];
                [gBlockedChannelsDisplay addObject:clean];
            }
        }
        if (savedChannels == nil) {
            [defaults setObject:[gBlockedChannelsDisplay copy] forKey:kBlockedChannelsKey];
        }

        gUserBlockedVideoIDs = [NSMutableSet set];
        for (id item in [defaults arrayForKey:kUserBlockedVideoIDsKey]) {
            if ([item isKindOfClass:NSString.class] && ((NSString *)item).length == 11) {
                [gUserBlockedVideoIDs addObject:item];
            }
        }
        gUserBlockedVideoTitles = [NSMutableSet set];
        for (id item in [defaults arrayForKey:kUserBlockedVideoTitlesKey]) {
            if ([item isKindOfClass:NSString.class] && ((NSString *)item).length >= 3) {
                [gUserBlockedVideoTitles addObject:[(NSString *)item lowercaseString]];
            }
        }
    }
    os_unfair_lock_unlock(&gFocusCacheLock);
}

static void YTKACEFocusScheduleCacheSave(void) {
    os_unfair_lock_lock(&gFocusCacheLock);
    if (gFocusCacheDirty) {
        os_unfair_lock_unlock(&gFocusCacheLock);
        return;
    }
    gFocusCacheDirty = YES;
    os_unfair_lock_unlock(&gFocusCacheLock);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&gFocusCacheLock);
        gFocusCacheDirty = NO;
        NSDictionary *snapshot = [gFocusCache copy];
        os_unfair_lock_unlock(&gFocusCacheLock);
        [snapshot writeToURL:YTKACEFocusCacheURL() atomically:YES];
    });
}

static NSDictionary *YTKACEFocusCachedInfo(NSString *videoID) {
    if (videoID.length != 11) return nil;
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    NSDictionary *entry = gFocusCache[videoID];
    os_unfair_lock_unlock(&gFocusCacheLock);
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    NSTimeInterval ts = [entry[@"ts"] doubleValue];
    if (NSDate.date.timeIntervalSince1970 - ts >= kYTBlockCacheTTL) {
        return nil;
    }
    return entry;
}

static void YTKACEFocusNotifyBlocklistChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:kFocusBlocklistChangedNotification
                          object:nil];
    });
}

static void YTKACEFocusAddUserBlockedChannel(NSString *channelName) {
    NSString *trimmed = [channelName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return;
    NSString *lower = [trimmed lowercaseString];
    YTKACEFocusLoadCacheIfNeeded();
    NSArray<NSString *> *allChannels = nil;
    os_unfair_lock_lock(&gFocusCacheLock);
    if (![gBlockedChannelsLower containsObject:lower]) {
        [gBlockedChannelsLower addObject:lower];
        [gBlockedChannelsDisplay addObject:trimmed];
    }
    allChannels = [gBlockedChannelsDisplay copy];
    os_unfair_lock_unlock(&gFocusCacheLock);
    [NSUserDefaults.standardUserDefaults setObject:allChannels forKey:kBlockedChannelsKey];
    YTKACEFocusNotifyBlocklistChanged();
}

static void YTKACEFocusAddUserBlockedVideo(NSString *videoID, NSString * _Nullable title) {
    YTKACEFocusLoadCacheIfNeeded();
    NSArray<NSString *> *allIDs = nil;
    NSArray<NSString *> *allTitles = nil;
    os_unfair_lock_lock(&gFocusCacheLock);
    if (videoID.length == 11) {
        [gUserBlockedVideoIDs addObject:videoID];
        allIDs = [gUserBlockedVideoIDs allObjects];
    }
    NSString *trimmedTitle = [title stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedTitle.length >= 3) {
        [gUserBlockedVideoTitles addObject:[trimmedTitle lowercaseString]];
        allTitles = [gUserBlockedVideoTitles allObjects];
    }
    os_unfair_lock_unlock(&gFocusCacheLock);
    if (allIDs != nil) {
        [NSUserDefaults.standardUserDefaults setObject:allIDs forKey:kUserBlockedVideoIDsKey];
    }
    if (allTitles != nil) {
        [NSUserDefaults.standardUserDefaults setObject:allTitles forKey:kUserBlockedVideoTitlesKey];
    }
    YTKACEFocusNotifyBlocklistChanged();
}

// MARK: - Exported Filter Management & Password APIs

NSSet<NSString *> *YTKACEFocusGetBlockedCategoryIDs(void) {
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    NSSet<NSString *> *copy = [gBlockedCategoryIDs copy];
    os_unfair_lock_unlock(&gFocusCacheLock);
    return copy;
}

void YTKACEFocusSetBlockedCategoryIDs(NSSet<NSString *> *categoryIDs) {
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    gBlockedCategoryIDs = [categoryIDs mutableCopy] ?: [NSMutableSet set];
    NSArray *arr = [gBlockedCategoryIDs allObjects];
    os_unfair_lock_unlock(&gFocusCacheLock);
    [NSUserDefaults.standardUserDefaults setObject:arr forKey:kBlockedCategoryIDsKey];
    YTKACEFocusNotifyBlocklistChanged();
}

NSArray<NSString *> *YTKACEFocusGetBlockedTitleKeywords(void) {
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    NSArray<NSString *> *copy = [gBlockedTitleKeywords copy];
    os_unfair_lock_unlock(&gFocusCacheLock);
    return copy;
}

void YTKACEFocusSetBlockedTitleKeywords(NSArray<NSString *> *keywords) {
    YTKACEFocusLoadCacheIfNeeded();
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *kw in keywords) {
        NSString *lw = [[kw stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if (lw.length > 0 && ![clean containsObject:lw]) [clean addObject:lw];
    }
    os_unfair_lock_lock(&gFocusCacheLock);
    gBlockedTitleKeywords = clean;
    NSArray *snapshot = [gBlockedTitleKeywords copy];
    os_unfair_lock_unlock(&gFocusCacheLock);
    [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kBlockedTitleKeywordsKey];
    [NSUserDefaults.standardUserDefaults setInteger:2 forKey:kBlockedTitleSeedVersionKey];
    YTKACEFocusNotifyBlocklistChanged();
}

NSArray<NSString *> *YTKACEFocusGetBlockedChannels(void) {
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    NSArray<NSString *> *copy = [gBlockedChannelsDisplay copy];
    os_unfair_lock_unlock(&gFocusCacheLock);
    return copy;
}

void YTKACEFocusSetBlockedChannels(NSArray<NSString *> *channels) {
    YTKACEFocusLoadCacheIfNeeded();
    NSMutableArray<NSString *> *display = [NSMutableArray array];
    NSMutableSet<NSString *> *lower = [NSMutableSet set];
    for (NSString *ch in channels) {
        NSString *clean = [ch stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length == 0) continue;
        NSString *lw = [clean lowercaseString];
        if (![lower containsObject:lw]) {
            [lower addObject:lw];
            [display addObject:clean];
        }
    }
    os_unfair_lock_lock(&gFocusCacheLock);
    gBlockedChannelsDisplay = display;
    gBlockedChannelsLower = lower;
    NSArray *snapshot = [gBlockedChannelsDisplay copy];
    os_unfair_lock_unlock(&gFocusCacheLock);
    [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kBlockedChannelsKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kUserBlockedChannelsKey];
    YTKACEFocusNotifyBlocklistChanged();
}

NSUInteger YTKACEFocusBlockedVideoCount(void) {
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    NSUInteger count = MAX(gUserBlockedVideoIDs.count, gUserBlockedVideoTitles.count);
    os_unfair_lock_unlock(&gFocusCacheLock);
    return count;
}

void YTKACEFocusClearBlockedVideos(void) {
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    [gUserBlockedVideoIDs removeAllObjects];
    [gUserBlockedVideoTitles removeAllObjects];
    os_unfair_lock_unlock(&gFocusCacheLock);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kUserBlockedVideoIDsKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kUserBlockedVideoTitlesKey];
    YTKACEFocusNotifyBlocklistChanged();
}

static NSString *YTKACEFocusHashPassword(NSString *password) {
    NSString *salted = [NSString stringWithFormat:@"YTKACE_FOCUS_SALT_v1:%@", password ?: @""];
    NSData *data = [salted dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

BOOL YTKACEFocusHasPassword(void) {
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kFocusPasswordHashKey];
    return stored.length == CC_SHA256_DIGEST_LENGTH * 2;
}

BOOL YTKACEFocusVerifyPassword(NSString *password) {
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kFocusPasswordHashKey];
    if (stored.length == 0 || password.length == 0) return NO;
    return [stored isEqualToString:YTKACEFocusHashPassword(password)];
}

void YTKACEFocusSetPassword(NSString *password) {
    if (password.length == 0) return;
    [NSUserDefaults.standardUserDefaults setObject:YTKACEFocusHashPassword(password)
                                            forKey:kFocusPasswordHashKey];
}

NSString *YTKACEFocusGetAPIKey(void) {
    NSString *custom = [[NSUserDefaults.standardUserDefaults stringForKey:kFocusCustomAPIKey]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (custom.length > 0) return custom;
    return kYTBlockAPIKey ?: @"";
}

BOOL YTKACEFocusHasCustomAPIKey(void) {
    NSString *custom = [[NSUserDefaults.standardUserDefaults stringForKey:kFocusCustomAPIKey]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return custom.length > 0;
}

void YTKACEFocusSetAPIKey(NSString * _Nullable apiKey) {
    NSString *trimmed = [apiKey stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kFocusCustomAPIKey];
    } else {
        [NSUserDefaults.standardUserDefaults setObject:trimmed forKey:kFocusCustomAPIKey];
    }
}

// MARK: - Matching Helpers

static BOOL YTKACEIsVideoIDBlocked(NSString *videoID) {
    if (videoID.length != 11) return NO;
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    BOOL blocked = [gUserBlockedVideoIDs containsObject:videoID];
    os_unfair_lock_unlock(&gFocusCacheLock);
    return blocked;
}

static BOOL YTKACEIsExactChannelBlocked(NSString *lowerTrimmed) {
    if (lowerTrimmed.length == 0) return NO;
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    BOOL blocked = [gBlockedChannelsLower containsObject:lowerTrimmed];
    os_unfair_lock_unlock(&gFocusCacheLock);
    return blocked;
}

static BOOL YTKACEIsChannelNameBlocked(NSString *channelName) {
    if (channelName.length == 0) return NO;
    NSString *trimmed = [[channelName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (trimmed.length == 0) return NO;
    if (YTKACEIsExactChannelBlocked(trimmed)) return YES;

    NSArray<NSString *> *seps = @[@" • ", @" · ", @" \u2022 ", @" \u00B7 ", @" - "];
    for (NSString *sep in seps) {
        NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:sep];
        if (parts.count > 1) {
            for (NSString *part in parts) {
                NSString *clean = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (YTKACEIsExactChannelBlocked(clean)) return YES;
            }
        }
    }
    if ([trimmed hasPrefix:@"by "]) {
        NSString *afterBy = [[trimmed substringFromIndex:3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (YTKACEIsExactChannelBlocked(afterBy)) return YES;
    }
    return NO;
}

static BOOL YTKACEIsTitleBlocked(NSString *title) {
    if (title.length == 0) return NO;
    NSString *lower = [title lowercaseString];
    YTKACEFocusLoadCacheIfNeeded();
    NSArray<NSString *> *keywords = nil;
    NSArray<NSString *> *blockedTitles = nil;
    os_unfair_lock_lock(&gFocusCacheLock);
    keywords = [gBlockedTitleKeywords copy];
    if (gUserBlockedVideoTitles.count > 0) {
        blockedTitles = [gUserBlockedVideoTitles allObjects];
    }
    os_unfair_lock_unlock(&gFocusCacheLock);
    for (NSString *kw in keywords) {
        if ([lower containsString:kw]) return YES;
    }
    for (NSString *bt in blockedTitles) {
        if ([lower isEqualToString:bt] || [lower containsString:bt]) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTKACEIsCategoryBlocked(NSString *categoryID) {
    if (categoryID.length == 0) return NO;
    YTKACEFocusLoadCacheIfNeeded();
    os_unfair_lock_lock(&gFocusCacheLock);
    BOOL blocked = [gBlockedCategoryIDs containsObject:categoryID];
    os_unfair_lock_unlock(&gFocusCacheLock);
    return blocked;
}

static NSString *YTKACEBlockReasonForMetadata(NSString *videoID, NSString *channel, NSString *title, NSString *categoryID) {
    if (YTKACEIsVideoIDBlocked(videoID)) {
        return @"Blocked video";
    }
    if (YTKACEIsChannelNameBlocked(channel)) {
        return [NSString stringWithFormat:@"Blocked channel: %@", channel];
    }
    if (YTKACEIsTitleBlocked(title)) {
        return @"Blocked by title filter";
    }
    if (YTKACEIsCategoryBlocked(categoryID)) {
        return @"Blocked by category filter";
    }
    return nil;
}

// MARK: - YouTube Data API v3 Lookup (Batched + Cached)

static void YTKACEFetchVideosFromAPI(NSArray<NSString *> *videoIDs,
                                     void (^completion)(NSDictionary<NSString *, NSDictionary *> *results)) {
    NSString *apiKey = YTKACEFocusGetAPIKey();
    if (videoIDs.count == 0 || apiKey.length == 0) {
        if (completion) completion(@{});
        return;
    }
    YTKACEFocusLoadCacheIfNeeded();

    NSMutableArray<NSString *> *toFetch = [NSMutableArray array];
    os_unfair_lock_lock(&gFocusCacheLock);
    for (NSString *vid in videoIDs) {
        if (vid.length != 11) continue;
        if (gFocusCache[vid] != nil || [gFocusInFlightIDs containsObject:vid]) continue;
        [gFocusInFlightIDs addObject:vid];
        [toFetch addObject:vid];
        if (toFetch.count >= 50) break;
    }
    os_unfair_lock_unlock(&gFocusCacheLock);

    if (toFetch.count == 0) {
        if (completion) completion(@{});
        return;
    }

    NSString *idsParam = [toFetch componentsJoinedByString:@","];
    NSString *urlString = [NSString stringWithFormat:
        @"https://www.googleapis.com/youtube/v3/videos?part=snippet&fields=items(id,snippet(title,channelTitle,categoryId))&id=%@&key=%@",
        idsParam, apiKey];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        os_unfair_lock_lock(&gFocusCacheLock);
        for (NSString *vid in toFetch) [gFocusInFlightIDs removeObject:vid];
        os_unfair_lock_unlock(&gFocusCacheLock);
        if (completion) completion(@{});
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12.0;

    [[NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableDictionary<NSString *, NSDictionary *> *parsed = [NSMutableDictionary dictionary];
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class] &&
            ((NSHTTPURLResponse *)response).statusCode == 200 && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *items = [json isKindOfClass:NSDictionary.class] ? json[@"items"] : nil;
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            if ([items isKindOfClass:NSArray.class]) {
                for (id item in items) {
                    if (![item isKindOfClass:NSDictionary.class]) continue;
                    NSString *vid = item[@"id"];
                    NSDictionary *snippet = item[@"snippet"];
                    if (![vid isKindOfClass:NSString.class] || ![snippet isKindOfClass:NSDictionary.class]) continue;
                    NSString *cat = [snippet[@"categoryId"] isKindOfClass:NSString.class] ? snippet[@"categoryId"] : @"";
                    NSString *ch = [snippet[@"channelTitle"] isKindOfClass:NSString.class] ? snippet[@"channelTitle"] : @"";
                    NSString *title = [snippet[@"title"] isKindOfClass:NSString.class] ? snippet[@"title"] : @"";
                    parsed[vid] = @{@"cat": cat, @"ch": ch, @"t": title, @"ts": @(now)};
                }
            }
        }

        os_unfair_lock_lock(&gFocusCacheLock);
        for (NSString *vid in toFetch) {
            [gFocusInFlightIDs removeObject:vid];
            if (parsed[vid] != nil) {
                gFocusCache[vid] = parsed[vid];
            }
        }
        os_unfair_lock_unlock(&gFocusCacheLock);

        if (parsed.count > 0) {
            YTKACEFocusScheduleCacheSave();
        }
        if (completion) {
            completion(parsed);
        }
    }] resume];
}

static void YTKACEResolveVideoChannelAndTitle(NSString *videoID,
                                              void (^completion)(NSString * _Nullable channel, NSString * _Nullable title)) {
    NSDictionary *cached = YTKACEFocusCachedInfo(videoID);
    if (cached != nil && ([cached[@"ch"] length] > 0 || [cached[@"t"] length] > 0)) {
        if (completion) completion(cached[@"ch"], cached[@"t"]);
        return;
    }
    YTKACEFetchVideosFromAPI(@[videoID], ^(NSDictionary<NSString *, NSDictionary *> *results) {
        NSDictionary *info = results[videoID] ?: YTKACEFocusCachedInfo(videoID);
        NSString *ch = [info[@"ch"] isKindOfClass:NSString.class] ? info[@"ch"] : nil;
        NSString *t = [info[@"t"] isKindOfClass:NSString.class] ? info[@"t"] : nil;
        if (completion) completion(ch, t);
    });
}

// MARK: - YTBlock-Style Blocked Overlay UI (No Unhide Button)

static UIView *YTKACEBuildRedNoSignBadge(CGFloat size, CGFloat cornerRadius, CGFloat symbolSize) {
    UIView *badge = [[UIView alloc] init];
    badge.backgroundColor = [UIColor colorWithRed:0.90 green:0.12 blue:0.12 alpha:1.0];
    badge.layer.cornerRadius = cornerRadius;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *iconCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:symbolSize
                            weight:UIImageSymbolWeightBold];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"nosign" withConfiguration:iconCfg]];
    iconView.tintColor = UIColor.whiteColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;

    [badge addSubview:iconView];
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:size],
        [badge.heightAnchor constraintEqualToConstant:size],
        [iconView.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor]
    ]];
    return badge;
}

static UIView *YTKACEBuildBlockedOverlayView(CGRect bounds, NSString *reason, BOOL compact) {
    UIView *overlay = [[UIView alloc] initWithFrame:bounds];
    overlay.tag = kFocusBlockedOverlayTag;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = YES;

    if (compact) {
        overlay.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return YTKACEInterfaceBackgroundColor(traits);
        }];

        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return YTKACEInterfaceBackgroundColor(traits);
        }];
        card.layer.borderWidth = 1.0;
        card.layer.cornerRadius = 4.0;
        card.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.32 alpha:1.0]
                : [UIColor colorWithWhite:0.20 alpha:1.0];
        }].CGColor;

        UIView *badge = YTKACEBuildRedNoSignBadge(28.0, 6.0, 17.0);

        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = @"BLOCKED";
        titleLabel.textColor = UIColor.labelColor;
        titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[badge, titleLabel]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 10.0;
        row.translatesAutoresizingMaskIntoConstraints = NO;

        [card addSubview:row];
        [overlay addSubview:card];

        [NSLayoutConstraint activateConstraints:@[
            [card.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:10.0],
            [card.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-10.0],
            [card.topAnchor constraintEqualToAnchor:overlay.topAnchor constant:6.0],
            [card.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor constant:-6.0],
            [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
            [row.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [row.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-14.0]
        ]];
        return overlay;
    }

    overlay.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.97];

    UIView *badge = YTKACEBuildRedNoSignBadge(44.0, 10.0, 27.0);

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"BLOCKED";
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *reasonLabel = [[UILabel alloc] init];
    reasonLabel.text = reason ?: @"Blocked by focus filter";
    reasonLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    reasonLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    reasonLabel.textAlignment = NSTextAlignmentCenter;
    reasonLabel.numberOfLines = 2;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[badge, titleLabel, reasonLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [overlay addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:16.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-16.0]
    ]];

    return overlay;
}

static void YTKACEShowBlockedOverlayOnView(UIView *host, NSString *reason, BOOL compact) {
    if (host == nil) return;
    UIView *existing = [host viewWithTag:kFocusBlockedOverlayTag];
    if (existing != nil) {
        existing.frame = host.bounds;
        [host bringSubviewToFront:existing];
        return;
    }
    UIView *overlay = YTKACEBuildBlockedOverlayView(host.bounds, reason, compact);
    [host addSubview:overlay];
    [host bringSubviewToFront:overlay];
}

static void YTKACERemoveBlockedOverlayFromView(UIView *host) {
    if (host == nil) return;
    UIView *existing = [host viewWithTag:kFocusBlockedOverlayTag];
    [existing removeFromSuperview];
}

// MARK: - Search / Feed / Playlist Cell Inspection for Blocked Overlay

static BOOL YTKACEIsInsideVideoListSurface(UIView *view) {
    UIResponder *r = view;
    for (NSUInteger depth = 0; r != nil && depth < 18; depth++) {
        NSString *cls = NSStringFromClass([r class]);
        if ([cls containsString:@"YTSearchResultsViewController"] ||
            [cls containsString:@"YTBrowseViewController"] ||
            [cls containsString:@"YTPlaylistPanel"] ||
            [cls containsString:@"YTWatchNext"]) {
            return YES;
        }
        if ([cls containsString:@"YTSettings"] ||
            [cls containsString:@"YTKACE"]) {
            return NO;
        }
        r = [r nextResponder];
    }
    return NO;
}

static NSString *YTKACEBlockedReasonForCell(UIView *cell) {
    if (cell == nil) return nil;
    CGFloat h = CGRectGetHeight(cell.bounds);
    CGFloat w = CGRectGetWidth(cell.bounds);
    if (h < 68.0 || w < 180.0) return nil;
    if (!YTKACEIsInsideVideoListSurface(cell)) return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 70) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;

        if (node.tag == kFocusBlockedOverlayTag) continue;

        NSString *label = node.accessibilityLabel;
        if (label.length >= 3) {
            if (YTKACEIsChannelNameBlocked(label)) {
                return @"Blocked channel";
            }
            NSArray<NSString *> *parts = [label componentsSeparatedByString:@","];
            for (NSString *part in parts) {
                if (YTKACEIsChannelNameBlocked(part)) {
                    NSString *clean = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    return [NSString stringWithFormat:@"Blocked channel: %@", clean];
                }
            }
            if (YTKACEIsTitleBlocked(label)) {
                return @"Blocked by title filter";
            }
        }

        if ([node isKindOfClass:UILabel.class]) {
            NSString *text = ((UILabel *)node).text;
            if (text.length >= 3) {
                if (YTKACEIsChannelNameBlocked(text)) {
                    return [NSString stringWithFormat:@"Blocked channel: %@", text];
                }
                if (YTKACEIsTitleBlocked(text)) {
                    return @"Blocked by title filter";
                }
            }
        }

        if (node.subviews.count > 0) {
            [queue addObjectsFromArray:node.subviews];
        }
    }
    return nil;
}

static void YTKACERefreshVisibleCellsInView(UIView *root) {
    if (root == nil) return;
    Class cellClass = NSClassFromString(@"_ASCollectionViewCell");
    if (cellClass != Nil && [root isKindOfClass:cellClass]) {
        NSString *reason = YTKACEBlockedReasonForCell(root);
        objc_setAssociatedObject(root, kFocusCellReasonKey, reason, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (reason.length > 0) {
            YTKACEShowBlockedOverlayOnView(root, reason, YES);
        } else {
            YTKACERemoveBlockedOverlayFromView(root);
        }
        return;
    }
    for (UIView *child in root.subviews) {
        YTKACERefreshVisibleCellsInView(child);
    }
}

static void YTKACERefreshAllVisibleCells(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                YTKACERefreshVisibleCellsInView(window);
            }
        }
    });
}

static void YTKACEFocusCellLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalCellLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalCellLayoutSubviews)(receiver, selector);
    }
    if (receiver.window == nil) return;

    NSString *reason = objc_getAssociatedObject(receiver, kFocusCellReasonKey);
    if (reason == nil) {
        reason = YTKACEBlockedReasonForCell(receiver);
        if (reason != nil) {
            objc_setAssociatedObject(receiver, kFocusCellReasonKey, reason, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }

    if (reason.length > 0) {
        YTKACEShowBlockedOverlayOnView(receiver, reason, YES);
    }
}

static void YTKACEFocusCellPrepareForReuse(UIView *receiver, SEL selector) {
    objc_setAssociatedObject(receiver, kFocusCellReasonKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    YTKACERemoveBlockedOverlayFromView(receiver);
    if (OriginalCellPrepareForReuse != NULL) {
        ((void (*)(id, SEL))OriginalCellPrepareForReuse)(receiver, selector);
    }
}

// MARK: - 3-Dot Video Menu Actions ("Block Channel" & "Block Video" — Block Only)

static NSString *YTKACEScanProtobufBytesForVideoID(NSData *data) {
    if (data.length < 13) return nil;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    const NSUInteger len = data.length;
    for (NSUInteger i = 0; i + 12 < len; i++) {
        // Protobuf string field tag (0x0a, 0x12, 0x1a, 0x22) followed by length 11 (0x0b)
        unsigned char tag = bytes[i];
        if ((tag != 0x0a && tag != 0x12 && tag != 0x1a && tag != 0x22) || bytes[i + 1] != 0x0b) {
            continue;
        }
        BOOL valid = YES;
        for (NSUInteger j = 0; j < 11; j++) {
            unsigned char c = bytes[i + 2 + j];
            BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '_';
            if (!ok) { valid = NO; break; }
        }
        if (!valid) continue;
        NSString *cand = [[NSString alloc] initWithBytes:bytes + i + 2 length:11 encoding:NSASCIIStringEncoding];
        if (cand.length == 11) return cand;
    }
    return nil;
}

static NSString *YTKACEExtractVideoIDFromDump(NSString *dump) {
    if (dump.length == 0) return nil;
    static NSRegularExpression *primaryRegex = nil;
    static NSRegularExpression *packedRegex = nil;
    static NSRegularExpression *b64Regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        primaryRegex = [NSRegularExpression
            regularExpressionWithPattern:@"video_?[Ii]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                 options:0
                                   error:NULL];
        packedRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\\\n\\\\013([A-Za-z0-9_-]{11})"
                                 options:0
                                   error:NULL];
        b64Regex = [NSRegularExpression
            regularExpressionWithPattern:@"(?:params|serialized_share_entity|discovery_params):\\s*\"([A-Za-z0-9+/=_%-]{16,160})\""
                                 options:0
                                   error:NULL];
    });

    NSTextCheckingResult *match = [primaryRegex firstMatchInString:dump
                                                           options:0
                                                             range:NSMakeRange(0, dump.length)];
    if (match != nil) {
        return [dump substringWithRange:[match rangeAtIndex:1]];
    }
    match = [packedRegex firstMatchInString:dump
                                    options:0
                                      range:NSMakeRange(0, dump.length)];
    if (match != nil) {
        return [dump substringWithRange:[match rangeAtIndex:1]];
    }
    NSArray<NSTextCheckingResult *> *b64Matches = [b64Regex matchesInString:dump
                                                                    options:0
                                                                      range:NSMakeRange(0, dump.length)];
    for (NSTextCheckingResult *m in b64Matches) {
        NSString *raw = [dump substringWithRange:[m rangeAtIndex:1]];
        NSString *decoded = [raw stringByRemovingPercentEncoding] ?: raw;
        NSData *data = [[NSData alloc] initWithBase64EncodedString:decoded
            options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *vid = YTKACEScanProtobufBytesForVideoID(data);
        if (vid.length == 11) return vid;
    }
    return nil;
}

static NSString *YTKACEExtractVideoIDFromObject(id obj) {
    if (obj == nil) return nil;
    NSArray *items = [obj isKindOfClass:NSArray.class] ? (NSArray *)obj : @[obj];
    for (id item in items) {
        NSString *dump = nil;
        @try { dump = [item description]; } @catch (__unused NSException *e) {}
        NSString *vid = YTKACEExtractVideoIDFromDump(dump);
        if (vid.length == 11) return vid;
        if ([item respondsToSelector:@selector(data)]) {
            @try {
                id d = ((id (*)(id, SEL))objc_msgSend)(item, @selector(data));
                if ([d isKindOfClass:NSData.class]) {
                    vid = YTKACEScanProtobufBytesForVideoID((NSData *)d);
                    if (vid.length == 11) return vid;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return nil;
}

static UIView *YTKACEEnclosingVideoCell(id sourceView) {
    if (![sourceView isKindOfClass:UIView.class]) return nil;
    Class cellClass = NSClassFromString(@"_ASCollectionViewCell");
    UIView *walk = (UIView *)sourceView;
    for (NSUInteger depth = 0; walk != nil && depth < 18; depth++) {
        if (cellClass != Nil && [walk isKindOfClass:cellClass]) {
            return walk;
        }
        walk = walk.superview;
    }
    return nil;
}

static void YTKACEExtractTitleAndChannelFromCell(UIView *cell,
                                                 NSString **outTitle,
                                                 NSString **outChannel) {
    if (cell == nil) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    NSString *bestTitle = nil;
    NSString *bestChannel = nil;
    while (queue.count > 0 && visited < 70) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (node.tag == kFocusBlockedOverlayTag) continue;

        NSString *label = node.accessibilityLabel;
        if (label.length >= 4) {
            // YouTube accessibility format: "Title, 10 minutes, Go to channel, Channel Name, 1M views"
            NSArray<NSString *> *parts = [label componentsSeparatedByString:@","];
            if (parts.count >= 2 && bestTitle.length == 0) {
                NSString *first = [parts.firstObject stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (first.length >= 4 && ![first.lowercaseString hasPrefix:@"go to channel"]) {
                    bestTitle = first;
                }
            }
            for (NSUInteger i = 0; i < parts.count; i++) {
                NSString *clean = [parts[i] stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([[clean lowercaseString] isEqualToString:@"go to channel"] && i + 1 < parts.count) {
                    NSString *ch = [parts[i + 1] stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (ch.length > 0) bestChannel = ch;
                } else if ([[clean lowercaseString] hasPrefix:@"go to channel "]) {
                    NSString *ch = [[clean substringFromIndex:14] stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (ch.length > 0) bestChannel = ch;
                } else if ([[clean lowercaseString] hasPrefix:@"by "] && bestChannel.length == 0) {
                    NSString *ch = [[clean substringFromIndex:3] stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (ch.length > 0) bestChannel = ch;
                }
            }
        }
        if ([node isKindOfClass:UILabel.class]) {
            NSString *text = [((UILabel *)node).text stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (text.length >= 3) {
                if (bestTitle.length == 0 && ![text containsString:@" • "] && ![text containsString:@" · "]) {
                    bestTitle = text;
                } else if (bestChannel.length == 0 && ([text containsString:@" • "] || [text containsString:@" · "])) {
                    NSString *sep = [text containsString:@" • "] ? @" • " : @" · ";
                    NSString *first = [[text componentsSeparatedByString:sep].firstObject
                        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (first.length > 0) bestChannel = first;
                }
            }
        }
        if (node.subviews.count > 0) {
            [queue addObjectsFromArray:node.subviews];
        }
    }
    if (outTitle != NULL) *outTitle = bestTitle;
    if (outChannel != NULL) *outChannel = bestChannel;
}

static BOOL YTKACEActionsLookLikeVideoMenu(id renderers, NSArray *actions) {
    for (id action in actions) {
        NSString *title = nil;
        @try { title = [action valueForKey:@"title"]; } @catch (__unused NSException *e) {}
        if (![title isKindOfClass:NSString.class]) continue;
        NSString *lower = [title lowercaseString];
        if ([lower containsString:@"watch later"] ||
            [lower containsString:@"save to playlist"] ||
            [lower containsString:@"save video to playlist"] ||
            [lower containsString:@"play next in queue"] ||
            [lower containsString:@"download video"] ||
            [lower containsString:@"not interested"] ||
            [lower containsString:@"don't recommend channel"]) {
            return YES;
        }
    }
    NSString *dump = nil;
    @try { dump = [renderers description]; } @catch (__unused NSException *e) {}
    if (dump.length > 0) {
        if ([dump containsString:@"ADD_TO_WATCH_LATER"] ||
            [dump containsString:@"QUEUE_PLAY_NEXT"] ||
            [dump containsString:@"OFFLINE_ADD"] ||
            [dump containsString:@"BOOKMARK_BORDER"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTKACEActionsAlreadyContainBlockItems(NSArray *actions) {
    for (id action in actions) {
        NSString *title = nil;
        @try { title = [action valueForKey:@"title"]; } @catch (__unused NSException *e) {}
        if ([title isKindOfClass:NSString.class] &&
            ([title isEqualToString:@"Block Channel"] || [title isEqualToString:@"Block Video"])) {
            return YES;
        }
    }
    return NO;
}

static UIImage *YTKACERedBlockMenuIcon(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:20.0
                            weight:UIImageSymbolWeightMedium];
    UIImage *base = [UIImage systemImageNamed:@"nosign" withConfiguration:cfg];
    return [[base imageWithTintColor:UIColor.systemRedColor]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static void YTKACEEnforceBlockedPlayback(id playerController, NSString *videoID, NSString *reason);

id YTKACEFocusAppendMenuActions(id renderers, id entry, id sourceView, id actions) {
    if (![actions isKindOfClass:NSArray.class]) return actions;
    NSArray *actionList = (NSArray *)actions;
    if (YTKACEActionsAlreadyContainBlockItems(actionList)) return actions;

    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeAction = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    if (actionClass == Nil || ![actionClass respondsToSelector:makeAction]) return actions;
    if (actionList.count > 0 && ![[actionList firstObject] isKindOfClass:actionClass]) return actions;

    NSString *videoID = YTKACEExtractVideoIDFromObject(renderers);
    if (videoID.length != 11) {
        videoID = YTKACEExtractVideoIDFromObject(entry);
    }
    UIView *enclosingCell = YTKACEEnclosingVideoCell(sourceView);
    BOOL isVideoMenu = (videoID.length == 11) ||
                       (enclosingCell != nil) ||
                       YTKACEActionsLookLikeVideoMenu(renderers, actionList);
    if (!isVideoMenu) return actions;

    NSString *cellTitle = nil;
    NSString *cellChannel = nil;
    YTKACEExtractTitleAndChannelFromCell(enclosingCell, &cellTitle, &cellChannel);

    __weak UIView *weakCell = enclosingCell;
    UIImage *icon = YTKACERedBlockMenuIcon();

    dispatch_block_t blockVideoHandler = ^{
        YTKACEFocusAddUserBlockedVideo(videoID, cellTitle);
        UIView *cell = weakCell;
        if (cell != nil) {
            objc_setAssociatedObject(cell, kFocusCellReasonKey, @"Blocked video", OBJC_ASSOCIATION_COPY_NONATOMIC);
            YTKACEShowBlockedOverlayOnView(cell, @"Blocked video", YES);
        }
        if (gActivePlayerController != nil && videoID.length == 11 && [gActiveVideoID isEqualToString:videoID]) {
            YTKACEEnforceBlockedPlayback(gActivePlayerController, videoID, @"Blocked video");
        }
        YTKACEShowNotice(@"Video blocked");
        if (videoID.length == 11) {
            YTKACEResolveVideoChannelAndTitle(videoID, ^(__unused NSString *ch, NSString *title) {
                if (title.length >= 3) {
                    YTKACEFocusAddUserBlockedVideo(videoID, title);
                }
            });
        }
    };

    dispatch_block_t blockChannelHandler = ^{
        UIView *cell = weakCell;
        if (cell != nil) {
            objc_setAssociatedObject(cell, kFocusCellReasonKey, @"Blocked channel", OBJC_ASSOCIATION_COPY_NONATOMIC);
            YTKACEShowBlockedOverlayOnView(cell, @"Blocked channel", YES);
        }
        if (cellChannel.length > 0) {
            YTKACEFocusAddUserBlockedChannel(cellChannel);
            if (gActivePlayerController != nil && videoID.length == 11 && [gActiveVideoID isEqualToString:videoID]) {
                YTKACEEnforceBlockedPlayback(gActivePlayerController, videoID,
                    [NSString stringWithFormat:@"Blocked channel: %@", cellChannel]);
            }
            YTKACEShowNotice([NSString stringWithFormat:@"Blocked channel: %@", cellChannel]);
        }
        if (videoID.length == 11) {
            YTKACEResolveVideoChannelAndTitle(videoID, ^(NSString *channel, __unused NSString *title) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (channel.length > 0) {
                        YTKACEFocusAddUserBlockedChannel(channel);
                        if (gActivePlayerController != nil && [gActiveVideoID isEqualToString:videoID]) {
                            YTKACEEnforceBlockedPlayback(gActivePlayerController, videoID,
                                [NSString stringWithFormat:@"Blocked channel: %@", channel]);
                        }
                        if (cellChannel.length == 0) {
                            YTKACEShowNotice([NSString stringWithFormat:@"Blocked channel: %@", channel]);
                        }
                    } else if (cellChannel.length == 0) {
                        YTKACEFocusAddUserBlockedVideo(videoID, cellTitle);
                        YTKACEShowNotice(@"Video blocked");
                    }
                });
            });
        } else if (cellChannel.length == 0) {
            YTKACEFocusAddUserBlockedVideo(videoID, cellTitle);
            YTKACEShowNotice(@"Video blocked");
        }
    };

    id blockChannelAction = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
        actionClass, makeAction, @"Block Channel", icon, 0, [blockChannelHandler copy]);
    id blockVideoAction = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
        actionClass, makeAction, @"Block Video", icon, 0, [blockVideoHandler copy]);

    NSMutableArray *updated = [actionList mutableCopy];
    if (blockChannelAction != nil) [updated addObject:blockChannelAction];
    if (blockVideoAction != nil) [updated addObject:blockVideoAction];
    return updated;
}

// MARK: - Surface Detection (Home & Watch Next Removal Only — Search Stays Intact!)

static id YTKACEFocusSafeMsg(id obj, SEL sel) {
    if (obj == nil || ![obj respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSData *YTKACEFocusBytesForObject(id obj) {
    if (obj == nil) return nil;
    id data = YTKACEFocusSafeMsg(obj, @selector(data));
    if ([data isKindOfClass:NSData.class] && ((NSData *)data).length > 0) {
        return (NSData *)data;
    }
    NSMutableData *combined = nil;
    NSArray<NSString *> *keys = @[@"contentsArray", @"itemsArray", @"content", @"elementRenderer", @"itemSectionRenderer"];
    for (NSString *key in keys) {
        id child = YTKACEFocusSafeMsg(obj, NSSelectorFromString(key));
        if (child == nil) continue;
        NSArray *arr = [child isKindOfClass:NSArray.class] ? (NSArray *)child : @[child];
        NSUInteger count = 0;
        for (id item in arr) {
            if (count++ >= 8) break;
            id itemData = YTKACEFocusSafeMsg(item, @selector(data));
            if ([itemData isKindOfClass:NSData.class] && ((NSData *)itemData).length > 0) {
                if (!combined) combined = [NSMutableData data];
                [combined appendData:itemData];
            }
        }
    }
    return combined;
}

static NSString *YTKACEFocusBrowseID(id obj) {
    if (obj == nil) return nil;
    for (NSString *selName in @[@"browseID", @"browseIdentifier"]) {
        id val = YTKACEFocusSafeMsg(obj, NSSelectorFromString(selName));
        if ([val isKindOfClass:NSString.class] && ((NSString *)val).length > 0) {
            return (NSString *)val;
        }
    }
    return nil;
}

static BOOL YTKACEFocusWalkAncestors(id receiver, BOOL (^predicate)(id node)) {
    id walk = receiver;
    SEL parentSel = @selector(parentViewController);
    for (NSUInteger depth = 0; walk != nil && depth < 14; depth++) {
        if (predicate(walk)) return YES;
        id next = [walk respondsToSelector:parentSel]
            ? ((id (*)(id, SEL))objc_msgSend)(walk, parentSel) : nil;
        if (next == nil && [walk isKindOfClass:UIResponder.class]) {
            next = ((UIResponder *)walk).nextResponder;
        }
        if (next == walk) break;
        walk = next;
    }
    return NO;
}

static BOOL YTKACEIsHomeFeedReceiver(id receiver) {
    if (receiver == nil) return NO;
    return YTKACEFocusWalkAncestors(receiver, ^BOOL(id node) {
        NSString *bid = YTKACEFocusBrowseID(node);
        return [bid isEqualToString:@"FEwhat_to_watch"];
    });
}

static BOOL YTKACEIsWatchNextReceiver(id receiver) {
    if (receiver == nil) return NO;
    return YTKACEFocusWalkAncestors(receiver, ^BOOL(id node) {
        NSString *cls = NSStringFromClass([node class]);
        return [cls containsString:@"YTWatchNext"] ||
               [cls containsString:@"YTWatchFlow"] ||
               [cls containsString:@"YTSingleVideoWatchNext"];
    });
}

static BOOL YTKACEIsEssentialWatchMetadataSection(id section) {
    if (section == nil) return NO;
    NSString *cls = [NSStringFromClass([section class]) lowercaseString];
    if ([cls containsString:@"slimvideo"] ||
        [cls containsString:@"videometadata"] ||
        [cls containsString:@"comment"] ||
        [cls containsString:@"playlistpanel"] ||
        [cls containsString:@"description"]) {
        return YES;
    }
    NSData *bytes = YTKACEFocusBytesForObject(section);
    if (bytes.length == 0) return NO;
    NSArray<NSString *> *keepMarkers = @[
        @"slim_video",
        @"video_metadata",
        @"video_title",
        @"video_action_bar",
        @"scrollable_action_bar",
        @"non_scrollable_action_bar",
        @"video_owner",
        @"channel_bar",
        @"comments_entry_point",
        @"comment_teaser",
        @"id.ui.comments",
        @"playlist_panel",
        @"video_description"
    ];
    for (NSString *m in keepMarkers) {
        NSData *pat = [m dataUsingEncoding:NSASCIIStringEncoding];
        if (pat.length > 0 && [bytes rangeOfData:pat options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// Only remove Home Screen recommendations and Watch Next related videos.
// Search results stay intact and receive Blocked overlays instead of being deleted!
NSArray *YTKACEFocusFilterSections(id receiver, NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }

    // 1. Remove ALL Home Screen recommendations
    if (YTKACEIsHomeFeedReceiver(receiver)) {
        return @[];
    }

    // 2. Remove related/suggested videos under the Watch player
    if (YTKACEIsWatchNextReceiver(receiver)) {
        NSMutableArray *kept = [NSMutableArray array];
        for (id section in sections) {
            if (YTKACEIsEssentialWatchMetadataSection(section)) {
                [kept addObject:section];
            }
        }
        return kept;
    }

    // 3. Keep Search/Subscriptions/Channel items intact (blocked ones get a Blocked overlay)
    return sections;
}

// MARK: - Playback Guard + Full Player Blocked Overlay

static void YTKACEEnforceBlockedPlayback(id playerController, NSString *videoID, NSString *reason) {
    if (playerController == nil || reason.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(playerController, kFocusBlockedVideoKey, videoID ?: @"blocked", OBJC_ASSOCIATION_COPY_NONATOMIC);
        SEL pauseSel = @selector(pause);
        if ([playerController respondsToSelector:pauseSel]) {
            ((void (*)(id, SEL))objc_msgSend)(playerController, pauseSel);
        }
        YTKACEPauseYouTubePlayer();
        if ([playerController isKindOfClass:UIViewController.class]) {
            UIView *playerView = ((UIViewController *)playerController).view;
            YTKACEShowBlockedOverlayOnView(playerView, reason, NO);
        }
    });
}

void YTKACEFocusFilterVideoActivated(id playerController, NSString *videoID) {
    if (playerController == nil) return;
    gActivePlayerController = playerController;
    gActiveVideoID = [videoID copy];

    objc_setAssociatedObject(playerController, kFocusBlockedVideoKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if ([playerController isKindOfClass:UIViewController.class]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACERemoveBlockedOverlayFromView(((UIViewController *)playerController).view);
        });
    }

    if (videoID.length != 11) return;

    if (YTKACEIsVideoIDBlocked(videoID)) {
        YTKACEEnforceBlockedPlayback(playerController, videoID, @"Blocked video");
        return;
    }

    NSDictionary *cached = YTKACEFocusCachedInfo(videoID);
    if (cached != nil) {
        NSString *reason = YTKACEBlockReasonForMetadata(videoID, cached[@"ch"], cached[@"t"], cached[@"cat"]);
        if (reason != nil) {
            YTKACEEnforceBlockedPlayback(playerController, videoID, reason);
        }
        return;
    }

    __weak id weakController = playerController;
    YTKACEFetchVideosFromAPI(@[videoID], ^(NSDictionary<NSString *, NSDictionary *> *results) {
        id strongController = weakController;
        if (strongController == nil) return;
        NSDictionary *info = results[videoID] ?: YTKACEFocusCachedInfo(videoID);
        if (info == nil) return;
        NSString *reason = YTKACEBlockReasonForMetadata(videoID, info[@"ch"], info[@"t"], info[@"cat"]);
        if (reason != nil) {
            YTKACEEnforceBlockedPlayback(strongController, videoID, reason);
        }
    });
}

static void YTKACEFocusPlayerPlay(id receiver, SEL selector) {
    NSString *blockedID = objc_getAssociatedObject(receiver, kFocusBlockedVideoKey);
    if (blockedID.length > 0) {
        return;
    }
    if (OriginalPlayerPlay != NULL) {
        ((void (*)(id, SEL))OriginalPlayerPlay)(receiver, selector);
    }
}

// MARK: - Redirect Shorts (reelWatchEndpoint) to Normal Player (watchEndpoint)

static id YTKACEConvertShortsCommandToWatchCommand(id command) {
    if (command == nil) return command;

    id reelEndpoint = nil;
    SEL hasReelSel = NSSelectorFromString(@"hasReelWatchEndpoint");
    SEL reelSel = NSSelectorFromString(@"reelWatchEndpoint");
    if ([command respondsToSelector:hasReelSel] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(command, hasReelSel) &&
        [command respondsToSelector:reelSel]) {
        reelEndpoint = ((id (*)(id, SEL))objc_msgSend)(command, reelSel);
    } else if ([command respondsToSelector:reelSel]) {
        reelEndpoint = ((id (*)(id, SEL))objc_msgSend)(command, reelSel);
    }

    if (reelEndpoint == nil) return command;

    NSString *videoID = nil;
    for (NSString *selName in @[@"videoId", @"videoID"]) {
        SEL s = NSSelectorFromString(selName);
        if ([reelEndpoint respondsToSelector:s]) {
            id val = ((id (*)(id, SEL))objc_msgSend)(reelEndpoint, s);
            if ([val isKindOfClass:NSString.class] && ((NSString *)val).length == 11) {
                videoID = (NSString *)val;
                break;
            }
        }
    }
    if (videoID.length != 11) return command;

    Class cmdClass = NSClassFromString(@"YTICommand");
    Class watchClass = NSClassFromString(@"YTIWatchEndpoint");
    if (cmdClass == Nil || watchClass == Nil) return command;

    id watchEndpoint = [[watchClass alloc] init];
    SEL setVidLower = NSSelectorFromString(@"setVideoId:");
    SEL setVidUpper = NSSelectorFromString(@"setVideoID:");
    if ([watchEndpoint respondsToSelector:setVidLower]) {
        ((void (*)(id, SEL, id))objc_msgSend)(watchEndpoint, setVidLower, videoID);
    } else if ([watchEndpoint respondsToSelector:setVidUpper]) {
        ((void (*)(id, SEL, id))objc_msgSend)(watchEndpoint, setVidUpper, videoID);
    } else {
        return command;
    }

    id newCommand = [[cmdClass alloc] init];
    SEL setWatchSel = NSSelectorFromString(@"setWatchEndpoint:");
    if (![newCommand respondsToSelector:setWatchSel]) return command;
    ((void (*)(id, SEL, id))objc_msgSend)(newCommand, setWatchSel, watchEndpoint);

    return newCommand;
}

static BOOL YTKACEFocusHandleCmd5(id self, SEL _cmd, id command, id entry, id view, id sender, id completion) {
    id routed = YTKACEConvertShortsCommandToWatchCommand(command);
    return ((BOOL (*)(id, SEL, id, id, id, id, id))OriginalCmdHandle5)(self, _cmd, routed, entry, view, sender, completion);
}

static BOOL YTKACEFocusHandleCmd4(id self, SEL _cmd, id command, id entry, id view, id sender) {
    id routed = YTKACEConvertShortsCommandToWatchCommand(command);
    return ((BOOL (*)(id, SEL, id, id, id, id))OriginalCmdHandle4)(self, _cmd, routed, entry, view, sender);
}

static BOOL YTKACEFocusHandleCmd3(id self, SEL _cmd, id command, id entry, id sender) {
    id routed = YTKACEConvertShortsCommandToWatchCommand(command);
    return ((BOOL (*)(id, SEL, id, id, id))OriginalCmdHandle3)(self, _cmd, routed, entry, sender);
}

static BOOL YTKACEFocusHandleCmd1(id self, SEL _cmd, id command) {
    id routed = YTKACEConvertShortsCommandToWatchCommand(command);
    return ((BOOL (*)(id, SEL, id))OriginalCmdHandle1)(self, _cmd, routed);
}

// MARK: - Hardcoded End Screen Removal

static BOOL YTKACEFocusHasEndscreen(__unused id receiver, __unused SEL selector) {
    return NO;
}

static id YTKACEFocusEndscreen(__unused id receiver, __unused SEL selector) {
    return nil;
}

static void YTKACEFocusCreatorEndscreenShow(__unused id receiver, __unused SEL selector) {
    return;
}

// MARK: - Stop & Hide Constant Home Screen Loading Spinner (Zero CPU/GPU Waste)

static void YTKACEStopSpinnerView(UIView *view) {
    if (view == nil) return;
    SEL stopSel = @selector(stopAnimating);
    if ([view respondsToSelector:stopSel]) {
        ((void (*)(id, SEL))objc_msgSend)(view, stopSel);
    }
    view.hidden = YES;
    view.alpha = 0.0;
}

static void YTKACEHideSpinnersInTree(UIView *root, NSUInteger depth) {
    if (root == nil || depth > 10) return;
    NSString *cls = NSStringFromClass([root class]);
    if ([root isKindOfClass:UIActivityIndicatorView.class] ||
        [cls containsString:@"ActivityIndicator"]) {
        YTKACEStopSpinnerView(root);
        return;
    }
    for (UIView *sub in root.subviews) {
        YTKACEHideSpinnersInTree(sub, depth + 1);
    }
}

static void YTKACEMDCStartAnimating(UIView *receiver, SEL selector) {
    if (YTKACEIsHomeFeedReceiver(receiver)) {
        YTKACEStopSpinnerView(receiver);
        return;
    }
    if (OriginalMDCStartAnimating != NULL) {
        ((void (*)(id, SEL))OriginalMDCStartAnimating)(receiver, selector);
    }
}

static void YTKACEMDCDidMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalMDCDidMoveToWindow != NULL) {
        ((void (*)(id, SEL))OriginalMDCDidMoveToWindow)(receiver, selector);
    }
    if (receiver.window != nil && YTKACEIsHomeFeedReceiver(receiver)) {
        YTKACEStopSpinnerView(receiver);
    }
}

static void YTKACEQTMStartAnimating(UIView *receiver, SEL selector) {
    if (YTKACEIsHomeFeedReceiver(receiver)) {
        YTKACEStopSpinnerView(receiver);
        return;
    }
    if (OriginalQTMStartAnimating != NULL) {
        ((void (*)(id, SEL))OriginalQTMStartAnimating)(receiver, selector);
    }
}

static void YTKACEUIActivityStartAnimating(UIView *receiver, SEL selector) {
    if (YTKACEIsHomeFeedReceiver(receiver)) {
        YTKACEStopSpinnerView(receiver);
        return;
    }
    if (OriginalUIActivityStartAnimating != NULL) {
        ((void (*)(id, SEL))OriginalUIActivityStartAnimating)(receiver, selector);
    }
}

static const NSInteger kFocusHomeHubTag = 0x464F4353;

static UIControl *YTKACEFindNativeSearchButtonInView(UIView *root, NSUInteger depth) {
    if (root == nil || depth > 14) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:@"YTRightNavigationButtons"]) {
        SEL searchSel = NSSelectorFromString(@"searchButton");
        if ([root respondsToSelector:searchSel]) {
            id btn = ((id (*)(id, SEL))objc_msgSend)(root, searchSel);
            if ([btn isKindOfClass:UIControl.class]) return (UIControl *)btn;
        }
    }
    if ([root isKindOfClass:UIControl.class] && root.tag != kFocusHomeHubTag) {
        NSString *ident = root.accessibilityIdentifier.lowercaseString ?: @"";
        NSString *label = root.accessibilityLabel.lowercaseString ?: @"";
        if ([ident isEqualToString:@"id.ui.navigation.search.button"] ||
            [label isEqualToString:@"search"]) {
            return (UIControl *)root;
        }
    }
    for (UIView *sub in root.subviews) {
        UIControl *found = YTKACEFindNativeSearchButtonInView(sub, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

@interface YTKACEHomeSearchTarget : NSObject
+ (instancetype)sharedTarget;
- (void)openSearch:(UIButton *)sender;
@end

@implementation YTKACEHomeSearchTarget
+ (instancetype)sharedTarget {
    static YTKACEHomeSearchTarget *target = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [YTKACEHomeSearchTarget new];
    });
    return target;
}

- (void)openSearch:(UIButton *)sender {
    UIWindow *window = sender.window;
    if (window == nil) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *cand in ((UIWindowScene *)scene).windows) {
                if (cand.isKeyWindow) { window = cand; break; }
            }
            if (window != nil) break;
        }
    }
    UIControl *searchButton = YTKACEFindNativeSearchButtonInView(window, 0);
    if (searchButton != nil) {
        [searchButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}
@end

static UIImage *YTKACEBuildRedYouTubePlayIcon(CGSize size) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    fmt.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0.0, 0.0, size.width, size.height);
        UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:size.height * 0.28];
        [[UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0] setFill];
        [bg fill];

        UIBezierPath *tri = [UIBezierPath bezierPath];
        CGFloat cx = size.width * 0.52;
        CGFloat cy = size.height * 0.50;
        CGFloat halfH = size.height * 0.22;
        CGFloat halfW = size.width * 0.14;
        [tri moveToPoint:CGPointMake(cx - halfW, cy - halfH)];
        [tri addLineToPoint:CGPointMake(cx + halfW, cy)];
        [tri addLineToPoint:CGPointMake(cx - halfW, cy + halfH)];
        [tri closePath];
        [UIColor.whiteColor setFill];
        [tri fill];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static void YTKACEEnsureHomeSearchHub(UIViewController *controller) {
    UIView *host = controller.view;
    if (host == nil) return;
    UIView *hub = [host viewWithTag:kFocusHomeHubTag];
    if (hub == nil) {
        // 1. Custom Logo: [Red Play Icon] YouTube tej(cursive)
        UIImageView *playIcon = [[UIImageView alloc] initWithImage:
            YTKACEBuildRedYouTubePlayIcon(CGSizeMake(40.0, 28.0))];
        playIcon.contentMode = UIViewContentModeScaleAspectFit;
        playIcon.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [playIcon.widthAnchor constraintEqualToConstant:40.0],
            [playIcon.heightAnchor constraintEqualToConstant:28.0]
        ]];

        UILabel *ytLabel = [[UILabel alloc] init];
        NSMutableAttributedString *wordmark = [[NSMutableAttributedString alloc] initWithString:@"YouTube" attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: UIColor.labelColor,
            NSKernAttributeName: @(-1.0)
        }];
        UIFont *cursive = [UIFont fontWithName:@"SnellRoundhand-Bold" size:17.0]
            ?: [UIFont fontWithName:@"SnellRoundhand" size:17.0]
            ?: [UIFont italicSystemFontOfSize:16.0];
        NSAttributedString *tej = [[NSAttributedString alloc] initWithString:@" tej" attributes:@{
            NSFontAttributeName: cursive,
            NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
            NSBaselineOffsetAttributeName: @(-1.0)
        }];
        [wordmark appendAttributedString:tej];
        ytLabel.attributedText = wordmark;

        UIStackView *logoRow = [[UIStackView alloc] initWithArrangedSubviews:@[playIcon, ytLabel]];
        logoRow.axis = UILayoutConstraintAxisHorizontal;
        logoRow.alignment = UIStackViewAlignmentCenter;
        logoRow.spacing = 6.0;

        // 2. Centered minimalist Search Bar
        UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
        cfg.title = @"Search";
        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:17.0 weight:UIImageSymbolWeightMedium];
        cfg.image = [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:symCfg];
        cfg.imagePadding = 10.0;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(13.0, 22.0, 13.0, 22.0);
        cfg.baseForegroundColor = UIColor.secondaryLabelColor;
        cfg.baseBackgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.13 alpha:1.0]
                : [UIColor colorWithWhite:0.94 alpha:1.0];
        }];
        UIButton *searchBar = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
        searchBar.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        searchBar.translatesAutoresizingMaskIntoConstraints = NO;
        searchBar.layer.borderWidth = 0.75;
        searchBar.layer.borderColor = UIColor.separatorColor.CGColor;
        searchBar.layer.cornerRadius = 24.0;
        searchBar.clipsToBounds = YES;
        [searchBar addTarget:YTKACEHomeSearchTarget.sharedTarget
                      action:@selector(openSearch:)
            forControlEvents:UIControlEventTouchUpInside];
        [searchBar.heightAnchor constraintEqualToConstant:48.0].active = YES;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logoRow, searchBar]];
        stack.tag = kFocusHomeHubTag;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 22.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        [host addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:host.centerYAnchor constant:-36.0],
            [searchBar.widthAnchor constraintEqualToAnchor:host.widthAnchor constant:-56.0],
            [searchBar.widthAnchor constraintLessThanOrEqualToConstant:360.0]
        ]];
        hub = stack;
    }
    hub.hidden = NO;
    [host bringSubviewToFront:hub];
}

static void YTKACEBrowseViewDidLayoutSubviews(UIViewController *receiver, SEL selector) {
    if (OriginalBrowseLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalBrowseLayoutSubviews)(receiver, selector);
    }
    if (YTKACEIsHomeFeedReceiver(receiver)) {
        YTKACEHideSpinnersInTree(receiver.view, 0);
        YTKACEEnsureHomeSearchHub(receiver);
    }
}

void YTKACEInstallFocusFilterHooks(void) {
    YTKACEFocusLoadCacheIfNeeded();

    static id blocklistObserver = nil;
    if (blocklistObserver == nil) {
        blocklistObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:kFocusBlocklistChangedNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            YTKACERefreshAllVisibleCells();
        }];
    }

    // 1. Blocked overlay on Search/Feed video cards
    YTKACEInstallInstanceHook(@"_ASCollectionViewCell",
                              @"layoutSubviews",
                              (IMP)YTKACEFocusCellLayoutSubviews,
                              &OriginalCellLayoutSubviews);
    YTKACEInstallInstanceHook(@"_ASCollectionViewCell",
                              @"prepareForReuse",
                              (IMP)YTKACEFocusCellPrepareForReuse,
                              &OriginalCellPrepareForReuse);

    // 2. Redirect Shorts (reelWatchEndpoint) to normal video player (watchEndpoint)
    YTKACEInstallInstanceHook(@"YTCommandRouter",
                              @"handleCommand:entry:fromView:sender:completionBlock:",
                              (IMP)YTKACEFocusHandleCmd5,
                              &OriginalCmdHandle5);
    YTKACEInstallInstanceHook(@"YTCommandRouter",
                              @"handleCommand:entry:fromView:sender:",
                              (IMP)YTKACEFocusHandleCmd4,
                              &OriginalCmdHandle4);
    YTKACEInstallInstanceHook(@"YTCommandRouter",
                              @"handleCommand:entry:sender:",
                              (IMP)YTKACEFocusHandleCmd3,
                              &OriginalCmdHandle3);
    YTKACEInstallInstanceHook(@"YTCommandRouter",
                              @"handleCommand:",
                              (IMP)YTKACEFocusHandleCmd1,
                              &OriginalCmdHandle1);

    // 3. Block playback resume for blocked videos
    YTKACEInstallInstanceHook(@"YTPlayerViewController",
                              @"play",
                              (IMP)YTKACEFocusPlayerPlay,
                              &OriginalPlayerPlay);

    // 4. Strip creator end-screen cards directly from player response & controller
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"hasEndscreen",
                              (IMP)YTKACEFocusHasEndscreen,
                              &OriginalHasEndscreen);
    YTKACEInstallInstanceHook(@"YTIPlayerResponse",
                              @"endscreen",
                              (IMP)YTKACEFocusEndscreen,
                              &OriginalEndscreen);
    YTKACEInstallInstanceHook(@"YTCreatorEndscreenController",
                              @"showEndscreen",
                              (IMP)YTKACEFocusCreatorEndscreenShow,
                              &OriginalCreatorEndscreenShow);

    // 5. Stop and hide constant loading spinner on the Home screen
    YTKACEInstallInstanceHook(@"MDCActivityIndicator",
                              @"startAnimating",
                              (IMP)YTKACEMDCStartAnimating,
                              &OriginalMDCStartAnimating);
    YTKACEInstallInstanceHook(@"MDCActivityIndicator",
                              @"didMoveToWindow",
                              (IMP)YTKACEMDCDidMoveToWindow,
                              &OriginalMDCDidMoveToWindow);
    YTKACEInstallInstanceHook(@"QTMActivityIndicator",
                              @"startAnimating",
                              (IMP)YTKACEQTMStartAnimating,
                              &OriginalQTMStartAnimating);
    YTKACEInstallInstanceHook(@"UIActivityIndicatorView",
                              @"startAnimating",
                              (IMP)YTKACEUIActivityStartAnimating,
                              &OriginalUIActivityStartAnimating);
    YTKACEInstallInstanceHook(@"YTBrowseViewController",
                              @"viewDidLayoutSubviews",
                              (IMP)YTKACEBrowseViewDidLayoutSubviews,
                              &OriginalBrowseLayoutSubviews);
}
