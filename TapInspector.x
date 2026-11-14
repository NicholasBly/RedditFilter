// TapInspector.x
//
// Debug builds only (the whole file compiles to nothing otherwise). See
// TapInspector.h for what it records and why.
//
// How a tap is judged:
//   * it starts on one of Reddit's feed lists (SliceKit's ListCollectionView),
//   * the finger moves less than kTapSlop points and lifts within kTapMaxTime,
//   * then, within kResultWindow seconds, either a screen opens (push or
//     present) or a post's tap handler runs. If neither happens it's dead.

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Preferences.h"
#import "TapInspector.h"

#if REDDITFILTER_DEBUG

static const CGFloat kTapSlop = 12.0;
static const NSTimeInterval kTapMaxTime = 0.7;
static const NSTimeInterval kResultWindow = 1.2;
static const NSUInteger kKeepDead = 12;
static const NSUInteger kKeepGood = 4;

static NSMutableArray<NSString *> *gDeadReports, *gGoodReports;
static NSUInteger gTapCount, gDeadCount;
static CFTimeInterval gLastNavigation, gLastTapHandler;
static NSString *gLastTapHandlerName;

// The touch being followed (at most one; multi-finger touches are ignored).
static uintptr_t gTouchID;
static CFTimeInterval gTouchStart;
static CGPoint gTouchStartPoint;
static CGFloat gTouchMaxMove;
static BOOL gTouchOnFeed;
static NSString *gTouchSnapshot;

#pragma mark - Small formatting helpers

static NSString *RFName(id object) {
  if (!object) return @"nil";
  NSString *name = NSStringFromClass([object class]);
  NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
  return dot.location == NSNotFound ? name : [name substringFromIndex:dot.location + 1];
}

static NSString *RFRect(CGRect r) {
  return [NSString stringWithFormat:@"(%.1f,%.1f %.1fx%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *RFStateName(UIGestureRecognizerState state) {
  switch (state) {
    case UIGestureRecognizerStatePossible: return @"possible";
    case UIGestureRecognizerStateBegan: return @"began";
    case UIGestureRecognizerStateChanged: return @"changed";
    case UIGestureRecognizerStateEnded: return @"ENDED";
    case UIGestureRecognizerStateCancelled: return @"cancelled";
    case UIGestureRecognizerStateFailed: return @"failed";
  }
  return @"?";
}

static BOOL RFIsFeedList(UIView *view) {
  return [NSStringFromClass(view.class) containsString:@"ListCollectionView"];
}

// Swift stored properties of SliceKit's ListCollectionView, read through the
// ObjC ivar list (names confirmed in Reddit 2026.45.1). Returns NO if missing.
static BOOL RFReadOptionalDouble(id object, const char *name, BOOL *isSet, double *value) {
  Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
  if (!ivar) return NO;
  const uint8_t *base = (__bridge const void *)object;
  ptrdiff_t offset = ivar_getOffset(ivar);
  memcpy(value, base + offset, sizeof(double));
  *isSet = base[offset + sizeof(double)] == 0; // Swift Optional<CGFloat>: tag byte 1 means nil
  return YES;
}

static BOOL RFReadInt(id object, const char *name, NSInteger *value) {
  Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
  if (!ivar) return NO;
  memcpy(value, (const uint8_t *)(__bridge const void *)object + ivar_getOffset(ivar), sizeof(NSInteger));
  return YES;
}

static BOOL RFBool(id object, SEL selector) {
  return [object respondsToSelector:selector] ? ((BOOL(*)(id, SEL))objc_msgSend)(object, selector) : NO;
}

#pragma mark - Snapshot

static NSString *RFScrollViewLine(UIScrollView *sv) {
  CGPoint off = sv.contentOffset;
  CALayer *presentation = sv.layer.presentationLayer;
  CGPoint shown = presentation ? presentation.bounds.origin : off;
  UIEdgeInsets inset = sv.adjustedContentInset;
  NSMutableString *line = [NSMutableString stringWithFormat:
      @"%@ offset=(%.1f,%.1f) onScreen=(%.1f,%.1f) content=(%.0fx%.0f) inset(t%.0f b%.0f) "
      @"dragging=%d decelerating=%d tracking=%d scrollAnimating=%d scrollEnabled=%d paging=%d",
      RFName(sv), off.x, off.y, shown.x, shown.y, sv.contentSize.width, sv.contentSize.height, inset.top,
      inset.bottom, sv.isDragging, sv.isDecelerating, sv.isTracking, RFBool(sv, @selector(isScrollAnimating)),
      sv.isScrollEnabled, sv.isPagingEnabled];
  BOOL isSet = NO;
  double preserved = 0;
  NSInteger count = 0;
  if (RFReadOptionalDouble(sv, "preservedContentOffsetY", &isSet, &preserved))
    [line appendFormat:@" preservedY=%@", isSet ? [NSString stringWithFormat:@"%.1f", preserved] : @"nil"];
  if (RFReadInt(sv, "contentOffsetPreservationCount", &count)) [line appendFormat:@" preserveCount=%ld", (long)count];
  NSArray *animations = sv.layer.animationKeys;
  if (animations.count) [line appendFormat:@" layerAnimations=%@", [animations componentsJoinedByString:@","]];
  return line;
}

static NSString *RFCellsLine(UIView *hitView, UITouch *touch) {
  UICollectionViewCell *hitCell = nil;
  for (UIView *v = hitView; v; v = v.superview)
    if ([v isKindOfClass:UICollectionViewCell.class]) { hitCell = (UICollectionViewCell *)v; break; }
  UICollectionView *list = nil;
  for (UIView *v = hitCell ?: hitView; v; v = v.superview)
    if ([v isKindOfClass:UICollectionView.class]) { list = (UICollectionView *)v; break; }
  if (!list) return @"cells: (not inside a collection view)";

  CGPoint p = [touch locationInView:list];
  NSIndexPath *underFinger = [list indexPathForItemAtPoint:p];
  NSIndexPath *owner = hitCell ? [list indexPathForCell:hitCell] : nil;
  NSMutableString *line = [NSMutableString stringWithFormat:@"cells: under finger=%@  owns touched view=%@",
      underFinger ? [NSString stringWithFormat:@"%ld/%ld", (long)underFinger.section, (long)underFinger.item] : @"none",
      owner ? [NSString stringWithFormat:@"%ld/%ld", (long)owner.section, (long)owner.item] : @"none"];
  if (underFinger && owner && ![underFinger isEqual:owner]) [line appendString:@"  <-- MISMATCH (another cell is on top)"];
  if (hitCell && !CGRectContainsPoint(hitCell.frame, p)) [line appendString:@"  <-- touched view sticks out of its cell"];

  NSMutableArray *overlaps = [NSMutableArray array];
  for (UICollectionViewCell *cell in list.visibleCells) {
    if (!CGRectContainsPoint(CGRectInset(cell.frame, 0, -1), p) && !CGRectContainsPoint(cell.frame, p)) continue;
    NSIndexPath *ip = [list indexPathForCell:cell];
    [overlaps addObject:[NSString stringWithFormat:@"%ld/%ld %@ frame=%@ hidden=%d alpha=%.2f", (long)ip.section,
                                                   (long)ip.item, RFName(cell), RFRect(cell.frame), cell.hidden, cell.alpha]];
  }
  // Zero- or near-zero-height items next to the finger (e.g. blank feed items).
  for (UICollectionViewCell *cell in list.visibleCells) {
    if (cell.frame.size.height > 2 || fabs(CGRectGetMidY(cell.frame) - p.y) > 400) continue;
    NSIndexPath *ip = [list indexPathForCell:cell];
    [overlaps addObject:[NSString stringWithFormat:@"%ld/%ld %@ frame=%@ (zero height, near finger)", (long)ip.section,
                                                   (long)ip.item, RFName(cell), RFRect(cell.frame)]];
  }
  if (overlaps.count) [line appendFormat:@"\n    cells at/near finger: %@", [overlaps componentsJoinedByString:@"\n                          "]];
  return line;
}

static NSString *RFSnapshot(UITouch *touch, UIWindow *window) {
  NSMutableString *out = [NSMutableString string];
  UIView *hit = touch.view;
  CGPoint p = [touch locationInView:nil];
  [out appendFormat:@"  touched view: %@%@\n", RFName(hit),
                    [hit isKindOfClass:UIControl.class]
                        ? [NSString stringWithFormat:@" (UIControl enabled=%d)", ((UIControl *)hit).enabled]
                        : @""];
  [out appendFormat:@"  %@\n", RFCellsLine(hit, touch)];

  // The view chain from the touched view up to the window.
  [out appendString:@"  view chain (touched view first):\n"];
  NSInteger depth = 0;
  NSMutableArray<UIScrollView *> *scrollViews = [NSMutableArray array];
  for (UIView *v = hit; v; v = v.superview, depth++) {
    if ([v isKindOfClass:UIScrollView.class]) [scrollViews addObject:(UIScrollView *)v];
    BOOL interesting = depth < 10 || [v isKindOfClass:UIScrollView.class] || [v isKindOfClass:UICollectionViewCell.class] ||
                       v.layer.animationKeys.count || !v.userInteractionEnabled;
    if (!interesting) continue;
    NSMutableString *row = [NSMutableString stringWithFormat:@"    %2ld %@ frame=%@", (long)depth, RFName(v), RFRect(v.frame)];
    if (v.alpha < 1) [row appendFormat:@" alpha=%.2f", v.alpha];
    if (v.hidden) [row appendString:@" HIDDEN"];
    if (!v.userInteractionEnabled) [row appendString:@" userInteraction=NO"];
    if (!CGAffineTransformIsIdentity(v.transform)) [row appendString:@" transformed"];
    if (v.layer.animationKeys.count)
      [row appendFormat:@" ANIMATING[%@]", [v.layer.animationKeys componentsJoinedByString:@","]];
    for (UIGestureRecognizer *g in v.gestureRecognizers)
      if (g.enabled && ![NSStringFromClass(g.class) hasPrefix:@"_UI"])
        [row appendFormat:@" {%@ %@}", RFName(g), RFStateName(g.state)];
    [out appendFormat:@"%@\n", row];
  }

  [out appendString:@"  scroll views (innermost first):\n"];
  for (UIScrollView *sv in scrollViews) [out appendFormat:@"    %@\n", RFScrollViewLine(sv)];
  [out appendFormat:@"  finger at (%.0f,%.0f) in window %@\n", p.x, p.y, RFRect(window.bounds)];
  return out;
}

static NSString *RFGestureLine(UITouch *touch, NSString *label) {
  NSMutableArray *items = [NSMutableArray array];
  for (UIGestureRecognizer *g in touch.gestureRecognizers)
    [items addObject:[NSString stringWithFormat:@"%@@%@=%@%@", RFName(g), RFName(g.view), RFStateName(g.state),
                                                g.enabled ? @"" : @"(disabled)"]];
  return [NSString stringWithFormat:@"  gestures that saw the touch (%@): %@\n", label,
                                    items.count ? [items componentsJoinedByString:@", "] : @"none"];
}

#pragma mark - Recording

static void RFKeep(NSMutableArray *list, NSString *report, NSUInteger limit) {
  [list insertObject:report atIndex:0];
  while (list.count > limit) [list removeLastObject];
}

static void RFTapFinished(NSString *snapshot, CFTimeInterval start, CFTimeInterval duration, CGFloat moved) {
  gTapCount++;
  NSUInteger number = gTapCount;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kResultWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    BOOL navigated = gLastNavigation >= start;
    BOOL handled = gLastTapHandler >= start;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss.SSS";
    NSString *when = [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-(CACurrentMediaTime() - start)]];
    NSString *verdict = navigated ? @"opened a screen"
                        : handled ? [NSString stringWithFormat:@"tap handler ran (%@) but nothing opened", gLastTapHandlerName]
                                  : @"DEAD: nothing opened and no post tap handler ran";
    NSString *report = [NSString stringWithFormat:@"tap #%lu at %@, %.2fs, moved %.1fpt: %@\n%@", (unsigned long)number,
                                                  when, duration, moved, verdict, snapshot];
    if (navigated || handled) {
      RFKeep(gGoodReports, report, kKeepGood);
    } else {
      gDeadCount++;
      RFKeep(gDeadReports, report, kKeepDead);
    }
  });
}

static void RFObserveTouches(UIWindow *window, UIEvent *event, BOOL afterDelivery) {
  NSSet<UITouch *> *touches = event.allTouches;
  if (touches.count != 1) {
    if (!afterDelivery) gTouchID = 0; // multi-finger: not a tap
    return;
  }
  UITouch *touch = touches.anyObject;
  uintptr_t touchID = (uintptr_t)(__bridge void *)touch;
  CGPoint p = [touch locationInView:nil];

  switch (touch.phase) {
    case UITouchPhaseBegan: {
      if (afterDelivery) return;
      gTouchOnFeed = NO;
      for (UIView *v = touch.view; v; v = v.superview)
        if (RFIsFeedList(v)) { gTouchOnFeed = YES; break; }
      gTouchID = gTouchOnFeed ? touchID : 0;
      if (!gTouchOnFeed) return;
      gTouchStart = touch.timestamp;
      gTouchStartPoint = p;
      gTouchMaxMove = 0;
      gTouchSnapshot = RFSnapshot(touch, window); // state at the moment the finger lands
      break;
    }
    case UITouchPhaseMoved:
    case UITouchPhaseStationary:
      if (touchID == gTouchID && !afterDelivery)
        gTouchMaxMove = MAX(gTouchMaxMove, hypot(p.x - gTouchStartPoint.x, p.y - gTouchStartPoint.y));
      break;
    case UITouchPhaseEnded: {
      if (touchID != gTouchID) return;
      CGFloat moved = MAX(gTouchMaxMove, hypot(p.x - gTouchStartPoint.x, p.y - gTouchStartPoint.y));
      CFTimeInterval duration = touch.timestamp - gTouchStart;
      if (moved > kTapSlop || duration > kTapMaxTime) { gTouchID = 0; return; }
      if (!afterDelivery) {
        gTouchSnapshot = [gTouchSnapshot stringByAppendingString:RFGestureLine(touch, @"before lift")];
        return;
      }
      NSString *snapshot = [gTouchSnapshot stringByAppendingString:RFGestureLine(touch, @"after lift")];
      gTouchID = 0;
      RFTapFinished(snapshot, gTouchStart, duration, moved);
      break;
    }
    case UITouchPhaseCancelled:
      if (touchID == gTouchID && afterDelivery) gTouchID = 0;
      break;
    default:
      break;
  }
}

#pragma mark - "Did the tap do anything?" signals

// Post tap handlers live in Swift classes. Hook them by name and skip any that
// a future Reddit version renames.
static void RFHookTapHandler(const char *className, const char *selectorName, BOOL takesArgument) {
  Class cls = objc_getClass(className);
  SEL selector = sel_registerName(selectorName);
  Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
  if (!method) return;
  NSString *label = [NSString stringWithFormat:@"%@ %s", RFName(cls), selectorName];
  __block IMP original = NULL;
  IMP replacement;
  if (takesArgument) {
    replacement = imp_implementationWithBlock(^(id self, id argument) {
      gLastTapHandler = CACurrentMediaTime();
      gLastTapHandlerName = label;
      ((void (*)(id, SEL, id))original)(self, selector, argument);
    });
  } else {
    replacement = imp_implementationWithBlock(^(id self) {
      gLastTapHandler = CACurrentMediaTime();
      gLastTapHandlerName = label;
      ((void (*)(id, SEL))original)(self, selector);
    });
  }
  original = method_setImplementation(method, replacement);
}

static void RFInstallTapHandlerHooks(void) {
  RFHookTapHandler("_TtC14FeedKit_Slices22FeedFlexStackSliceView", "didTapWithGestureRecognizer:", YES);
  RFHookTapHandler("_TtC14FeedKit_Slices18FeedStackSliceView", "didTapWithGestureRecognizer:", YES);
  RFHookTapHandler("_TtC14FeedKit_Slices17DeferredSliceView", "didTapWithGestureRecognizer:", YES);
  RFHookTapHandler("_TtC8SliceKit13FlexStackView", "didSingleTap", NO);
  RFHookTapHandler("_TtC27RedditSliceKit_CommonSlices22AnimatedImageSliceView", "onTapGesture", NO);
  RFHookTapHandler("_TtC14FeedKit_Slices20ServerImageSliceView", "screenTapped", NO);
}

%group TapInspector

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  BOOL touches = event.type == UIEventTypeTouches;
  if (touches) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ RFInstallTapHandlerHooks(); }); // after launch, once Reddit's classes are loaded
    RFObserveTouches(self, event, NO);
  }
  %orig;
  if (touches) RFObserveTouches(self, event, YES);
}
%end

%hook UINavigationController
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
  gLastNavigation = CACurrentMediaTime();
  %orig;
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(void (^)(void))completion {
  gLastNavigation = CACurrentMediaTime();
  %orig;
}
%end

%end

#pragma mark - Menu API

NSString *RFTapInspectorSummary(void) {
  return [NSString stringWithFormat:@"%lu dead tap%@ out of %lu tap%@ on the feed", (unsigned long)gDeadCount,
                                    gDeadCount == 1 ? @"" : @"s", (unsigned long)gTapCount, gTapCount == 1 ? @"" : @"s"];
}

NSString *RFTapInspectorReport(void) {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  NSMutableString *out = [NSMutableString stringWithFormat:
      @"RedditFilter tap inspector\nReddit %@ (%@), iOS %@, %@\n%@\n"
      @"filters: promoted=%d recommended=%d nsfw=%d awards=%d scores=%d automod=%d\n\n",
      info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], UIDevice.currentDevice.systemVersion,
      UIDevice.currentDevice.model, RFTapInspectorSummary(), [d boolForKey:kRedditFilterPromoted],
      [d boolForKey:kRedditFilterRecommended], [d boolForKey:kRedditFilterNSFW], [d boolForKey:kRedditFilterAwards],
      [d boolForKey:kRedditFilterScores], [d boolForKey:kRedditFilterAutoCollapseAutoMod]];
  [out appendString:@"===== DEAD TAPS (newest first) =====\n"];
  for (NSString *r in gDeadReports) [out appendFormat:@"%@\n", r];
  if (!gDeadReports.count) [out appendString:@"(none yet)\n\n"];
  [out appendString:@"===== RECENT TAPS THAT WORKED (for comparison) =====\n"];
  for (NSString *r in gGoodReports) [out appendFormat:@"%@\n", r];
  return out;
}

void RFTapInspectorReset(void) {
  [gDeadReports removeAllObjects];
  [gGoodReports removeAllObjects];
  gTapCount = gDeadCount = 0;
}

%ctor {
  gDeadReports = [NSMutableArray array];
  gGoodReports = [NSMutableArray array];
  %init(TapInspector);
}

#endif
