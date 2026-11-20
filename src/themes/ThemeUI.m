#import "ThemeUI.h"
#import "ThemeFeatures.h"
#import "ThemeShop.h"
#import "ThemeVersion.h"
#import "ThemeProductIdentity.h"
#import "ThemeStoreResolver.h"
#import "NativeThemeWorkflow.h"
#import "ThemeArchive.h"
#import <objc/runtime.h>
#import "../core/Localization.h"

// Main-queue state keeps an in-progress UI download visible after reopening.
static NSNotificationName const RUINThemeUIDownloadChanged = @"app.ruin.themeui.downloadChanged";
static BOOL gThemeUIDownloading;
static BOOL gThemeUIDownloadSaved;
static NSString *gThemeUIDownloadName;
static NSError *gThemeUIDownloadError;

typedef NS_ENUM(NSInteger, RUINThemeUISection) {
    RUINThemeUISectionDownload,
    RUINThemeUISectionShop,
    RUINThemeUISectionSaved,
    RUINThemeUISectionNative,
    RUINThemeUISectionCount
};

static NSString *RUINThemeUIString(id value)
{
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return @"";
}

static BOOL RUINThemeUIFlag(id value)
{
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

static NSString *RUINThemeUIName(NSDictionary *record)
{
    NSString *name = RUINThemeUIString(record[@"name"]);
    if (!name.length) name = RUINThemeUIString(record[@"productID"]);
    if (!name.length) name = RUINLocalizedString(@"themes.unnamed");
    if (name.length > 256) name = [name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 256)]];
    return name;
}

static NSString *RUINThemeUIVersion(NSDictionary *record)
{
    NSString *version = RUINThemeUIString(record[@"versionString"]);
    if (!version.length) version = RUINThemeUIString(record[@"version"]);
    return version.length ? version : RUINLocalizedString(@"common.unverified");
}

static NSURL *RUINThemeUIArchiveURL(NSDictionary *record)
{
    id value = record[@"packageURL"];
    NSURL *url = [value isKindOfClass:[NSURL class]] ? value : nil;
    return RUINThemeUIFlag(record[@"downloadedLocally"]) &&
        RUINThemeUIFlag(record[@"archiveStructureValidated"]) && url.isFileURL &&
        [url.pathExtension.lowercaseString isEqualToString:@"linetheme"] ? url : nil;
}

static NSArray<NSDictionary *> *RUINThemeUIVisibleArchives(NSArray<NSDictionary *> *archives)
{
    NSMutableArray *visible = [NSMutableArray array];
    NSMutableDictionary<NSArray *, NSNumber *> *indices = [NSMutableDictionary dictionary];
    for (NSDictionary *record in archives) {
        NSURL *URL = RUINThemeUIArchiveURL(record);
        if (!URL) continue;
        NSString *productID = RUINCanonicalThemeProductID(record[@"productID"]);
        NSString *version = RUINThemeDownloadVersion(RUINThemeUIString(record[@"version"]));
        if (!version.length) version = RUINThemeDownloadVersion(RUINThemeUIString(record[@"versionString"]));
        // Names and archive UUID filenames are not product identity. Preserve
        // distinct versions and rows whose metadata cannot establish identity.
        if (!productID.length || !version.length) { [visible addObject:record]; continue; }
        NSArray *key = @[productID, version];
        NSNumber *index = indices[key];
        if (!index) {
            indices[key] = @(visible.count);
            [visible addObject:record];
        } else if ([URL.path compare:RUINThemeUIArchiveURL(visible[index.unsignedIntegerValue]).path] == NSOrderedAscending) {
            // Stable representative across scan order; retain its original URL
            // for preview/share validation. Never modify the underlying archive.
            visible[index.unsignedIntegerValue] = record;
        }
    }
    return [visible copy];
}

static NSString *RUINThemeUINativeStatus(NSDictionary *record)
{
    if (RUINThemeUIFlag(record[@"owned"])) return RUINLocalizedString(@"themes.owned");
    if (RUINThemeUIFlag(record[@"grantedByDefault"])) return RUINLocalizedString(@"font.available_by_default");
    NSDate *expiry = [record[@"validUntil"] isKindOfClass:[NSDate class]] ? record[@"validUntil"] : nil;
    if (expiry) return expiry.timeIntervalSinceNow > 0 ? RUINLocalizedString(@"themes.within_expiry") : RUINLocalizedString(@"themes.expired_record");
    return RUINLocalizedString(@"themes.usage_unverified");
}

static NSError *RUINThemeUIError(NSString *message)
{
    return [NSError errorWithDomain:RUINThemeErrorDomain code:RUINThemeErrorNativeAPIUnavailable
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *RUINThemeUIInputError(NSString *name, NSString *productID, NSString *version)
{
    if (!name.length) return RUINLocalizedString(@"themes.name_required");
    if (name.length > 256 || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return RUINLocalizedString(@"names.invalid_name");
    if (productID.length < 6 || productID.length > 128)
        return RUINLocalizedString(@"themes.product_id_length");
    for (NSUInteger i = 0; i < productID.length; i++) {
        unichar c = [productID characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
              (c >= 'A' && c <= 'Z') || c == '-' || c == '_' || c == '.'))
            return RUINLocalizedString(@"themes.invalid_product_id");
    }
    if (!RUINThemeDownloadVersion(version)) return RUINLocalizedString(@"themes.version_required");
    return nil;
}

static NSString *RUINThemeUITrim(NSString *value)
{
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}


// MARK: - Theme package previews

static NSCache<NSString *, UIImage *> *RUINThemePreviewMemoryCache(void)
{
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 64; });
    return cache;
}

static NSMutableDictionary<NSString *, NSMutableArray<void (^)(UIImage * _Nullable)> *> *RUINThemePreviewPending(void)
{
    static NSMutableDictionary *pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; });
    return pending;
}

static NSURL *RUINThemePreviewCacheDirectory(void)
{
    NSURL *caches = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *dir = [caches URLByAppendingPathComponent:@"RUINThemePreviews" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *RUINThemePreviewCacheKey(NSDictionary *record, NSURL *url)
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    long long size = [attrs[NSFileSize] longLongValue];
    long long mtime = (long long)[attrs[NSFileModificationDate] timeIntervalSince1970];
    NSString *raw = [NSString stringWithFormat:@"%@-%@-%lld-%lld",
        RUINThemeUIString(record[@"productID"]), RUINThemeUIVersion(record), size, mtime];
    NSMutableString *key = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '.') [key appendFormat:@"%C", c];
        else [key appendString:@"_"];
    }
    return key;
}

static UIImage *RUINThemePreviewPickImage(NSURL *stageDir)
{
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:stageDir
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
    UIImage *bestImage = nil;
    double bestScore = -1;
    for (NSURL *file in enumerator) {
        NSString *ext = file.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"])) continue;
        if ([file.path containsString:@"__MACOSX"]) continue;
        NSNumber *isDir = nil;
        [file getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        UIImage *image = [UIImage imageWithContentsOfFile:file.path];
        if (!image) continue;
        CGFloat pixels = (CGFloat)CGImageGetWidth(image.CGImage) * (CGFloat)CGImageGetHeight(image.CGImage);
        NSString *name = file.lastPathComponent.lowercaseString;
        double score = MIN(pixels, 4000000.0) / 100000.0;
        if ([name containsString:@"preview"]) score += 100;
        if ([name containsString:@"thumbnail"] || [name containsString:@"thumb"]) score += 90;
        if ([name containsString:@"main"]) score += 50;
        if ([name containsString:@"background"] || [name containsString:@"_bg"] || [name hasPrefix:@"bg"]) score += 45;
        if ([name containsString:@"top"]) score += 30;
        if (score > bestScore) { bestScore = score; bestImage = image; }
    }
    return bestImage;
}

static UIImage *RUINThemePreviewDownscale(UIImage *image, CGFloat maxDimension)
{
    CGFloat width = (CGFloat)CGImageGetWidth(image.CGImage), height = (CGFloat)CGImageGetHeight(image.CGImage);
    if (MAX(width, height) <= maxDimension) return image;
    CGFloat scale = maxDimension / MAX(width, height);
    CGSize size = CGSizeMake(MAX(1, floor(width * scale)), MAX(1, floor(height * scale)));
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

static void RUINThemePreviewLoad(NSDictionary *record, void (^completion)(UIImage * _Nullable image))
{
    NSURL *url = RUINThemeUIArchiveURL(record);
    if (!url) { completion(nil); return; }
    NSString *key = RUINThemePreviewCacheKey(record, url);
    UIImage *cached = [RUINThemePreviewMemoryCache() objectForKey:key];
    if (cached) { completion(cached); return; }
    NSURL *cacheFile = [RUINThemePreviewCacheDirectory() URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"png"]];
    @synchronized (RUINThemePreviewPending()) {
        NSMutableArray *waiters = RUINThemePreviewPending()[key];
        if (waiters) { [waiters addObject:[completion copy]]; return; }
        RUINThemePreviewPending()[key] = [NSMutableArray arrayWithObject:[completion copy]];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            UIImage *image = [UIImage imageWithContentsOfFile:cacheFile.path];
            if (!image) {
                NSURL *stageRoot = [RUINThemePreviewCacheDirectory() URLByAppendingPathComponent:@"stage" isDirectory:YES];
                [NSFileManager.defaultManager createDirectoryAtURL:stageRoot withIntermediateDirectories:YES attributes:nil error:nil];
                NSError *error = nil;
                NSURL *stage = RUINStageThemeArchiveAtURL(url, stageRoot, &error);
                if (stage) {
                    UIImage *picked = RUINThemePreviewPickImage(stage);
                    if (picked) {
                        image = RUINThemePreviewDownscale(picked, 1200);
                        NSData *png = UIImagePNGRepresentation(image);
                        if (png) [png writeToURL:cacheFile atomically:YES];
                    }
                    [NSFileManager.defaultManager removeItemAtURL:stage error:nil];
                }
            }
            if (image) [RUINThemePreviewMemoryCache() setObject:image forKey:key];
            NSArray *waiters = nil;
            @synchronized (RUINThemePreviewPending()) {
                waiters = [RUINThemePreviewPending()[key] copy];
                [RUINThemePreviewPending() removeObjectForKey:key];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                for (void (^waiter)(UIImage *) in waiters) waiter(image);
            });
        }
    });
}

static UIImage *RUINThemePreviewThumbnail(UIImage *image)
{
    // Renderer sizes are points; the default format already renders at the
    // screen scale, so 56pt yields a 168px bitmap on a 3x display.
    CGSize size = CGSizeMake(56, 56);
    if (!image || image.size.width <= 0 || image.size.height <= 0) return image;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
        CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
}

static NSString *RUINThemePackageSizeText(NSDictionary *record)
{
    NSURL *url = RUINThemeUIArchiveURL(record);
    NSDictionary *attrs = url ? [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil] : nil;
    if (!attrs) return RUINLocalizedString(@"common.unverified");
    return [NSByteCountFormatter stringFromByteCount:[attrs[NSFileSize] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
}

@class RUINThemeSettingsViewController;

@interface RUINThemePackageViewController : UITableViewController <UIDocumentInteractionControllerDelegate>
- (instancetype)initWithRecord:(NSDictionary *)record listController:(RUINThemeSettingsViewController *)listController;
@end

@interface RUINThemeSettingsViewController : UITableViewController <UIDocumentInteractionControllerDelegate>
@property(nonatomic, copy) NSArray<NSDictionary *> *archives;
@property(nonatomic, copy) NSArray<NSDictionary *> *nativeRecords;
@property(nonatomic) BOOL catalogAvailable;
@property(nonatomic) BOOL nativeCatalogAvailable;
@property(nonatomic) BOOL downloadAvailable;
@property(nonatomic) BOOL catalogLoading;
@property(nonatomic) BOOL catalogReloadRequested;
@property(nonatomic) BOOL hasCatalog;
@property(nonatomic) BOOL checkingArchive;
@property(nonatomic, strong) NSError *catalogError;
@property(nonatomic, weak) UIAlertController *downloadPrompt;
@property(nonatomic, weak) UIAlertAction *downloadSubmitAction;
@property(nonatomic, strong) UIDocumentInteractionController *documentController;
@end

@implementation RUINThemeSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _archives = @[];
        _nativeRecords = @[];
        self.title = RUINLocalizedString(@"themes.title");
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadCatalog)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = RUINLocalizedString(@"themes.refresh_list");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadCatalog) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(downloadStateChanged:)
        name:RUINThemeUIDownloadChanged object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAvailability];
    [self reloadCatalog];
}

- (void)updateAvailability
{
    NSDictionary *diagnostics = RUINThemeDiagnostics();
    NSDictionary *operations = diagnostics[@"operations"];
    self.catalogAvailable = RUINThemeUIFlag(operations[@"localCatalog"][@"available"]);
    self.downloadAvailable = RUINThemeUIFlag(operations[@"manualDownload"][@"available"]);
    self.nativeCatalogAvailable = RUINThemeUIFlag(diagnostics[@"metadataEvidence"][@"nativeCoreDataCatalog"][@"catalogRuntimeAvailable"]);
}

- (BOOL)canDownload
{
    return self.downloadAvailable && !gThemeUIDownloading && !self.checkingArchive &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey];
}

- (BOOL)hasDownloadStatus
{
    return gThemeUIDownloading || gThemeUIDownloadSaved || gThemeUIDownloadError || self.checkingArchive;
}

- (BOOL)isVisible
{
    return self.viewIfLoaded.window && self.navigationController.topViewController == self &&
        !self.presentedViewController;
}

- (void)reloadRows
{
    self.navigationItem.rightBarButtonItem.enabled = !self.catalogLoading && !self.checkingArchive;
    [self.tableView reloadData];
}

- (void)reloadCatalog
{
    if (self.catalogLoading) {
        self.catalogReloadRequested = YES;
        return;
    }
    [self updateAvailability];
    if (!self.catalogAvailable) {
        self.catalogError = RUINThemeUIError(RUINLocalizedString(@"themes.catalog_unavailable"));
        [self.refreshControl endRefreshing];
        [self reloadRows];
        return;
    }
    self.catalogLoading = YES;
    [self reloadRows];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSArray<NSDictionary *> *catalog = RUINThemeCatalog(&error);
            NSMutableArray *archives = [NSMutableArray array];
            NSMutableArray *nativeRecords = [NSMutableArray array];
            for (NSDictionary *record in catalog) {
                if (RUINThemeUIArchiveURL(record)) [archives addObject:record];
                else if ([record[@"sourceEntity"] isEqual:@"OwnedThemeProduct"]) [nativeRecords addObject:record];
            }
            NSError *resultError = catalog ? nil : (error ?: RUINThemeUIError(RUINLocalizedString(@"themes.list_fetch_error")));
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) owner = weakSelf;
                if (!owner) return;
                owner.catalogLoading = NO;
                owner.catalogError = resultError;
                if (catalog) {
                    owner.archives = RUINThemeUIVisibleArchives(archives);
                    owner.nativeRecords = nativeRecords;
                    owner.hasCatalog = YES;
                }
                [owner.refreshControl endRefreshing];
                [owner reloadRows];
                if (owner.catalogReloadRequested) {
                    owner.catalogReloadRequested = NO;
                    [owner reloadCatalog];
                }
            });
        }
    });
}

- (void)downloadStateChanged:(NSNotification *)notification
{
    [self reloadRows];
    if ([notification.userInfo[@"finished"] boolValue] && gThemeUIDownloadSaved) [self reloadCatalog];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return RUINThemeUISectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == RUINThemeUISectionDownload) return 3 + (self.hasDownloadStatus ? 1 : 0) + (self.catalogError ? 1 : 0);
    if (section == RUINThemeUISectionShop) return 2;
    return MAX((NSInteger)(section == RUINThemeUISectionSaved ? self.archives.count : self.nativeRecords.count), 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == RUINThemeUISectionDownload) return RUINLocalizedString(@"common.download");
    if (section == RUINThemeUISectionSaved) return [NSString stringWithFormat:(RUINLocalizedString(@"themes.saved_file_count") ?: @"保存済みファイル（%lu）"), (unsigned long)self.archives.count];
    if (section == RUINThemeUISectionShop) return RUINLocalizedString(@"shops.theme_title");
    return [NSString stringWithFormat:(RUINLocalizedString(@"themes.native_record_count") ?: @"LINEの着せかえ記録（%lu）"), (unsigned long)self.nativeRecords.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == RUINThemeUISectionShop) return nil;
    if (section == RUINThemeUISectionDownload) {
        if (!self.downloadAvailable) return RUINLocalizedString(@"themes.download_unavailable");
        return RUINLocalizedString(@"themes.download_help");
    }
    NSString *note = section == RUINThemeUISectionSaved
        ? RUINLocalizedString(@"themes.downloaded_files_footer")
        : (self.nativeCatalogAvailable
            ? RUINLocalizedString(@"themes.native_records_footer")
            : RUINLocalizedString(@"themes.native_records_unavailable"));
    if (self.catalogError && self.hasCatalog)
        note = [note stringByAppendingFormat:@"\n%@", RUINLocalizedString(@"themes.list_update_failed")];
    return note;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ThemeRow"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ThemeRow"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = YES;
    BOOL spinning = NO;

    if (path.section == RUINThemeUISectionDownload && path.row == 0) {
        cell.textLabel.text = RUINLocalizedString(@"themes.enable_downloads");
        UISwitch *toggle = [UISwitch new];
        toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey];
        toggle.enabled = self.downloadAvailable && !gThemeUIDownloading;
        toggle.accessibilityLabel = cell.textLabel.text;
        [toggle addTarget:self action:@selector(downloadEnabledChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (path.section == RUINThemeUISectionDownload && path.row == 1) {
        cell.textLabel.text = RUINLocalizedString(@"themes.download_from_url");
        cell.detailTextLabel.text = RUINLocalizedString(@"themes.url_download_hint");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = self.canDownload;
        cell.textLabel.textColor = self.canDownload ? UIColor.labelColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = self.canDownload ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (path.section == RUINThemeUISectionDownload && path.row == 2) {
        cell.textLabel.text = RUINLocalizedString(@"themes.manual_download");
        cell.detailTextLabel.text = RUINLocalizedString(@"themes.manual_download_hint");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = self.canDownload;
        cell.textLabel.textColor = self.canDownload ? UIColor.labelColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = self.canDownload ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (path.section == RUINThemeUISectionDownload && self.catalogError && path.row == 3 + (self.hasDownloadStatus ? 1 : 0)) {
        cell.textLabel.text = RUINLocalizedString(@"themes.list_refresh_failed");
        cell.detailTextLabel.text = RUINLocalizedString(@"common.view_reason");
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (path.section == RUINThemeUISectionDownload) {
        spinning = gThemeUIDownloading || self.checkingArchive;
        if (gThemeUIDownloading) {
            cell.textLabel.text = RUINLocalizedString(@"themes.download_checking");
            cell.detailTextLabel.text = gThemeUIDownloadName;
        } else if (self.checkingArchive) cell.textLabel.text = RUINLocalizedString(@"themes.file_checking");
        else if (gThemeUIDownloadError) {
            cell.textLabel.text = RUINLocalizedString(@"themes.download_failed");
            cell.detailTextLabel.text = RUINLocalizedString(@"common.view_reason");
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.textLabel.text = RUINLocalizedString(@"themes.file_saved");
            cell.detailTextLabel.text = gThemeUIDownloadName;
        }
    } else if (path.section == RUINThemeUISectionShop) {
        cell.textLabel.text = RUINLocalizedString(path.row == 0
            ? @"themes.open_shop" : @"themes.open_my_themes");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        NSArray<NSDictionary *> *records = path.section == RUINThemeUISectionSaved ? self.archives : self.nativeRecords;
        if (records.count) {
            NSDictionary *record = records[path.row];
            cell.textLabel.text = RUINThemeUIName(record);
            if (path.section == RUINThemeUISectionSaved) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ · %@",
                    RUINThemeUIVersion(record), RUINThemePackageSizeText(record)];
                cell.imageView.layer.cornerRadius = 12;
                cell.imageView.clipsToBounds = YES;
                NSURL *archiveURL = RUINThemeUIArchiveURL(record);
                NSString *key = archiveURL ? RUINThemePreviewCacheKey(record, archiveURL) : nil;
                objc_setAssociatedObject(cell, "ruin.packageKey", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
                UIImage *thumb = key ? [RUINThemePreviewMemoryCache() objectForKey:[key stringByAppendingString:@"#thumb"]] : nil;
                if (thumb) {
                    cell.imageView.image = thumb;
                } else {
                    cell.imageView.image = [UIImage systemImageNamed:@"paintpalette.fill"];
                    cell.imageView.tintColor = UIColor.systemGray3Color;
                    if (key) {
                        __weak UITableViewCell *weakCell = cell;
                        RUINThemePreviewLoad(record, ^(UIImage *image) {
                            UITableViewCell *strongCell = weakCell;
                            if (!strongCell || !image) return;
                            if (![objc_getAssociatedObject(strongCell, "ruin.packageKey") isEqual:key]) return;
                            UIImage *resized = RUINThemePreviewThumbnail(image);
                            [RUINThemePreviewMemoryCache() setObject:resized forKey:[key stringByAppendingString:@"#thumb"]];
                            strongCell.imageView.image = resized;
                            strongCell.imageView.tintColor = nil;
                            [strongCell setNeedsLayout];
                        });
                    }
                }
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:(RUINLocalizedString(@"themes.downloaded_file_details") ?: @"商品ID: %@\nバージョン: %@%@"),
                    RUINThemeUIString(record[@"productID"]), RUINThemeUIVersion(record),
                    [@" · " stringByAppendingString:RUINThemeUINativeStatus(record)]];
                cell.imageView.image = nil;
            }
            cell.accessoryType = path.section == RUINThemeUISectionSaved ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryDetailButton;
            cell.userInteractionEnabled = path.section == RUINThemeUISectionNative || (!gThemeUIDownloading && !self.checkingArchive);
            cell.selectionStyle = cell.userInteractionEnabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        } else {
            spinning = self.catalogLoading;
            if (self.catalogLoading) cell.textLabel.text = RUINLocalizedString(@"themes.list_loading");
            else if (self.catalogError) {
                cell.textLabel.text = RUINLocalizedString(@"themes.list_fetch_failed");
                cell.detailTextLabel.text = RUINLocalizedString(@"common.view_reason");
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else if (path.section == RUINThemeUISectionNative && !self.nativeCatalogAvailable) cell.textLabel.text = RUINLocalizedString(@"themes.native_records_failed");
            else cell.textLabel.text = path.section == RUINThemeUISectionSaved ? RUINLocalizedString(@"themes.no_saved_files") : RUINLocalizedString(@"themes.no_native_records");
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
        }
    }
    if (spinning) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        indicator.accessibilityLabel = RUINLocalizedString(@"common.processing");
        [indicator startAnimating];
        cell.accessoryView = indicator;
    }
    return cell;
}

- (void)downloadEnabledChanged:(UISwitch *)toggle
{
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:RUINThemeShopDownloadEnabledDefaultsKey];
    [self reloadRows];
}

- (void)showMessage:(NSString *)message title:(NSString *)title
{
    if (!self.isVisible) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSError *)error title:(NSString *)title
{
    NSString *message = error.localizedDescription ?: RUINLocalizedString(@"errors.operation_failed");
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorNotConnectedToInternet: message = RUINLocalizedString(@"errors.offline"); break;
            case NSURLErrorTimedOut: message = RUINLocalizedString(@"errors.timeout"); break;
            case NSURLErrorNetworkConnectionLost: message = RUINLocalizedString(@"errors.connection_lost"); break;
            case NSURLErrorCancelled: message = RUINLocalizedString(@"errors.cancelled"); break;
            default: break;
        }
    }
    [self showMessage:message title:title];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path
{
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == RUINThemeUISectionShop) {
        if (path.row == 0) RUINOpenThemeShop(self);
        else RUINOpenDownloadedThemes(self);
        return;
    }
    if (path.section == RUINThemeUISectionDownload) {
        if (path.row == 1) [self showStoreURLPrompt];
        else if (path.row == 2) [self showDownloadPrompt];
        else if (self.catalogError && path.row == 3 + (self.hasDownloadStatus ? 1 : 0)) [self showError:self.catalogError title:RUINLocalizedString(@"themes.list_refresh_failed")];
        else if (path.row == 3 && gThemeUIDownloadError && !gThemeUIDownloading && !self.checkingArchive)
            [self showError:gThemeUIDownloadError title:RUINLocalizedString(@"themes.download_failed")];
        return;
    }
    NSArray<NSDictionary *> *records = path.section == RUINThemeUISectionSaved ? self.archives : self.nativeRecords;
    if (!records.count) {
        if (self.catalogError && !self.catalogLoading) [self showError:self.catalogError title:RUINLocalizedString(@"themes.list_fetch_failed")];
        return;
    }
    NSDictionary *record = records[path.row];
    if (path.section == RUINThemeUISectionNative) [self showNativeRecord:record];
    else if (!gThemeUIDownloading && !self.checkingArchive) {
        RUINThemePackageViewController *package = [[RUINThemePackageViewController alloc] initWithRecord:record listController:self];
        [self.navigationController pushViewController:package animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)path
{
    if (path.section == RUINThemeUISectionNative && (NSUInteger)path.row < self.nativeRecords.count) [self showNativeRecord:self.nativeRecords[path.row]];
}

- (void)showNativeRecord:(NSDictionary *)record
{
    [self showMessage:[NSString stringWithFormat:(RUINLocalizedString(@"themes.native_record_details") ?: @"商品ID: %@\nバージョン: %@\n%@\n\nLINEの保存記録です。現在の適用状態は確認していません。"),
        RUINThemeUIString(record[@"productID"]), RUINThemeUIVersion(record), RUINThemeUINativeStatus(record)]
        title:RUINThemeUIName(record)];
}

- (void)showStoreURLPrompt
{
    if (!self.canDownload) return;
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"themes.download_from_url")
        message:RUINLocalizedString(@"themes.store_url_hint") preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://store.line.me/themeshop/product/…";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak UIAlertController *weakPrompt = prompt;
    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *download = [UIAlertAction actionWithTitle:RUINLocalizedString(@"common.download") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *URLText = RUINThemeUITrim(weakPrompt.textFields.firstObject.text);
        if (!RUINValidatedThemeStoreURL(URLText)) {
            [weakSelf showMessage:RUINLocalizedString(@"themes.invalid_store_url") title:RUINLocalizedString(@"themes.download_start_failed")];
            return;
        }
        // Preserve the confirmed request through resolution and download kickoff.
        RUINThemeSettingsViewController *owner = weakSelf;
        if (!owner) return;
        gThemeUIDownloading = YES;
        gThemeUIDownloadSaved = NO;
        gThemeUIDownloadError = nil;
        gThemeUIDownloadName = RUINLocalizedString(@"themes.store_info_loading");
        [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil];
        RUINResolveThemeStoreURL(URLText, ^(NSDictionary<NSString *, NSString *> *theme, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                gThemeUIDownloading = NO;
                gThemeUIDownloadName = nil;
                if (error || ![theme isKindOfClass:NSDictionary.class] ||
                    ![theme[@"name"] isKindOfClass:NSString.class] ||
                    ![theme[@"productID"] isKindOfClass:NSString.class] ||
                    ![theme[@"version"] isKindOfClass:NSString.class]) {
                    gThemeUIDownloadError = RUINThemeUIError(RUINLocalizedString(@"themes.store_info_failed"));
                }
                [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil];
                if (gThemeUIDownloadError) {
                    if (owner.isVisible) [owner showError:gThemeUIDownloadError title:RUINLocalizedString(@"themes.download_start_failed")];
                } else [owner startDownloadWithName:theme[@"name"] productID:theme[@"productID"] version:theme[@"version"]];
            });
        });
    }];
    download.enabled = NO;
    __weak UITextField *weakField = prompt.textFields.firstObject;
    [weakField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        download.enabled = RUINValidatedThemeStoreURL(RUINThemeUITrim(weakField.text)) != nil;
    }] forControlEvents:UIControlEventEditingChanged];
    [prompt addAction:download];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)showDownloadPrompt
{
    if (!self.canDownload) return;
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"themes.download_file")
        message:RUINLocalizedString(@"themes.manual_fields_required") preferredStyle:UIAlertControllerStyleAlert];
    NSArray<NSString *> *placeholders = @[RUINLocalizedString(@"common.name"), RUINLocalizedString(@"themes.product_id"), RUINLocalizedString(@"themes.version_placeholder")];
    for (NSUInteger i = 0; i < placeholders.count; i++) {
        [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = placeholders[i];
            field.accessibilityLabel = placeholders[i];
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.keyboardType = i > 0 ? UIKeyboardTypeASCIICapable : UIKeyboardTypeDefault;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            [field addTarget:self action:@selector(downloadFieldsChanged:) forControlEvents:UIControlEventEditingChanged];
        }];
    }
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakPrompt = prompt;
    UIAlertAction *download = [UIAlertAction actionWithTitle:RUINLocalizedString(@"common.download") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIAlertController *active = weakPrompt;
        if (active.textFields.count != 3) return;
        [weakSelf startDownloadWithName:RUINThemeUITrim(active.textFields[0].text)
            productID:RUINThemeUITrim(active.textFields[1].text) version:RUINThemeUITrim(active.textFields[2].text)];
    }];
    [prompt addAction:download];
    self.downloadPrompt = prompt;
    self.downloadSubmitAction = download;
    [self downloadFieldsChanged:nil];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)downloadFieldsChanged:(UITextField *)field
{
    NSArray<UITextField *> *fields = self.downloadPrompt.textFields;
    if (fields.count != 3) return;
    NSString *error = RUINThemeUIInputError(RUINThemeUITrim(fields[0].text), RUINThemeUITrim(fields[1].text), RUINThemeUITrim(fields[2].text));
    self.downloadSubmitAction.enabled = !error && self.canDownload;
    self.downloadPrompt.message = error ?: RUINLocalizedString(@"themes.manual_download_help");
}

- (void)startDownloadWithName:(NSString *)name productID:(NSString *)productID version:(NSString *)version
{
    [self updateAvailability];
    NSString *inputError = RUINThemeUIInputError(name, productID, version);
    if (!self.canDownload || inputError) {
        [self showMessage:inputError ?: RUINLocalizedString(@"themes.download_not_ready") title:RUINLocalizedString(@"themes.download_start_failed")];
        return;
    }
    gThemeUIDownloading = YES;
    gThemeUIDownloadSaved = NO;
    gThemeUIDownloadName = [name copy];
    gThemeUIDownloadError = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil];
    __weak typeof(self) weakSelf = self;
    RUINDownloadThemeByID(name, productID, version, ^(NSURL *packageURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gThemeUIDownloading = NO;
            BOOL localArchive = packageURL.isFileURL && [packageURL.pathExtension.lowercaseString isEqualToString:@"linetheme"];
            gThemeUIDownloadError = error ?: (localArchive ? nil : RUINThemeUIError(RUINLocalizedString(@"themes.saved_file_missing")));
            gThemeUIDownloadSaved = !gThemeUIDownloadError;
            [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil userInfo:@{@"finished": @YES}];
            if (gThemeUIDownloadError) [weakSelf showError:gThemeUIDownloadError title:RUINLocalizedString(@"themes.download_failed")];
            else if (weakSelf.isVisible) {
                UIAlertController *saved = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"common.saved")
                    message:RUINLocalizedString(@"themes.file_saved_help")
                    preferredStyle:UIAlertControllerStyleAlert];
                [saved addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"themes.open_my_themes") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    RUINOpenDownloadedThemes(weakSelf);
                }]];
                [saved addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
                [weakSelf presentViewController:saved animated:YES completion:nil];
            }
        });
    });
}

- (CGRect)menuRect:(CGRect)rect
{
    CGRect visible = CGRectIntersection(rect, self.tableView.bounds);
    return CGRectIsNull(visible) || CGRectIsEmpty(visible)
        ? CGRectMake(CGRectGetMidX(self.tableView.bounds), CGRectGetMidY(self.tableView.bounds), 1, 1) : visible;
}

- (void)openArchive:(NSDictionary *)record preview:(BOOL)preview anchorRect:(CGRect)rect
{
    NSURL *requestedURL = RUINThemeUIArchiveURL(record);
    if (!requestedURL || self.checkingArchive || gThemeUIDownloading) return;
    self.checkingArchive = YES;
    [self reloadRows];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSArray<NSDictionary *> *catalog = RUINThemeCatalog(&error);
            NSURL *verifiedURL = nil;
            for (NSDictionary *candidate in catalog) {
                NSURL *url = RUINThemeUIArchiveURL(candidate);
                if (url && [url.path isEqualToString:requestedURL.path]) { verifiedURL = url; break; }
            }
            NSError *resultError = verifiedURL ? nil : (error ?: RUINThemeUIError(RUINLocalizedString(@"themes.archive_validation_failed")));
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) owner = weakSelf;
                if (!owner) return;
                owner.checkingArchive = NO;
                [owner reloadRows];
                if (!owner.isVisible) return;
                if (resultError) { [owner showError:resultError title:RUINLocalizedString(@"media.open_failed")]; return; }
                UIDocumentInteractionController *document = [UIDocumentInteractionController interactionControllerWithURL:verifiedURL];
                document.delegate = owner;
                document.UTI = @"jp.naver.talk.theme-package";
                owner.documentController = document;
                BOOL presented = preview ? [document presentPreviewAnimated:YES]
                    : [document presentOptionsMenuFromRect:[owner menuRect:rect] inView:owner.tableView animated:YES];
                if (!presented) [owner showMessage:preview
                    ? RUINLocalizedString(@"media.preview_unavailable")
                    : RUINLocalizedString(@"media.no_share_targets")
                    title:preview ? RUINLocalizedString(@"themes.preview_failed") : RUINLocalizedString(@"media.share_failed")];
            });
        }
    });
}

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller
{
    return self.navigationController ?: self;
}

@end


// MARK: - Full-screen preview viewer

@interface RUINThemePreviewViewerController : UIViewController <UIScrollViewDelegate>
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, strong) UIImageView *imageView;
@end

@implementation RUINThemePreviewViewerController

- (instancetype)initWithImage:(UIImage *)image
{
    self = [super init];
    if (self) _image = image;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.delegate = self;
    scroll.minimumZoomScale = 1.0;
    scroll.maximumZoomScale = 4.0;
    scroll.backgroundColor = UIColor.blackColor;
    self.imageView = [[UIImageView alloc] initWithImage:self.image];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.frame = scroll.bounds;
    [scroll addSubview:self.imageView];
    [self.view addSubview:scroll];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    [self.view addGestureRecognizer:tap];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return self.imageView; }

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

// MARK: - Theme package detail

@interface RUINThemeSettingsViewController (RUINPackageDetailSupport)
- (void)reloadCatalog;
@end

@interface RUINThemePackageViewController ()
@property(nonatomic, copy) NSDictionary *record;
@property(nonatomic, weak) RUINThemeSettingsViewController *listController;
@property(nonatomic, strong) UIImage *previewImage;
@property(nonatomic) BOOL previewLoaded;
@property(nonatomic, strong) UIDocumentInteractionController *documentController;
@end

static void RUINThemeUIApplySystemNavigationBarAppearance(UIViewController *controller)
{
    UITraitCollection *traits = controller.viewIfLoaded ? controller.viewIfLoaded.traitCollection : controller.traitCollection;
    UIColor *labelColor = [UIColor.labelColor resolvedColorWithTraitCollection:traits];
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithDefaultBackground];
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: labelColor};
    appearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: labelColor};
    controller.navigationItem.standardAppearance = appearance;
    controller.navigationItem.scrollEdgeAppearance = appearance;
    controller.navigationItem.compactAppearance = appearance;
}

@implementation RUINThemePackageViewController

- (instancetype)initWithRecord:(NSDictionary *)record listController:(RUINThemeSettingsViewController *)listController
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _record = [record copy];
        _listController = listController;
        self.title = RUINThemeUIName(record);
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    RUINThemeUIApplySystemNavigationBarAppearance(self);
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    RUINThemeUIApplySystemNavigationBarAppearance(self);
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    __weak typeof(self) weakSelf = self;
    RUINThemePreviewLoad(self.record, ^(UIImage *image) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        owner.previewImage = image;
        owner.previewLoaded = YES;
        [owner.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationFade];
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : section == 1 ? 4 : 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 1 ? RUINLocalizedString(@"themes.package_info") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 2 ? RUINLocalizedString(@"themes.add_to_native_hint") : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path
{
    if (path.section == 0) {
        if (self.previewImage) {
            CGFloat width = CGRectGetWidth(tableView.bounds) - 40;
            CGFloat ratio = self.previewImage.size.height / MAX(self.previewImage.size.width, 1);
            return MIN(MAX(width * ratio, 180), 460);
        }
        return 120;
    }
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path
{
    if (path.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PackagePreview"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"PackagePreview"];
        cell.selectionStyle = self.previewImage ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.textLabel.text = nil;
        cell.accessoryView = nil;
        UIImageView *imageView = [cell.contentView viewWithTag:777];
        if (!imageView) {
            imageView = [UIImageView new];
            imageView.tag = 777;
            imageView.contentMode = UIViewContentModeScaleAspectFit;
            imageView.clipsToBounds = YES;
            imageView.layer.cornerRadius = 12;
            imageView.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:imageView];
            [NSLayoutConstraint activateConstraints:@[
                [imageView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
                [imageView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
                [imageView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
                [imageView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
            ]];
        }
        imageView.image = self.previewImage;
        if (!self.previewLoaded) {
            cell.textLabel.text = RUINLocalizedString(@"themes.generating_preview");
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        } else if (!self.previewImage) {
            cell.textLabel.text = RUINLocalizedString(@"themes.preview_unavailable_package");
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
        }
        return cell;
    }
    if (path.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PackageInfo"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"PackageInfo"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSURL *url = RUINThemeUIArchiveURL(self.record);
        switch (path.row) {
            case 0: cell.textLabel.text = RUINLocalizedString(@"themes.product_id"); cell.detailTextLabel.text = RUINThemeUIString(self.record[@"productID"]); break;
            case 1: cell.textLabel.text = RUINLocalizedString(@"themes.version_label"); cell.detailTextLabel.text = RUINThemeUIVersion(self.record); break;
            case 2: cell.textLabel.text = RUINLocalizedString(@"themes.package_size"); cell.detailTextLabel.text = RUINThemePackageSizeText(self.record); break;
            default: cell.textLabel.text = RUINLocalizedString(@"themes.file_name"); cell.detailTextLabel.text = url.lastPathComponent ?: @""; break;
        }
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.7;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PackageAction"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"PackageAction"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = UIColor.labelColor;
    switch (path.row) {
        case 0: cell.textLabel.text = RUINLocalizedString(@"themes.add_to_native"); break;
        case 1: cell.textLabel.text = RUINLocalizedString(@"media.share_action"); break;
        default:
            cell.textLabel.text = RUINLocalizedString(@"themes.delete_package");
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.accessoryType = UITableViewCellAccessoryNone;
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path
{
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        if (self.previewImage) {
            RUINThemePreviewViewerController *viewer = [[RUINThemePreviewViewerController alloc] initWithImage:self.previewImage];
            viewer.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:viewer animated:YES completion:nil];
        }
        return;
    }
    if (path.section != 2) return;
    if (path.row == 0) RUINOpenDownloadedThemes(self);
    else if (path.row == 1) [self shareArchive];
    else [self confirmDelete];
}

- (void)shareArchive
{
    NSURL *requestedURL = RUINThemeUIArchiveURL(self.record);
    if (!requestedURL) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSArray<NSDictionary *> *catalog = RUINThemeCatalog(&error);
            NSURL *verifiedURL = nil;
            for (NSDictionary *candidate in catalog) {
                NSURL *url = RUINThemeUIArchiveURL(candidate);
                if (url && [url.path isEqualToString:requestedURL.path]) { verifiedURL = url; break; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) owner = weakSelf;
                if (!owner || !owner.viewIfLoaded.window) return;
                if (!verifiedURL) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"media.share_failed")
                        message:RUINLocalizedString(@"themes.archive_validation_failed") preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
                    [owner presentViewController:alert animated:YES completion:nil];
                    return;
                }
                UIDocumentInteractionController *document = [UIDocumentInteractionController interactionControllerWithURL:verifiedURL];
                document.delegate = owner;
                document.UTI = @"jp.naver.talk.theme-package";
                owner.documentController = document;
                CGRect rect = [owner.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:2]];
                if (![document presentOptionsMenuFromRect:rect inView:owner.tableView animated:YES]) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"media.share_failed")
                        message:RUINLocalizedString(@"media.no_share_targets") preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
                    [owner presentViewController:alert animated:YES completion:nil];
                }
            });
        }
    });
}

- (void)confirmDelete
{
    NSURL *url = RUINThemeUIArchiveURL(self.record);
    if (!url) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"themes.delete_package")
        message:RUINLocalizedString(@"themes.delete_package_message") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"themes.delete_package") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        NSString *key = RUINThemePreviewCacheKey(owner.record, url);
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        [NSFileManager.defaultManager removeItemAtURL:[RUINThemePreviewCacheDirectory() URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"png"]] error:nil];
        [RUINThemePreviewMemoryCache() removeObjectForKey:key];
        [RUINThemePreviewMemoryCache() removeObjectForKey:[key stringByAppendingString:@"#thumb"]];
        RUINThemeSettingsViewController *list = owner.listController;
        [owner.navigationController popViewControllerAnimated:YES];
        [list reloadCatalog];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller
{
    return self.navigationController ?: self;
}

@end

void RUINOpenThemeSettings(UIViewController *owner)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINOpenThemeSettings(owner); });
        return;
    }
    UINavigationController *navigation = [owner isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)owner : owner.navigationController;
    BOOL visibleOwner = owner == navigation;
    for (UIViewController *candidate = owner; candidate; candidate = candidate.parentViewController) {
        if (candidate == navigation.topViewController) { visibleOwner = YES; break; }
    }
    if (!navigation || !visibleOwner || navigation.presentedViewController ||
        [navigation.topViewController isKindOfClass:[RUINThemeSettingsViewController class]]) return;
    [navigation pushViewController:[RUINThemeSettingsViewController new] animated:YES];
}
