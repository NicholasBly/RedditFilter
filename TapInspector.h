// TapInspector.h
//
// Debug builds only: records "dead taps" on Reddit's feeds, meaning short taps
// that didn't open anything and didn't reach a post's tap handler. Each one
// is saved with a snapshot of what was under the finger (the view chain, the
// cells, every scroll view's state and the gesture recognizers that saw the
// touch), so the report shows exactly why the tap went nowhere.
//
// Shown in the RedditFilter menu under "TAP INSPECTOR · DEBUG".

#import <Foundation/Foundation.h>
#import "DebugMenu.h"

#if REDDITFILTER_DEBUG

// One line for the menu, e.g. "3 dead taps out of 41 taps on the feed".
NSString *RFTapInspectorSummary(void);

// Full text report (newest first) for copying into a bug report.
NSString *RFTapInspectorReport(void);

// Forget everything recorded so far.
void RFTapInspectorReset(void);

#endif
