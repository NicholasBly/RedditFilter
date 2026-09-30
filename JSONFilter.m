// JSONFilter.m
//
// Edits Reddit's GraphQL responses before the app sees them. See JSONFilter.h.
//
// Every lookup below is type-checked, so a JSON null (NSNull), a missing key,
// or a renamed key can never crash the app; the worst case is "nothing gets
// filtered" (which the debug menu will then show as a miss).

#import "JSONFilter.h"
#import "DebugMenu.h"

static NSString *const kAutoModAccountId = @"t2_6l4z3";

#pragma mark - Type-safe helpers

static NSDictionary *RFDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSMutableDictionary *RFMutableDict(id value) {
  return [value isKindOfClass:NSMutableDictionary.class] ? value : nil;
}
static NSArray *RFArray(id value) { return [value isKindOfClass:NSArray.class] ? value : nil; }
static NSString *RFString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static BOOL RFTrue(id value) { return [value isKindOfClass:NSNumber.class] && [value boolValue]; }

// Like -valueForKeyPath:, but only walks dictionaries and returns nil (instead
// of throwing) when it hits a null or a missing key.
static id RFValueAtPath(id root, NSString *path) {
  id value = root;
  for (NSString *key in [path componentsSeparatedByString:@"."]) {
    value = [RFDict(value) objectForKey:key];
    if (!value) return nil;
  }
  return value;
}

BOOL RFPrefsAnyEnabled(RFPrefs p) {
  return p.promoted || p.recommended || p.nsfw || p.awards || p.scores || p.automod;
}

#pragma mark - Filtering single objects

typedef struct {
  RFPrefs prefs;
  BOOL homeFeed; // YES only while filtering a Home feed response
} RFContext;

// A Home feed post that Reddit injected as a recommendation. Popular posts
// used to pad out a thin Home feed are kept, same as before.
static BOOL RFIsHomeRecommendation(id context) {
  NSDictionary *rec = RFDict(context);
  NSString *typeName = RFString(rec[@"typeName"]);
  NSString *typeId = RFString(rec[@"typeIdentifier"]);
  if (!typeName || !typeId) return NO;
  BOOL popularFiller = [typeName isEqualToString:@"PopularRecommendationContext"] ||
                       [typeId hasPrefix:@"global_popular"];
  return !popularFiller;
}

// Returns YES if it changed anything.
static BOOL RFFilterNode(id object, const RFContext *ctx) {
  NSMutableDictionary *node = RFMutableDict(object);
  NSString *type = RFString(node[@"__typename"]);
  if (!type) return NO;
  RFPrefs p = ctx->prefs;
  BOOL changed = NO;

  BOOL isPost = [type isEqualToString:@"SubredditPost"];
  if (isPost || [type isEqualToString:@"Comment"]) {
    if (p.awards) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
      changed = YES;
    }
    if (p.scores) {
      node[@"isScoreHidden"] = @YES;
      changed = YES;
    }
    if (isPost && p.nsfw && RFTrue(node[@"isNsfw"])) {
      node[@"isHidden"] = @YES;
      changed = YES;
    }
    if (!isPost && p.automod &&
        [RFString(RFDict(node[@"authorInfo"])[@"id"]) isEqualToString:kAutoModAccountId]) {
      node[@"isInitiallyCollapsed"] = @YES;
      changed = YES;
    }
    return changed;
  }

  if ([type isEqualToString:@"AdPost"]) {
    if (!p.promoted) return NO;
    node[@"isHidden"] = @YES;
    return YES;
  }

  if (![type isEqualToString:@"CellGroup"]) return NO;

  // Promoted: ads carry an adPayload. Emptying the cells hides the whole post.
  if (p.promoted && RFDict(node[@"adPayload"])) {
    node[@"cells"] = @[];
    return YES;
  }

  // Recommended: Home feed only. Popular (and other discovery feeds) are made
  // entirely of recommendations, so doing this there wipes the whole feed.
  if (p.recommended && ctx->homeFeed && RFIsHomeRecommendation(node[@"recommendationContext"])) {
    node[@"cells"] = @[];
    return YES;
  }

  if (p.awards || p.scores) {
    for (id item in RFArray(node[@"cells"])) {
      NSMutableDictionary *cell = RFMutableDict(item);
      if (![RFString(cell[@"__typename"]) isEqualToString:@"ActionCell"]) continue;
      if (p.awards) {
        cell[@"isAwardHidden"] = @YES;
        [RFMutableDict(cell[@"goldenUpvoteInfo"]) setObject:@NO forKey:@"isGildable"];
      }
      if (p.scores) cell[@"isScoreHidden"] = @YES;
      changed = YES;
    }
  }
  return changed;
}

// An array of nodes, e.g. postsInfoByIds.
static BOOL RFFilterNodes(NSArray *nodes, const RFContext *ctx) {
  BOOL changed = NO;
  for (id node in nodes) changed |= RFFilterNode(node, ctx);
  return changed;
}

// An array of { node: ... } wrappers: feed edges and comment trees.
static BOOL RFFilterEdges(NSArray *edges, const RFContext *ctx) {
  BOOL changed = NO;
  for (id edge in edges) changed |= RFFilterNode(RFDict(edge)[@"node"], ctx);
  return changed;
}

static BOOL RFClearKeys(NSMutableDictionary *dict, NSArray *keys) {
  BOOL changed = NO;
  for (NSString *key in keys) {
    if (![dict objectForKey:key]) continue;
    [dict setObject:@[] forKey:key];
    changed = YES;
  }
  return changed;
}

#pragma mark - Filtering whole responses

// Schema-agnostic fallback for operations without a fast path, or when a fast
// path stops resolving (e.g. Reddit renames homeV3 to homeV4).
static BOOL RFFilterGeneric(NSDictionary *payload, const RFContext *ctx) {
  BOOL changed = NO;
  for (id root in payload.allValues) {
    if (RFArray(root)) {
      changed |= RFFilterNodes(root, ctx);
      continue;
    }
    NSMutableDictionary *dict = RFMutableDict(root);
    if (!dict) continue;

    // Feeds: <root>.<any key>.edges. Every key is checked because dictionary
    // order is random and nearly every object also has a __typename key.
    for (id child in dict.allValues) changed |= RFFilterEdges(RFArray(RFDict(child)[@"edges"]), ctx);

    // Comments: <root>.commentForest.trees
    changed |= RFFilterEdges(RFArray(RFValueAtPath(dict, @"commentForest.trees")), ctx);

    if (ctx->prefs.promoted)
      changed |= RFClearKeys(dict, @[ @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds" ]);
    if (ctx->prefs.recommended) changed |= RFClearKeys(dict, @[ @"recommendations" ]);
  }
  return changed;
}

// Operations whose data lives in one fixed list. If the path stops resolving,
// the generic filter takes over and the debug menu records a miss.
typedef struct {
  __unsafe_unretained NSString *operation;
  __unsafe_unretained NSString *path;
  RFSchemaSig signature;
  BOOL isEdges; // YES: list of { node: ... }, NO: list of nodes
} RFFastPath;

static const RFFastPath kFastPaths[] = {
    {@"HomeFeedSdui", @"data.homeV3.elements.edges", RFSchemaSigEdges, YES},
    {@"PopularFeedSdui", @"data.popularV3.elements.edges", RFSchemaSigEdges, YES},
    {@"FeedPostDetailsByIds", @"data.postsInfoByIds", RFSchemaSigNodeArray, NO},
};

static BOOL RFFilterPostInfo(NSMutableDictionary *json, NSDictionary *payload, const RFContext *ctx) {
  id raw = payload[@"postInfoById"];
  if (raw == [NSNull null]) return NO; // deleted/removed post: nothing to do
  NSMutableDictionary *post = RFMutableDict(raw);
  id forest = post[@"commentForest"];
  NSArray *trees = RFArray(RFDict(forest)[@"trees"]);
  // A post with zero comments has no commentForest at all; that still counts as a hit.
  BOOL resolved = trees || (post && (!forest || forest == [NSNull null]));
  RF_RECORD_SCHEMA(@"PostInfoById", @"data.postInfoById.commentForest.trees", resolved, json, RFSchemaSigTrees);

  BOOL changed = resolved ? RFFilterEdges(trees, ctx) : RFFilterGeneric(payload, ctx);
  changed |= RFFilterNode(post, ctx);
  return changed;
}

static BOOL RFFilterCommentAds(NSMutableDictionary *json, NSDictionary *payload, const RFContext *ctx) {
  NSMutableDictionary *container = nil;
  for (id value in payload.allValues) {
    NSMutableDictionary *dict = RFMutableDict(value);
    if ([dict objectForKey:@"pdpCommentsAds"]) {
      container = dict;
      break;
    }
  }
  RF_RECORD_SCHEMA(@"PdpCommentsAds", @"data.*.pdpCommentsAds", container != nil, json, RFSchemaSigCommentsAds);
  if (!ctx->prefs.promoted) return NO;
  if (!container) return RFFilterGeneric(payload, ctx);
  [container setObject:@[] forKey:@"pdpCommentsAds"];
  return YES;
}

static BOOL RFFilterResponse(NSMutableDictionary *json, NSDictionary *payload, NSString *op, const RFContext *ctx) {
  for (size_t i = 0; i < sizeof(kFastPaths) / sizeof(kFastPaths[0]); i++) {
    const RFFastPath *fast = &kFastPaths[i];
    if (![op isEqualToString:fast->operation]) continue;
    NSArray *list = RFArray(RFValueAtPath(json, fast->path));
    RF_RECORD_SCHEMA(fast->operation, fast->path, list != nil, json, fast->signature);
    if (!list) return RFFilterGeneric(payload, ctx);
    return fast->isEdges ? RFFilterEdges(list, ctx) : RFFilterNodes(list, ctx);
  }
  if ([op isEqualToString:@"PostInfoById"] || [op isEqualToString:@"PostInfoByIdComments"])
    return RFFilterPostInfo(json, payload, ctx);
  if ([op isEqualToString:@"PdpCommentsAds"]) return RFFilterCommentAds(json, payload, ctx);
  return RFFilterGeneric(payload, ctx); // e.g. ProfileFeedSdui, HomeFeedSduiBg
}

static BOOL RFIsHomeFeed(NSString *op, NSDictionary *payload) {
  if ([op hasPrefix:@"HomeFeed"]) return YES; // HomeFeedSdui, HomeFeedSduiBg, HomeFeedWithDefer
  for (id key in payload) // backup in case the operation name wasn't found
    if ([RFString(key) hasPrefix:@"home"]) return YES;
  return NO;
}

// Telemetry and config calls that never contain posts: skip them before parsing.
static NSSet<NSString *> *RFIgnoredOperations(void) {
  static NSSet *set;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    set = [[NSSet alloc] initWithObjects:
        @"GetAccount", @"FetchIdentityPreferences", @"DynamicConfigsByNames",
        @"GetAllExperimentVariants", @"AdsOffRedditLocation", @"UserLocation",
        @"CookiePreferences", @"FetchSubscribedSubreddits", @"AdsOffRedditPreferences",
        @"Age", @"RecommendedPrompts", @"EnrollInGamification", @"BadgeCounts",
        @"GetEligibleUXExperiences", @"GetUserAdEligibility", @"GoldBalances",
        @"PaymentSubscriptions", @"FeaturedDevvitGame", @"ModQueueNewItemCount",
        @"LastModeratedSubredditName", @"AwardProductOffers", @"BlockedRedditors",
        @"GamesPreferences", @"GetRedditUsersByIds", @"SubredditsForNames",
        @"SubredditsForIds", @"ExposeExperimentBatch", @"GetProfilePostFlairTemplates",
        @"GetRedditorByNameApollo", @"GetActiveSubreddits", @"GetMyShowcaseCarousel",
        @"UserPublicTrophies", @"PostDraftsCount", @"BrandToolsStatus",
        @"NotificationInbox", @"TrendingSearchesQuery", nil];
  });
  return set;
}

NSData *RFFilteredResponseData(NSData *data, NSString *operationName, RFPrefs prefs) {
  if (!data.length || [RFIgnoredOperations() containsObject:operationName]) return nil;

  NSMutableDictionary *json = RFMutableDict([NSJSONSerialization JSONObjectWithData:data
                                                                            options:NSJSONReadingMutableContainers
                                                                              error:NULL]);
  NSDictionary *payload = RFDict(json[@"data"]);
  if (!payload) return nil; // not GraphQL, or an error response like {"data": null}

  RFContext ctx = {prefs, RFIsHomeFeed(operationName, payload)};
  if (!RFFilterResponse(json, payload, operationName, &ctx)) return nil; // unchanged: skip re-encoding
  return [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
}

#pragma mark - Operation name

NSString *RFOperationName(NSURLRequest *request) {
  // Apollo (Reddit's GraphQL client) labels every request with this header.
  NSString *name = [request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  if (name.length) return name;

  NSData *body = request.HTTPBody;
  if (body.length) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      regex = [[NSRegularExpression alloc] initWithPattern:@"\"operationName\"\\s*:\\s*\"([^\"]+)\""
                                                   options:0
                                                     error:NULL];
    });
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    NSTextCheckingResult *match = text ? [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (match.numberOfRanges > 1) return [text substringWithRange:[match rangeAtIndex:1]];
  }

  for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO].queryItems)
    if ([item.name isEqualToString:@"operationName"] && item.value.length) return item.value;

  return @"Unknown";
}
