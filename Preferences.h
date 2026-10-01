#import <UIKit/UIKit.h>

#define kRedditFilterPromoted @"kRedditFilterPromoted"
#define kRedditFilterRecommended @"kRedditFilterRecommended"
#define kRedditFilterNSFW @"kRedditFilterNSFW"
#define kRedditFilterAwards @"kRedditFilterAwards"
#define kRedditFilterScores @"kRedditFilterScores"
#define kRedditFilterAutoCollapseAutoMod @"kRedditFilterAutoCollapseAutoMod"

#define kToggleCellID @"kToggleCellID"

// Defined in Tweak.xm, used by the settings screen.
#ifdef __cplusplus
extern "C" {
#endif
void RFReloadPreferences(void); // call after changing a setting
UIImage *iconWithName(NSString *iconName);
Class CoreClass(NSString *name);
#ifdef __cplusplus
}
#endif
