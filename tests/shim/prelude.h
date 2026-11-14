// Included before every test translation unit (Linux/GNUstep only).
#import <Foundation/Foundation.h>
// GCC's objc.h defines YES as "(BOOL)1", which breaks @YES boxing under clang.
#undef YES
#undef NO
#define YES __objc_yes
#define NO __objc_no
