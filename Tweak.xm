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
static NSSet<NSString *> *ignoredOperationsSet;

typedef struct {
    BOOL promoted;
    BOOL recommended;
    BOOL nsfw;
    BOOL awards;
    BOOL scores;
    BOOL automod;
} RedditFilterPrefs;

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
                
                // SAFELY retrieve the private _bundle ivar
                Ivar bundleIvar = class_getInstanceVariable(object_getClass(catalog), "_bundle");
                if (!bundleIvar) continue;
                
                NSBundle *bundle = object_getIvar(catalog, bundleIvar);
                if (!bundle) continue;

                UIImage *image = [UIImage imageNamed:imageName
                                            inBundle:bundle
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

static void filterNode(NSMutableDictionary *node, RedditFilterPrefs prefs) {
    if (![node isKindOfClass:NSMutableDictionary.class]) return;

    // Fetch typeName once and ensure it is a valid string to prevent unrecognized selector crashes
    NSString *typeName = node[@"__typename"];
    if (![typeName isKindOfClass:NSString.class]) return;

    if ([typeName isEqualToString:@"SubredditPost"]) {
        if (prefs.awards) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
        }
        if (prefs.scores) node[@"isScoreHidden"] = @YES;
        if (prefs.nsfw && [node[@"isNsfw"] boolValue]) node[@"isHidden"] = @YES;
    } 
    else if ([typeName isEqualToString:@"Comment"]) {
        if (prefs.awards) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
        }
        if (prefs.scores) node[@"isScoreHidden"] = @YES;
        
        if (prefs.automod) {
            NSDictionary *authorInfo = node[@"authorInfo"];
            if ([authorInfo isKindOfClass:NSDictionary.class] && [authorInfo[@"id"] isEqualToString:@"t2_6l4z3"]) {
                node[@"isInitiallyCollapsed"] = @YES;
            }
        }
    }
    else if ([typeName isEqualToString:@"CellGroup"]) {
        // 1. Check Promoted (AdPayloads)
        if (prefs.promoted && [node[@"adPayload"] isKindOfClass:NSDictionary.class]) {
            node[@"cells"] = @[];
            node[@"RedditFilter_ShouldRemove"] = @YES;
            return; // Exit early if we cleared the cells
        }

        // 2. Check Recommended
        if (prefs.recommended && [node[@"recommendationContext"] isKindOfClass:NSDictionary.class]) {
            NSDictionary *recContext = node[@"recommendationContext"];
            id recTypeName = recContext[@"typeName"];
            id typeIdentifier = recContext[@"typeIdentifier"];
            id isContextHidden = recContext[@"isContextHidden"];
            
            if ([recTypeName isKindOfClass:NSString.class] && 
                [typeIdentifier isKindOfClass:NSString.class] && 
                [isContextHidden isKindOfClass:NSNumber.class]) {
                
                if (!(([recTypeName isEqualToString:@"PopularRecommendationContext"] ||
                       [typeIdentifier hasPrefix:@"global_popular"]) &&
                      [isContextHidden boolValue])) {
                    node[@"cells"] = @[];
                    node[@"RedditFilter_ShouldRemove"] = @YES;
                    return;
                }
            }
        }

        // 3. Process remaining ActionCells ONLY if Awards or Scores filters are enabled
        if (prefs.awards || prefs.scores) {
            NSMutableArray *cells = node[@"cells"];
            if ([cells isKindOfClass:NSMutableArray.class]) {
                for (NSMutableDictionary *cell in cells) {
                    if (![cell isKindOfClass:NSMutableDictionary.class]) continue;
                    
                    if ([cell[@"__typename"] isEqualToString:@"ActionCell"]) {
                        if (prefs.awards) {
                            cell[@"isAwardHidden"] = @YES;
                            id goldenInfo = cell[@"goldenUpvoteInfo"];
                            if ([goldenInfo isKindOfClass:NSMutableDictionary.class]) {
                                ((NSMutableDictionary *)goldenInfo)[@"isGildable"] = @NO;
                            }
                        }
                        if (prefs.scores) cell[@"isScoreHidden"] = @YES;
                    }
                }
            }
        }
    }
    else if ([typeName isEqualToString:@"AdPost"]) {
        if (prefs.promoted) node[@"isHidden"] = @YES;
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

        // Load preferences once per network request
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        RedditFilterPrefs prefs = {
            [defaults boolForKey:kRedditFilterPromoted],
            [defaults boolForKey:kRedditFilterRecommended],
            [defaults boolForKey:kRedditFilterNSFW],
            [defaults boolForKey:kRedditFilterAwards],
            [defaults boolForKey:kRedditFilterScores],
            [defaults boolForKey:kRedditFilterAutoCollapseAutoMod]
        };

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

        // Ignore Telemetry & Configs (Performance Saver)
        if ([ignoredOperationsSet containsObject:operationName]) {
            return completionHandler(data, response, error);
        }

        // Fast Path based on known schemas
        if ([operationName isEqualToString:@"HomeFeedSdui"]) {
            if ([json valueForKeyPath:@"data.homeV3.elements.edges"]) {
                NSMutableArray *edges = json[@"data"][@"homeV3"][@"elements"][@"edges"];
                for (NSInteger i = edges.count - 1; i >= 0; i--) {
                    NSMutableDictionary *edge = edges[i];
                    filterNode(edge[@"node"], prefs);
                    if (edge[@"node"][@"RedditFilter_ShouldRemove"]) {
                        [edges removeObjectAtIndex:i];
                    }
                }
            }
        } else if ([operationName isEqualToString:@"PopularFeedSdui"]) {
            if ([json valueForKeyPath:@"data.popularV3.elements.edges"]) {
                NSMutableArray *edges = json[@"data"][@"popularV3"][@"elements"][@"edges"];
                for (NSInteger i = edges.count - 1; i >= 0; i--) {
                    NSMutableDictionary *edge = edges[i];
                    filterNode(edge[@"node"], prefs);
                    if (edge[@"node"][@"RedditFilter_ShouldRemove"]) {
                        [edges removeObjectAtIndex:i];
                    }
                }
            }
        } else if ([operationName isEqualToString:@"FeedPostDetailsByIds"]) {
            if ([json valueForKeyPath:@"data.postsInfoByIds"]) {
                for (NSMutableDictionary *node in json[@"data"][@"postsInfoByIds"]) {
                    filterNode(node, prefs);
                }
            }
        } else if ([operationName isEqualToString:@"PostInfoByIdComments"] || [operationName isEqualToString:@"PostInfoById"]) {
            if ([json valueForKeyPath:@"data.postInfoById.commentForest.trees"]) {
                for (NSMutableDictionary *tree in json[@"data"][@"postInfoById"][@"commentForest"][@"trees"]) {
                    filterNode(tree[@"node"], prefs);
                }
            }
            if ([json valueForKeyPath:@"data.postInfoById"]) {
                filterNode(json[@"data"][@"postInfoById"], prefs);
            }
        } else if ([operationName isEqualToString:@"PdpCommentsAds"]) {
            // Instantly clear out Comment Ads
            if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted]) {
                if (json[@"data"] && [json[@"data"] isKindOfClass:NSDictionary.class]) {
                    NSMutableDictionary *dataDict = json[@"data"];
                    if (dataDict.allValues.firstObject[@"pdpCommentsAds"]) {
                        dataDict.allValues.firstObject[@"pdpCommentsAds"] = @[];
                    }
                }
            }
        } else {
            // Original recursive logic for unknown queries (like ProfileFeedSdui)
            if (json[@"data"] && [json[@"data"] isKindOfClass:NSDictionary.class]) {
                NSDictionary *dataDict = json[@"data"];
                NSMutableDictionary *root = dataDict.allValues.firstObject;
                
                if ([root isKindOfClass:NSDictionary.class]) {
                  if ([root.allValues.firstObject isKindOfClass:NSDictionary.class] &&
                      root.allValues.firstObject[@"edges"]) {
                    NSMutableArray *edges = root.allValues.firstObject[@"edges"];
                    for (NSInteger i = edges.count - 1; i >= 0; i--) {
                        NSMutableDictionary *edge = edges[i];
                        filterNode(edge[@"node"], prefs);
                        if (edge[@"node"][@"RedditFilter_ShouldRemove"]) {
                            [edges removeObjectAtIndex:i];
                        }
                    }
                  }
                      
                  if (root[@"commentForest"])
                    for (NSMutableDictionary *tree in root[@"commentForest"][@"trees"])
                      filterNode(tree[@"node"], prefs);
                      
                  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                  BOOL filterPromoted = [defaults boolForKey:kRedditFilterPromoted];
                  
                  if (root[@"commentsPageAds"] && filterPromoted)
                    root[@"commentsPageAds"] = @[];
                    
                  if (root[@"commentTreeAds"] && filterPromoted)
                    root[@"commentTreeAds"] = @[];
                    
                  if (root[@"pdpCommentsAds"] && filterPromoted) // Kept just in case the fast path misses
                    root[@"pdpCommentsAds"] = @[];
                    
                  if (root[@"recommendations"] && [defaults boolForKey:kRedditFilterRecommended])
                    root[@"recommendations"] = @[];
                } else if ([root isKindOfClass:NSArray.class]) {
                  for (NSMutableDictionary *node in (NSArray *)root) filterNode(node, prefs);
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

// Create a static key for associated objects
static char kConstraintsAddedKey;

%hook ToggleImageTableViewCell
- (void)updateConstraints {
    %orig;

    // Prevent adding duplicate constraints if updateConstraints is called multiple times.
    NSNumber *constraintsAdded = objc_getAssociatedObject(self, &kConstraintsAddedKey);
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
        objc_setAssociatedObject(self, &kConstraintsAddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
%end

%end

%ctor {
  // Initialize caches
  imageCache = [[NSCache alloc] init];
  stringCache = [[NSCache alloc] init];

  // Initialize Ignored Operations Set
  ignoredOperationsSet = [[NSSet alloc] initWithObjects:
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
  
  // Correct keys used for default values. Previously all checks were for kRedditFilterPromoted.
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
