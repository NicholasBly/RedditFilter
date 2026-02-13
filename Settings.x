#import <AppSettingsViewController.h>
#import <UserDrawerViewController.h>
#import "FeedFilterSettingsViewController.h"

NSBundle *redditFilterBundle;

extern UIImage *iconWithName(NSString *iconName);
extern NSString *localizedString(NSString *key, NSString *table);

@interface UserDrawerViewController ()
- (void)navigateToRedditFilterSettings;
@end

// We keep this just in case the side menu still works, as it provides a backup entry point.
%hook UserDrawerViewController

- (void)defineAvailableUserActions {
  %orig;
  [self.availableUserActions addObject:@1337];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if ([tableView isEqual:self.actionsTableView] &&
      self.availableUserActions[indexPath.row].unsignedIntegerValue == 1337) {
    UITableViewCell *cell =
        [self.actionsTableView dequeueReusableCellWithIdentifier:@"UserDrawerActionTableViewCell"];
    
    cell.textLabel.text = @"RedditFilter";
    
    UIImage *icon = iconWithName(@"rpl3/filter") ?: iconWithName(@"icon_filter") ?: iconWithName(@"icon-filter-outline");
    if (icon) {
        cell.imageView.image = [[icon imageScaledToSize:CGSizeMake(20, 20)] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return cell;
  }
  return %orig;
}

%new
- (void)navigateToRedditFilterSettings {
  [self dismissViewControllerAnimated:YES completion:nil];
  FeedFilterSettingsViewController *filterSettingsViewController =
      [(FeedFilterSettingsViewController *)[objc_getClass("FeedFilterSettingsViewController") alloc]
          initWithStyle:UITableViewStyleGrouped];
  [[self currentNavigationController] pushViewController:filterSettingsViewController animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if ([tableView isEqual:self.actionsTableView] &&
      self.availableUserActions[indexPath.row].unsignedIntegerValue == 1337) {
    return [self navigateToRedditFilterSettings];
  }
  %orig;
}
%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    NSString *name = NSStringFromClass([self class]);

    if ([name containsString:@"RedditSliceKit"] && 
        [name containsString:@"AppSettingsView"] && 
        [name containsString:@"HostingController"]) {

        if (self.navigationItem.rightBarButtonItems) {
            for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems) {
                if (item.tag == 1337) return;
            }
        }

        UIBarButtonItem *filterButton = [[UIBarButtonItem alloc] initWithTitle:@"RedditFilter"
                                                                         style:UIBarButtonItemStylePlain
                                                                        target:self
                                                                        action:@selector(openRedditFilterFromNav)];
        filterButton.tag = 1337; // Tag to identify our button

        [filterButton setTitlePositionAdjustment:UIOffsetMake(0, 3.5) forBarMetrics:UIBarMetricsDefault];

        // 5. Add it to the Navigation Bar
        NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy];
        if (!items) items = [NSMutableArray array];
        [items insertObject:filterButton atIndex:0]; // Add to the start of the list (right side)
        
        self.navigationItem.rightBarButtonItems = items;
    }
}

%new
- (void)openRedditFilterFromNav {
    // Launch the Tweak Settings
    FeedFilterSettingsViewController *vc = [(FeedFilterSettingsViewController *)[objc_getClass("FeedFilterSettingsViewController") alloc] initWithStyle:UITableViewStyleGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}

%end

%ctor {
  redditFilterBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"RedditFilter"
                                                                              ofType:@"bundle"]];
  if (!redditFilterBundle)
    redditFilterBundle = [NSBundle bundleWithPath:@THEOS_PACKAGE_INSTALL_PREFIX
                                   @"/Library/Application Support/RedditFilter.bundle"];
}
