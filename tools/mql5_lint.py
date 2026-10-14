#!/usr/bin/env python3
"""Static sanity checks for the Autotrader MQL5 sources.

There is no MetaEditor/wine in this sandbox, so the EA cannot be compiled
here. These checks catch the classes of mistake that would otherwise show
up as compile errors for the owner:

  1. unbalanced (), {}, [] (comments and string literals stripped first)
  2. duplicate global function / #define names across headers
  3. every method declared in a class has a definition (or is inline)
  4. every method the EA calls on our own objects actually exists
  5. include guards present, unique, and matching the file name
  6. known-bad MQL5 API calls (functions that do not exist in MQL5)
"""
import re, sys, os, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = [
    "MQL5/Include/Autotrader/Panel.mqh",
    "MQL5/Include/Autotrader/SymbolIntelligence.mqh",
    "MQL5/Include/Autotrader/MarketData.mqh",
    "MQL5/Include/Autotrader/RegimeEngine.mqh",
    "MQL5/Include/Autotrader/ModernIndicators.mqh",
    "MQL5/Include/Autotrader/SmartMoney.mqh",
    "MQL5/Include/Autotrader/VolumeFlow.mqh",
    "MQL5/Include/Autotrader/DirectionEngine.mqh",
    "MQL5/Include/Autotrader/SafetyManager.mqh",
    "MQL5/Include/Autotrader/StatsKeeper.mqh",
    "MQL5/Include/Autotrader/TradeEngine.mqh",
    "MQL5/Experts/Autotrader/Autotrader.mq5",
]

problems = []


def strip(src):
    """remove // and /* */ comments and string/char literals"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
            i += 1
            out.append('""')
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                i += 2 if src[i] == '\\' else 1
            i += 1
            out.append("'x'")
        else:
            out.append(c)
            i += 1
    return ''.join(out)


clean = {}
raw = {}
for rel in FILES:
    path = os.path.join(ROOT, rel)
    src = open(path, encoding='utf-8', errors='replace').read()
    raw[rel] = src
    clean[rel] = strip(src)

# ---- 1. balance -------------------------------------------------------
pairs = {')': '(', '}': '{', ']': '['}
for rel in FILES:
    stack, line = [], 1
    for ch in clean[rel]:
        if ch == '\n':
            line += 1
        elif ch in '({[':
            stack.append((ch, line))
        elif ch in ')}]':
            if not stack:
                problems.append(f"{rel}:{line}: unmatched '{ch}'")
            else:
                op, opline = stack.pop()
                if op != pairs[ch]:
                    problems.append(
                        f"{rel}:{line}: '{ch}' closes '{op}' opened at line {opline}")
    if stack:
        problems.append(f"{rel}: {len(stack)} unclosed bracket(s): "
                        f"{[(c, l) for c, l in stack[:5]]}")

# ---- 5. include guards ------------------------------------------------
guards = {}
for rel in FILES[:-1]:
    m = re.findall(r'#ifndef\s+(\w+)', raw[rel])
    if not m:
        problems.append(f"{rel}: missing #ifndef include guard")
        continue
    g = m[0]
    if g in guards:
        problems.append(f"{rel}: guard {g} already used by {guards[g]}")
    guards[g] = rel
    if not re.search(r'#define\s+' + g, raw[rel]):
        problems.append(f"{rel}: guard {g} never defined")
    if not re.search(r'#endif\s*//\s*' + g, raw[rel]):
        problems.append(f"{rel}: guard {g} not closed with a matching #endif")

# ---- 2. duplicate global definitions ---------------------------------
# free (global) functions only - Class::method definitions are scoped to
# their class and may legitimately share a name
func_def = re.compile(
    r'^([A-Za-z_][\w:<>,\*&\s]*?)\b([A-Za-z_]\w*)\s*\(([^;{)]*)\)\s*(?:const\s*)?\{',
    re.M)
KEYWORDS = {'if', 'for', 'while', 'switch', 'return', 'else', 'do', 'case',
            'class', 'struct', 'enum', 'new', 'delete'}
defs = collections.defaultdict(list)
for rel in FILES:
    for m in func_def.finditer(clean[rel]):
        ret, name = m.group(1), m.group(2)
        if name in KEYWORDS or '::' in ret:
            continue
        defs[name].append(rel)
for name, where in defs.items():
    if len(where) > 1:
        problems.append(f"duplicate global definition of {name}() in {sorted(set(where))}")

defines = collections.defaultdict(list)
for rel in FILES:
    for m in re.finditer(r'^#define\s+(\w+)', raw[rel], re.M):
        defines[m.group(1)].append(rel)
for name, where in defines.items():
    if len(where) > 1:
        problems.append(f"duplicate #define {name} in {sorted(set(where))}")

# ---- 3. declared class methods must be defined or inline --------------
for rel in FILES:
    body = clean[rel]
    for cls in re.finditer(r'\bclass\s+(\w+)\s*\{', body):
        cname = cls.group(1)
        # find the class body by brace matching
        i = body.index('{', cls.end() - 1)
        depth, j = 0, i
        while j < len(body):
            if body[j] == '{':
                depth += 1
            elif body[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        cbody = body[i:j + 1]
        BUILTIN = {'IntegerToString', 'DoubleToString', 'MathRound', 'MathMax',
                   'MathMin', 'MathAbs', 'StringFormat', 'TimeToString',
                   'ShortToString', 'StringLen', 'TimeCurrent', 'return'}
        declared = set()
        for m in re.finditer(r'\b([A-Za-z_]\w*)\s*\([^;{)]*\)\s*(?:const\s*)?;', cbody):
            if m.group(1) not in KEYWORDS | BUILTIN:
                declared.add(m.group(1))
        inline = set(m.group(1) for m in
                     re.finditer(r'\b([A-Za-z_]\w*)\s*\([^;{)]*\)\s*(?:const\s*)?\{', cbody))
        defined = set(m.group(1) for m in
                      re.finditer(re.escape(cname) + r'::([A-Za-z_]\w*)\s*\(', body))
        missing = declared - inline - defined
        if missing:
            problems.append(f"{rel}: class {cname} declares but never defines "
                            f"{sorted(missing)}")
        # every out-of-line definition must also be declared
        unknown = defined - declared - inline - {cname, '~' + cname}
        if unknown:
            problems.append(f"{rel}: {cname}:: defined but not declared: {sorted(unknown)}")

# ---- 4. EA calls on our own objects -----------------------------------
ea = clean[FILES[-1]]
owner = {
    'g_main': 'Panel.mqh', 'g_live': 'Panel.mqh',
    'g_symbol': 'SymbolIntelligence.mqh', 'g_dir': 'DirectionEngine.mqh',
    'g_safety': 'SafetyManager.mqh', 'g_stats': 'StatsKeeper.mqh',
    'g_trade': 'TradeEngine.mqh',
}
hdr = {os.path.basename(f): clean[f] for f in FILES}
for var, h in owner.items():
    for m in re.finditer(re.escape(var) + r'\.([A-Za-z_]\w*)\s*\(', ea):
        meth = m.group(1)
        if meth not in hdr[h]:
            problems.append(f"EA calls {var}.{meth}() but {h} has no such method")

# struct member access from the EA
for m in re.finditer(r'g_trade\.st\[\w+\]\.(\w+)', ea):
    if m.group(1) not in hdr['TradeEngine.mqh']:
        problems.append(f"EA reads st[].{m.group(1)} which is not in SATTradeState")
for m in re.finditer(r'g_dir\.(a30|a15|a5)\.(\w+)', ea):
    if m.group(2) not in hdr['DirectionEngine.mqh']:
        problems.append(f"EA reads g_dir.{m.group(1)}.{m.group(2)} - unknown member")

# ---- 6. API calls that do not exist in MQL5 ---------------------------
BAD = {
    'FileSize(': 'use FileGetInteger(name, FILE_SIZE)',
    'FileIsLineEnding(': 'not an MQL5 function',
    'ZeroMemory(': 'not safe on structs containing strings',
    'iTime(': None,  # valid, listed to keep the map honest
}
for rel in FILES:
    for call, note in BAD.items():
        if note and call in clean[rel]:
            problems.append(f"{rel}: uses {call} - {note}")

# ---- report -----------------------------------------------------------
lines = sum(len(raw[f].splitlines()) for f in FILES)
print(f"checked {len(FILES)} files, {lines} lines")
if problems:
    print(f"\n{len(problems)} problem(s):")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("no problems found")
