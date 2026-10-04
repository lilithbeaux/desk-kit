{ ===================================================================
  detauto_types — Shared types, constants, and key-code mappings for
  detauto: a deterministic Pascal desktop automation daemon.

  FPC 3.2.2 notes:
  • No inline var declarations — all variables in var blocks.
  • No for-in loops — use indexed for loops only.
  • Packed record for C-struct compatibility.
  =================================================================== }
unit detauto_types;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, UnixType;

{ -------------------------------------------------------------------
  Linux input subsystem constants (from <linux/input-event-codes.h>)
  ------------------------------------------------------------------- }

{ Input event types }
const
  EV_SYN      = 0;
  EV_KEY      = 1;
  EV_REL      = 2;
  EV_ABS      = 3;
  EV_REP      = 5;

{ Synchronization event codes }
  SYN_REPORT      = 0;
  SYN_CONFIGTYPE_LSB = 1;
  SYN_CONFIGTYPE_MSB  = 2;

{ Key event values }
  KVAL_UP        = 0;
  KVAL_DOWN      = 1;
  KVAL_REPEAT    = 2;

{ Relative axis codes }
  REL_X         = 0;
  REL_Y         = 1;
  REL_HWHEEL    = 6;
  REL_WHEEL     = 11;

{ Mouse button codes }
  BTN_LEFT      = 272;
  BTN_RIGHT     = 273;
  BTN_MIDDLE    = 274;
  BTN_SIDE      = 275;
  BTN_EXTRA     = 276;
  BTN_FORWARD   = 277;
  BTN_BACK      = 278;

{ Special character key codes (for shifted typing) }
  KEY_MINUS       = 12;
  KEY_EQUAL       = 13;
  KEY_LEFTBRACE   = 26;
  KEY_RIGHTBRACE  = 27;
  KEY_BACKSLASH   = 43;
  KEY_SEMICOLON   = 39;
  KEY_APOSTROPHE  = 40;
  KEY_COMMA       = 51;
  KEY_DOT         = 52;
  KEY_SLASH       = 53;
  KEY_GRAVE       = 41;

{ Linux input event modifier key codes }
  KEY_LEFTCTRL    = 224;
  KEY_RIGHTCTRL   = 225;
  KEY_LEFTSHIFT   = 42;
  KEY_RIGHTSHIFT  = 54;
  KEY_LEFTALT     = 56;
  KEY_RIGHTALT    = 100;
  KEY_LEFTMETA    = 125;
  KEY_RIGHTMETA   = 126;

{ Event bits (for UI_SET_EVBIT) }
  EVBIT_SYN     = 0;
  EVBIT_KEY     = 1;
  EVBIT_REL     = 2;

{ -------------------------------------------------------------------
  Modifier key codes
  ------------------------------------------------------------------- }
  MOD_KEY_CTRL_L    = 29;
  MOD_KEY_CTRL_R    = 97;
  MOD_KEY_SHIFT_L   = 42;
  MOD_KEY_SHIFT_R   = 54;
  MOD_KEY_ALT_L     = 56;
  MOD_KEY_ALT_R     = 100;
  MOD_KEY_SUPER_L   = 125;
  MOD_KEY_SUPER_R   = 126;

{ -------------------------------------------------------------------
  uinput ioctl values.
  _IOC_NONE=0, _IOC_WRITE=1 on Linux x86-64.
  Base = 'U' = 85 = $55, DirShift=30, TypeShift=8, NRShift=0, SizeMask=$3FFF
  ------------------------------------------------------------------- }
  UI_DEV_CREATE   = $00005501;
  UI_DEV_DESTROY  = $00005502;
  UI_SET_EVBIT    = $40005564;
  UI_SET_KEYBIT   = $40005565;
  UI_SET_RELBIT   = $40005566;

{ -------------------------------------------------------------------
  uinput device constants
  ------------------------------------------------------------------- }
  UINPUT_MAX_NAME_SIZE = 80;
  UINPUT_USER_DEV_SIZE = 1116;
  UINPUT_DEV  = '/dev/uinput';
  INPUT_DEV_DIR = '/dev/input/';

{ -------------------------------------------------------------------
  IPC constants
  ------------------------------------------------------------------- }
  SOCK_PATH    = '/tmp/detd.sock';
  BACKLOG      = 16;
  MAX_REPLY    = 65536;
  POLL_TIMEOUT_MS = 200;
  EPOLL_MAX_EVENTS = 64;

{ -------------------------------------------------------------------
  Hotkey modifier bitmasks
  ------------------------------------------------------------------- }
  HOTKEY_MOD_NONE   = 0;
  HOTKEY_MOD_CTRL   = 1;
  HOTKEY_MOD_SHIFT  = 2;
  HOTKEY_MOD_ALT    = 4;
  HOTKEY_MOD_SUPER  = 8;
  MAX_HOTKEYS      = 64;

{ epoll constants }
  EPOLLIN  = $00000001;
  EPOLLOUT = $00000004;
  EPOLLERR = $00000008;
  EPOLLHUP = $00000010;

{ -------------------------------------------------------------------
  Command opcode for IPC
  ------------------------------------------------------------------- }
  CMD_KEY         = 1;
  CMD_TYPE          = 2;
  CMD_MOUSE_MOVE    = 3;
  CMD_MOUSE_CLICK   = 4;
  CMD_FOCUS         = 5;
  CMD_WINDOW_LIST   = 6;
  CMD_ACTIVE_WINDOW = 7;
  CMD_WAIT_WINDOW   = 8;
  CMD_REGISTER_HK   = 9;
  CMD_UNREGISTER_HK = 10;
  CMD_SCREENSHOT    = 11;
  CMD_STATUS        = 12;
  CMD_EXIT          = 13;
  CMD_ECHO          = 14;
  CMD_CAMOX_GET     = 15;
  CMD_CAMOX_RUN     = 16;
  CMD_HOTKEY_FIRED  = 17;
  CMD_DOCTOR        = 18;

{ -------------------------------------------------------------------
  Record / type definitions
  ------------------------------------------------------------------- }

{ Mirrors struct input_event from <linux/input.h> — 24 bytes on x86-64 }
type
  TInputEvent = packed record
    tv_sec:    Int64;
    tv_usec:   Int64;
    event_type: Word;
    code:      Word;
    value:     Int32;
  end;
  PInputEvent = ^TInputEvent;

{ Mirrors struct sockaddr_un — 110 bytes on x86-64 }
  TSockAddrUn = packed record
    sun_family: Word;
    sun_path: array[0..107] of AnsiChar;
  end;

{ Mirrors struct epoll_event — 12 bytes on x86-64 (4 + 8) }
  TEpollEvent = packed record
    events: UInt32;
    data:   PtrUInt;
  end;
  PEpollEvent = ^TEpollEvent;

{ Mirrors struct uinput_user_dev — 1116 bytes.
  Only first 80 bytes (name) are meaningful; rest is zero-padded
  because we use UI_SET_KEYBIT / UI_SET_EVBIT ioctls. }
  TUinputUserDev = packed record
    name: array[0..UINPUT_MAX_NAME_SIZE-1] of AnsiChar;
    _pad: array[0..UINPUT_USER_DEV_SIZE - UINPUT_MAX_NAME_SIZE - 1] of Byte;
  end;

{ Modifier key state tracker }
  TModState = record
    ctrl_key  : Word;
    shift_key : Word;
    alt_key   : Word;
    super_key : Word;
    ctrl      : Boolean;
    shift     : Boolean;
    alt       : Boolean;
    super     : Boolean;
  end;

{ A single registered hotkey }
  THotkeyRec = record
    combo_str : AnsiString;
    codes     : array[0..7] of Word;
    nkeys     : Integer;
    mods      : Word;         { bitmask of HOTKEY_MOD_* }
    key_code  : Word;         { the non-modifier key }
    action    : AnsiString;
    enabled   : Boolean;
  end;

  THotkeyList = array of THotkeyRec;

{ Callback type for hotkey actions: receives the action string }
  THotkeyCallback = procedure(const action: AnsiString);

{ X11 hotkey registration record }
  TX11Hotkey = record
    keycode    : Word;
    modifiers  : Word;
    action     : AnsiString;
  end;

{ X11 modifier key tracker }
  TModKey = record
    keycode : Word;
    name    : AnsiString;
  end;

{ X11 atom indices — matches the ATOM_NAMES_ARR order in detauto_x11keys }
  TAtomConst = (
    ATOM_WM_NAME,
    ATOM_WM_CLASS,
    ATOM_NET_WM_PID,
    ATOM_NET_WM_STATE,
    ATOM_NET_ACTIVE_WINDOW,
    ATOM_NET_WM_STATE_SKIP_PAGER,
    ATOM_NET_WM_STATE_SKIP_TASKBAR,
    ATOM_NET_WM_STATE_MODAL,
    ATOM_NET_WM_STATE_HIDDEN,
    ATOM_NET_WM_STATE_FOCUSED,
    ATOM_NET_WM_STATE_STICKY,
    ATOM_NET_WM_STATE_ABOVE,
    ATOM_NET_WM_STATE_BELOW,
    ATOM_NET_WM_STATE_FULLSCREEN,
    ATOM_NET_WM_STATE_MAXIMIZED_VERT,
    ATOM_NET_WM_STATE_MAXIMIZED_HORZ
  );

{ Key code array returned by ParseKeyCombo }
  TKeyCodeArray = array of Word;

{ Window information from X11 enumeration }
  TWindowInfo = record
    xid         : LongWord;
    name        : AnsiString;
    wm_class    : AnsiString;
    wm_class2   : AnsiString;
    pid         : LongInt;
    is_phantom  : Boolean;
    is_focusable: Boolean;
    is_active   : Boolean;
    layer       : Integer;
    screen_x    : Integer;
    screen_y    : Integer;
    width       : Integer;
    height      : Integer;
    importance  : Integer;
  end;

{ Window list }
  TWindowList = array of TWindowInfo;

{ Command result returned by daemon to CLI }
  TCmdResult = record
    ok      : Boolean;
    data    : AnsiString;
    error_msg: AnsiString;
  end;

{ Simple key name → keycode entry }
  TKeyEntry = record
    name : array[0..31] of AnsiChar;
    code : Word;
  end;

{ Built-in key name → keycode table }
const
  KEY_STORE_SIZE = 130;
var
  KeyStore: array[0..KEY_STORE_SIZE-1] of TKeyEntry;
  KeyStoreCount: Integer;

{ -------------------------------------------------------------------
  Function prototypes
  ------------------------------------------------------------------- }

{ Look up a kernel key code from a human-readable name.
  Returns 0 if not found. }
function KeyNameToCode(const name: AnsiString): Word;

{ Parse a key combination string like "ctrl+shift+f12" into key codes.
  Modifiers come first in the returned array. }
function ParseKeyCombo(const combo: AnsiString): TKeyCodeArray;

{ Initialise the key-name table — call once at program start. }
procedure InitKeyStore;

{ Convert the current modifier mask to a string like "ctrl+shift" }
function ModMaskToStr(mods: Word): AnsiString;

implementation

var
  _Initialized: Boolean = False;

{ ------------------------------------------------------------------- }
function KeyNameToCode(const name: AnsiString): Word;
var
  i : Integer;
  lc: array[0..31] of AnsiChar;
begin
  Result := 0;
  if not _Initialized then
    Exit;
  if Length(name) = 0 then
    Exit;
  { lowercase copy, truncated to 31 chars }
  StrPLCopy(lc, LowerCase(Trim(name)), 31);
  for i := 0 to KeyStoreCount - 1 do
  begin
    if StrComp(PAnsiChar(@KeyStore[i].name), lc) = 0 then
      Exit(KeyStore[i].code);
  end;
end;

{ ------------------------------------------------------------------- }
function ParseKeyCombo(const combo: AnsiString): TKeyCodeArray;
var
  parts : TStringList;
  i     : Integer;
  c     : Word;
  tmp   : TKeyCodeArray;
  n     : Integer;
  code  : Integer;
  cInt  : Integer;
begin
  SetLength(Result, 0);
  if combo = '' then
    Exit;

  parts := TStringList.Create;
  try
    parts.Delimiter := '+';
    parts.DelimitedText := combo;
    n := 0;
    for i := 0 to parts.Count - 1 do
    begin
      c := KeyNameToCode(Trim(parts[i]));
      if c = 0 then
      begin
        { Try numeric }
        Val(Trim(parts[i]), cInt, code);
        if code = 0 then
        begin
        c := Word(cInt);
          SetLength(tmp, n + 1);
          tmp[n] := c;
          Inc(n);
        end;
      end
      else
      begin
        SetLength(tmp, n + 1);
        tmp[n] := c;
        Inc(n);
      end;
    end;
    SetLength(tmp, n);
    Result := tmp;
  finally
    parts.Free;
  end;
end;

{ ------------------------------------------------------------------- }
function ModMaskToStr(mods: Word): AnsiString;
begin
  Result := '';
  if (mods and HOTKEY_MOD_CTRL) > 0 then
    Result := Result + 'ctrl+';
  if (mods and HOTKEY_MOD_SHIFT) > 0 then
    Result := Result + 'shift+';
  if (mods and HOTKEY_MOD_ALT) > 0 then
    Result := Result + 'alt+';
  if (mods and HOTKEY_MOD_SUPER) > 0 then
    Result := Result + 'super+';
  if Result <> '' then
    SetLength(Result, Length(Result) - 1);
end;

{ -------------------------------------------------------------------
  Key store: built-in name → keycode table
  ------------------------------------------------------------------- }
procedure InitKeyStore;
const
  TABLE : array[0..129] of record n: AnsiString; c: Word end = (
    (n:'esc';           c:1),
    (n:'escape';        c:1),
    { digits }
    (n:'1'; c:2),  (n:'2'; c:3),  (n:'3'; c:4),  (n:'4'; c:5),
    (n:'5'; c:6),  (n:'6'; c:7),  (n:'7'; c:8),  (n:'8'; c:9),
    (n:'9'; c:10), (n:'0'; c:11),
    { punctuation }
    (n:'minus'; c:12),  (n:'-'; c:12),
    (n:'equal'; c:13),  (n:'='; c:13),
    (n:'backspace'; c:14), (n:'bksp'; c:14),
    (n:'tab'; c:15),
    { QWERTY row }
    (n:'q'; c:16),  (n:'w'; c:17),  (n:'e'; c:18),
    (n:'r'; c:19),  (n:'t'; c:20),  (n:'y'; c:21),
    (n:'u'; c:22),  (n:'i'; c:23),  (n:'o'; c:24),
    (n:'p'; c:25),
    (n:'leftbrace'; c:26), (n:'['; c:26),
    (n:'rightbrace'; c:27), (n:']'; c:27),
    (n:'backslash'; c:43), (n:#92; c:43),
    { ASDF row }
    (n:'a'; c:30),  (n:'s'; c:31),  (n:'d'; c:32),
    (n:'f'; c:33),  (n:'g'; c:34),  (n:'h'; c:35),
    (n:'j'; c:36),  (n:'k'; c:37),  (n:'l'; c:38),
    (n:'semicolon'; c:39), (n:';'; c:39),
    (n:'apostrophe'; c:40), (n:#39; c:40),
    { ZXC row }
    (n:'z'; c:44),  (n:'x'; c:45),  (n:'c'; c:46),
    (n:'v'; c:47),  (n:'b'; c:48),  (n:'n'; c:49),
    (n:'m'; c:50),
    (n:'comma'; c:51), (n:','; c:51),
    (n:'dot'; c:52),  (n:'.'; c:52),
    (n:'slash'; c:53), (n:'/'; c:53),
    (n:'grave'; c:41), (n:'`'; c:41),
    { misc }
    (n:'space'; c:57), (n:'sp'; c:57),
    (n:'enter'; c:28), (n:'return'; c:28),
    (n:'capslock'; c:58), (n:'caps'; c:58),
    (n:'delete'; c:111), (n:'del'; c:111),
    (n:'insert'; c:110), (n:'ins'; c:110),
    { navigation }
    (n:'up'; c:103),  (n:'down'; c:108),
    (n:'left'; c:105), (n:'right'; c:106),
    (n:'home'; c:102), (n:'end'; c:107),
    (n:'pageup'; c:104), (n:'pgup'; c:104),
    (n:'pagedown'; c:109), (n:'pgdn'; c:109),
    { modifiers }
    (n:'ctrl'; c:29),     (n:'control'; c:29),
    (n:'leftctrl'; c:29), (n:'lctrl'; c:29),
    (n:'shift'; c:42),    (n:'leftshift'; c:42),
    (n:'lshift'; c:42),
    (n:'alt'; c:56),      (n:'leftalt'; c:56),
    (n:'lalt'; c:56),
    (n:'super'; c:125),   (n:'leftsuper'; c:125),
    (n:'lwin'; c:125),    (n:'win'; c:125),
    (n:'meta'; c:125),
    (n:'rightctrl'; c:97), (n:'rctrl'; c:97),
    (n:'rightshift'; c:54), (n:'rshift'; c:54),
    (n:'rightalt'; c:100), (n:'ralt'; c:100),
    (n:'rightsuper'; c:126), (n:'rsuper'; c:126),
    (n:'rmeta'; c:126),
    { function keys }
    (n:'f1'; c:59),  (n:'f2'; c:60),  (n:'f3'; c:61),
    (n:'f4'; c:62),  (n:'f5'; c:63),  (n:'f6'; c:64),
    (n:'f7'; c:65),  (n:'f8'; c:66),  (n:'f9'; c:67),
    (n:'f10'; c:68), (n:'f11'; c:87), (n:'f12'; c:88),
    (n:'f13'; c:183), (n:'f14'; c:184), (n:'f15'; c:185),
    { placeholder to reach 130 entries }
    (n:'space'; c:57),
    (n:'f16'; c:186), (n:'f17'; c:187), (n:'f18'; c:188),
    (n:'f19'; c:189), (n:'f20'; c:190), (n:'f21'; c:191),
    (n:'f22'; c:192)
  );
var
  i: Integer;
begin
  if _Initialized then
    Exit;
  KeyStoreCount := High(TABLE) + 1;
  if KeyStoreCount > KEY_STORE_SIZE then
    KeyStoreCount := KEY_STORE_SIZE;
  for i := 0 to KeyStoreCount - 1 do
  begin
    StrPLCopy(KeyStore[i].name, TABLE[i].n, 31);
    KeyStore[i].code := TABLE[i].c;
  end;
  _Initialized := True;
end;

{ ------------------------------------------------------------------- }
initialization
  KeyStoreCount := 0;
  FillChar(KeyStore, SizeOf(KeyStore), 0);

end.
