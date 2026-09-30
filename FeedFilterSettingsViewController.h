#import "Preferences.h"
#import <BaseLabel.h>
#import <BaseTableReusableView.h>
#import <BaseTableViewController.h>
#import <LayoutGuidance.h>
#import <ToggleImageTableViewCell.h>

@interface UIView ()
- (void)associatePropertySetter:(SEL)propertySetter
        withThemePropertyGetter:(SEL)themePropertyGetter;
@end

@interface UIImage ()
- (UIImage *)imageScaledToSize:(CGSize)size;
@end

@interface FeedFilterSettingsViewController : BaseTableViewController
@end