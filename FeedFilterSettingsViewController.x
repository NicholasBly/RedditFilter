#import <objc/runtime.h>
#import "FeedFilterSettingsViewController.h"
#import "DebugMenu.h"
#import "RFLogo.h"

#ifndef RF_VERSION
#define RF_VERSION "dev" // the Makefile passes the real version
#endif

#pragma mark - The filter rows

typedef struct {
  __unsafe_unretained NSString *key;
  __unsafe_unretained NSString *title;
  __unsafe_unretained NSString *subtitle; // nil for none
  __unsafe_unretained NSString *icons;    // comma-separated, first icon found wins
  BOOL switchOnMeansShow;                 // YES: switch ON shows the content (the saved setting is the opposite)
} RFToggleRow;

static const RFToggleRow kToggleRows[] = {
    {kRedditFilterPromoted, @"Promoted", nil, @"rpl3/tag,icon_tag", YES},
    {kRedditFilterRecommended, @"Recommended", nil, @"rpl3/spam,icon_spam", YES},
    {kRedditFilterNSFW, @"NSFW", nil, @"rpl3/nsfw,icon_nsfw_outline,icon_nsfw", YES},
    {kRedditFilterAwards, @"Awards", @"Show awards on posts and comments",
     @"rpl3/award,icon_gift_fill,icon_award,icon-award-outline", YES},
    {kRedditFilterScores, @"Scores", @"Show vote count on posts and comments", @"rpl3/upvote,icon_upvote", YES},
    {kRedditFilterAutoCollapseAutoMod, @"AutoMod", @"Auto collapse AutoMod comments", @"rpl3/mod,icon_mod", NO},
};
static const NSInteger kToggleRowCount = sizeof(kToggleRows) / sizeof(kToggleRows[0]);

#pragma mark - Cell helpers (fall back to plain UIKit if Reddit renames its classes)

static UILabel *RFMainLabel(ImageLabelTableViewCell *cell) {
  if ([cell respondsToSelector:@selector(mainLabel)]) return cell.mainLabel;
  if ([cell respondsToSelector:@selector(imageLabelView)]) return cell.imageLabelView.mainLabel;
  return cell.textLabel;
}

static UILabel *RFDetailLabel(ImageLabelTableViewCell *cell) {
  if ([cell respondsToSelector:@selector(detailLabel)]) return cell.detailLabel;
  if ([cell respondsToSelector:@selector(imageLabelView)]) return cell.imageLabelView.detailLabel;
  return cell.detailTextLabel;
}

static UISwitch *RFSwitch(ToggleImageTableViewCell *cell) {
  if ([cell respondsToSelector:@selector(accessorySwitch)]) return cell.accessorySwitch;
  if ([cell.accessoryView isKindOfClass:UISwitch.class]) return (UISwitch *)cell.accessoryView;
  UISwitch *toggle = [UISwitch new];
  cell.accessoryView = toggle;
  return toggle;
}

static void RFSetIcon(ImageLabelTableViewCell *cell, NSString *iconNames) {
  UIImage *icon = nil;
  for (NSString *name in [iconNames componentsSeparatedByString:@","])
    if ((icon = iconWithName(name))) break;
  if (!icon) return;
  if ([icon respondsToSelector:@selector(imageScaledToSize:)]) icon = [icon imageScaledToSize:CGSizeMake(20, 20)];
  icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  if ([cell respondsToSelector:@selector(setDisplayImage:)]) cell.displayImage = icon;
  else if ([cell respondsToSelector:@selector(imageLabelView)]) cell.imageLabelView.imageView.image = icon;
  else cell.imageView.image = icon;
}

static void RFApplyTheme(UIView *view, SEL setter, SEL themeGetter) {
  if ([view respondsToSelector:@selector(associatePropertySetter:withThemePropertyGetter:)])
    [view associatePropertySetter:setter withThemePropertyGetter:themeGetter];
}

// Section header/footer: a themed label inset like Reddit's own settings.
static UIView *RFSectionView(UITableView *tableView, NSString *text, CGFloat height) {
  if (!text) return nil;

  // Reddit's spacing class is a Swift class, so it needs CoreClass to be found.
  Class guidanceClass = CoreClass(@"LayoutGuidance");
  LayoutGuidance *guidance =
      [guidanceClass respondsToSelector:@selector(currentGuidance)] ? [guidanceClass currentGuidance] : nil;
  CGFloat padding = guidance.gridPadding > 0 ? guidance.gridPadding : 16.0;
  CGFloat width = tableView.bounds.size.width;

  Class labelClass = %c(BaseLabel);
  UILabel *label = [labelClass respondsToSelector:@selector(labelWithSubheaderFont)]
                       ? [labelClass labelWithSubheaderFont]
                       : [UILabel new];
  label.frame = CGRectMake(padding, 0, MAX(width - padding * 2, 0), height);
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  label.numberOfLines = 0;
  label.text = text;
  RFApplyTheme(label, @selector(setTextColor:), @selector(metaTextColor));

  Class containerClass = %c(BaseTableReusableView);
  UIView *container = [[(containerClass ?: UIView.class) alloc] initWithFrame:CGRectMake(0, 0, width, height)];
  UIView *content = [container respondsToSelector:@selector(contentView)]
                        ? ((BaseTableReusableView *)container).contentView
                        : container;
  [content addSubview:label];
  RFApplyTheme(container, @selector(setBackgroundColor:), @selector(canvasColor));
  return container;
}

#pragma mark - Sections

typedef NS_ENUM(NSInteger, RFSection) { RFSectionFilters, RFSectionDebug, RFSectionAbout };

// Filters, [Schema Paths (debug builds only)], About
static const NSInteger kSectionCount = REDDITFILTER_DEBUG ? 3 : 2;

static RFSection RFSectionAt(NSInteger section) {
  if (section == 0) return RFSectionFilters;
  if (REDDITFILTER_DEBUG && section == 1) return RFSectionDebug;
  return RFSectionAbout;
}

#pragma mark - About section

typedef struct {
  __unsafe_unretained NSString *title;
  __unsafe_unretained NSString *subtitle; // nil = show the version
  __unsafe_unretained NSString *link;     // opened when the row is tapped
  __unsafe_unretained NSString *symbol;   // SF Symbol name, or nil to show the logo
} RFAboutRow;

static const RFAboutRow kAboutRows[] = {
    {@"RedditFilter", nil, @"https://github.com/NicholasBly/RedditFilter/releases",
     @"line.3.horizontal.decrease.circle"},
    {@"Nicholas Bly", @"Developer", @"https://github.com/NicholasBly/RedditFilter", nil},
    {@"level3tjg", @"Original creator",
     @"https://github.com/level3tjg/RedditFilter", @"person.crop.circle"},
};
static const NSInteger kAboutRowCount = sizeof(kAboutRows) / sizeof(kAboutRows[0]);
static const CGFloat kAboutIconSize = 36.0;

// Draws an image centered in a fixed-size square so every row's text lines up.
static UIImage *RFBoxedImage(UIImage *image, CGFloat inset) {
  if (!image) return nil;
  CGSize box = CGSizeMake(kAboutIconSize, kAboutIconSize);
  CGFloat side = kAboutIconSize - inset * 2;
  CGFloat scale = MIN(side / image.size.width, side / image.size.height);
  CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:box];
  UIImage *boxed = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [image drawInRect:CGRectMake((box.width - size.width) / 2, (box.height - size.height) / 2, size.width,
                                 size.height)];
  }];
  return [boxed imageWithRenderingMode:image.renderingMode];
}

static UIImage *RFLogo(void) {
  static UIImage *logo;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSData *data = [NSData dataWithBytesNoCopy:(void *)kRFLogoPNG length:sizeof(kRFLogoPNG) freeWhenDone:NO];
    logo = RFBoxedImage([UIImage imageWithData:data], 0);
  });
  return logo;
}

static NSString *RFVersionText(void) {
  return [@"Version " @RF_VERSION stringByAppendingString:REDDITFILTER_DEBUG ? @" (debug build)" : @""];
}

static UITableViewCell *RFAboutCell(UITableView *tableView, NSInteger index) {
  static NSString *const kAboutCellID = @"RFAboutCell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kAboutCellID];
  if (!cell) {
    // A plain UIKit cell, colored with Reddit's theme when it's available.
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kAboutCellID];
    cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.tintColor = UIColor.secondaryLabelColor;
    RFApplyTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
    RFApplyTheme(cell.detailTextLabel, @selector(setTextColor:), @selector(metaTextColor));
    RFApplyTheme(cell.imageView, @selector(setTintColor:), @selector(metaTextColor));
    RFApplyTheme(cell, @selector(setBackgroundColor:), @selector(bodyColor));
  }
  if (index < 0 || index >= kAboutRowCount) return cell;
  const RFAboutRow *row = &kAboutRows[index];
  cell.textLabel.text = row->title;
  cell.detailTextLabel.text = row->subtitle ?: RFVersionText();
  cell.imageView.image = row->symbol ? RFBoxedImage([UIImage systemImageNamed:row->symbol], 7.0) : RFLogo();
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}

#if REDDITFILTER_DEBUG
// Declarations for the debug-only helpers so the call sites below are typed.
// (The implementations are added to the class at runtime by Logos below.)
@interface FeedFilterSettingsViewController (RFSchemaDebug)
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView;
- (void)rfCopyDiscoveredPath:(UIButton *)sender;
- (void)rfCopyFailedJSON:(UIButton *)sender;
- (void)rfResetCounters:(UIButton *)sender;
@end
#endif

%subclass FeedFilterSettingsViewController : BaseTableViewController

- (void)viewDidLoad {
  %orig;
  self.title = @"RedditFilter";
  Class toggleCellClass = CoreClass(@"ToggleImageTableViewCell") ?: UITableViewCell.class;
  [self.tableView registerClass:toggleCellClass forCellReuseIdentifier:kToggleCellID];
#if REDDITFILTER_DEBUG
  // Debug rows carry multi-line detail text, so let them self-size.
  self.tableView.estimatedRowHeight = 60.0;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
#endif
}

- (void)viewWillAppear:(BOOL)animated {
  %orig;
#if REDDITFILTER_DEBUG
  // Stats accrue while the app runs; refresh them each time the screen opens.
  [self.tableView reloadData];
#endif
}

%new
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return kSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  switch (RFSectionAt(section)) {
    case RFSectionFilters:
      return kToggleRowCount;
    case RFSectionDebug:
#if REDDITFILTER_DEBUG
      // One row per tracked schema path, plus a trailing "reset" row.
      return [[RFSchemaDebug shared] snapshot].count + 1;
#endif
      return 0;
    case RFSectionAbout:
      return kAboutRowCount;
  }
  return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  RFSection section = RFSectionAt(indexPath.section);
  if (section == RFSectionAbout) return RFAboutCell(tableView, indexPath.row);
#if REDDITFILTER_DEBUG
  if (section == RFSectionDebug) return [self debugCellForRow:indexPath.row inTableView:tableView];
#endif
  ToggleImageTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kToggleCellID
                                                                   forIndexPath:indexPath];
  if (indexPath.row >= kToggleRowCount) return cell;
  const RFToggleRow *row = &kToggleRows[indexPath.row];

  RFMainLabel(cell).text = row->title;
  RFDetailLabel(cell).text = row->subtitle;
  RFSetIcon(cell, row->icons);

  UISwitch *toggle = RFSwitch(cell);
  BOOL saved = [NSUserDefaults.standardUserDefaults boolForKey:row->key];
  toggle.on = row->switchOnMeansShow ? !saved : saved;
  toggle.tag = indexPath.row;
  // Only remove our own action (cells get reused), never Reddit's.
  [toggle removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
  [toggle addTarget:self action:@selector(rfToggleChanged:) forControlEvents:UIControlEventValueChanged];

  // Tag the cell so the layout fix in Tweak.xm applies to our rows only.
  objc_setAssociatedObject(cell, @selector(rfOwnedCell), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [cell setNeedsUpdateConstraints];
  return cell;
}

%new
- (void)rfToggleChanged:(UISwitch *)sender {
  if (sender.tag < 0 || sender.tag >= kToggleRowCount) return;
  const RFToggleRow *row = &kToggleRows[sender.tag];
  BOOL filterOn = row->switchOnMeansShow ? !sender.on : sender.on;
  [NSUserDefaults.standardUserDefaults setBool:filterOn forKey:row->key];
  RFReloadPreferences();
}

%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (RFSectionAt(indexPath.section) != RFSectionAbout || indexPath.row >= kAboutRowCount) return;
  NSURL *url = [NSURL URLWithString:kAboutRows[indexPath.row].link];
  if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  NSString *text = nil;
  switch (RFSectionAt(section)) {
    case RFSectionFilters: text = @"FILTERS"; break;
    case RFSectionDebug: text = @"SCHEMA PATHS · DEBUG"; break;
    case RFSectionAbout: text = @"ABOUT"; break;
  }
  return RFSectionView(tableView, text, 40.0);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return 40.0;
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  NSString *text = nil;
  switch (RFSectionAt(section)) {
    case RFSectionFilters:
      text = @"Filter specific types of posts from your feed";
      break;
    case RFSectionDebug:
      text = @"✓ resolved · ✗ broke (structural fallback is now filtering). "
             @"Tap Copy on a ✗ row to grab the auto-discovered replacement path.";
      break;
    case RFSectionAbout:
      break; // no footer, just some space at the bottom
  }
  return RFSectionView(tableView, text, [self tableView:tableView heightForFooterInSection:section]);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return RFSectionAt(section) == RFSectionDebug ? 76.0 : 40.0;
}

// ---------------------------------------------------------------------------
// Schema-path debug section.
//
// All of the method *declarations* below are compiled unconditionally so that
// Logos always registers them on the subclass; only their bodies are gated on
// REDDITFILTER_DEBUG. In a release build the bodies collapse to no-ops, the
// section is never shown (numberOfSections returns 1), and these methods are
// never invoked.
// ---------------------------------------------------------------------------
%new
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView {
#if REDDITFILTER_DEBUG
  static NSString *const kRFDebugCellID = @"RFSchemaDebugCell";
  
  // Deliberately a plain UIKit cell, not a Reddit class: the whole point of
  // this screen is to keep working when Reddit's own classes/schema change.
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRFDebugCellID];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:kRFDebugCellID];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                            weight:UIFontWeightRegular];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
  }
  cell.accessoryView = nil;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;

  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  
  // Trailing "reset" row.
  if (row >= (NSInteger)snapshot.count) {
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.text = @"Reset counters";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = @"Clear all stats and re-arm path discovery";
    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetButton setTitle:@"Reset" forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [resetButton addTarget:self
                    action:@selector(rfResetCounters:)
          forControlEvents:UIControlEventTouchUpInside];
    [resetButton sizeToFit];
    cell.accessoryView = resetButton;
    return cell;
  }

  NSDictionary *record = snapshot[row];
  NSString *op = record[kRFDebugOp];
  NSString *expected = record[kRFDebugExpected];
  NSString *discovered = record[kRFDebugDiscovered];
  NSInteger hits = [record[kRFDebugHits] integerValue];
  NSInteger misses = [record[kRFDebugMisses] integerValue];
  BOOL seen = [record[kRFDebugSeen] boolValue];
  BOOL lastResolved = [record[kRFDebugLastResolved] boolValue];

  cell.textLabel.textColor = [UIColor labelColor];
  cell.textLabel.text = op;

  NSString *detail;
  UIColor *detailColor;
  if (!seen) {
    detail = [NSString stringWithFormat:@"untested\nexpected: %@", expected];
    detailColor = [UIColor secondaryLabelColor];
  } else if (lastResolved) {
    detail = [NSString stringWithFormat:@"\u2713 OK \u00b7 %ld hit%@",
                                        (long)hits, hits == 1 ? @"" : @"s"];
    if (misses > 0)
      detail = [detail stringByAppendingFormat:@"  (recovered after %ld miss%@)",
                                               (long)misses, misses == 1 ? @"" : @"es"];
    detailColor = [UIColor systemGreenColor];
  } else {
    detail = [NSString stringWithFormat:@"\u2717 MISS \u00b7 %ld miss%@ \u00b7 fallback active",
                                        (long)misses, misses == 1 ? @"" : @"es"];
    if (discovered.length) {
      detail = [detail stringByAppendingFormat:@"\n\u2192 %@", discovered];
      UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
      [copyButton setTitle:@"Copy" forState:UIControlStateNormal];
      copyButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
      copyButton.tag = row;
      [copyButton addTarget:self
                     action:@selector(rfCopyDiscoveredPath:)
           forControlEvents:UIControlEventTouchUpInside];
      [copyButton sizeToFit];
      cell.accessoryView = copyButton;
    } else {
      detail = [detail stringByAppendingFormat:@"\ncould not auto-locate a new path\nexpected: %@",
                                               expected];
                                               
      // Show the "Copy JSON" button if we captured a payload
      NSString *failedJSON = record[kRFDebugFailedJSON];
      if (failedJSON.length > 0) {
          detail = [detail stringByAppendingString:@"\n\u2192 raw payload captured"];
          UIButton *copyJsonButton = [UIButton buttonWithType:UIButtonTypeSystem];
          [copyJsonButton setTitle:@"Copy JSON" forState:UIControlStateNormal];
          copyJsonButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
          copyJsonButton.tag = row;
          [copyJsonButton addTarget:self
                             action:@selector(rfCopyFailedJSON:)
                   forControlEvents:UIControlEventTouchUpInside];
          [copyJsonButton sizeToFit];
          cell.accessoryView = copyJsonButton;
      }
    }
    detailColor = [UIColor systemRedColor];
  }
  cell.detailTextLabel.text = detail;
  cell.detailTextLabel.textColor = detailColor;
  return cell;
#else
  return nil;
#endif
}
%new
- (void)rfCopyDiscoveredPath:(UIButton *)sender {
#if REDDITFILTER_DEBUG
  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  if (sender.tag < 0 || sender.tag >= (NSInteger)snapshot.count) return;
  NSString *discovered = snapshot[sender.tag][kRFDebugDiscovered];
  if (!discovered.length) return;
  UIPasteboard.generalPasteboard.string = discovered;
  [sender setTitle:@"Copied" forState:UIControlStateNormal];
  [sender sizeToFit];
  __weak UIButton *weakSender = sender;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSender setTitle:@"Copy" forState:UIControlStateNormal];
                   [weakSender sizeToFit];
                 });
#endif
}
%new
- (void)rfCopyFailedJSON:(UIButton *)sender {
#if REDDITFILTER_DEBUG
  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  if (sender.tag < 0 || sender.tag >= (NSInteger)snapshot.count) return;
  
  NSString *failedJSON = snapshot[sender.tag][kRFDebugFailedJSON];
  if (!failedJSON.length) return;
  
  UIPasteboard.generalPasteboard.string = failedJSON;
  [sender setTitle:@"Copied" forState:UIControlStateNormal];
  [sender sizeToFit];
  
  __weak UIButton *weakSender = sender;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSender setTitle:@"Copy JSON" forState:UIControlStateNormal];
                   [weakSender sizeToFit];
                 });
#endif
}
%new
- (void)rfResetCounters:(UIButton *)sender {
#if REDDITFILTER_DEBUG
  [[RFSchemaDebug shared] reset];
  [self.tableView reloadData];
#endif
}
%end
