// Minimal single-threaded stand-in for libdispatch, for the Linux unit tests only.
#pragma once
typedef long dispatch_once_t;
static inline void dispatch_once(dispatch_once_t *pred, void (^block)(void)) {
  if (!*pred) { *pred = 1; block(); }
}
