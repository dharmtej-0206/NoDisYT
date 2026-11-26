#import "../../YTKACE.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static id YTKACEShortsLimitObserver;

// Permanently disable infinite scrolling / auto-advancing in Shorts.
BOOL YTKACEShortsLimitReached(void) {
    return YES;
}

static UIViewController *YTKACEReelRootController(UIViewController *controller,
                                                  NSUInteger depth) {
    if (controller == nil || depth > 6) return nil;
    SEL active = NSSelectorFromString(@"activeReelPlaybackVideoID");
    if ([controller respondsToSelector:active]) return controller;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = YTKACEReelRootController(child, depth + 1);
        if (found != nil) return found;
    }
    return YTKACEReelRootController(controller.presentedViewController, depth + 1);
}

static UIViewController *YTKACEActiveReelController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isHidden) continue;
            UIViewController *found = YTKACEReelRootController(window.rootViewController, 0);
            if (found != nil) return found;
        }
    }
    return nil;
}

static void YTKACEDisableReelPagersInTree(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 8) return;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIScrollView.class]) {
            UIScrollView *candidate = (UIScrollView *)child;
            if (CGRectGetHeight(candidate.bounds) > 200.0 &&
                (candidate.isPagingEnabled ||
                 candidate.contentSize.height > CGRectGetHeight(candidate.bounds) ||
                 [NSStringFromClass(candidate.class) containsString:@"CollectionView"])) {
                candidate.scrollEnabled = NO;
                candidate.bounces = NO;
                candidate.panGestureRecognizer.enabled = NO;
            }
        }
        YTKACEDisableReelPagersInTree(child, depth + 1);
    }
}

static void YTKACEShortsLimitTick(void) {
    static NSTimeInterval last = 0.0;
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - last < 0.25) return;
    last = now;

    UIViewController *reel = YTKACEActiveReelController();
    if (reel == nil) return;
    YTKACEDisableReelPagersInTree(reel.view, 0);
}

void YTKACEInstallShortsLimitHooks(void) {
    if (YTKACEShortsLimitObserver != nil) return;
    YTKACEShortsLimitObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:@"YTKACEPlaybackTimeDidChange"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    YTKACEShortsLimitTick();
                }];
}
