{ ===================================================================
  detauto_inputevt — Kernel-level input event listener.
  Monitors /dev/input/event* directly: this is the “below X11”
  hotkey detector. It intercepts key events BEFORE X11 ever sees
  them, tracks modifier state, and matches registered hotkey combos.
  =================================================================== }
unit detauto_inputevt;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, BaseUnix, UnixType, Unix,
  detauto_types;

const
  { epoll_ctl operations }
  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  EPOLL_CTL_MOD = 3;
  { epoll_ctl operations above; EPOLLIN/OUT/ERR/HUP in detauto_types }
  EPOLLWAKEUP = LongInt($80000000);

  { Number of event devices to track }
  MAX_EVENT_FDS = 32;

type
  { Callback when a registered hotkey fires }
  { (THotkeyCallback is now in detauto_types) }

  { Single file-descriptor entry in the epoll set }
  TEventFdEntry = record
    fd     : cint;
    evdev  : array[0..63] of AnsiChar;  { device path e.g. /dev/input/event3 }
    fd_valid: Boolean;
  end;

  { The kernel-level input event listener daemon }
  TInputEvtDaemon = class
  private
    FEpollFd     : cint;
    FEntries     : array[0..MAX_EVENT_FDS-1] of TEventFdEntry;
    FEntryCount  : Integer;
    FEds         : array[0..MAX_EVENT_FDS-1] of TEpollEvent;
    FModState    : TModState;
    FHotkeys     : THotkeyList;
    FHotkeyCount : Integer;
    FFiredCount  : Integer;
    FOnHotkey    : THotkeyCallback;
    FRunning     : Boolean;
    function  OpenEventDevices: Integer;
    procedure CloseAllFds;
    procedure ProcessOneEvent(var ev: TInputEvent);
    function  CheckHotkeys: Boolean;
    procedure SetModFromKey(code: Word; pressed: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    procedure RegisterHotkey(const combo, action: AnsiString);
    procedure SetCallback(cb: THotkeyCallback);
    function  Start: Boolean;
    procedure Stop;
    { Call this from the main event loop. It blocks for up to timeout_ms.
      Returns the number of hotkeys fired. }
    function  PollOnce(timeout_ms: Integer = 0): Integer;
  end;

implementation

{ epoll wrappers — declared as external C functions }
function epoll_create1(flags: cint): cint; cdecl; external;
function epoll_ctl(epfd: cint; op: cint; fd: cint; event: pointer): cint; cdecl; external;
function epoll_wait(epfd: cint; events: pointer; maxevents: cint; timeout: cint): cint; cdecl; external;

{ ------------------------------------------------------------------ }
constructor TInputEvtDaemon.Create;
var
  i: Integer;
begin
  FEpollFd := -1;
  FEntryCount := 0;
  FRunning := False;
  FillChar(FEntries, SizeOf(FEntries), 0);
  FillChar(FEds, SizeOf(FEds), 0);
  FillChar(FModState, SizeOf(FModState), 0);
  FModState.ctrl_key := KEY_LEFTCTRL;
  FModState.shift_key := KEY_LEFTSHIFT;
  FModState.alt_key := KEY_LEFTALT;
  FModState.super_key := KEY_LEFTMETA;
  FOnHotkey := nil;
  FFiredCount := 0;
  FHotkeyCount := 0;
  FRunning := False;
  SetLength(FHotkeys, 0);
  for i := 0 to MAX_EVENT_FDS - 1 do
    FEntries[i].fd := -1;
end;

{ ------------------------------------------------------------------ }
destructor TInputEvtDaemon.Destroy;
begin
  Stop;
  inherited;
end;

{ ------------------------------------------------------------------ }
procedure TInputEvtDaemon.SetCallback(cb: THotkeyCallback);
begin
  FOnHotkey := cb;
end;

{ ------------------------------------------------------------------ }
procedure TInputEvtDaemon.RegisterHotkey(const combo, action: AnsiString);
var
  h: THotkeyRec;
  codes: TKeyCodeArray;
  i: Integer;
begin
  codes := ParseKeyCombo(combo);
  if Length(codes) = 0 then
  begin
    WriteLn(stderr, 'det-auto[inputevt]: unknown key combo: ', combo);
    Exit;
  end;
  SetLength(FHotkeys, FHotkeyCount + 1);
  h := Default(THotkeyRec);
  h.combo_str := combo;
  h.action := action;
  h.nkeys := Length(codes);
  for i := 0 to High(codes) do
  begin
    if i < 8 then
      h.codes[i] := codes[i];
  end;
  FHotkeys[FHotkeyCount] := h;
  Inc(FHotkeyCount);
  WriteLn('[det-auto[inputevt]] registered hotkey: ', combo, ' -> ', action);
end;

{ ------------------------------------------------------------------ }
{ Scan /proc/bus/input/devices to find event device names, then
  open each /dev/input/event* that exists. }
function TInputEvtDaemon.OpenEventDevices: Integer;
var
  f: TextFile;
  line: AnsiString;
  dev_name: AnsiString;
  event_path: AnsiString;
  dev_fd: cint;
  i: Integer;
  numStr: AnsiString;
  j: Integer;
begin
  Result := 0;

  { Read /proc/bus/input/devices to find keyboard handlers }
  AssignFile(f, '/proc/bus/input/devices');
  {$I-}
  Reset(f);
  {$I+}
  if IoResult <> 0 then
  begin
    WriteLn(stderr, 'det-auto[inputevt]: cannot read /proc/bus/input/devices');
    Exit(0);
  end;

  dev_name := '';
  while not Eof(f) do
  begin
    ReadLn(f, line);
    if Copy(Trim(line), 1, 5) = 'Name=' then
    begin
      dev_name := Trim(Copy(line, Pos('=', line) + 1, Length(line)));
      { strip quotes }
      if Pos('"', dev_name) > 0 then
        dev_name := Copy(dev_name, Pos('"', dev_name) + 1, LastDelimiter('"', dev_name) - 2);
    end;

    if Copy(Trim(line), 1, 4) = 'H:' then
    begin
      { Extract event handler from line like: H: Handlers=kbd event3 }
      if (Pos('kbd', line) > 0) or (Pos('event', line) > 0) then
      begin
        { find eventN name }
        event_path := '';
        i := 1;
        while i <= Length(line) - 5 do
        begin
          if Copy(line, i, 6) = 'event' then
          begin
            { extract digits }
            numStr := '';
            j := i + 6;
            while (j <= Length(line)) and (line[j] >= '0') and (line[j] <= '9') do
            begin
              numStr := numStr + line[j];
              Inc(j);
            end;
            if numStr <> '' then
            begin
              event_path := '/dev/input/event' + numStr;
              Break;
            end;
          end;
          Inc(i);
        end;

        if (event_path <> '') and (FEntryCount < MAX_EVENT_FDS) then
        begin
          dev_fd := fpOpen(event_path, O_RDWR or O_NONBLOCK);
          if dev_fd >= 0 then
          begin
            FEntries[FEntryCount].fd := dev_fd;
            StrPLCopy(FEntries[FEntryCount].evdev, event_path, 63);
            FEntries[FEntryCount].fd_valid := True;
            Inc(FEntryCount);
            Inc(Result);
            { Register with epoll }
            FEds[FEntryCount - 1].events := EPOLLIN or EPOLLWAKEUP;
            FEds[FEntryCount - 1].data := UInt64(dev_fd);
            if epoll_ctl(FEpollFd, EPOLL_CTL_ADD, dev_fd, @FEds[FEntryCount - 1]) < 0 then
              WriteLn(stderr, 'det-auto[inputevt]: epoll_ctl failed for ', event_path);
          end;
        end;
        dev_name := '';
      end;
    end;
  end;

  CloseFile(f);
  Exit(Result);
end;

{ ------------------------------------------------------------------ }
procedure TInputEvtDaemon.CloseAllFds;
var
  i: Integer;
begin
  for i := 0 to FEntryCount - 1 do
  begin
    if FEntries[i].fd_valid then
    begin
      epoll_ctl(FEpollFd, EPOLL_CTL_DEL, FEntries[i].fd, nil);
      fpClose(FEntries[i].fd);
      FEntries[i].fd := -1;
      FEntries[i].fd_valid := False;
    end;
  end;
  FEntryCount := 0;
end;

{ ------------------------------------------------------------------ }
procedure TInputEvtDaemon.SetModFromKey(code: Word; pressed: Boolean);
begin
  case code of
    KEY_LEFTCTRL, KEY_RIGHTCTRL:   FModState.ctrl := pressed;
    KEY_LEFTSHIFT, KEY_RIGHTSHIFT: FModState.shift := pressed;
    KEY_LEFTALT, KEY_RIGHTALT:     FModState.alt := pressed;
    KEY_LEFTMETA, KEY_RIGHTMETA:   FModState.super := pressed;
  end;
end;

{ ------------------------------------------------------------------ }
{ Process one input_event from a keyboard device. }
procedure TInputEvtDaemon.ProcessOneEvent(var ev: TInputEvent);
var
  fired: Integer;
  i: Integer;
  j: Integer;
  match: Boolean;
  pressed: Boolean;
  kc: Word;
  is_mod: Boolean;
begin
  { Only care about EV_KEY events }
  if ev.event_type <> EV_KEY then
    Exit;

  { Mouse buttons are not hotkeys }
  if (ev.code >= BTN_LEFT) and (ev.code <= BTN_BACK) then
    Exit;

  { Key codes >= 256 are not keyboard keys }
  if ev.code > 255 then
    Exit;

  pressed := (ev.value = KVAL_DOWN);

  { Update modifier state }
  SetModFromKey(ev.code, pressed);

  { Don't match combos on key release }
  if not pressed then
    Exit;

  { Check all registered hotkeys }
  for i := 0 to FHotkeyCount - 1 do
  begin
    match := True;
    { Check modifiers }
    for j := 0 to FHotkeys[i].nkeys - 2 do
    begin
      kc := FHotkeys[i].codes[j];
      is_mod := False;
      if (kc = KEY_LEFTCTRL) or (kc = KEY_RIGHTCTRL) then
        is_mod := (FModState.ctrl);
      if (kc = KEY_LEFTSHIFT) or (kc = KEY_RIGHTSHIFT) then
        is_mod := (FModState.shift);
      if (kc = KEY_LEFTALT) or (kc = KEY_RIGHTALT) then
        is_mod := (FModState.alt);
      if (kc = KEY_LEFTMETA) or (kc = KEY_RIGHTMETA) then
        is_mod := (FModState.super);
      { Non-modifier keys in the modifier position — treat as literal press }
      if not is_mod then
        is_mod := True;
      if not is_mod then
      begin
        match := False;
        Break;
      end;
    end;

    { Check the final (non-modifier) key }
    if match and (ev.code = FHotkeys[i].codes[FHotkeys[i].nkeys - 1]) then
    begin
      { Fire the hotkey action }
      if Length(FHotkeys[i].action) > 0 then
      begin
        if Assigned(FOnHotkey) then
        begin
          WriteLn('[det-auto[inputevt]] hotkey fired: ', FHotkeys[i].combo_str);
          FOnHotkey(FHotkeys[i].action);
        end;
      end;
      Inc(FFiredCount);
    end;
  end;
end;

{ ------------------------------------------------------------------ }
function TInputEvtDaemon.CheckHotkeys: Boolean;
begin
  Result := (FModState.ctrl or FModState.shift or FModState.alt or FModState.super);
end;

{ ------------------------------------------------------------------ }
function TInputEvtDaemon.Start: Boolean;
var
  opened: Integer;
begin
  if FRunning then
    Exit(True);

  { Create epoll instance }
  FEpollFd := epoll_create1(EPOLLWAKEUP);
  if FEpollFd < 0 then
  begin
    WriteLn(stderr, 'det-auto[inputevt]: epoll_create1 failed');
    Exit(False);
  end;

  { Open event devices }
  opened := OpenEventDevices;
  WriteLn('[det-auto[inputevt]] opened ', opened, ' event devices');

  FRunning := True;
  Result := True;
end;

{ ------------------------------------------------------------------ }
procedure TInputEvtDaemon.Stop;
begin
  if not FRunning then
    Exit;
  FRunning := False;
  CloseAllFds;
  if FEpollFd >= 0 then
  begin
    fpClose(FEpollFd);
    FEpollFd := -1;
  end;
end;

{ ------------------------------------------------------------------ }
{ Poll all event devices for input for up to timeout_ms milliseconds.
  Returns the number of hotkeys that fired. }
function TInputEvtDaemon.PollOnce(timeout_ms: Integer = 0): Integer;
var
  nevents: cint;
  i: Integer;
  buf: array[0..63] of TInputEvent;
  nread: cint;
  cnt: Integer;
  fd: Integer;
  ev_idx: Integer;
begin
  Result := 0;
  FFiredCount := 0;
  if not FRunning or (FEpollFd < 0) then
    Exit(0);

  nevents := epoll_wait(FEpollFd, @FEds[0], MAX_EVENT_FDS, timeout_ms);
  if nevents <= 0 then
    Exit(0);

  for i := 0 to nevents - 1 do
  begin
    fd := Integer(FEds[i].data);
    { Read all available events on this fd }
    repeat
      nread := fpRead(fd, @buf, SizeOf(TInputEvent) * 64);
      if nread <= 0 then
        Break;
      cnt := nread div SizeOf(TInputEvent);
      ev_idx := 0;
      while ev_idx < cnt do
      begin
        ProcessOneEvent(buf[ev_idx]);
        Inc(ev_idx);
      end;
    until nread <= 0;
  end;

  Result := FFiredCount;
end;

end.
