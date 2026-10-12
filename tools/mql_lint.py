#!/usr/bin/env python3
"""A small structural linter for the MQL5 sources.

There is no MetaEditor in CI, so this catches the class of mistakes that
cost the most time when compiling by hand:

* includes that point at files that do not exist
* unbalanced braces / parentheses (ignoring comments and string literals)
* a method declared in a class but never defined (or defined but never declared)
* a class method that writes to a member inside a `const` method

It is not a compiler. It is a smoke alarm.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MQL5 = os.path.join(ROOT, "mql5")

KEYWORDS = {
    "if", "for", "while", "switch", "return", "else", "do", "sizeof", "catch",
    "new", "delete", "break", "continue", "case", "struct", "class", "enum",
    "const", "static", "void", "int", "double", "string", "bool", "color",
    "datetime", "long", "ulong", "uint", "short", "char", "float", "uchar",
    "ushort", "template", "typename", "virtual", "operator", "true", "false",
}


def strip_code(text: str) -> str:
    """Remove comments and string/char literals, keep everything else."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif two == "/*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif text[i] == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif text[i] == "'":
            i += 1
            while i < n and text[i] != "'":
                i += 2 if text[i] == "\\" else 1
            i += 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def check_balance(path: str, code: str) -> list[str]:
    errs = []
    for open_c, close_c in (("{", "}"), ("(", ")")):
        if code.count(open_c) != code.count(close_c):
            errs.append(f"{path}: unbalanced {open_c}{close_c} "
                        f"({code.count(open_c)} vs {code.count(close_c)})")
    return errs


def check_includes(path: str, code: str) -> list[str]:
    errs = []
    base = os.path.dirname(path)
    for inc in re.findall(r'#include\s+[<"]([^>"]+)[>"]', code):
        inc = inc.replace("\\", "/")
        if not inc.startswith("Autotrader"):
            continue   # MT5 standard library (Trade/, Controls/, ...)
        candidates = [
            os.path.join(MQL5, "Include", inc),
            os.path.join(os.path.dirname(path), inc),
        ]
        if not any(os.path.exists(c) for c in candidates):
            errs.append(f"{path}: include not found: {inc}")
    return errs


def check_class_methods(path: str, code: str) -> list[str]:
    """Every `RetType Name(args) const?;` in a class needs a `Class::Name`."""
    errs = []
    for m in re.finditer(r"class\s+(\w+)\s*(?::\s*public\s+\w+)?\s*\{", code):
        cls = m.group(1)
        start = m.end() - 1
        depth = 0
        end = start
        for i in range(start, len(code)):
            if code[i] == "{":
                depth += 1
            elif code[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        # keep only the text at class scope: anything inside a nested
        # brace block (an inline method body, an if, ...) is dropped
        body_top, depth = [], 0
        for ch in code[start + 1:end]:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            elif depth == 0:
                body_top.append(ch)
        body_top = "".join(body_top)
        for sig in re.finditer(
                r"^[ \t]+(?:const\s+)?[\w:<>]+\s*[&*]?\s*(\w+)\s*\([^;{)]*\)\s*(?:const)?\s*;",
                body_top, flags=re.M):
            name = sig.group(1)
            if name in KEYWORDS or name in ("return", "Print", "PrintFormat"):
                continue
            if f"{cls}::{name}" not in code:
                errs.append(f"{path}: {cls}::{name} declared but not defined")
    return errs


def check_const_writes(path: str, code: str) -> list[str]:
    """A `... const` method must not assign to a member."""
    errs = []
    for m in re.finditer(r"\w+\s+(\w+)::(\w+)\s*\(([^)]*)\)\s*(const)?\s*\{", code):
        cls, name, const = m.group(1), m.group(2), m.group(4)
        if not const:
            continue
        depth = 1
        i = m.end()
        while i < len(code) and depth:
            if code[i] == "{":
                depth += 1
            elif code[i] == "}":
                depth -= 1
            i += 1
        body = code[m.end():i]
        for w in re.finditer(r"\b(m_\w+)\s*(?:=[^=]|\+\+|--)", body):
            errs.append(f"{path}: {cls}::{name}() is const but writes {w.group(1)}")
    return errs


def main() -> int:
    files = []
    for base, _, names in os.walk(MQL5):
        files += [os.path.join(base, n) for n in names if n.endswith((".mq5", ".mqh"))]
    errors, checked = [], 0
    for path in sorted(files):
        raw = open(path, encoding="utf-8", errors="ignore").read()
        code = strip_code(raw)
        checked += 1
        rel = os.path.relpath(path, ROOT)
        for fn in (check_balance, check_includes, check_class_methods, check_const_writes):
            errors += [e.replace(path, rel) for e in fn(path, code)]

    print(f"mql5 files checked: {checked}")
    for e in errors:
        print("  ERROR", e)
    print("RESULT:", "PASS" if not errors else f"{len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
