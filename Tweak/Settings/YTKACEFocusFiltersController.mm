#import "YTKACEFocusFiltersController.h"
#import "YTKACERootOptionsController.h"
#import "../Features/Interface/FocusFilter.h"
#import "../Runtime/Preferences.h"
#import "../UI/Notice.h"

static UIColor *YTKACEFocusSettingsBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTKACEInterfaceBackgroundColor(traits);
    }];
}

// MARK: - Category Multi-Select Controller

@interface YTKACEFocusCategoriesController : UITableViewController
@end

@implementation YTKACEFocusCategoriesController {
    NSArray<NSDictionary<NSString *, NSString *> *> *_categories;
    NSMutableSet<NSString *> *_blockedIDs;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Blocked Categories";
        _categories = YTKACEFocusAllCategories();
        _blockedIDs = [YTKACEFocusGetBlockedCategoryIDs() mutableCopy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Block All"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(selectAllCategories)],
        [[UIBarButtonItem alloc] initWithTitle:@"Allow All"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(unselectAllCategories)]
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTKACEOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    YTKACEApplyAppearance(self);
    self.tableView.backgroundColor = YTKACEFocusSettingsBackground();
}

- (void)saveCategories {
    YTKACEFocusSetBlockedCategoryIDs([_blockedIDs copy]);
}

- (void)selectAllCategories {
    for (NSDictionary<NSString *, NSString *> *cat in _categories) {
        [_blockedIDs addObject:cat[@"id"]];
    }
    [self saveCategories];
    [self.tableView reloadData];
}

- (void)unselectAllCategories {
    [_blockedIDs removeAllObjects];
    [self saveCategories];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)_categories.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"CHECKED CATEGORIES ARE BLOCKED";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FocusCatCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FocusCatCell"];
    }
    NSDictionary<NSString *, NSString *> *cat = _categories[(NSUInteger)indexPath.row];
    BOOL blocked = [_blockedIDs containsObject:cat[@"id"]];
    cell.textLabel.text = cat[@"name"];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.backgroundColor = YTKACEInterfaceSurfaceColor(self.traitCollection);
    cell.tintColor = UIColor.systemRedColor;
    cell.accessoryType = blocked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary<NSString *, NSString *> *cat = _categories[(NSUInteger)indexPath.row];
    NSString *cid = cat[@"id"];
    if ([_blockedIDs containsObject:cid]) {
        [_blockedIDs removeObject:cid];
    } else {
        [_blockedIDs addObject:cid];
    }
    [self saveCategories];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end

// MARK: - Multiline Text List Editor (Titles & Channels)

@interface YTKACEFocusTextListController : UIViewController
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                  initialText:(NSString *)initialText
                   saveAction:(void (^)(NSString *text))saveAction;
@end

@implementation YTKACEFocusTextListController {
    NSString *_subtitleText;
    NSString *_initialText;
    void (^_saveAction)(NSString *text);
    UITextView *_textView;
}

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                  initialText:(NSString *)initialText
                   saveAction:(void (^)(NSString *text))saveAction {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.title = title;
        _subtitleText = [subtitle copy];
        _initialText = [initialText copy];
        _saveAction = [saveAction copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                             target:self
                             action:@selector(saveTapped)];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = _subtitleText;
    hint.font = [UIFont systemFontOfSize:13.0];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    _textView = [[UITextView alloc] init];
    _textView.text = _initialText;
    _textView.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightRegular];
    _textView.textColor = UIColor.labelColor;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.layer.cornerRadius = 10.0;
    _textView.layer.borderWidth = 1.0;
    _textView.layer.borderColor = UIColor.separatorColor.CGColor;
    _textView.textContainerInset = UIEdgeInsetsMake(12.0, 10.0, 12.0, 10.0);
    _textView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:hint];
    [self.view addSubview:_textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
        [hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
        [_textView.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:10.0],
        [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
        [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
        [_textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16.0]
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTKACEOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    YTKACEApplyAppearance(self);
    self.view.backgroundColor = YTKACEFocusSettingsBackground();
    _textView.backgroundColor = YTKACEInterfaceSurfaceColor(self.traitCollection);
}

- (void)saveTapped {
    if (_saveAction) {
        _saveAction(_textView.text ?: @"");
    }
    YTKACEShowNotice(@"Filters saved");
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// MARK: - Main Focus Filters Controller (Unlocked)

@interface YTKACEFocusFiltersController : UITableViewController
@end

@implementation YTKACEFocusFiltersController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Focus Filters";
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTKACEOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    YTKACEApplyAppearance(self);
    self.tableView.backgroundColor = YTKACEFocusSettingsBackground();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 4 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"FILTERS" : @"SECURITY";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"3-dot Block Channel and Block Video always work without a password. Editing or unblocking filters here requires your password.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FocusFilterRow"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"FocusFilterRow"];
    }
    cell.backgroundColor = YTKACEInterfaceSurfaceColor(self.traitCollection);
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            NSUInteger blocked = YTKACEFocusGetBlockedCategoryIDs().count;
            NSUInteger total = YTKACEFocusAllCategories().count;
            cell.textLabel.text = @"Blocked Categories";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu of %lu blocked",
                (unsigned long)blocked, (unsigned long)total];
        } else if (indexPath.row == 1) {
            NSUInteger count = YTKACEFocusGetBlockedTitleKeywords().count;
            cell.textLabel.text = @"Blocked Title Keywords";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu keywords", (unsigned long)count];
        } else if (indexPath.row == 2) {
            NSUInteger count = YTKACEFocusGetBlockedChannels().count;
            cell.textLabel.text = @"Blocked Channels";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu channels", (unsigned long)count];
        } else {
            NSUInteger count = YTKACEFocusBlockedVideoCount();
            cell.textLabel.text = @"Blocked Videos";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu blocked via 3-dot menu (tap to clear)",
                (unsigned long)count];
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else {
        cell.textLabel.text = @"Change Password";
        cell.detailTextLabel.text = @"Update the password required to open Focus Filters";
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            [self.navigationController pushViewController:[YTKACEFocusCategoriesController new] animated:YES];
        } else if (indexPath.row == 1) {
            NSString *joined = [YTKACEFocusGetBlockedTitleKeywords() componentsJoinedByString:@", "];
            YTKACEFocusTextListController *vc = [[YTKACEFocusTextListController alloc]
                initWithTitle:@"Title Keywords"
                     subtitle:@"Separate keywords by comma or new line (case-insensitive)."
                  initialText:joined
                   saveAction:^(NSString *text) {
                NSMutableArray<NSString *> *parsed = [NSMutableArray array];
                NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@",\n\r"];
                for (NSString *part in [text componentsSeparatedByCharactersInSet:seps]) {
                    NSString *clean = [[part stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
                    if (clean.length > 0 && ![parsed containsObject:clean]) {
                        [parsed addObject:clean];
                    }
                }
                YTKACEFocusSetBlockedTitleKeywords(parsed);
            }];
            [self.navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 2) {
            NSString *joined = [YTKACEFocusGetBlockedChannels() componentsJoinedByString:@"\n"];
            YTKACEFocusTextListController *vc = [[YTKACEFocusTextListController alloc]
                initWithTitle:@"Blocked Channels"
                     subtitle:@"One channel name per line (exact match, case-insensitive)."
                  initialText:joined
                   saveAction:^(NSString *text) {
                NSMutableArray<NSString *> *parsed = [NSMutableArray array];
                for (NSString *line in [text componentsSeparatedByCharactersInSet:
                        NSCharacterSet.newlineCharacterSet]) {
                    NSString *clean = [line stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (clean.length > 0 && ![parsed containsObject:clean]) {
                        [parsed addObject:clean];
                    }
                }
                YTKACEFocusSetBlockedChannels(parsed);
            }];
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            NSUInteger count = YTKACEFocusBlockedVideoCount();
            if (count == 0) {
                YTKACEShowNotice(@"No individually blocked videos");
                return;
            }
            UIAlertController *confirm = [UIAlertController
                alertControllerWithTitle:@"Clear Blocked Videos"
                                 message:[NSString stringWithFormat:@"Unblock all %lu videos blocked via the 3-dot menu?",
                                          (unsigned long)count]
                          preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"Clear All"
                                                        style:UIAlertActionStyleDestructive
                                                      handler:^(__unused UIAlertAction *action) {
                YTKACEFocusClearBlockedVideos();
                YTKACEShowNotice(@"Cleared blocked videos");
                [self.tableView reloadData];
            }]];
            [self presentViewController:confirm animated:YES completion:nil];
        }
    } else {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Change Focus Password"
                             message:@"Enter your current password and a new password."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Current password";
            tf.secureTextEntry = YES;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"New password";
            tf.secureTextEntry = YES;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Confirm new password";
            tf.secureTextEntry = YES;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Update"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            NSString *curr = weakAlert.textFields[0].text ?: @"";
            NSString *next = weakAlert.textFields[1].text ?: @"";
            NSString *conf = weakAlert.textFields[2].text ?: @"";
            if (!YTKACEFocusVerifyPassword(curr)) {
                YTKACEShowNotice(@"Current password is incorrect");
                return;
            }
            if (next.length < 4) {
                YTKACEShowNotice(@"Password must be at least 4 characters");
                return;
            }
            if (![next isEqualToString:conf]) {
                YTKACEShowNotice(@"Passwords do not match");
                return;
            }
            YTKACEFocusSetPassword(next);
            YTKACEShowNotice(@"Focus password updated");
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

// MARK: - Password Gate Entry Point

void YTKACEPresentFocusFiltersWithPasswordGate(UIViewController *presenter) {
    if (presenter == nil) return;

    if (!YTKACEFocusHasPassword()) {
        UIAlertController *setup = [UIAlertController
            alertControllerWithTitle:@"Set Focus Password"
                             message:@"Create a password to protect editing Focus Filters. Blocking via the 3-dot menu will still work without a password."
                      preferredStyle:UIAlertControllerStyleAlert];
        [setup addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"New password (min 4 chars)";
            tf.secureTextEntry = YES;
        }];
        [setup addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Confirm password";
            tf.secureTextEntry = YES;
        }];
        [setup addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakSetup = setup;
        [setup addAction:[UIAlertAction actionWithTitle:@"Set Password"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            NSString *p1 = weakSetup.textFields[0].text ?: @"";
            NSString *p2 = weakSetup.textFields[1].text ?: @"";
            if (p1.length < 4) {
                YTKACEShowNotice(@"Password must be at least 4 characters");
                return;
            }
            if (![p1 isEqualToString:p2]) {
                YTKACEShowNotice(@"Passwords do not match");
                return;
            }
            YTKACEFocusSetPassword(p1);
            YTKACEShowNotice(@"Focus password set");
            [presenter.navigationController setNavigationBarHidden:NO animated:NO];
            [presenter.navigationController pushViewController:[YTKACEFocusFiltersController new] animated:YES];
        }]];
        [presenter presentViewController:setup animated:YES completion:nil];
        return;
    }

    UIAlertController *unlock = [UIAlertController
        alertControllerWithTitle:@"Focus Filters Locked"
                         message:@"Enter your password to edit Focus Filters."
                  preferredStyle:UIAlertControllerStyleAlert];
    [unlock addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Password";
        tf.secureTextEntry = YES;
    }];
    [unlock addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakUnlock = unlock;
    [unlock addAction:[UIAlertAction actionWithTitle:@"Unlock"
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        NSString *entered = weakUnlock.textFields.firstObject.text ?: @"";
        if (!YTKACEFocusVerifyPassword(entered)) {
            YTKACEShowNotice(@"Incorrect password");
            return;
        }
        [presenter.navigationController setNavigationBarHidden:NO animated:NO];
        [presenter.navigationController pushViewController:[YTKACEFocusFiltersController new] animated:YES];
    }]];
    [presenter presentViewController:unlock animated:YES completion:nil];
}
