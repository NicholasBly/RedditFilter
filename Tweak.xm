#import <Carousel.h>
#import <Comment.h>
#import <Post.h>
#import <ToggleImageTableViewCell.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "Preferences.h"

static NSMutableArray *assetBundles;
static NSString *const kRedditFilterMutedWords = @"kRedditFilterMutedWords";

extern "C" UIImage *iconWithName(NSString *iconName) {
  NSArray *commonIconSizes = @[
    @"24",
    @"20",
    @"16",
  ];
  UIImage *iconImage;
  for (NSBundle *bundle in assetBundles) {
    for (NSString *iconSize in commonIconSizes) {
      if (iconImage) break;
      iconImage = [UIImage imageNamed:[NSString stringWithFormat:@"%@_%@", iconName, iconSize]
                            inBundle:bundle
                            compatibleWithTraitCollection:nil];
    }
    if (!iconImage)
      iconImage = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
  }
  return iconImage;
}

extern "C" NSString *localizedString(NSString *key, NSString *table) {
  for (NSBundle *bundle in assetBundles) {
    NSString *localizedString = [bundle localizedStringForKey:key value:nil table:table];
    if (![localizedString isEqualToString:key]) return localizedString;
  }
  return nil;
}

extern "C" Class CoreClass(NSString *name) {
  Class cls = NSClassFromString(name);
  NSArray *prefixes = @[
    @"Reddit.",
    @"RedditCore.",
    @"RedditCoreModels.",
    @"RedditCore_RedditCoreModels.",
    @"RedditUI.",
  ];
  for (NSString *prefix in prefixes) {
    if (cls) break;
    cls = NSClassFromString([prefix stringByAppendingString:name]);
  }
  return cls;
}

static BOOL shouldFilterObject(id object) {
  NSString *className = NSStringFromClass(object_getClass(object));
  BOOL isAdPost = [className hasSuffix:@"AdPost"] ||
                  ([object respondsToSelector:@selector(isAdPost)] && ((Post *)object).isAdPost) ||
                  ([object respondsToSelector:@selector(isPromotedUserPostAd)] &&
                   [(Post *)object isPromotedUserPostAd]) ||
                  ([object respondsToSelector:@selector(isPromotedCommunityPostAd)] &&
                   [(Post *)object isPromotedCommunityPostAd]);
  BOOL isRecommendation = [className containsString:@"Recommend"];
  BOOL isLivestream = [className containsString:@"Stream"];
  BOOL isNSFW = [object respondsToSelector:@selector(isNSFW)] && ((Post *)object).isNSFW;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] && isAdPost)
    return YES;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended] && isRecommendation)
    return YES;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterLivestreams] && isLivestream)
    return YES;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterNSFW] && isNSFW) 
    return YES;
  return NO;
}

static BOOL containsMutedWords(NSString *text) {
    if (!text) return NO;
    NSArray *mutedWords = [NSUserDefaults.standardUserDefaults objectForKey:kRedditFilterMutedWords];
    for (NSString *word in mutedWords) {
        if ([text localizedCaseInsensitiveContainsString:word]) {
            return YES;
        }
    }
    return NO;
}

static NSArray *filteredObjects(NSArray *objects) {
    if (!objects) return nil;
    NSMutableArray *filtered = [NSMutableArray new];
    
    for (id post in objects) {
        if (![post isKindOfClass:%c(Post)]) {
            [filtered addObject:post];
            continue;
        }
        
        // Check muted words
        NSString *title = [post valueForKey:@"title"];
        NSString *text = [post valueForKey:@"selftext"];
        if (containsMutedWords(title) || containsMutedWords(text)) {
            continue;
        }
        
        // Existing filters
        if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] && 
            [[post valueForKey:@"promoted"] boolValue]) {
            continue;
        }
        
        [filtered addObject:post];
    }
    return filtered;
}

static void filterNode(NSMutableDictionary *node) {
  if (![node isKindOfClass:NSMutableDictionary.class]) return;

  // Regular post
  if ([node[@"__typename"] isEqualToString:@"SubredditPost"]) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards]) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }

    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores])
      node[@"isScoreHidden"] = @YES;

    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterNSFW] &&
        [node[@"isNsfw"] boolValue])
      node[@"isHidden"] = @YES;
  }
  
  if ([node[@"__typename"] isEqualToString:@"CellGroup"]) {
    for (NSMutableDictionary *cell in node[@"cells"]) {
      if ([cell[@"__typename"] isEqualToString:@"ActionCell"]) {
        if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards]) {
          cell[@"isAwardHidden"] = @YES;
          cell[@"goldenUpvoteInfo"][@"isGildable"] = @NO;
        }

        if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores])
          cell[@"isScoreHidden"] = @YES;
      }
    }
  }

  // Ad post
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted]) {
    if ([node[@"__typename"] isEqualToString:@"AdPost"]) node[@"isHidden"] = @YES;
    if ([node[@"__typename"] isEqualToString:@"CellGroup"] &&
        [node[@"adPayload"] isKindOfClass:NSDictionary.class])
      node[@"cells"] = @[];
  }

  // Recommendation
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended]) {
    if ([node[@"__typename"] isEqualToString:@"CellGroup"] && ![node[@"recommendationContext"] isEqual:[NSNull null]])
      node[@"cells"] = @[];
  }

  // Comment
  if ([node[@"__typename"] isEqualToString:@"Comment"]) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards]) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }

    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores])
      node[@"isScoreHidden"] = @YES;

    if ([node[@"authorInfo"] isKindOfClass:NSDictionary.class] &&
        [node[@"authorInfo"][@"id"] isEqualToString:@"t2_6l4z3"] &&
        [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAutoCollapseAutoMod])
      node[@"isInitiallyCollapsed"] = @YES;
  }
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response,
                                                      NSError *error))completionHandler {
  if (![request.URL.host hasPrefix:@"gql"] && ![request.URL.host hasPrefix:@"oauth"])
    return %orig;
    
  return %orig(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
    if (!data || error) {
      completionHandler(data, response, error);
      return;
    }
    
    NSError *jsonError;
    NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:NSJSONReadingMutableContainers
                                                           error:&jsonError];
    if (!json || jsonError) {
      completionHandler(data, response, error);
      return;
    }
    
    if ([json isKindOfClass:NSDictionary.class]) {
      if (json[@"data"] && [json[@"data"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *jsonData = json[@"data"];
        NSMutableDictionary *root = jsonData.allValues.firstObject;
        if ([root isKindOfClass:NSDictionary.class]) {
          if ([root.allValues.firstObject isKindOfClass:NSDictionary.class] &&
              root.allValues.firstObject[@"edges"]) {
            for (NSMutableDictionary *edge in root.allValues.firstObject[@"edges"]) {
              filterNode(edge[@"node"]);
            }
          }

          if (root[@"commentForest"]) {
            for (NSMutableDictionary *tree in root[@"commentForest"][@"trees"]) {
              filterNode(tree[@"node"]);
            }
          }

          if (root[@"commentsPageAds"] &&
              [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted]) {
            root[@"commentsPageAds"] = @[];
          }

          if (root[@"recommendations"] &&
              [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended]) {
            root[@"recommendations"] = @[];
          }
        } else if ([root isKindOfClass:NSArray.class]) {
          for (NSMutableDictionary *node in (NSArray *)root) {
            filterNode(node);
          }
        }
      }
    }
    
    NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    completionHandler(newData, response, error);
  });
}
%end

// Only necessary for older app versions
%group Legacy

%hook Listing
- (void)fetchNextPage:(id)completion {
    %orig(^(NSArray *objects, id response) {
        if (completion) {
            completion(filteredObjects(objects), response);
        }
    });
}
%end

%hook FeedNetworkSource
- (NSArray *)postsAndCommentsFromData:(id)data {
    return filteredObjects(%orig);
}
%end

%hook PostDetailPresenter
- (BOOL)shouldFetchCommentAdPost {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] ? NO : %orig;
}
- (BOOL)shouldFetchAdditionalCommentAdPosts {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] ? NO : %orig;
}
%end

%hook StreamManager
- (instancetype)initWithAccountContext:(id)accountContext
                                source:(NSInteger)source
                 deeplinkSubredditName:(id)deeplinkSubredditName
                       streamingConfig:(id)streamingConfig {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterLivestreams]) return nil;
  return %orig;
}
- (instancetype)initWithService:(id)service
                         source:(NSInteger)source
          deeplinkSubredditName:(id)deeplinkSubredditName
                streamingConfig:(id)streamingConfig {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterLivestreams]) return nil;
  return %orig;
}
%end

%hook Carousel
- (BOOL)isHiddenByUserWithAccountSettings:(id)accountSettings {
  return ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended] &&
          ([self.analyticType containsString:@"recommended"] ||
           [self.analyticType containsString:@"similar"] ||
           [self.analyticType containsString:@"popular"])) ||
         %orig;
}
%end

%hook QuickActionViewModel
- (void)fetchActions {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended]) return;
  %orig;
}
%end

%hook Post
- (NSArray *)awardingTotals {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? 0 : %orig;
}
- (BOOL)canAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores] ? YES : %orig;
}
%end

%hook Comment
- (NSArray *)awardingTotals {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? 0 : %orig;
}
- (BOOL)canAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO : %orig;
}
- (BOOL)shouldHighlightForHighAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores] ? YES : %orig;
}
- (BOOL)shouldAutoCollapse {
  return [NSUserDefaults.standardUserDefaults boolForKey:k
