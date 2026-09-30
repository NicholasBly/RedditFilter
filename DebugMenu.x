// DebugMenu.x
//
// Implementation of RFSchemaDebug. The entire file is compiled out when
// REDDITFILTER_DEBUG is 0, so nothing here ships in a release build.

#import "DebugMenu.h"

#if REDDITFILTER_DEBUG

NSString *const kRFDebugOp = @"op";
NSString *const kRFDebugExpected = @"expected";
NSString *const kRFDebugHits = @"hits";
NSString *const kRFDebugMisses = @"misses";
NSString *const kRFDebugDiscovered = @"discovered";
NSString *const kRFDebugLastResolved = @"lastResolved";
NSString *const kRFDebugSeen = @"seen";
NSString *const kRFDebugFailedJSON = @"failedJSON";

// Bounds for discovery so a broken path can never turn into an expensive walk
// on every response.
static const NSInteger kRFMaxVisited = 6000; // total nodes inspected
static const NSInteger kRFMaxDepth = 9;      // key-path depth
static const NSUInteger kRFMaxArrayProbe = 6; // array elements descended into

@implementation RFSchemaDebug {
  dispatch_queue_t _queue;             // serializes all access to the stores
  NSMutableArray<NSString *> *_order;  // operation names, in display order
  NSMutableDictionary<NSString *, NSMutableDictionary *> *_records;
}

+ (instancetype)shared {
  static RFSchemaDebug *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[RFSchemaDebug alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("com.level3tjg.redditfilter.schemadebug", DISPATCH_QUEUE_SERIAL);
    _order = [NSMutableArray array];
    _records = [NSMutableDictionary dictionary];

    // Seed the known operations so the menu lists every path up front, even
    // before any matching traffic has been observed. Keep these in sync with
    // the hardcoded paths in JSONFilter.m.
    [self seedOperation:@"HomeFeedSdui" expected:@"data.homeV3.elements.edges"];
    [self seedOperation:@"PopularFeedSdui" expected:@"data.popularV3.elements.edges"];
    [self seedOperation:@"FeedPostDetailsByIds" expected:@"data.postsInfoByIds"];
    [self seedOperation:@"PostInfoById" expected:@"data.postInfoById.commentForest.trees"];
    [self seedOperation:@"PdpCommentsAds" expected:@"data.*.pdpCommentsAds"];
  }
  return self;
}

// Caller must be on _queue (or constructing, as in init where there is no
// contention yet).
- (void)seedOperation:(NSString *)op expected:(NSString *)expected {
  if (_records[op]) {
    _records[op][kRFDebugExpected] = expected;
    return;
  }
  [_order addObject:op];
  _records[op] = [@{
    kRFDebugOp : op,
    kRFDebugExpected : expected,
    kRFDebugHits : @0,
    kRFDebugMisses : @0,
    kRFDebugLastResolved : @NO,
    kRFDebugSeen : @NO,
  } mutableCopy];
}

- (void)recordOperation:(NSString *)operation
           expectedPath:(NSString *)expectedPath
               resolved:(BOOL)resolved
                   json:(id)json
              signature:(RFSchemaSig)signature {
  if (operation.length == 0) return;

  __block BOOL needsDiscovery = NO;
  dispatch_sync(_queue, ^{
    NSMutableDictionary *record = _records[operation];
    if (record) {
        // 1. Update the stats so it no longer says "untested"
        record[kRFDebugSeen] = @YES;
        record[kRFDebugLastResolved] = @(resolved);
        
        if (resolved) {
            record[kRFDebugHits] = @([record[kRFDebugHits] integerValue] + 1);
        } else {
            record[kRFDebugMisses] = @([record[kRFDebugMisses] integerValue] + 1);
            // If it missed and we haven't discovered a new path yet, arm discovery
            if (!record[kRFDebugDiscovered]) {
                needsDiscovery = YES;
            }
        }
    }
  });

  if (!needsDiscovery) return;

  // 2. Run the actual discovery process outside the lock
  NSString *discovered = [[self class] discoverPathForSignature:signature in:json];
  
  dispatch_sync(_queue, ^{
    NSMutableDictionary *record = _records[operation];
    // Re-check: another thread may have filled it in the meantime.
    if (record && !record[kRFDebugDiscovered]) {
      if (discovered.length) {
        record[kRFDebugDiscovered] = discovered;
      } else {
        // 3. If discovery failed, capture the raw JSON so you can inspect it
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (jsonData) {
            record[kRFDebugFailedJSON] = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
      }
    }
  });
}

- (NSArray<NSDictionary *> *)snapshot {
  __block NSArray *result;
  dispatch_sync(_queue, ^{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_order.count];
    for (NSString *op in _order) {
      // Deep-ish copy: the values are immutable, so a shallow copy is a safe
      // immutable snapshot for the UI to read on the main thread.
      [out addObject:[_records[op] copy]];
    }
    result = out;
  });
  return result;
}

- (void)reset {
  dispatch_sync(_queue, ^{
    for (NSString *op in _order) {
      NSMutableDictionary *record = _records[op];
      record[kRFDebugHits] = @0;
      record[kRFDebugMisses] = @0;
      record[kRFDebugLastResolved] = @NO;
      record[kRFDebugSeen] = @NO;
      [record removeObjectForKey:kRFDebugDiscovered];
	  [record removeObjectForKey:kRFDebugFailedJSON];
    }
  });
}

#pragma mark - Discovery

// Returns YES if `value` matches the shape described by `signature`.
+ (BOOL)value:(id)value matchesSignature:(RFSchemaSig)signature {
  switch (signature) {
    case RFSchemaSigEdges:
    case RFSchemaSigTrees: {
      if (![value isKindOfClass:NSArray.class]) return NO;
      for (id element in (NSArray *)value) {
        if (![element isKindOfClass:NSDictionary.class]) continue;
        if (((NSDictionary *)element)[@"node"]) return YES;
      }
      return NO;
    }
    case RFSchemaSigNodeArray: {
      if (![value isKindOfClass:NSArray.class]) return NO;
      for (id element in (NSArray *)value) {
        if (![element isKindOfClass:NSDictionary.class]) continue;
        if (((NSDictionary *)element)[@"__typename"]) return YES;
      }
      return NO;
    }
    case RFSchemaSigCommentsAds:
      return [value isKindOfClass:NSArray.class];
  }
  return NO;
}

// The key that breakages most commonly leave intact (only the ancestors get
// renamed). Discovery prefers a key match so the suggested path stays a clean,
// index-free, drop-in replacement.
+ (NSString *)preferredKeyForSignature:(RFSchemaSig)signature {
  switch (signature) {
    case RFSchemaSigEdges:       return @"edges";
    case RFSchemaSigTrees:       return @"trees";
    case RFSchemaSigNodeArray:   return @"postsInfoByIds";
    case RFSchemaSigCommentsAds: return @"pdpCommentsAds";
  }
  return nil;
}

+ (NSString *)discoverPathForSignature:(RFSchemaSig)signature in:(id)json {
  if (![json isKindOfClass:NSDictionary.class] && ![json isKindOfClass:NSArray.class]) {
    return nil;
  }
  NSString *preferredKey = [self preferredKeyForSignature:signature];

  // First try to locate the data by its (stable) key, validating the value
  // against the expected shape. This is the common ancestor-rename case.
  if (preferredKey) {
    NSString *byKey = [self breadthFirstPathIn:json
                                       testing:^BOOL(NSString *key, id value) {
                                         return [key isEqualToString:preferredKey] &&
                                                [self value:value matchesSignature:signature];
                                       }];
    if (byKey) return byKey;
  }

  // Fall back to a purely structural search (the key itself was renamed).
  return [self breadthFirstPathIn:json
                          testing:^BOOL(NSString *key, id value) {
                            return [self value:value matchesSignature:signature];
                          }];
}

// Breadth-first walk that returns the shallowest key path whose (key, value)
// satisfies `test`. Dict children are addressed as `.key`; array elements as
// `[i]`. Because the search returns as soon as a matching *container* is
// dequeued, the resulting path points at that container and contains no array
// indices (making it a valid -valueForKeyPath: replacement).
+ (NSString *)breadthFirstPathIn:(id)root testing:(BOOL (^)(NSString *key, id value))test {
  // Each queue entry: @[ key-or-NSNull, value, pathString ].
  NSMutableArray *queue = [NSMutableArray array];
  [queue addObject:@[ [NSNull null], root, @"" ]];
  NSInteger visited = 0;

  while (queue.count) {
    NSArray *entry = queue.firstObject;
    [queue removeObjectAtIndex:0];
    id key = entry[0];
    id value = entry[1];
    NSString *path = entry[2];

    if (++visited > kRFMaxVisited) break;

    // Skip the synthetic root entry; only test real (key, value) pairs.
    if (path.length && test([key isKindOfClass:NSString.class] ? key : @"", value)) {
      return path;
    }

    if (path.length && [self depthOfPath:path] >= kRFMaxDepth) continue;

    if ([value isKindOfClass:NSDictionary.class]) {
      [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id childKey, id childValue, BOOL *stop) {
        if (![childKey isKindOfClass:NSString.class]) return;
        NSString *childPath = path.length
                                  ? [NSString stringWithFormat:@"%@.%@", path, childKey]
                                  : (NSString *)childKey;
        [queue addObject:@[ childKey, childValue ?: [NSNull null], childPath ]];
      }];
    } else if ([value isKindOfClass:NSArray.class]) {
      NSArray *array = (NSArray *)value;
      NSUInteger limit = MIN(array.count, kRFMaxArrayProbe);
      for (NSUInteger i = 0; i < limit; i++) {
        NSString *childPath = [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)i];
        [queue addObject:@[ [NSNull null], array[i] ?: [NSNull null], childPath ]];
      }
    }
  }
  return nil;
}

+ (NSInteger)depthOfPath:(NSString *)path {
  if (path.length == 0) return 0;
  NSInteger depth = 1;
  NSUInteger length = path.length;
  for (NSUInteger i = 0; i < length; i++) {
    unichar c = [path characterAtIndex:i];
    if (c == '.' || c == '[') depth++;
  }
  return depth;
}

@end

#endif // REDDITFILTER_DEBUG
