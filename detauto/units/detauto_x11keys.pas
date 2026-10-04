{ ===================================================================
  detauto_x11keys — X11 window management + X11-level hotkey listener.
  Runs on top of the X server: enumerates windows, filters phantoms,
  ranks importance, manages focus, and listens for XGrabKey hotkeys.
  =================================================================== }

unit detauto_x11keys;

{$mode objfpc}{$H+}

interface

uses
  BaseUnix, UnixType, Unix, ctypes, xlib, x, xutil, detauto_types, detauto_uinput;

{ ------------------------------------------------------------------
  TPhantomWindow — a window identified as having no title and no
  WM_CLASS.  These are invisible system windows (_NET_WM_PID=0,
  dock/desktop/backdrop) that clutter window lists.
  ------------------------------------------------------------------ }
type
  TPhantomWindow = record
    id       : TWindow;
    pid_hint : LongInt;
  end;

{ ------------------------------------------------------------------
  TX11Window — canonical window descriptor used by every route.
  ------------------------------------------------------------------ }
  TX11Window = record
    id         : TWindow;
    name       : AnsiString;
    wm_class   : AnsiString;
    pid        : LongInt;
    is_phantom : Boolean;
    is_focus   : Boolean;
    is_mapped  : Boolean;
    x, y       : LongInt;
    width      : LongInt;
    height     : LongInt;
    importance : Integer;
  end;

  PX11Window = ^TX11Window;
  TX11WindowList = array of TX11Window;

{ ------------------------------------------------------------------
  TX11Backend — manages the X11 display connection, window
  enumeration, phantom trimming, importance ranking, focus, and
  X11-level hotkey registration via XGrabKey.
  ------------------------------------------------------------------ }
  TX11Backend = class
  private
    FDpy           : PXDisplay;
    FRoot          : TWindow;
    FScreen        : LongInt;
    FAtoms         : array[TAtomConst] of TAtom;
    FHotkeys       : array[0..63] of TX11Hotkey;
    FHotkeyCount   : Integer;
    FKeyState      : array[0..255] of Boolean;
    FConnected     : Boolean;
    FWmState       : array[0..15] of TModKey;
    function  GetDisplay: PXDisplay;
    function  GetRootWindow: TWindow;
    function  GetAtom(idx: TAtomConst): TAtom;
    function  ReadWindowProp(window: TWindow; atom: TAtom): AnsiString;
    function  ReadWindowPid(window: TWindow): LongInt;
    function  GetWindowName(window: TWindow): AnsiString;
    function  GetWindowClass(window: TWindow): AnsiString;
    function  IsMapped(window: TWindow): Boolean;
    procedure GetWindowGeometry(window: TWindow; out x, y, w, h: LongInt);
    function  IsPhantom(const win: TX11Window): Boolean;
    procedure ComputeImportance(win: PX11Window; winCount: Integer);
    procedure SortByImportance(var wins: TX11WindowList);
  public
    constructor Create;
    destructor Destroy; override;
    function  Connect(const displayName: AnsiString = ''): Boolean;
    procedure Disconnect;
    function  IsConnected: Boolean;
    { Window management }
    function  EnumerateWindows: TX11WindowList;
    function  FindWindow(const pattern: AnsiString): TWindow;
    function  GetFocusedWindow: TWindow;
    function  SetActiveWindow(window: TWindow): Boolean;
    procedure RaiseWindowX(window: TWindow);
    function  FocusWindow(window: TWindow): Boolean;
    function  FocusWindowByName(const name: AnsiString): Boolean;
    procedure ForceUnmap(window: TWindow);
    { X11 hotkey listener }
    function  RegisterX11Hotkey(const combo: AnsiString; action: AnsiString): Boolean;
    function  UnregisterX11Hotkey(const combo: AnsiString): Boolean;
    function  X11PollEvents(uinput: TUinputBackend): Integer;
    function  GetDisplayString: AnsiString;
    function  GetConnectionFd: cint;
  end;

function X11GetBackend: TX11Backend;

implementation

var
  GlobalX11 : TX11Backend;

function X11GetBackend: TX11Backend;
begin
  if GlobalX11 = nil then
    GlobalX11 := TX11Backend.Create;
  Result := GlobalX11;
end;

{ ------------------------------------------------------------------ }
constructor TX11Backend.Create;
{ Sets up atoms for the window properties we read. }
const
  ATOM_NAMES: array[TAtomConst] of AnsiString = (
    'WM_NAME',          { ATOM_WM_NAME }
    'WM_CLASS',         { ATOM_WM_CLASS }
    '_NET_WM_PID',      { ATOM_NET_WM_PID }
    '_NET_WM_STATE',    { ATOM_NET_WM_STATE }
    '_NET_ACTIVE_WINDOW', { ATOM_NET_ACTIVE_WINDOW }
    '_NET_WM_STATE_SKIP_PAGER',    { ATOM_NET_WM_STATE_SKIP_PAGER }
    '_NET_WM_STATE_SKIP_TASKBAR',  { ATOM_NET_WM_STATE_SKIP_TASKBAR }
    '_NET_WM_STATE_MODAL',         { ATOM_NET_WM_STATE_MODAL }
    '_NET_WM_STATE_HIDDEN',        { ATOM_NET_WM_STATE_HIDDEN }
    '_NET_WM_STATE_FOCUSED',       { ATOM_NET_WM_STATE_FOCUSED }
    '_NET_WM_STATE_STICKY',        { ATOM_NET_WM_STATE_STICKY }
    '_NET_WM_STATE_ABOVE',         { ATOM_NET_WM_STATE_ABOVE }
    '_NET_WM_STATE_BELOW',         { ATOM_NET_WM_STATE_BELOW }
    '_NET_WM_STATE_FULLSCREEN',    { ATOM_NET_WM_STATE_FULLSCREEN }
    '_NET_WM_STATE_MAXIMIZED_VERT',  { ATOM_NET_WM_STATE_MAXIMIZED_VERT }
    '_NET_WM_STATE_MAXIMIZED_HORZ'   { ATOM_NET_WM_STATE_MAXIMIZED_HORZ }
  );
var
  i: TAtomConst;
  name: AnsiString;
begin
  inherited Create;
  FDpy := nil;
  FRoot := 0;
  FScreen := 0;
  FHotkeyCount := 0;
  FillChar(FKeyState, SizeOf(FKeyState), 0);
  FillChar(FWmState, SizeOf(FWmState), 0);

  { Intern all the atoms we need }
  { We defer actual intern until Connect — atoms are display-specific }
  for i := Low(TAtomConst) to High(TAtomConst) do
    FAtoms[i] := 0;
end;

{ ------------------------------------------------------------------ }
destructor TX11Backend.Destroy;
begin
  Disconnect;
  inherited Destroy;
end;

{ ------------------------------------------------------------------ }
function TX11Backend.GetDisplay: PXDisplay;
begin
  Result := FDpy;
end;

function TX11Backend.GetRootWindow: TWindow;
begin
  Result := FRoot;
end;

function TX11Backend.GetAtom(idx: TAtomConst): TAtom;
begin
  Result := FAtoms[idx];
end;

function TX11Backend.GetConnectionFd: cint;
begin
  if FDpy <> nil then
    Result := ConnectionNumber(FDpy)
  else
    Result := -1;
end;

{ ------------------------------------------------------------------ }
function TX11Backend.Connect(const displayName: AnsiString): Boolean;
var
  namePtr: PChar;
  i: TAtomConst;
const
  ATOM_NAMES_ARR: array[TAtomConst] of AnsiString = (
    'WM_NAME', 'WM_CLASS', '_NET_WM_PID', '_NET_WM_STATE',
    '_NET_ACTIVE_WINDOW', '_NET_WM_STATE_SKIP_PAGER',
    '_NET_WM_STATE_SKIP_TASKBAR', '_NET_WM_STATE_MODAL',
    '_NET_WM_STATE_HIDDEN', '_NET_WM_STATE_FOCUSED',
    '_NET_WM_STATE_STICKY', '_NET_WM_STATE_ABOVE',
    '_NET_WM_STATE_BELOW', '_NET_WM_STATE_FULLSCREEN',
    '_NET_WM_STATE_MAXIMIZED_VERT', '_NET_WM_STATE_MAXIMIZED_HORZ'
  );
begin
  if FDpy <> nil then
    Exit(True);

  if displayName = '' then
    namePtr := nil
  else
    namePtr := PChar(displayName);

  FDpy := XOpenDisplay(namePtr);
  if FDpy = nil then
  begin
    WriteLn(stderr, 'det-auto[x11]: cannot open display');
    Exit(False);
  end;

  FScreen := XDefaultScreen(FDpy);
  FRoot := XRootWindow(FDpy, FScreen);

  { Intern all needed atoms (order matches TAtomConst enum) }
  for i := Low(TAtomConst) to High(TAtomConst) do
    FAtoms[i] := XInternAtom(FDpy, PChar(ATOM_NAMES_ARR[i]), False);

  { Select for property change and substructure on root }
  XSelectInput(FDpy, FRoot, PropertyChangeMask or SubstructureNotifyMask);
  XFlush(FDpy);
  FConnected := True;

  Result := True;
end;

{ ------------------------------------------------------------------ }
procedure TX11Backend.Disconnect;
begin
  if FDpy <> nil then
  begin
    XCloseDisplay(FDpy);
    FDpy := nil;
  end;
  FRoot := 0;
  FConnected := False;
end;

function TX11Backend.IsConnected: Boolean;
begin
  Result := FDpy <> nil;
end;

{ ------------------------------------------------------------------ }
function TX11Backend.ReadWindowProp(window: TWindow; atom: TAtom): AnsiString;
var
  actualType: TAtom;
  actualFormat: cint;
  nitems: culong;
  bytesAfter: culong;
  prop: PByte;
  ret: cint;
  i: Integer;
  ch: Byte;
  s: AnsiString;
begin
  Result := '';
  if (FDpy = nil) or (atom = 0) then
    Exit;

  ret := XGetWindowProperty(FDpy, window, atom,
    0,          { offset }
    1024,       { length (longs) }
    False,      { delete? }
    AnyPropertyType,
    @actualType, @actualFormat, @nitems, @bytesAfter, @prop);

  if (ret <> 0) or (prop = nil) or (actualFormat = 0) then
    Exit;

  { Build ANSIstring from raw bytes, stopping at null terminator }
  SetLength(s, 0);
  i := 0;
  while (i < Integer(nitems)) and (prop[i] <> 0) do
  begin
    ch := prop[i];
    s := s + chr(ch);
    Inc(i);
  end;
  XFree(prop);
  Result := s;
end;

{ ------------------------------------------------------------------ }
function TX11Backend.ReadWindowPid(window: TWindow): LongInt;
var
  actualType: TAtom;
  actualFormat: cint;
  nitems: culong;
  bytesAfter: culong;
  prop: PByte;
  ret: cint;
  pidVal: LongInt;
begin
  Result := 0;
  if (FDpy = nil) or (FAtoms[ATOM_NET_WM_PID] = 0) then
    Exit;

  ret := XGetWindowProperty(FDpy, window, FAtoms[ATOM_NET_WM_PID],
    0, 1, False, AnyPropertyType, @actualType, @actualFormat,
    @nitems, @bytesAfter, @prop);

  if (ret <> 0) or (prop = nil) or (actualFormat <> 32) then
    Exit;

  { PID is a 32-bit value }
  pidVal := 0;
  if nitems >= 4 then
  begin
    Move(prop^, pidVal, 4);
  end;
  Result := pidVal;
  XFree(prop);
end;

{ ------------------------------------------------------------------ }
function TX11Backend.GetWindowName(window: TWindow): AnsiString;
var
  name: PAnsiChar;
  netWmName: TAtom;
begin
  Result := '';
  if FDpy = nil then
    Exit;
  if XFetchName(FDpy, window, @name) > 0 then
  begin
    if name <> nil then
    begin
      Result := AnsiString(name);
      XFree(name);
    end;
  end
  else
  begin
    { Fallback: try _NET_WM_NAME (UTF8_STRING) }
    netWmName := XInternAtom(FDpy, '_NET_WM_NAME', False);
    if netWmName <> 0 then
      Result := ReadWindowProp(window, netWmName);
  end;
end;

{ ------------------------------------------------------------------ }
function TX11Backend.GetWindowClass(window: TWindow): AnsiString;
var
  actualType: TAtom;
  actualFormat: cint;
  nitems: culong;
  bytesAfter: culong;
  prop: PByte;
  ret: cint;
  i: Integer;
  s: AnsiString;
begin
  Result := '';
  if (FDpy = nil) or (FAtoms[ATOM_WM_CLASS] = 0) then
    Exit;

  ret := XGetWindowProperty(FDpy, window, FAtoms[ATOM_WM_CLASS],
    0, 1024, False, AnyPropertyType,
    @actualType, @actualFormat, @nitems, @bytesAfter, @prop);

  if (ret <> 0) or (prop = nil) then
    Exit;

  { WM_CLASS contains two null-separated strings: instance, then class.
    We want the class (second string). }
  if actualFormat = 8 then
  begin
    { Skip first null-terminated string (instance name) }
    i := 0;
    while (i < Integer(nitems)) and (prop[i] <> 0) do
      Inc(i);
    Inc(i); { skip the null }
    { Now read the class name }
    SetLength(s, 0);
    while (i < Integer(nitems)) and (prop[i] <> 0) do
    begin
      s := s + chr(prop[i]);
      Inc(i);
    end;
    Result := s;
  end;
  XFree(prop);
end;

{ ------------------------------------------------------------------ }
function TX11Backend.IsMapped(window: TWindow): Boolean;
var
  attrib: TXWindowAttributes;
begin
  Result := False;
  if (FDpy = nil) or (XGetWindowAttributes(FDpy, window, @attrib) = 0) then
    Exit;
  Result := (attrib.map_state = IsViewable) or (attrib.map_state = IsUnviewable);
end;

{ ------------------------------------------------------------------ }
procedure TX11Backend.GetWindowGeometry(window: TWindow; out x, y, w, h: LongInt);
var
  root_ret: TWindow;
  abs_x, abs_y: cint;
  width, height: cuint;
  border, depth: cuint;
begin
  x := 0; y := 0; w := 0; h := 0;
  if FDpy = nil then
    Exit;
  if XGetGeometry(FDpy, window, @root_ret, @abs_x, @abs_y,
    @width, @height, @border, @depth) > 0 then
  begin
    x := abs_x;
    y := abs_y;
    w := width;
    h := height;
  end;
end;

{ ------------------------------------------------------------------ }
function TX11Backend.IsPhantom(const win: TX11Window): Boolean;
begin
  { Phantom: no title AND no WM_CLASS }
  Result := (win.name = '') and (win.wm_class = '');
end;

{ ------------------------------------------------------------------ }
procedure TX11Backend.ComputeImportance(win: PX11Window; winCount: Integer);
var
  score: Integer;
begin
  score := 0;

  { Active window gets top priority }
  if win^.is_focus then
    score := score + 1000;

  { Has a WM_CLASS — real application }
  if win^.wm_class <> '' then
    score := score + 500;

  { Has a title — visible window }
  if win^.name <> '' then
    score := score + 250;

  { Has a PID — real process }
  if win^.pid > 0 then
    score := score + 100;

  { Not a phantom }
  if not win^.is_phantom then
    score := score + 50;

  { Earlier in the list tends to mean higher in the stack }
  score := score + (winCount - Integer(win^.id) mod winCount);

  win^.importance := score;
end;

{ ------------------------------------------------------------------ }
procedure TX11Backend.SortByImportance(var wins: TX11WindowList);
var
  i, j: Integer;
  tmp: TX11Window;
  winCount: Integer;
begin
  winCount := Length(wins);
  if winCount < 2 then
    Exit;

  { Simple insertion sort: stable, O(n²) fine for <200 windows }
  for i := 1 to winCount - 1 do
  begin
    j := i;
    while (j > 0) and (wins[j-1].importance < wins[j].importance) do
    begin
      tmp := wins[j-1];
      wins[j-1] := wins[j];
      wins[j] := tmp;
      Dec(j);
    end;
  end;
end;

{ ================================================================= }
{ TX11Backend — core window & focus operations (continued)         }
{ ================================================================= }

{ EnumerateWindows: query X server for all top-level windows }
function TX11Backend.EnumerateWindows: TX11WindowList;
var
  rootRet, parentRet: PWindow;
  children: PWindow;
  nchildren: cuint;
  i: Integer;
  attr: TXWindowAttributes;
  focused: TWindow;
begin
  SetLength(Result, 0);
  if (not FConnected) or (FDpy = nil) then Exit;

  children := nil;
  nchildren := 0;
  if XQueryTree(FDpy, FRoot, @rootRet, @parentRet, @children, @nchildren) = 0 then
    Exit;

  if (children = nil) or (nchildren = 0) then
  begin
    if children <> nil then XFree(children);
    Exit;
  end;

  SetLength(Result, nchildren);
  for i := 0 to nchildren - 1 do
  begin
    FillChar(Result[i], SizeOf(TX11Window), 0);
    Result[i].id := children[i];
    Result[i].name := GetWindowName(children[i]);
    Result[i].wm_class := GetWindowClass(children[i]);
    Result[i].pid := ReadWindowPid(children[i]);
    Result[i].is_phantom := IsPhantom(Result[i]);
    Result[i].is_mapped := IsMapped(children[i]);
    if XGetWindowAttributes(FDpy, children[i], @attr) > 0 then
    begin
      Result[i].x := attr.x;
      Result[i].y := attr.y;
      Result[i].width := attr.width;
      Result[i].height := attr.height;
    end;
  end;

  XFree(children);

  { Mark the focused window }
  focused := GetFocusedWindow;
  for i := 0 to High(Result) do
    if Result[i].id = focused then
      Result[i].is_focus := True;

  { Rank by importance }
  for i := 0 to High(Result) do
    ComputeImportance(@Result[i], Length(Result));
  SortByImportance(Result);
end;

{ FindWindow: search window list by name or WM_CLASS }
function TX11Backend.FindWindow(const pattern: AnsiString): TWindow;
var
  wins: TX11WindowList;
  i: Integer;
begin
  Result := 0;
  if (not FConnected) or (FDpy = nil) then Exit;
  wins := EnumerateWindows;
  for i := 0 to High(wins) do
  begin
    if (wins[i].name = pattern) or (wins[i].wm_class = pattern) then
    begin
      Result := wins[i].id;
      Exit;
    end;
  end;
end;

{ GetDisplayString: return the DISPLAY environment variable }
function TX11Backend.GetDisplayString: AnsiString;
begin
  Result := fpGetEnv('DISPLAY');
  if Result = '' then
    Result := '(none)';
end;

{ ------------------------------------------------------------------ }

function TX11Backend.GetFocusedWindow: TWindow;
var
  revert: cint;
begin
  Result := 0;
  if (not FConnected) or (FDpy = nil) then Exit;
  XGetInputFocus(FDpy, @Result, @revert);
end;

function TX11Backend.SetActiveWindow(window: TWindow): Boolean;
begin
  Result := False;
  if (not FConnected) or (FDpy = nil) or (window = 0) then Exit;
  if XSetInputFocus(FDpy, window, RevertToParent, CurrentTime) >= 0 then
  begin
    XRaiseWindow(FDpy, window);
    XFlush(FDpy);
    Result := True;
  end;
end;

procedure TX11Backend.RaiseWindowX(window: TWindow);
begin
  if (not FConnected) or (FDpy = nil) or (window = 0) then Exit;
  XRaiseWindow(FDpy, window);
  XFlush(FDpy);
end;

{ FocusWindow: raises and sets input focus — returns success }
function TX11Backend.FocusWindow(window: TWindow): Boolean;
begin
  if (not FConnected) or (FDpy = nil) or (window = 0) then
  begin
    Result := False;
    Exit;
  end;
  RaiseWindowX(window);
  Result := SetActiveWindow(window);
end;

function TX11Backend.FocusWindowByName(const name: AnsiString): Boolean;
var
  wins: TX11WindowList;
  i: Integer;
begin
  Result := False;
  if not FConnected then Exit;
  wins := EnumerateWindows;
  for i := 0 to High(wins) do
    if wins[i].name = name then
    begin
      Result := FocusWindow(wins[i].id);
      Exit;
    end;
end;

{ ForceUnmap: unmaps (hides) a window at the X11 level }
procedure TX11Backend.ForceUnmap(window: TWindow);
begin
  if (not FConnected) or (FDpy = nil) or (window = 0) then Exit;
  XUnmapWindow(FDpy, window);
  XFlush(FDpy);
end;

{ ================================================================= }
{ TX11Backend — X11 hotkey listener                              }
{ ================================================================= }

{ Parse a key combo string like "Ctrl+Alt+T" into modifiers and keycode.
  Last segment is the key name; all preceding segments are modifier names. }
function TX11Backend.RegisterX11Hotkey(const combo: AnsiString; action: AnsiString): Boolean;
var
  parts: array[0..7] of AnsiString;
  nparts   : Integer;
  idx      : Integer;
  keycode  : TKeyCode;
  modifiers: cuint;
  keysym   : TKeySym;
  keyStr   : AnsiString;
  s        : AnsiString;
  p        : Integer;
begin
  Result := False;
  if (not FConnected) or (FDpy = nil) then Exit;

  modifiers := 0;
  nparts    := 0;
  s         := combo;

  { split on '+' }
  while (Length(s) > 0) and (nparts < 8) do
  begin
    p := pos('+', s);
    if p > 0 then
    begin
      parts[nparts] := Copy(s, 1, p - 1);
      s := Copy(s, p + 1, MaxInt);
      Inc(nparts);
    end
    else
    begin
      parts[nparts] := s;
      Inc(nparts);
      s := '';
    end;
  end;

  if nparts = 0 then Exit;
  keyStr := parts[nparts - 1];

  { parse modifier names (case-insensitive via LowerCase) }
  for idx := 0 to nparts - 2 do
  begin
    if LowerCase(parts[idx]) = 'ctrl' then
      modifiers := modifiers or ControlMask
    else if LowerCase(parts[idx]) = 'shift' then
      modifiers := modifiers or ShiftMask
    else if LowerCase(parts[idx]) = 'alt' then
      modifiers := modifiers or Mod1Mask
    else if LowerCase(parts[idx]) = 'super' then
      modifiers := modifiers or Mod4Mask
    else if LowerCase(parts[idx]) = 'meta' then
      modifiers := modifiers or Mod4Mask;
  end;

  keysym := XStringToKeysym(PChar(keyStr));
  keycode := XKeysymToKeycode(FDpy, keysym);

  if keycode > 0 then
  begin
    XGrabKey(FDpy, keycode, modifiers, FRoot, 0, GrabModeAsync, GrabModeAsync);
    XFlush(FDpy);
    Result := True;
  end;
end;

function TX11Backend.UnregisterX11Hotkey(const combo: AnsiString): Boolean;
var
  parts: array[0..7] of AnsiString;
  nparts   : Integer;
  idx      : Integer;
  keycode  : TKeyCode;
  modifiers: cuint;
  keysym   : TKeySym;
  keyStr   : AnsiString;
  s        : AnsiString;
  p        : Integer;
begin
  Result := False;
  if (not FConnected) or (FDpy = nil) then Exit;

  modifiers := 0;
  nparts := 0;
  s := combo;

  while (Length(s) > 0) and (nparts < 8) do
  begin
    p := pos('+', s);
    if p > 0 then
    begin
      parts[nparts] := Copy(s, 1, p - 1);
      s := Copy(s, p + 1, MaxInt);
      Inc(nparts);
    end
    else
    begin
      parts[nparts] := s;
      Inc(nparts);
      s := '';
    end;
  end;

  if nparts = 0 then Exit;
  keyStr := parts[nparts - 1];

  for idx := 0 to nparts - 2 do
  begin
    if LowerCase(parts[idx]) = 'ctrl' then
      modifiers := modifiers or ControlMask
    else if LowerCase(parts[idx]) = 'shift' then
      modifiers := modifiers or ShiftMask
    else if LowerCase(parts[idx]) = 'alt' then
      modifiers := modifiers or Mod1Mask
    else if LowerCase(parts[idx]) = 'super' then
      modifiers := modifiers or Mod4Mask
    else if LowerCase(parts[idx]) = 'meta' then
      modifiers := modifiers or Mod4Mask;
  end;

  keysym := XStringToKeysym(PChar(keyStr));
  keycode := XKeysymToKeycode(FDpy, keysym);

  if keycode > 0 then
  begin
    XUngrabKey(FDpy, keycode, modifiers, FRoot);
    XFlush(FDpy);
    Result := True;
  end;
end;

{ X11PollEvents: drain pending X11 events, return count processed }
function TX11Backend.X11PollEvents(uinput: TUinputBackend): LongInt;
var
  event: TXEvent;
begin
  Result := 0;
  if (not FConnected) or (FDpy = nil) then Exit;

  while XPending(FDpy) > 0 do
  begin
    XNextEvent(FDpy, @event);
    Inc(Result);
  end;
end;
end.
