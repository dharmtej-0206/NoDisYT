#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>

static IMP OriginalImageNamedBundleTraits;
static IMP OriginalImageNamedBundle;

static NSCache<NSString *, UIImage *> *YTKACETejLogoCache(void) {
    static NSCache<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
    });
    return cache;
}

static BOOL YTKACEIsYouTubeWordmarkName(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"youtube_logo"] ||
           [lower containsString:@"youtube_premium_logo"];
}

static UIImage *YTKACEDecorateLogoWithTej(UIImage *base,
                                          NSString *name,
                                          UITraitCollection *traits) {
    if (base == nil) return nil;
    CGSize baseSize = base.size;
    // Only decorate the top-bar YouTube wordmark (skip tiny icons or huge splash graphics)
    if (baseSize.width < 40.0 || baseSize.height < 12.0 || baseSize.height > 44.0) {
        return base;
    }

    NSString *lower = name.lowercaseString;
    BOOL isDark = [lower containsString:@"dark"] || [lower containsString:@"white"];
    if (!isDark && traits != nil) {
        if (@available(iOS 13.0, *)) {
            isDark = (traits.userInterfaceStyle == UIUserInterfaceStyleDark);
        }
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@_%d_%.1fx%.1f_%.1f",
                          name, isDark ? 1 : 0, baseSize.width, baseSize.height, base.scale];
    UIImage *cached = [YTKACETejLogoCache() objectForKey:cacheKey];
    if (cached != nil) return cached;

    CGFloat fontSize = MAX(12.0, MIN(16.0, baseSize.height * 0.62));
    UIFont *cursive = [UIFont fontWithName:@"SnellRoundhand-Bold" size:fontSize]
        ?: [UIFont fontWithName:@"SnellRoundhand" size:fontSize]
        ?: [UIFont italicSystemFontOfSize:fontSize];
    UIColor *textColor = isDark
        ? [UIColor colorWithWhite:0.90 alpha:1.0]
        : [UIColor colorWithWhite:0.15 alpha:1.0];
    NSDictionary *attrs = @{
        NSFontAttributeName: cursive,
        NSForegroundColorAttributeName: textColor
    };
    NSString *signature = @"tej";
    CGSize textSize = [signature sizeWithAttributes:attrs];

    CGFloat spacing = 4.0;
    CGFloat canvasWidth = ceil(baseSize.width + spacing + textSize.width + 3.0);
    CGFloat canvasHeight = ceil(MAX(baseSize.height, textSize.height));

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = base.scale > 0.0 ? base.scale : UIScreen.mainScreen.scale;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(canvasWidth, canvasHeight) format:format];
    UIImage *composite = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        CGFloat logoY = (canvasHeight - baseSize.height) * 0.5;
        [base drawInRect:CGRectMake(0.0, logoY, baseSize.width, baseSize.height)];

        CGFloat textY = (canvasHeight - textSize.height) * 0.5 + 2.0;
        [signature drawAtPoint:CGPointMake(baseSize.width + spacing, textY) withAttributes:attrs];
    }];

    UIImage *result = [composite imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if (result != nil) {
        [YTKACETejLogoCache() setObject:result forKey:cacheKey];
    }
    return result ?: base;
}

static UIImage *YTKACEImageNamedBundleTraits(id receiver,
                                              SEL selector,
                                              NSString *name,
                                              NSBundle *bundle,
                                              UITraitCollection *traits) {
    if (OriginalImageNamedBundleTraits == NULL) {
        return nil;
    }
    UIImage *(*original)(id, SEL, NSString *, NSBundle *, UITraitCollection *) =
        (UIImage *(*)(id, SEL, NSString *, NSBundle *, UITraitCollection *))
            OriginalImageNamedBundleTraits;
    UIImage *image = original(receiver, selector, name, bundle, traits);
    if (image != nil && YTKACEIsYouTubeWordmarkName(name)) {
        return YTKACEDecorateLogoWithTej(image, name, traits);
    }
    return image;
}

static UIImage *YTKACEImageNamedBundle(id receiver,
                                       SEL selector,
                                       NSString *name,
                                       NSBundle *bundle) {
    if (OriginalImageNamedBundle == NULL) {
        return nil;
    }
    UIImage *(*original)(id, SEL, NSString *, NSBundle *) =
        (UIImage *(*)(id, SEL, NSString *, NSBundle *))OriginalImageNamedBundle;
    UIImage *image = original(receiver, selector, name, bundle);
    if (image != nil && YTKACEIsYouTubeWordmarkName(name)) {
        return YTKACEDecorateLogoWithTej(image, name, UIScreen.mainScreen.traitCollection);
    }
    return image;
}

void YTKACEInstallPremiumLogoHooks(void) {
    YTKACEInstallClassHook(@"UIImage",
                           @"imageNamed:inBundle:compatibleWithTraitCollection:",
                           (IMP)YTKACEImageNamedBundleTraits,
                           &OriginalImageNamedBundleTraits);
    YTKACEInstallClassHook(@"UIImage",
                           @"imageNamed:inBundle:",
                           (IMP)YTKACEImageNamedBundle,
                           &OriginalImageNamedBundle);
}
