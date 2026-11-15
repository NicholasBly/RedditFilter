// DeadTapFix.x
//
// Works around a bug in Reddit 2026.45.1's feeds: taps on a post do nothing
// until you scroll a little.
//
// Cause (confirmed with the Tap Inspector on a real device): the feed's
// pull-to-refresh control (RefreshControlSliceView, rewritten in 45.1) gets
// left un-hidden at the top of the visible feed, right under the header. It's
// invisible, but it's about 80pt tall and sits on top of the posts, so taps in
// that band land on its Lottie animation view instead of the post and nothing
// happens. Scrolling moves it out of the way again, which is why a 1px scroll
// "fixes" it.
//
// Fix: the refresh control never needs taps (pulling down is handled by the
// scroll view's own pan gesture), so it now lets every touch fall through to
// whatever is underneath. Nothing about how it looks or refreshes changes.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TapInspector.h"

// Swift class from Reddit's RedditSliceKit_RPLSlices module; a UIRefreshControl subclass.
static const char *const kRefreshControlClass = "_TtC24RedditSliceKit_RPLSlices23RefreshControlSliceView";

@interface RefreshControlSliceView : UIRefreshControl
@end

%group DeadTapFix

%hook RefreshControlSliceView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
#if REDDITFILTER_DEBUG
  // Only ask UIKit what it would have hit when the debug build wants to count it.
  UIView *wouldHaveHit = %orig;
  if (wouldHaveHit && event.type == UIEventTypeTouches) RFTapInspectorNoteRefreshControlPassThrough();
#endif
  return nil; // returning nil lets UIKit keep looking, so the post underneath gets the tap
}
%end

%end

static BOOL RFInstallDeadTapFix(void) {
  static BOOL installed;
  if (installed) return YES;
  Class cls = objc_getClass(kRefreshControlClass);
  if (!cls) return NO; // renamed in a future Reddit version: do nothing
  %init(DeadTapFix, RefreshControlSliceView = cls);
  installed = YES;
  return YES;
}

%ctor {
  if (RFInstallDeadTapFix()) return;
  // Reddit's Swift classes may not be loaded yet this early; try again once the app has launched.
  __block id observer = [NSNotificationCenter.defaultCenter
      addObserverForName:UIApplicationDidFinishLaunchingNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *note) {
                RFInstallDeadTapFix();
                [NSNotificationCenter.defaultCenter removeObserver:observer];
              }];
}
