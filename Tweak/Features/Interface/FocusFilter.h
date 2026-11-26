#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void YTKACEInstallFocusFilterHooks(void);
NSArray *YTKACEFocusFilterSections(id _Nullable receiver, NSArray *sections);
void YTKACEFocusFilterVideoActivated(id _Nullable playerController, NSString * _Nullable videoID);
id _Nullable YTKACEFocusAppendMenuActions(id _Nullable renderers, id _Nullable entry, id _Nullable sourceView, id _Nullable actions);

NSArray<NSDictionary<NSString *, NSString *> *> *YTKACEFocusAllCategories(void);
NSSet<NSString *> *YTKACEFocusGetBlockedCategoryIDs(void);
void YTKACEFocusSetBlockedCategoryIDs(NSSet<NSString *> *categoryIDs);
NSArray<NSString *> *YTKACEFocusGetBlockedTitleKeywords(void);
void YTKACEFocusSetBlockedTitleKeywords(NSArray<NSString *> *keywords);
NSArray<NSString *> *YTKACEFocusGetBlockedChannels(void);
void YTKACEFocusSetBlockedChannels(NSArray<NSString *> *channels);
NSUInteger YTKACEFocusBlockedVideoCount(void);
void YTKACEFocusClearBlockedVideos(void);

BOOL YTKACEFocusHasPassword(void);
BOOL YTKACEFocusVerifyPassword(NSString *password);
void YTKACEFocusSetPassword(NSString *password);

NS_ASSUME_NONNULL_END
