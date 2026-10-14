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

# ---- 0. EA preamble ---------------------------------------------------
# The EA starts with a comment banner, followed by #property directives.
# Stray un-commented text before the first directive is parsed as MQL code
# and can make every subsequent class declaration fail with cascading errors.
ea_source = raw[FILES[-1]]
property_at = ea_source.find('#property')
if property_at < 0:
    problems.append(f"{FILES[-1]}: missing #property directives")
elif strip(ea_source[:property_at]).strip():
    problems.append(f"{FILES[-1]}: unexpected code before the first #property directive")

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
    # the 14 Oct 2026 MetaEditor compile (17 errors) and what each meant:
    'ORDER_PRICE_SL': 'no such constant - the pending-order stop is ORDER_SL',
    'ORDER_PRICE_TP': 'no such constant - the pending-order target is ORDER_TP',
    'TRADE_RETCODE_TRADE_TIMEOUT': 'no such retcode - it is TRADE_RETCODE_TIMEOUT (10012)',
}
for rel in FILES:
    for call, note in BAD.items():
        if note and call in clean[rel]:
            problems.append(f"{rel}: uses {call} - {note}")

# ---- 7. every ALL-CAPS name that is used must exist -------------------
# This is the check that would have caught the 14 Oct 2026 compile: an
# ALL-CAPS name is either OURS (#define / enum type / enum member / class /
# struct / function) or an MQL5 constant. Anything else is a
# "undeclared identifier" in MetaEditor - and, when it lands in a string
# expression, the extra "implicit conversion from 'unknown' to 'string'".
#
# The tables below hold the MQL5 names this project relies on. The first
# compile of this tree with MetaEditor is the evidence for the free-form
# list (17 errors, all four names that were wrong are now in BAD above);
# the property tables were checked member by member against real MQL5
# headers. When MetaEditor accepts a new name, add it to the right table.

# --- the property enum of each built-in accessor -----------------------
# Passing a constant from the wrong family, or a name that does not exist,
# is what produces MetaEditor's "cannot convert enum" plus
# "wrong parameters count / could be one of 2 function(s)" pair.
ORD_DBL = {'ORDER_VOLUME_INITIAL', 'ORDER_VOLUME_CURRENT', 'ORDER_PRICE_OPEN',
           'ORDER_SL', 'ORDER_TP', 'ORDER_PRICE_CURRENT', 'ORDER_PRICE_STOPLIMIT'}
ORD_INT = {'ORDER_TIME_SETUP', 'ORDER_TYPE', 'ORDER_STATE',
           'ORDER_TIME_EXPIRATION', 'ORDER_TIME_DONE', 'ORDER_TIME_SETUP_MSC',
           'ORDER_TIME_DONE_MSC', 'ORDER_TICKET', 'ORDER_MAGIC', 'ORDER_REASON',
           'ORDER_POSITION_ID', 'ORDER_POSITION_BY_ID'}
ORD_STR = {'ORDER_SYMBOL', 'ORDER_COMMENT', 'ORDER_EXTERNAL_ID'}
POS_DBL = {'POSITION_VOLUME', 'POSITION_PRICE_OPEN', 'POSITION_SL', 'POSITION_TP',
           'POSITION_PRICE_CURRENT', 'POSITION_SWAP', 'POSITION_PROFIT'}
POS_INT = {'POSITION_TIME', 'POSITION_TIME_MSC', 'POSITION_TIME_UPDATE',
           'POSITION_TIME_UPDATE_MSC', 'POSITION_TYPE', 'POSITION_MAGIC',
           'POSITION_TICKET', 'POSITION_REASON', 'POSITION_IDENTIFIER'}
POS_STR = {'POSITION_SYMBOL', 'POSITION_COMMENT', 'POSITION_EXTERNAL_ID'}
DEAL_DBL = {'DEAL_VOLUME', 'DEAL_PRICE', 'DEAL_COMMISSION', 'DEAL_SWAP',
            'DEAL_PROFIT', 'DEAL_FEE'}
DEAL_INT = {'DEAL_ORDER', 'DEAL_TIME', 'DEAL_TIME_MSC', 'DEAL_TYPE',
            'DEAL_ENTRY', 'DEAL_MAGIC', 'DEAL_REASON', 'DEAL_POSITION_ID'}
DEAL_STR = {'DEAL_SYMBOL', 'DEAL_COMMENT', 'DEAL_EXTERNAL_ID'}
ACC_DBL = {'ACCOUNT_BALANCE', 'ACCOUNT_CREDIT', 'ACCOUNT_PROFIT',
           'ACCOUNT_EQUITY', 'ACCOUNT_MARGIN', 'ACCOUNT_MARGIN_FREE',
           'ACCOUNT_MARGIN_LEVEL', 'ACCOUNT_MARGIN_SO_CALL', 'ACCOUNT_MARGIN_SO_SO',
           'ACCOUNT_MARGIN_INITIAL', 'ACCOUNT_MARGIN_MAINTENANCE',
           'ACCOUNT_ASSETS', 'ACCOUNT_LIABILITIES', 'ACCOUNT_COMMISSION_BLOCKED'}
ACC_INT = {'ACCOUNT_LOGIN', 'ACCOUNT_TRADE_MODE', 'ACCOUNT_LEVERAGE',
           'ACCOUNT_LIMIT_ORDERS', 'ACCOUNT_MARGIN_SO_MODE',
           'ACCOUNT_TRADE_ALLOWED', 'ACCOUNT_TRADE_EXPERT', 'ACCOUNT_MARGIN_MODE',
           'ACCOUNT_CURRENCY_DIGITS', 'ACCOUNT_FIFO_CLOSE', 'ACCOUNT_HEDGE_ALLOWED'}
PROPERTY_ENUMS = {
    'OrderGetDouble': ORD_DBL, 'OrderGetInteger': ORD_INT,
    'OrderGetString': ORD_STR,
    'PositionGetDouble': POS_DBL, 'PositionGetInteger': POS_INT,
    'PositionGetString': POS_STR,
    'HistoryDealGetDouble': DEAL_DBL, 'HistoryDealGetInteger': DEAL_INT,
    'HistoryDealGetString': DEAL_STR,
    'AccountInfoDouble': ACC_DBL, 'AccountInfoInteger': ACC_INT,
    'HistoryOrderGetDouble': ORD_DBL, 'HistoryOrderGetInteger': ORD_INT,
    'HistoryOrderGetString': ORD_STR,
}

# --- trade server return codes (ENUM... 10004..10045) ------------------
RETCODES = {
    'TRADE_RETCODE_REQUOTE', 'TRADE_RETCODE_REJECT', 'TRADE_RETCODE_CANCEL',
    'TRADE_RETCODE_PLACED', 'TRADE_RETCODE_DONE', 'TRADE_RETCODE_DONE_PARTIAL',
    'TRADE_RETCODE_ERROR', 'TRADE_RETCODE_TIMEOUT', 'TRADE_RETCODE_INVALID',
    'TRADE_RETCODE_INVALID_VOLUME', 'TRADE_RETCODE_INVALID_PRICE',
    'TRADE_RETCODE_INVALID_STOPS', 'TRADE_RETCODE_TRADE_DISABLED',
    'TRADE_RETCODE_MARKET_CLOSED', 'TRADE_RETCODE_NO_MONEY',
    'TRADE_RETCODE_PRICE_CHANGED', 'TRADE_RETCODE_PRICE_OFF',
    'TRADE_RETCODE_INVALID_EXPIRATION', 'TRADE_RETCODE_ORDER_CHANGED',
    'TRADE_RETCODE_TOO_MANY_REQUESTS', 'TRADE_RETCODE_NO_CHANGES',
    'TRADE_RETCODE_SERVER_DISABLES_AT', 'TRADE_RETCODE_CLIENT_DISABLES_AT',
    'TRADE_RETCODE_LOCKED', 'TRADE_RETCODE_FROZEN', 'TRADE_RETCODE_INVALID_FILL',
    'TRADE_RETCODE_CONNECTION', 'TRADE_RETCODE_ONLY_REAL',
    'TRADE_RETCODE_LIMIT_ORDERS', 'TRADE_RETCODE_LIMIT_VOLUME',
    'TRADE_RETCODE_INVALID_ORDER', 'TRADE_RETCODE_POSITION_CLOSED',
    'TRADE_RETCODE_INVALID_CLOSE_VOLUME', 'TRADE_RETCODE_CLOSE_ORDER_EXIST',
    'TRADE_RETCODE_LIMIT_POSITIONS', 'TRADE_RETCODE_REJECT_CANCEL',
    'TRADE_RETCODE_LONG_ONLY', 'TRADE_RETCODE_SHORT_ONLY',
    'TRADE_RETCODE_CLOSE_ONLY', 'TRADE_RETCODE_FIFO_CLOSE',
}

# --- everything else, one name per line -------------------------------
mql5_verified = """
ACCOUNT_TRADE_MODE_DEMO ACCOUNT_TRADE_MODE_CONTEST ACCOUNT_TRADE_MODE_REAL
SYMBOL_BID SYMBOL_ASK SYMBOL_LAST SYMBOL_POINT SYMBOL_DIGITS SYMBOL_SPREAD
SYMBOL_SPREAD_FLOAT SYMBOL_TIME SYMBOL_TIME_MSC SYMBOL_VOLUME SYMBOL_SELECT
SYMBOL_VISIBLE SYMBOL_START_TIME SYMBOL_TRADE_CALC_MODE SYMBOL_TRADE_MODE
SYMBOL_TRADE_MODE_FULL SYMBOL_TRADE_MODE_LONGONLY SYMBOL_TRADE_MODE_SHORTONLY
SYMBOL_TRADE_MODE_CLOSEONLY SYMBOL_TRADE_MODE_DISABLED
SYMBOL_TRADE_STOPS_LEVEL SYMBOL_TRADE_FREEZE_LEVEL SYMBOL_TRADE_CONTRACT_SIZE
SYMBOL_TRADE_TICK_SIZE SYMBOL_TRADE_TICK_VALUE
SYMBOL_TRADE_TICK_VALUE_PROFIT SYMBOL_TRADE_TICK_VALUE_LOSS
SYMBOL_EXPIRATION_MODE SYMBOL_EXPIRATION_SPECIFIED SYMBOL_EXPIRATION_GTC
SYMBOL_FILLING_MODE SYMBOL_FILLING_FOK SYMBOL_FILLING_IOC SYMBOL_ORDER_MODE
SYMBOL_SWAP_MODE SYMBOL_SWAP_LONG SYMBOL_SWAP_SHORT SYMBOL_MARGIN_INITIAL
SYMBOL_MARGIN_MAINTENANCE SYMBOL_VOLUME_MIN SYMBOL_VOLUME_MAX
SYMBOL_VOLUME_STEP SYMBOL_VOLUME_LIMIT SYMBOL_CURRENCY_BASE
SYMBOL_CURRENCY_PROFIT SYMBOL_CURRENCY_MARGIN SYMBOL_DESCRIPTION SYMBOL_NAME
SYMBOL_PATH SYMBOL_CATEGORY SYMBOL_TICKS_BOOKDEPTH SYMBOL_CALC_MODE_FOREX
SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE SYMBOL_CALC_MODE_CFD
SYMBOL_CALC_MODE_CFDINDEX SYMBOL_CALC_MODE_CFDLEVERAGE SYMBOL_CALC_MODE_FUTURES
SYMBOL_CALC_MODE_EXCH_STOCKS SYMBOL_CALC_MODE_EXCH_FUTURES
SYMBOL_CALC_MODE_EXCH_BONDS SYMBOL_CALC_MODE_SERV_COLLATERAL
SYMBOL_CALC_MODE_EXCH_STOCKS_MOEX SYMBOL_CALC_MODE_EXCH_BONDS_MOEX
MQL_HANDLES MQL_PROGRAM_TYPE MQL_DLLS_ALLOWED MQL_TRADE_ALLOWED MQL_DEBUG
MQL_PROFILER MQL_TESTER MQL_OPTIMIZATION MQL_VISUAL_MODE MQL_FRAME_MODE
MQL_LICENSE
TERMINAL_BUILD TERMINAL_CONNECTED TERMINAL_DLLS_ALLOWED
TERMINAL_TRADE_ALLOWED TERMINAL_MQID TERMINAL_COMMUNITY_ACCOUNT
TERMINAL_COMMUNITY_CONNECTION TERMINAL_SCREEN_DPI TERMINAL_MEMORY_PHYSICAL
TERMINAL_MEMORY_TOTAL TERMINAL_MEMORY_AVAILABLE TERMINAL_MEMORY_USED
TERMINAL_MAXBARS TERMINAL_CODEPAGE TERMINAL_CPU_CORES TERMINAL_DISK_SPACE
TERMINAL_X64 TERMINAL_OPENCL_SUPPORT TERMINAL_PING_LAST TERMINAL_VPS
FILE_READ FILE_WRITE FILE_BIN FILE_CSV FILE_TXT FILE_ANSI FILE_UNICODE
FILE_SHARE_READ FILE_SHARE_WRITE FILE_COMMON FILE_DELETE FILE_SIZE
FILE_OFFSET FILE_POSITION FILE_EXISTS
PERIOD_CURRENT PERIOD_M1 PERIOD_M2 PERIOD_M3 PERIOD_M4 PERIOD_M5 PERIOD_M6
PERIOD_M10 PERIOD_M12 PERIOD_M15 PERIOD_M20 PERIOD_M30 PERIOD_H1 PERIOD_H2
PERIOD_H3 PERIOD_H4 PERIOD_H6 PERIOD_H8 PERIOD_H12 PERIOD_D1 PERIOD_W1 PERIOD_MN1
SERIES_SYNCHRONIZED SERIES_LASTBAR_DATE SERIES_SERVER_FIRSTDATE
SERIES_TERMINAL_FIRSTDATE SERIES_BARS_COUNT SERIES_FLAGS
TIME_DATE TIME_MINUTES TIME_SECONDS TIME_DATE_MINUTES TIME_DATE_SECONDS
TIME_MINUTES_SECONDS TIME_DATE_MINUTES_SECONDS
CHARTEVENT_KEYDOWN CHARTEVENT_MOUSE_MOVE CHARTEVENT_OBJECT_CLICK
CHARTEVENT_OBJECT_CREATE CHARTEVENT_OBJECT_CHANGE CHARTEVENT_OBJECT_DELETE
CHARTEVENT_CHART_CHANGE CHARTEVENT_CUSTOM CHARTEVENT_OBJECT_DRAG
CHARTEVENT_CLICK CHART_EVENT_MOUSE_MOVE CHART_EVENT_OBJECT_CREATE
CHART_EVENT_OBJECT_DELETE CHART_MOUSE_SCROLL
OBJ_LABEL OBJ_RECTANGLE_LABEL OBJ_BUTTON OBJ_EDIT OBJ_BITMAP OBJ_BITMAP_LABEL
OBJ_RECTANGLE OBJ_TEXT OBJ_TREND OBJ_TRENDBYANGLE OBJ_HLINE OBJ_VLINE
OBJ_NO_PERIODS OBJ_ALL_PERIODS OBJ_PERIOD_M1 OBJ_PERIOD_M5 OBJ_PERIOD_M15
OBJ_PERIOD_M30 OBJ_PERIOD_H1 OBJ_PERIOD_D1
OBJPROP_COLOR OBJPROP_BGCOLOR OBJPROP_BORDER_COLOR OBJPROP_BACK
OBJPROP_BORDER_TYPE OBJPROP_CORNER OBJPROP_FONT OBJPROP_FONTSIZE
OBJPROP_HIDDEN OBJPROP_SELECTABLE OBJPROP_SELECTED OBJPROP_TEXT
OBJPROP_TIMEFRAMES OBJPROP_WIDTH OBJPROP_XDISTANCE OBJPROP_YDISTANCE
OBJPROP_XSIZE OBJPROP_YSIZE OBJPROP_ANCHOR OBJPROP_ANGLE OBJPROP_ZORDER
OBJPROP_TOOLTIP
ANCHOR_LEFT_UPPER ANCHOR_LEFT_LOWER ANCHOR_RIGHT_UPPER ANCHOR_RIGHT_LOWER
CORNER_LEFT_UPPER CORNER_LEFT_LOWER CORNER_RIGHT_UPPER CORNER_RIGHT_LOWER
BORDER_FLAT BORDER_RAISED BORDER_SUNKEN
CALENDAR_IMPORTANCE_HIGH CALENDAR_IMPORTANCE_MODERATE CALENDAR_IMPORTANCE_LOW
CALENDAR_IMPORTANCE_NONE CALENDAR_TIMEFRAME_MIN_1 CALENDAR_TIMEFRAME_HOUR_1
CALENDAR_TIMEFRAME_DAY_1 CALENDAR_TIMEFRAME_WEEK_1 CALENDAR_TIMEFRAME_MONTH_1
TRADE_TRANSACTION_ORDER_ADD TRADE_TRANSACTION_ORDER_UPDATE
TRADE_TRANSACTION_ORDER_DELETE TRADE_TRANSACTION_DEAL_ADD
TRADE_TRANSACTION_HISTORY_ADD TRADE_TRANSACTION_POSITION
TRADE_TRANSACTION_REQUEST
ORDER_TYPE_BUY ORDER_TYPE_SELL ORDER_TYPE_BUY_LIMIT ORDER_TYPE_SELL_LIMIT
ORDER_TYPE_BUY_STOP ORDER_TYPE_SELL_STOP ORDER_TYPE_BUY_STOP_LIMIT
ORDER_TYPE_SELL_STOP_LIMIT ORDER_TYPE_CLOSE_BY
ORDER_FILLING_FOK ORDER_FILLING_IOC ORDER_FILLING_RETURN ORDER_FILLING_BOC
ORDER_TIME_GTC ORDER_TIME_DAY ORDER_TIME_SPECIFIED ORDER_TIME_SPECIFIED_DAY
POSITION_TYPE_BUY POSITION_TYPE_SELL
DEAL_TYPE_BUY DEAL_TYPE_SELL DEAL_TYPE_BALANCE DEAL_TYPE_CREDIT
DEAL_TYPE_CHARGE DEAL_TYPE_CORRECTION DEAL_TYPE_BONUS DEAL_TYPE_COMMISSION
DEAL_TYPE_COMMISSION_DAILY DEAL_TYPE_COMMISSION_MONTHLY
DEAL_TYPE_COMMISSION_AGENT_DAILY DEAL_TYPE_COMMISSION_AGENT_MONTHLY
DEAL_TYPE_INTEREST DEAL_TYPE_BUY_CANCELED DEAL_TYPE_SELL_CANCELED
DEAL_ENTRY_IN DEAL_ENTRY_OUT DEAL_ENTRY_INOUT DEAL_ENTRY_OUT_BY
DEAL_REASON_CLIENT DEAL_REASON_MOBILE DEAL_REASON_WEB DEAL_REASON_EXPERT
DEAL_REASON_SL DEAL_REASON_TP DEAL_REASON_SO DEAL_REASON_ROLLOVER
DEAL_REASON_VMARGIN DEAL_REASON_SPLIT
ENUM_TIMEFRAMES ENUM_SYMBOL_CALC_MODE ENUM_SYMBOL_TRADE_MODE
ENUM_SYMBOL_INFO_DOUBLE ENUM_SYMBOL_INFO_INTEGER ENUM_SYMBOL_INFO_STRING
ENUM_ORDER_TYPE ENUM_ORDER_TYPE_FILLING ENUM_ORDER_TYPE_TIME
ENUM_ORDER_PROPERTY_DOUBLE ENUM_ORDER_PROPERTY_INTEGER ENUM_ORDER_PROPERTY_STRING
ENUM_POSITION_TYPE ENUM_POSITION_PROPERTY_DOUBLE ENUM_POSITION_PROPERTY_INTEGER
ENUM_POSITION_PROPERTY_STRING ENUM_DEAL_TYPE ENUM_DEAL_ENTRY
ENUM_ACCOUNT_TRADE_MODE ENUM_ACCOUNT_INFO_DOUBLE ENUM_ACCOUNT_INFO_INTEGER
ENUM_ACCOUNT_INFO_STRING ENUM_INIT_RETCODE ENUM_CHART_PROPERTY_INTEGER
ENUM_CHART_PROPERTY_STRING ENUM_OBJECT ENUM_OBJECT_PROPERTY_INTEGER
ENUM_OBJECT_PROPERTY_STRING ENUM_ANCHOR_POINT ENUM_BASE_CORNER ENUM_BORDER_TYPE
ENUM_CHART_EVENT ENUM_CHART_EVENT_MASK ENUM_SERIES_INFO_INTEGER
ENUM_TERMINAL_INFO_INTEGER ENUM_MQL_INFO_INTEGER ENUM_FILE_PROPERTY_INTEGER
ENUM_APPLIED_PRICE ENUM_MA_METHOD ENUM_CALENDAR_EVENT_IMPORTANCE
ENUM_CALENDAR_EVENT_TYPE ENUM_CALENDAR_EVENT_SECTOR ENUM_CALENDAR_EVENT_FREQUENCY
INIT_SUCCEEDED INIT_FAILED INVALID_HANDLE PROCESSING_STATUS_HANDLE
NULL M_PI SEEK_SET SEEK_CUR SEEK_END TERMINAL_WINDOW_HANDLE
""".split()
IDENT = re.compile(r'^[A-Z][A-Z0-9_]*$')
PROPERTY_MEMBERS = set()
for _t in PROPERTY_ENUMS.values():
    PROPERTY_MEMBERS |= _t
MQL5_VERIFIED = (set(w for w in mql5_verified if IDENT.match(w)) |
                 PROPERTY_MEMBERS | RETCODES)

# --- every name we declare ourselves ----------------------------------
OURS = set()
def collect_ours(src):
    for m in re.finditer(r'#define\s+(\w+)', src):
        OURS.add(m.group(1))
    for m in re.finditer(r'\b(?:enum|class|struct)\s+(\w+)', src):
        OURS.add(m.group(1))
    # enum members: comments and string literals are already stripped, so a
    # member ends at ',', '}' or the end of an "= value" initialiser
    # (the closing brace is part of the capture: the last member of an enum
    #  is terminated by '}', not by ',')
    for m in re.finditer(r'\benum\s+\w*\s*\{([^}]*\})', src, re.S):
        for tok in re.findall(r'([A-Za-z_]\w*)\s*(?:=\s*[^,}]+)?[,}]', m.group(1)):
            OURS.add(tok)
    # functions, plain and Class::method, defined at the start of a line
    for m in re.finditer(r'^[A-Za-z_][\w\s\*&<>]*?([A-Za-z_]\w*)\s*\(', src, re.M):
        OURS.add(m.group(1))
    for m in re.finditer(r'^[A-Za-z_][\w\s\*&<>]*?(\w+)::(\w+)\s*\(', src, re.M):
        OURS.add(m.group(1))
        OURS.add(m.group(2))
for rel in FILES:
    collect_ours(clean[rel])

used = collections.defaultdict(set)
for rel in FILES:
    for tok in set(re.findall(r'\b([A-Z][A-Z0-9_]{2,})\b', clean[rel])):
        used[tok].add(rel)
for tok in sorted(used):
    if tok in OURS or tok in MQL5_VERIFIED:
        continue
    problems.append(f"{sorted(used[tok])[0]}: {tok} is used but is defined "
                    f"nowhere - MetaEditor will report an undeclared identifier")

# ---- 8. the property argument of the built-in accessors ---------------
for rel in FILES:
    for m in re.finditer(r'\b(\w+)\s*\(\s*([A-Z][A-Z0-9_]{2,})\s*[,)]', clean[rel]):
        fn, arg = m.group(1), m.group(2)
        if fn in PROPERTY_ENUMS and arg not in PROPERTY_ENUMS[fn]:
            problems.append(f"{rel}: {fn}({arg}) - {arg} is not part of "
                            f"{fn}'s property enum")

# ---- 9. TRADE_RETCODE_* names ----------------------------------------
for rel in FILES:
    for tok in set(re.findall(r'\bTRADE_RETCODE_\w+', clean[rel])):
        if tok not in RETCODES:
            problems.append(f"{rel}: {tok} is not a trade server retcode")

# ---- report -----------------------------------------------------------
lines = sum(len(raw[f].splitlines()) for f in FILES)
print(f"checked {len(FILES)} files, {lines} lines")
if problems:
    print(f"\n{len(problems)} problem(s):")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("no problems found")
