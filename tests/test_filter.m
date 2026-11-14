// test_filter.m — unit tests for JSONFilter.m (built on Linux with GNUstep).
//
// Feed fixtures mirror the shapes in Reddit 2026.45.1's GraphQL fragments
// (feedElementEdgeFragment / cellGroupFragment / recommendationContextFragment).

#import <Foundation/Foundation.h>
#import "JSONFilter.h"

static int gPass = 0, gFail = 0;
static NSString *gTest = @"";

#define CHECK(cond, ...)                                                        \
  do {                                                                          \
    if (cond) {                                                                 \
      gPass++;                                                                  \
    } else {                                                                    \
      gFail++;                                                                  \
      printf("  FAIL [%s] %s\n", [gTest UTF8String],                            \
             [[NSString stringWithFormat:__VA_ARGS__] UTF8String]);             \
    }                                                                           \
  } while (0)

#pragma mark - Fixture helpers

static RFPrefs P(BOOL promoted, BOOL recommended, BOOL nsfw, BOOL awards, BOOL scores, BOOL automod) {
  RFPrefs p = {promoted, recommended, nsfw, awards, scores, automod};
  return p;
}
static RFPrefs Defaults(void) { return P(YES, NO, NO, NO, NO, NO); } // app defaults

static NSDictionary *Post(NSString *pid) {
  return @{
    @"__typename" : @"CellGroup",
    @"id" : [@"cg_" stringByAppendingString:pid],
    @"groupId" : pid,
    @"cells" : @[
      @{@"__typename" : @"TitleCell", @"id" : [pid stringByAppendingString:@"_title"], @"title" : pid, @"isVisited" : @NO},
      @{@"__typename" : @"ActionCell", @"id" : [pid stringByAppendingString:@"_action"], @"score" : @42,
        @"isScoreHidden" : @NO, @"isAwardHidden" : @NO, @"goldenUpvoteInfo" : @{@"isGildable" : @YES}},
    ],
    @"adPayload" : [NSNull null],
    @"recommendationContext" : [NSNull null],
  };
}
static NSDictionary *Ad(NSString *pid) {
  NSMutableDictionary *d = [Post(pid) mutableCopy];
  d[@"adPayload"] = @{@"__typename" : @"AdPayload", @"isBlankAd" : @NO, @"impressionId" : @"imp"};
  return d;
}
static NSDictionary *Rec(NSString *pid, NSString *typeName, NSString *typeId) {
  NSMutableDictionary *d = [Post(pid) mutableCopy];
  d[@"recommendationContext"] = @{@"__typename" : @"RecommendationContext", @"typeName" : typeName,
                                  @"typeIdentifier" : typeId, @"isContextHidden" : @NO, @"isSubscribed" : @NO,
                                  @"richText" : @""};
  return d;
}
static NSDictionary *Feed(NSString *root, NSArray *nodes) {
  NSMutableArray *edges = [NSMutableArray array];
  for (id n in nodes) [edges addObject:@{@"__typename" : @"FeedElementEdge", @"node" : n}];
  return @{@"data" : @{root : @{@"__typename" : @"HomeV3", @"elements" : @{
    @"__typename" : @"FeedElementConnection", @"edges" : edges,
    @"pageInfo" : @{@"hasNextPage" : @YES, @"endCursor" : @"cursor_2"}}}}};
}
static NSData *J(id obj) { return [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL]; }

// Runs the filter; returns the parsed output, or nil when the filter left the
// response untouched (the caller then passes the original bytes through).
static id Run(id fixture, NSString *op, RFPrefs p) {
  NSData *out = RFFilteredResponseData(J(fixture), op, p);
  return out ? [NSJSONSerialization JSONObjectWithData:out options:0 error:NULL] : nil;
}
static NSArray *Edges(id json, NSString *root) {
  return [json[@"data"] objectForKey:root][@"elements"][@"edges"];
}
// Ids of the posts a user would actually see: edges whose CellGroup still has cells.
static NSArray *Visible(NSArray *edges) {
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *e in edges) {
    NSDictionary *n = e[@"node"];
    if ([n[@"__typename"] isEqual:@"CellGroup"] && [n[@"cells"] count] == 0) continue;
    if ([n[@"isHidden"] isEqual:@YES]) continue;
    [ids addObject:n[@"groupId"] ?: n[@"id"] ?: @"?"];
  }
  return ids;
}
// Blank leftovers: CellGroups emptied by the filter, or posts only flagged hidden.
static NSUInteger Phantoms(NSArray *edges) {
  return edges.count - Visible(edges).count;
}

#pragma mark - Tests

static void TestHomeAdsRemovedNotBlanked(void) {
  gTest = @"home: promoted posts are removed, not left as blank items";
  id fx = Feed(@"homeV3", @[ Post(@"t3_a"), Ad(@"t3_ad1"), Post(@"t3_b"), Ad(@"t3_ad2"), Post(@"t3_c") ]);
  id out = Run(fx, @"HomeFeedSdui", Defaults());
  NSArray *edges = Edges(out, @"homeV3");
  CHECK([Visible(edges) isEqual:(@[ @"t3_a", @"t3_b", @"t3_c" ])], @"visible = %@", Visible(edges));
  CHECK(edges.count == 3, @"expected 3 feed items, got %lu (blank items left behind)", (unsigned long)edges.count);
  CHECK(Phantoms(edges) == 0, @"%lu blank leftover item(s)", (unsigned long)Phantoms(edges));
}

static void TestHomeRecommendedRemoved(void) {
  gTest = @"home: recommended posts removed, popular filler kept";
  id fx = Feed(@"homeV3", @[
    Post(@"t3_a"), Rec(@"t3_r1", @"SimilarSubredditRecommendationContext", @"similar_sub"),
    Rec(@"t3_pop", @"PopularRecommendationContext", @"global_popular"), Post(@"t3_b"),
    Rec(@"t3_pop2", @"SomeContext", @"global_popular_v2"),
  ]);
  id out = Run(fx, @"HomeFeedSdui", P(NO, YES, NO, NO, NO, NO));
  NSArray *edges = Edges(out, @"homeV3");
  CHECK([Visible(edges) isEqual:(@[ @"t3_a", @"t3_pop", @"t3_b", @"t3_pop2" ])], @"visible = %@", Visible(edges));
  CHECK(Phantoms(edges) == 0, @"%lu blank leftover item(s)", (unsigned long)Phantoms(edges));
}

static void TestPopularNotWiped(void) {
  gTest = @"popular: recommended filter leaves Popular alone";
  id fx = Feed(@"popularV3", @[
    Rec(@"t3_1", @"GeoPopularRecommendationContext", @"geo_popular"),
    Rec(@"t3_2", @"PopularVideosRecommendationContext", @"popular_videos"),
    Rec(@"t3_3", @"PopularRecommendationContext", @"global_popular"),
  ]);
  NSData *raw = RFFilteredResponseData(J(fx), @"PopularFeedSdui", P(NO, YES, NO, NO, NO, NO));
  CHECK(raw == nil, @"Popular response was modified");
  id out = Run(fx, @"PopularFeedSdui", P(YES, YES, NO, NO, NO, NO));
  CHECK(out == nil || [Visible(Edges(out, @"popularV3")) count] == 3, @"Popular lost posts");
}

static void TestPromotedOffKeepsAds(void) {
  gTest = @"promoted off: ads untouched";
  id fx = Feed(@"homeV3", @[ Post(@"t3_a"), Ad(@"t3_ad") ]);
  CHECK(RFFilteredResponseData(J(fx), @"HomeFeedSdui", P(NO, NO, NO, NO, NO, NO)) == nil, @"changed with all filters off");
  CHECK(RFFilteredResponseData(J(fx), @"HomeFeedSdui", P(NO, YES, NO, NO, NO, NO)) == nil, @"changed with only recommended");
}

static void TestEveryItemFilteredKeepsPageNonEmpty(void) {
  gTest = @"page where everything is filtered stays non-empty";
  id fx = Feed(@"homeV3", @[ Ad(@"t3_ad1"), Ad(@"t3_ad2"), Ad(@"t3_ad3") ]);
  id out = Run(fx, @"HomeFeedSdui", Defaults());
  NSArray *edges = Edges(out, @"homeV3");
  CHECK(edges.count == 1, @"expected 1 placeholder so paging continues, got %lu", (unsigned long)edges.count);
  CHECK(Visible(edges).count == 0, @"an ad is still visible: %@", Visible(edges));
  CHECK([out[@"data"][@"homeV3"][@"elements"][@"pageInfo"][@"endCursor"] isEqual:@"cursor_2"], @"pageInfo changed");
}

static void TestOrderAndContentPreserved(void) {
  gTest = @"kept posts keep order and content";
  id fx = Feed(@"homeV3", @[ Post(@"t3_1"), Ad(@"t3_ad"), Post(@"t3_2"), Post(@"t3_3") ]);
  id out = Run(fx, @"HomeFeedSdui", Defaults());
  NSArray *edges = Edges(out, @"homeV3");
  CHECK([Visible(edges) isEqual:(@[ @"t3_1", @"t3_2", @"t3_3" ])], @"order = %@", Visible(edges));
  CHECK([edges.firstObject isEqual:J(@0) ? edges.firstObject : nil], @"(sanity)");
  CHECK([edges[0][@"node"] isEqual:Post(@"t3_1")], @"first post was modified");
}

static void TestGenericFeedAdPostAndNSFWRemoved(void) {
  gTest = @"profile/generic feed: AdPost and NSFW posts removed";
  id fx = @{@"data" : @{@"profileV2" : @{@"__typename" : @"Profile", @"elements" : @{@"edges" : @[
    @{@"node" : @{@"__typename" : @"SubredditPost", @"id" : @"t3_ok", @"isNsfw" : @NO}},
    @{@"node" : @{@"__typename" : @"AdPost", @"id" : @"t3_ad"}},
    @{@"node" : @{@"__typename" : @"SubredditPost", @"id" : @"t3_nsfw", @"isNsfw" : @YES}},
  ], @"pageInfo" : @{@"hasNextPage" : @NO}}}}};
  id out = Run(fx, @"ProfileFeedSdui", P(YES, NO, YES, NO, NO, NO));
  NSArray *edges = out[@"data"][@"profileV2"][@"elements"][@"edges"];
  CHECK(edges.count == 1 && [edges[0][@"node"][@"id"] isEqual:@"t3_ok"], @"edges = %@", edges);
}

static void TestPostDetailsArrayNotShrunk(void) {
  gTest = @"FeedPostDetailsByIds: entries flagged, never removed";
  id fx = @{@"data" : @{@"postsInfoByIds" : @[
    @{@"__typename" : @"SubredditPost", @"id" : @"t3_a", @"isNsfw" : @NO},
    @{@"__typename" : @"SubredditPost", @"id" : @"t3_b", @"isNsfw" : @YES},
    @{@"__typename" : @"AdPost", @"id" : @"t3_c"},
  ]}};
  id out = Run(fx, @"FeedPostDetailsByIds", P(YES, NO, YES, NO, NO, NO));
  NSArray *arr = out[@"data"][@"postsInfoByIds"];
  CHECK(arr.count == 3, @"lookup array shrank to %lu (the app looks these up by id)", (unsigned long)arr.count);
  CHECK([arr[1][@"isHidden"] isEqual:@YES] && [arr[2][@"isHidden"] isEqual:@YES], @"not flagged hidden");
  CHECK(arr[0][@"isHidden"] == nil, @"clean post flagged");
}

static void TestAwardsAndScores(void) {
  gTest = @"awards + scores hidden on posts, comments, action cells";
  id fx = Feed(@"homeV3", @[ Post(@"t3_a") ]);
  id out = Run(fx, @"HomeFeedSdui", P(NO, NO, NO, YES, YES, NO));
  NSDictionary *action = Edges(out, @"homeV3")[0][@"node"][@"cells"][1];
  CHECK([action[@"isAwardHidden"] isEqual:@YES], @"isAwardHidden");
  CHECK([action[@"isScoreHidden"] isEqual:@YES], @"isScoreHidden");
  CHECK([action[@"goldenUpvoteInfo"][@"isGildable"] isEqual:@NO], @"isGildable");
  CHECK(Edges(out, @"homeV3").count == 1, @"post was removed");
  id post = @{@"data" : @{@"postInfoById" : @{@"__typename" : @"SubredditPost", @"id" : @"t3_x",
    @"awardings" : @[ @1 ], @"isGildable" : @YES, @"commentForest" : @{@"trees" : @[
      @{@"node" : @{@"__typename" : @"Comment", @"id" : @"c1", @"awardings" : @[ @1 ], @"authorInfo" : @{@"id" : @"t2_6l4z3"}}}
  ]}}}};
  out = Run(post, @"PostInfoById", P(NO, NO, NO, YES, YES, YES));
  NSDictionary *p = out[@"data"][@"postInfoById"];
  NSDictionary *c = p[@"commentForest"][@"trees"][0][@"node"];
  CHECK([p[@"awardings"] count] == 0 && [p[@"isScoreHidden"] isEqual:@YES], @"post awards/score");
  CHECK([c[@"awardings"] count] == 0 && [c[@"isInitiallyCollapsed"] isEqual:@YES], @"comment awards/automod");
}

static void TestCommentsNeverRemoved(void) {
  gTest = @"comments are never removed";
  id post = @{@"data" : @{@"postInfoById" : @{@"__typename" : @"SubredditPost", @"id" : @"t3_x",
    @"commentForest" : @{@"trees" : @[
      @{@"node" : @{@"__typename" : @"Comment", @"id" : @"c1", @"authorInfo" : @{@"id" : @"t2_6l4z3"}}},
      @{@"node" : @{@"__typename" : @"Comment", @"id" : @"c2", @"authorInfo" : @{@"id" : @"t2_other"}}},
  ]}}}};
  id out = Run(post, @"PostInfoById", P(YES, YES, YES, NO, NO, YES));
  CHECK([out[@"data"][@"postInfoById"][@"commentForest"][@"trees"] count] == 2, @"comment removed");
}

static void TestCommentAds(void) {
  gTest = @"comment-page ads cleared";
  id fx = @{@"data" : @{@"postInfoById" : @{@"__typename" : @"SubredditPost", @"pdpCommentsAds" : @[ @{@"x" : @1} ]}}};
  id out = Run(fx, @"PdpCommentsAds", Defaults());
  CHECK([out[@"data"][@"postInfoById"][@"pdpCommentsAds"] count] == 0, @"pdpCommentsAds = %@", out);
}

static void TestCrashSafety(void) {
  gTest = @"malformed / null data never crashes";
  NSArray *bad = @[
    @{@"data" : [NSNull null]},
    @{@"data" : @{@"homeV3" : [NSNull null]}},
    @{@"data" : @{@"homeV3" : @{@"elements" : [NSNull null]}}},
    @{@"data" : @{@"homeV3" : @{@"elements" : @{@"edges" : [NSNull null]}}}},
    @{@"data" : @{@"homeV3" : @{@"elements" : @{@"edges" : @[ [NSNull null], @{@"node" : [NSNull null]}, @{}, @1 ]}}}},
    @{@"data" : @{@"postInfoById" : [NSNull null]}},
    @{@"data" : @{@"postInfoById" : @{@"commentForest" : [NSNull null]}}},
    @[ @1, @2 ],
  ];
  RFPrefs all = P(YES, YES, YES, YES, YES, YES);
  for (id fx in bad)
    for (NSString *op in @[ @"HomeFeedSdui", @"PostInfoById", @"Unknown", @"PopularFeedSdui" ]) {
      @try {
        RFFilteredResponseData(J(fx), op, all);
        gPass++;
      } @catch (NSException *e) {
        CHECK(NO, @"threw %@ for %@ / %@", e.name, op, fx);
      }
    }
  CHECK(RFFilteredResponseData([@"not json" dataUsingEncoding:NSUTF8StringEncoding], @"HomeFeedSdui", all) == nil,
        @"non-JSON");
  NSString *multipart = @"\r\n---\r\ncontent-type: application/json\r\n\r\n{\"data\":{}}\r\n-----\r\n";
  CHECK(RFFilteredResponseData([multipart dataUsingEncoding:NSUTF8StringEncoding], @"HomeFeedSdui", all) == nil,
        @"multipart body");
}

static void TestFallbackFindsEdgesUnderAnyKey(void) {
  gTest = @"fallback filter finds edges under any key";
  id fx = @{@"data" : @{@"homeV9" : @{@"__typename" : @"X", @"zzz" : @{@"edges" : @[
    @{@"node" : Post(@"t3_a")}, @{@"node" : Ad(@"t3_ad")}
  ]}}}};
  id out = Run(fx, @"HomeFeedSdui", Defaults());
  NSArray *edges = out[@"data"][@"homeV9"][@"zzz"][@"edges"];
  CHECK(edges.count == 1 && [edges[0][@"node"][@"groupId"] isEqual:@"t3_a"], @"edges = %@", edges);
}

static void TestUnchangedAndIgnored(void) {
  gTest = @"unchanged responses and telemetry ops are skipped";
  id fx = Feed(@"homeV3", @[ Post(@"t3_a"), Post(@"t3_b") ]);
  CHECK(RFFilteredResponseData(J(fx), @"HomeFeedSdui", Defaults()) == nil, @"re-encoded an unchanged feed");
  id ads = Feed(@"homeV3", @[ Ad(@"t3_ad") ]);
  CHECK(RFFilteredResponseData(J(ads), @"GetAccount", Defaults()) == nil, @"ignored op was filtered");
}

static void TestOperationName(void) {
  gTest = @"operation name detection";
  NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.reddit.com/"]];
  [r setValue:@"HomeFeedSdui" forHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  r.HTTPBody = [@"{\"variables\":{\"id\":\"t3_abc\"},\"operationName\":\"Other\"}" dataUsingEncoding:NSUTF8StringEncoding];
  CHECK([RFOperationName(r) isEqual:@"HomeFeedSdui"], @"header: %@", RFOperationName(r));
  [r setValue:nil forHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  CHECK([RFOperationName(r) isEqual:@"Other"], @"body: %@", RFOperationName(r));
  NSURLRequest *q = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.reddit.com/?operationName=PostInfoById"]];
  CHECK([RFOperationName(q) isEqual:@"PostInfoById"], @"query: %@", RFOperationName(q));
  NSURLRequest *none = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.reddit.com/"]];
  CHECK([RFOperationName(none) isEqual:@"Unknown"], @"none: %@", RFOperationName(none));
}

int main(int argc, char **argv) {
  @autoreleasepool {
    void (*tests[])(void) = {
      TestHomeAdsRemovedNotBlanked, TestHomeRecommendedRemoved, TestEveryItemFilteredKeepsPageNonEmpty,
      TestOrderAndContentPreserved, TestGenericFeedAdPostAndNSFWRemoved, TestPostDetailsArrayNotShrunk,
      TestPopularNotWiped, TestPromotedOffKeepsAds, TestAwardsAndScores, TestCommentsNeverRemoved,
      TestCommentAds, TestCrashSafety, TestFallbackFindsEdgesUnderAnyKey, TestUnchangedAndIgnored,
      TestOperationName,
    };
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
      int before = gFail;
      tests[i]();
      printf("%s %s\n", gFail == before ? "PASS" : "FAIL", [gTest UTF8String]);
    }
    printf("\n%d checks passed, %d failed\n", gPass, gFail);
  }
  return gFail ? 1 : 0;
}
