#import "../YTKACE.h"
#import "../Runtime/Hooking.h"
#import "../Features/Interface/NavigationVisibility.h"

#import <UIKit/UIKit.h>

static IMP OriginalRightButtonsLayoutSubviews;

static void YTKACERightButtonsLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalRightButtonsLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalRightButtonsLayoutSubviews)(receiver, selector);
    }
    YTKACEApplyRightNavigationVisibility(receiver);
    YTKACEApplyTopNavigationGlass(receiver);
}

void YTKACEInstallSettingsEntryHooks(void) {
    YTKACEInstallInstanceHook(@"YTRightNavigationButtons",
                              @"layoutSubviews",
                              (IMP)YTKACERightButtonsLayoutSubviews,
                              &OriginalRightButtonsLayoutSubviews);
}
