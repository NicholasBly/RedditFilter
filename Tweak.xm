#import <Carousel.h>
#import <Comment.h>
#import <Post.h>
#import <ToggleImageTableViewCell.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "Preferences.h"

// --- Cache Setup ---
static NSCache *imageCache;
static NSCache *stringCache;

@interface CUICatalog : NSObject {
  NSBundle *_bundle;
}
- (NSArray<NSString *> *)allImageNames;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
@end

static NSMutableArray<NSBundle *> *assetBundles;
static NSMutableArray<CUICatalog *> *assetCatalogs;

extern "C" UIImage *iconWithName(NSString *iconName) {
    if (!iconName) return nil;
    
    // Check Cache First
    UIImage *cachedImage = [imageCache objectForKey:iconName];
    if (cachedImage) return cachedImage;

    for (CUICatalog *catalog in assetCatalogs) {
        for (NSString *imageName in [catalog allImageNames]) {
            if ([imageName hasPrefix:iconName] &&
                (imageName.length == iconName.length || imageName.length == iconName.length + 3)) {
                
                UIImage *image = [UIImage imageNamed:imageName
                                            inBundle:object_getIvar(catalog, class_getInstanceVariable(object_getClass(catalog), "_bundle"))
                       compatibleWithTraitCollection:nil];
                
                if (image) {
                    [imageCache setObject:image forKey:iconName];
                    return image;
                }
            }
        }
    }
    return nil;
}

extern "C" NSString *localizedString(NSString *key, NSString *table) {
    if (!key) return nil;
    
    NSString *cacheKey = [NSString stringWithFormat:@"%@-%@", key, table ?: @"nil"];
    NSString *cachedString = [stringCache objectForKey:cacheKey];
    if (cachedString) return cachedString;

    for (NSBundle *bundle in assetBundles) {
        NSString *localizedString = [bundle localizedStringForKey:key value:nil table:table];
        if (![localizedString isEqualToString:key]) {
            [stringCache setObject:localizedString forKey:cacheKey];
            return localizedString;
        }
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
    // Optimization: Check preferences first before doing expensive class/selector introspection
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL filterPromoted = [defaults boolForKey:kRedditFilterPromoted];
    BOOL filterRecommended = [defaults boolForKey:kRedditFilterRecommended];
    BOOL filterNSFW = [defaults boolForKey:kRedditFilterNSFW];

    // If no relevant filters are on, return early
    if (!filterPromoted && !filterRecommended && !filterNSFW) return NO;

    // Do introspection
    NSString *className = NSStringFromClass(object_getClass(object));
    
    // 1. Check Promoted (Ads)
    if (filterPromoted) {
        BOOL isAdPost = [className hasSuffix:@"AdPost"] ||
                        ([object respondsToSelector:@selector(isAdPost)] && ((Post *)object).isAdPost) ||
                        ([object respondsToSelector:@selector(isPromotedUserPostAd)] && [(Post *)object isPromotedUserPostAd]) ||
                        ([object respondsToSelector:@selector(isPromotedCommunityPostAd)] && [(Post *)object isPromotedCommunityPostAd]);
        if (isAdPost) return YES;
    }

    // 2. Check Recommended
    if (filterRecommended) {
        BOOL isRecommendation = [className containsString:@"Recommend"];
        if (isRecommendation) return YES;
    }

    // 3. Check NSFW
    if (filterNSFW) {
        BOOL isNSFW = [object respondsToSelector:@selector(isNSFW)] && ((Post *)object).isNSFW;
        if (isNSFW) return YES;
    }

    return NO;
}

static NSArray *filteredObjects(NSArray *objects) {
  return [objects filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                               id object, NSDictionary *bindings) {
        return !shouldFilterObject(object);
    }]];
}

static void filterNode(NSMutableDictionary *node) {
  if (![node isKindOfClass:NSMutableDictionary.class]) return;

  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

  // Regular post
  if ([node[@"__typename"] isEqualToString:@"SubredditPost"]) {
    if ([defaults boolForKey:kRedditFilterAwards]) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }
    if ([defaults boolForKey:kRedditFilterScores])
      node[@"isScoreHidden"] = @YES;
    if ([defaults boolForKey:kRedditFilterNSFW] && [node[@"isNsfw"] boolValue])
      node[@"isHidden"] = @YES;
  }
  
  // CellGroup handling
  if ([node[@"__typename"] isEqualToString:@"CellGroup"]) {
    // Helper to filter cells
    NSMutableArray *cells = node[@"cells"];
    if ([cells isKindOfClass:[NSMutableArray class]]) {
        for (NSMutableDictionary *cell in cells) {
          if (![cell isKindOfClass:NSMutableDictionary.class]) continue;

          if ([cell[@"__typename"] isEqualToString:@"ActionCell"]) {
            if ([defaults boolForKey:kRedditFilterAwards]) {
              cell[@"isAwardHidden"] = @YES;
              id goldenUpvoteInfo = cell[@"goldenUpvoteInfo"];
              if ([goldenUpvoteInfo isKindOfClass:NSDictionary.class] &&
                  ![goldenUpvoteInfo isEqual:[NSNull null]]) {
                  // Ensure we can mutate it, though usually JSON deserialization with MutableContainers handles this
                  if ([goldenUpvoteInfo isKindOfClass:NSMutableDictionary.class]) {
                     ((NSMutableDictionary *)goldenUpvoteInfo)[@"isGildable"] = @NO;
                  }
              }
            }
            if ([defaults boolForKey:kRedditFilterScores])
              cell[@"isScoreHidden"] = @YES;
          }
        }
    }

    // Check for ads in CellGroup
    if ([defaults boolForKey:kRedditFilterPromoted] &&
        [node[@"adPayload"] isKindOfClass:NSDictionary.class]) {
      node[@"cells"] = @[];
    }
    
    // Check for recommendations in CellGroup
    if ([defaults boolForKey:kRedditFilterRecommended] &&
        ![node[@"recommendationContext"] isEqual:[NSNull null]] &&
        [node[@"recommendationContext"] isKindOfClass:NSDictionary.class]) {
      NSDictionary *recommendationContext = node[@"recommendationContext"];
      id typeName = recommendationContext[@"typeName"];
      id typeIdentifier = recommendationContext[@"typeIdentifier"];
      id isContextHidden = recommendationContext[@"isContextHidden"];
      if (![typeIdentifier isEqual:[NSNull null]] && ![typeName isEqual:[NSNull null]] &&
          ![isContextHidden isEqual:[NSNull null]] &&
          [typeIdentifier isKindOfClass:NSString.class] &&
          [typeName isKindOfClass:NSString.class] &&
          [isContextHidden isKindOfClass:NSNumber.class]) {
        if (!(([typeName isEqualToString:@"PopularRecommendationContext"] ||
               [typeIdentifier hasPrefix:@"global_popular"]) &&
              [isContextHidden boolValue])) {
          node[@"cells"] = @[];
        }
      }
    }
  }
  // Ad post
  if ([defaults boolForKey:kRedditFilterPromoted]) {
    if ([node[@"__typename"] isEqualToString:@"AdPost"]) {
      node[@"isHidden"] = @YES;
    }
  }
  // Comment
  if ([node[@"__typename"] isEqualToString:@"Comment"]) {
    if ([defaults boolForKey:kRedditFilterAwards]) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }
    if ([defaults boolForKey:kRedditFilterScores])
      node[@"isScoreHidden"] = @YES;
    if ([node[@"authorInfo"] isKindOfClass:NSDictionary.class] &&
        [node[@"authorInfo"][@"id"] isEqualToString:@"t2_6l4z3"] &&
        [defaults boolForKey:kRedditFilterAutoCollapseAutoMod])
      node[@"isInitiallyCollapsed"] = @YES;
  }
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response,
                                                        NSError *error))completionHandler {
  if (![request.URL.host hasPrefix:@"gql"] && 
      ![request.URL.host hasPrefix:@"oauth"])
    return %orig;
    
  void (^newCompletionHandler)(NSData *, NSURLResponse *, NSError *) =
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return completionHandler(data, response, error);
        
        NSError *jsonError = nil;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:data
                                                        options:NSJSONReadingMutableContainers
                                                          error:&jsonError];
                                                          
        if (jsonError || !jsonObject || ![jsonObject isKindOfClass:NSDictionary.class]) {
            return completionHandler(data, response, error);
        }

        NSMutableDictionary *json = (NSMutableDictionary *)jsonObject;
        
        // Identify the GraphQL Operation
        NSString *operationName = @"Unknown";
        if (request.HTTPBody) {
            NSDictionary *bodyJson = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
            if (bodyJson[@"id"]) operationName = bodyJson[@"id"];
            else if (bodyJson[@"operationName"]) operationName = bodyJson[@"operationName"];
        } else if ([request.URL.query containsString:@"operationName="]) {
            NSArray *components = [request.URL.query componentsSeparatedByString:@"&"];
            for (NSString *param in components) {
                if ([param hasPrefix:@"operationName="]) {
                    operationName = [param substringFromIndex:14];
                    break;
                }
            }
        }

        // Fast Path by known schemas
        if ([operationName isEqualToString:@"HomeFeedSdui"]) {
            if ([json valueForKeyPath:@"data.homeV3.elements.edges"]) {
                for (NSMutableDictionary *edge in json[@"data"][@"homeV3"][@"elements"][@"edges"]) {
                    filterNode(edge[@"node"]);
                }
            }
        } else if ([operationName isEqualToString:@"PopularFeedSdui"]) {
            // NEW: Fast path for Recommended and Promoted posts in the Popular feed
            if ([json valueForKeyPath:@"data.popularV3.elements.edges"]) {
                for (NSMutableDictionary *edge in json[@"data"][@"popularV3"][@"elements"][@"edges"]) {
                    filterNode(edge[@"node"]);
                }
            }
        } else if ([operationName isEqualToString:@"FeedPostDetailsByIds"]) {
            if ([json valueForKeyPath:@"data.postsInfoByIds"]) {
                for (NSMutableDictionary *node in json[@"data"][@"postsInfoByIds"]) {
                    filterNode(node);
                }
            }
        } else if ([operationName isEqualToString:@"PostInfoByIdComments"] || [operationName isEqualToString:@"PostInfoById"]) {
            // This path automatically handles AutoMod, Awards, and NSFW inside comments
            if ([json valueForKeyPath:@"data.postInfoById.commentForest.trees"]) {
                for (NSMutableDictionary *tree in json[@"data"][@"postInfoById"][@"commentForest"][@"trees"]) {
                    filterNode(tree[@"node"]);
                }
            }
            if ([json valueForKeyPath:@"data.postInfoById"]) {
                filterNode(json[@"data"][@"postInfoById"]);
            }
        } else {
            // Original recursive logic for unknown queries fallback
            if (json[@"data"] && [json[@"data"] isKindOfClass:NSDictionary.class]) {
                NSDictionary *dataDict = json[@"data"];
                NSMutableDictionary *root = dataDict.allValues.firstObject;
                
                if ([root isKindOfClass:NSDictionary.class]) {
                  if ([root.allValues.firstObject isKindOfClass:NSDictionary.class] &&
                      root.allValues.firstObject[@"edges"])
                    for (NSMutableDictionary *edge in root.allValues.firstObject[@"edges"])
                      filterNode(edge[@"node"]);
                  
                  if (root[@"commentForest"])
                    for (NSMutableDictionary *tree in root[@"commentForest"][@"trees"])
                      filterNode(tree[@"node"]);
                  
                  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                  BOOL filterPromoted = [defaults boolForKey:kRedditFilterPromoted];
                  
                  if (root[@"commentsPageAds"] && filterPromoted)
                    root[@"commentsPageAds"] = @[];
                  
                  if (root[@"commentTreeAds"] && filterPromoted)
                    root[@"commentTreeAds"] = @[];
                  
                  if (root[@"pdpCommentsAds"] && filterPromoted)
                    root[@"pdpCommentsAds"] = @[];
                  
                  if (root[@"recommendations"] && [defaults boolForKey:kRedditFilterRecommended])
                    root[@"recommendations"] = @[];
                } else if ([root isKindOfClass:NSArray.class]) {
                  for (NSMutableDictionary *node in (NSArray *)root) filterNode(node);
                }
            }
        }
        
        NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        completionHandler(modifiedData ?: data, response, error);
      };
  return %orig(request, newCompletionHandler);
}
%end

// Only necessary for older app versions
%group Legacy

%hook Listing
- (void)fetchNextPage:(id (^)(NSArray *, id))completionHandler {
  id (^newCompletionHandler)(NSArray *, id) = ^(NSArray *objects, id _) {
    return completionHandler(filteredObjects(objects), _);
  };
  return %orig(newCompletionHandler);
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

%hook Carousel
- (BOOL)isHiddenByUserWithAccountSettings:(id)accountSettings {
  return ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended] &&
          ([self.analyticType containsString:@"recommended"] ||
           [self.analyticType containsString:@"similar"] ||
           [self.analyticType containsString:@"popular"])) || %orig;
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
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAutoCollapseAutoMod] &&
                 [((Comment *)self).authorPk isEqualToString:@"t2_6l4z3"]
             ? YES
             : %orig;
}
%end

%hook ToggleImageTableViewCell
- (void)updateConstraints {
    %orig;

    // Fix: Prevent adding duplicate constraints if updateConstraints is called multiple times.
    // Use an associated object to track if we've already done this.
    NSNumber *constraintsAdded = objc_getAssociatedObject(self, @selector(updateConstraints));
    if (constraintsAdded.boolValue) return;

    UIStackView *horizontalStackView = [self respondsToSelector:@selector(imageLabelView)]
          ? [self imageLabelView].horizontalStackView
          : object_getIvar(self, class_getInstanceVariable(object_getClass(self), "horizontalStackView"));
          
    UILabel *detailLabel = [self respondsToSelector:@selector(imageLabelView)]
                             ? [self imageLabelView].detailLabel
                             : [self detailLabel];

    if (!horizontalStackView || !detailLabel) return;
  
    if (detailLabel.text) {
        UIView *contentView = [self contentView];
        [contentView addConstraints:@[
            [NSLayoutConstraint constraintWithItem:detailLabel
                                         attribute:NSLayoutAttributeHeight
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:horizontalStackView
                                         attribute:NSLayoutAttributeHeight
                                        multiplier:.33
                                          constant:0],
            [NSLayoutConstraint constraintWithItem:horizontalStackView
                                         attribute:NSLayoutAttributeHeight
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:contentView
                                         attribute:NSLayoutAttributeHeight
                                        multiplier:1
                                          constant:0],
            [NSLayoutConstraint constraintWithItem:horizontalStackView
                                         attribute:NSLayoutAttributeCenterY
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:contentView
                                         attribute:NSLayoutAttributeCenterY
                                        multiplier:1
                                          constant:0]
        ]];
        
        // Mark as added
        objc_setAssociatedObject(self, @selector(updateConstraints), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
%end

%end

%ctor {
  // Initialize caches
  imageCache = [[NSCache alloc] init];
  stringCache = [[NSCache alloc] init];

  assetBundles = [NSMutableArray array];
  assetCatalogs = [NSMutableArray array];
  [assetBundles addObject:NSBundle.mainBundle];
  
  for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSBundle.mainBundle.bundlePath error:nil]) {
    if (![file hasSuffix:@"bundle"]) continue;
    NSBundle *bundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:[file stringByDeletingPathExtension] ofType:@"bundle"]];
    if (bundle) [assetBundles addObject:bundle];
  }
  
  for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"] error:nil]) {
    if (![file hasSuffix:@"framework"]) continue;

    NSString *frameworkPath = [NSBundle.mainBundle pathForResource:[file stringByDeletingPathExtension] ofType:@"framework" inDirectory:@"Frameworks"];
    NSBundle *bundle = [NSBundle bundleWithPath:frameworkPath];
    if (bundle) [assetBundles addObject:bundle];

    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworkPath error:nil]) {
      if (![file hasSuffix:@"bundle"]) continue;

      NSBundle *bundle = [NSBundle bundleWithPath:[frameworkPath stringByAppendingPathComponent:file]];
      if (bundle) [assetBundles addObject:bundle];
    }
  }
  
  for (NSBundle *bundle in assetBundles) {
    NSError *error;
    CUICatalog *catalog = [[%c(CUICatalog) alloc] initWithName:@"Assets" fromBundle:bundle error:&error];
    if (!error) [assetCatalogs addObject:catalog];
  }
  
  // Fix: Correct keys used for default values. Previously all checks were for kRedditFilterPromoted.
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  
  if (![defaults objectForKey:kRedditFilterPromoted])
    [defaults setBool:true forKey:kRedditFilterPromoted];
    
  if (![defaults objectForKey:kRedditFilterRecommended])
    [defaults setBool:false forKey:kRedditFilterRecommended];
    
  if (![defaults objectForKey:kRedditFilterNSFW])
    [defaults setBool:false forKey:kRedditFilterNSFW];
    
  if (![defaults objectForKey:kRedditFilterAwards])
    [defaults setBool:false forKey:kRedditFilterAwards];
    
  if (![defaults objectForKey:kRedditFilterScores])
    [defaults setBool:false forKey:kRedditFilterScores];
    
  if (![defaults objectForKey:kRedditFilterAutoCollapseAutoMod])
    [defaults setBool:false forKey:kRedditFilterAutoCollapseAutoMod];
    
  %init;
  %init(Legacy, Comment = CoreClass(@"Comment"), Post = CoreClass(@"Post"),
                   QuickActionViewModel = CoreClass(@"QuickActionViewModel"),
                   ToggleImageTableViewCell = CoreClass(@"ToggleImageTableViewCell"));
}
