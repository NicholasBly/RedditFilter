#import <objc/runtime.h>
#import <string.h>
#import "FeedFilterSettingsViewController.h"

// Adds a "RedditFilter" button to the top bar of Reddit's Settings screen.
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
  %orig;

  // This runs for every screen in the app, so use cheap C string checks
  // instead of building an NSString each time.
  const char *name = class_getName([self class]);
  if (!strstr(name, "AppSettingsView") || !strstr(name, "HostingController") || !strstr(name, "RedditSliceKit"))
    return;

  for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems)
    if (item.tag == 1337) return; // already added

  UIBarButtonItem *filterButton = [[UIBarButtonItem alloc] initWithTitle:@"RedditFilter"
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(openRedditFilterFromNav)];
  filterButton.tag = 1337;
  [filterButton setTitlePositionAdjustment:UIOffsetMake(0, 3.5) forBarMetrics:UIBarMetricsDefault];

  NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
  [items insertObject:filterButton atIndex:0];
  self.navigationItem.rightBarButtonItems = items;
}

%new
- (void)openRedditFilterFromNav {
  FeedFilterSettingsViewController *settings =
      [(FeedFilterSettingsViewController *)[objc_getClass("FeedFilterSettingsViewController") alloc]
          initWithStyle:UITableViewStyleGrouped];
  [self.navigationController pushViewController:settings animated:YES];
}

%end
