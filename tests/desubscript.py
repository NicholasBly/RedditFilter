#!/usr/bin/env python3
"""Rewrite ObjC dictionary subscripting for compilers/runtimes that lack it.

    base[@"k"] = v;   ->  [base setObject:(v) forKey:@"k"];
    base[@"k"]        ->  [base objectForKey:@"k"]

Only subscripts whose key starts with a string literal (@"...") are touched,
so C arrays (kFastPaths[i]) are left alone. Used only to build the Linux unit
tests against GNUstep; the shipping iOS build compiles the original source.
"""
import re
import sys

IDENT = re.compile(r"[A-Za-z0-9_]")
INT_SUBSCRIPTS = "--int" in sys.argv  # also rewrite arr[0]; only safe for code with no C arrays indexed by literals


def skip_string(s, i):
    """i at opening quote; return index after closing quote."""
    q = s[i]
    i += 1
    while i < len(s):
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == q:
            return i + 1
        i += 1
    return i


def match_close(s, i):
    """i at '[' or '(' ; return index of matching close."""
    pairs = {"[": "]", "(": ")", "{": "}"}
    stack = [pairs[s[i]]]
    j = i + 1
    while j < len(s):
        c = s[j]
        if c in "\"'":
            j = skip_string(s, j)
            continue
        if c in pairs:
            stack.append(pairs[c])
        elif stack and c == stack[-1]:
            stack.pop()
            if not stack:
                return j
        j += 1
    raise ValueError("unbalanced")


def base_start(s, i):
    """i = index of '[' of a subscript; walk back over the postfix base expr."""
    j = i - 1
    while j >= 0:
        c = s[j]
        if c in ")]":
            # find matching open going backwards
            close, open_ = c, "(" if c == ")" else "["
            depth = 0
            while j >= 0:
                if s[j] == close:
                    depth += 1
                elif s[j] == open_:
                    depth -= 1
                    if depth == 0:
                        break
                j -= 1
            j -= 1
            continue
        if IDENT.match(c):
            while j >= 0 and IDENT.match(s[j]):
                j -= 1
            continue
        if c == "." or (c == ">" and j > 0 and s[j - 1] == "-"):
            j -= 2 if c == ">" else 1
            continue
        break
    return j + 1


def convert_once(s):
    i = 0
    while i < len(s):
        c = s[i]
        if c in "\"'":
            i = skip_string(s, i)
            continue
        if c == "/" and s[i:i + 2] == "//":
            i = s.find("\n", i)
            if i < 0:
                return s, False
            continue
        if c == "/" and s[i:i + 2] == "/*":
            i = s.find("*/", i) + 2
            continue
        int_sub = INT_SUBSCRIPTS and c == "[" and i > 0 and (IDENT.match(s[i - 1]) or s[i - 1] in ")]") \
            and re.match(r"\[\d+\]", s[i:])
        if int_sub:
            close = s.index("]", i)
            start = base_start(s, i)
            return s[:start] + f"[{s[start:i]} objectAtIndex:{s[i + 1:close]}]" + s[close + 1:], True
        if c == "[" and i > 0 and (IDENT.match(s[i - 1]) or s[i - 1] in ")]") and s[i + 1:i + 3] == '@"':
            close = match_close(s, i)
            key = s[i + 1:close]
            # innermost first: if the key itself has subscripts, convert later passes
            start = base_start(s, i)
            base = s[start:i]
            rest = s[close + 1:]
            m = re.match(r"\s*=(?!=)", rest)
            if m:
                semi = close + 1 + m.end()
                # value runs to the ';' at depth 0
                j = semi
                depth = 0
                while j < len(s):
                    ch = s[j]
                    if ch in "\"'":
                        j = skip_string(s, j)
                        continue
                    if ch in "([{":
                        depth += 1
                    elif ch in ")]}":
                        depth -= 1
                    elif ch == ";" and depth == 0:
                        break
                    j += 1
                value = s[semi:j].strip()
                new = f"[{base} setObject:({value}) forKey:{key}]"
                return s[:start] + new + s[j:], True
            new = f"[{base} objectForKey:{key}]"
            return s[:start] + new + s[close + 1:], True
        i += 1
    return s, False


def convert(s):
    changed = True
    while changed:
        s, changed = convert_once(s)
    return s


if __name__ == "__main__":
    path = [a for a in sys.argv[1:] if not a.startswith("--")][0]
    sys.stdout.write(convert(open(path).read()))
