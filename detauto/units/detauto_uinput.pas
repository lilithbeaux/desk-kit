{ ===================================================================
  detauto_uinput — Kernel-level input injection via /dev/uinput.
  PRIMARY input route — injects events directly into the Linux kernel
  input subsystem; visible to ALL layers (X11, Wayland, console, AT-SPI).
  If unavailable, caller falls back to X11-level xdotool route.
  =================================================================== }
unit detauto_uinput;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, BaseUnix, UnixType, Unix,
  detauto_types;

type
  TUinputBackend = class
  private
    Fd       : cint;
    FInited  : Boolean;
    FDevName : array[0..63] of AnsiChar;
    function SetupDevice(const devName: AnsiString): Boolean;
    procedure InjectRaw(const ev: TInputEvent);
  public
    constructor Create(const devName: AnsiString = 'det-auto-uinput');
    destructor Destroy; override;
    function Init: Boolean;
    function Shutdown: Boolean;
    function IsActive: Boolean;
    procedure KeyDown(code: Word);
    procedure KeyUp(code: Word);
    procedure KeyPress(code: Word);
    procedure TypeText(const text: AnsiString);
    procedure MouseMoveRelative(dx, dy: Integer);
    procedure MouseClick(btn: Word);
    function GetDeviceName: AnsiString;
    procedure MouseDown(btn: Word);
    procedure MouseUp(btn: Word);
  end;

{ Convenience: build and inject a key-combo from a string like "ctrl+t" }
function UinputKeyCombo(const combo: AnsiString): Boolean;
function UinputTypeText(const text: AnsiString): Boolean;
function UinputMouseMove(dx, dy: Integer): Boolean;
function UinputClick(btn: Word): Boolean;

implementation

{ ------------------------------------------------------------------- }
constructor TUinputBackend.Create(const devName: AnsiString);
begin
  Fd := -1;
  FInited := False;
  StrPLCopy(FDevName, devName, 63);
end;

destructor TUinputBackend.Destroy;
begin
  if FInited then
    Shutdown;
  inherited;
end;

function TUinputBackend.IsActive: Boolean;
begin
  Result := FInited;
end;

function TUinputBackend.GetDeviceName: AnsiString;
begin
  Result := StrPas(@FDevName[0]);
  if Result = '' then
    Result := 'uinput';
end;

{ Open /dev/uinput, register key + rel event bits, create device }
function TUinputBackend.SetupDevice(const devName: AnsiString): Boolean;
var
  uidev: TUinputUserDev;
  ic: cint;
  i: Integer;
  tv: TTimeVal;
begin
  Result := False;
  FillChar(uidev, SizeOf(uidev), 0);
  StrPLCopy(uidev.name, devName, UINPUT_MAX_NAME_SIZE - 1);

  { Enable EV_KEY and EV_REL }
  ic := EV_KEY;
  if fpIOctl(Fd, UI_SET_EVBIT, @ic) < 0 then
  begin
    WriteLn(stderr, 'det-auto[uinput]: UI_SET_EVBIT(EV_KEY) failed');
    Exit;
  end;

  ic := EV_REL;
  if fpIOctl(Fd, UI_SET_EVBIT, @ic) < 0 then
  begin
    WriteLn(stderr, 'det-auto[uinput]: UI_SET_EVBIT(EV_REL) failed');
    Exit;
  end;

  ic := EV_SYN;
  fpIOctl(Fd, UI_SET_EVBIT, @ic);  { best-effort }

  { Register all key codes 1..255 }
  for i := 1 to 255 do
  begin
    ic := i;
    fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  end;

  { Extended keys }
  ic := MOD_KEY_CTRL_L;   fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  ic := MOD_KEY_CTRL_R;   fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  ic := MOD_KEY_SHIFT_L;  fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  ic := MOD_KEY_SHIFT_R;  fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  ic := MOD_KEY_ALT_L;    fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  ic := MOD_KEY_ALT_R;    fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  ic := MOD_KEY_SUPER_L;  fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  ic := MOD_KEY_SUPER_R;  fpIOctl(Fd, UI_SET_KEYBIT, @ic);

  { Mouse buttons }
  for i := BTN_LEFT to BTN_BACK do
  begin
    ic := i;
    fpIOctl(Fd, UI_SET_KEYBIT, @ic);
  end;

  { Relative axes }
  ic := REL_X;   fpIOctl(Fd, UI_SET_RELBIT, @ic);
  ic := REL_Y;   fpIOctl(Fd, UI_SET_RELBIT, @ic);

  { Write device struct }
  if fpWrite(Fd, @uidev, SizeOf(uidev)) <> SizeOf(uidev) then
  begin
    WriteLn(stderr, 'det-auto[uinput]: write(uinput_user_dev) failed');
    Exit;
  end;

  { Create device }
  if fpIOctl(Fd, UI_DEV_CREATE, nil) < 0 then
  begin
    WriteLn(stderr, 'det-auto[uinput]: UI_DEV_CREATE failed');
    Exit;
  end;

  { Sleep 100us for kernel to register }
  tv.tv_sec := 0;
  tv.tv_usec := 100;
  fpSelect(0, nil, nil, nil, @tv);

  Result := True;
end;

function TUinputBackend.Init: Boolean;
begin
  if FInited then
    Exit(True);

  Fd := fpOpen(UINPUT_DEV, O_RDWR);
  if Fd < 0 then
  begin
    Fd := fpOpen('/dev/input/uinput', O_RDWR);
    if Fd < 0 then
    begin
      WriteLn(stderr, 'det-auto[uinput]: cannot open /dev/uinput');
      Exit(False);
    end;
  end;

  if not SetupDevice(FDevName) then
  begin
    fpClose(Fd);
    Fd := -1;
    Exit(False);
  end;

  FInited := True;
  Exit(True);
end;

function TUinputBackend.Shutdown: Boolean;
begin
  if not FInited then
    Exit(True);
  fpIOctl(Fd, UI_DEV_DESTROY, nil);
  fpClose(Fd);
  Fd := -1;
  FInited := False;
  Exit(True);
end;

{ ------------------------------------------------------------------- }
procedure TUinputBackend.InjectRaw(const ev: TInputEvent);
var
  n: cint;
begin
  if not FInited then
    Exit;
  n := fpWrite(Fd, @ev, SizeOf(TInputEvent));
  if n <> SizeOf(TInputEvent) then
    WriteLn(stderr, 'det-auto[uinput]: write failed (', n, ')');
end;

{ ------------------------------------------------------------------- }
procedure TUinputBackend.KeyDown(code: Word);
var
  ev: TInputEvent;
begin
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_KEY;
  ev.code := code;
  ev.value := KVAL_DOWN;
  InjectRaw(ev);
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_SYN;
  ev.code := SYN_REPORT;
  InjectRaw(ev);
end;

procedure TUinputBackend.KeyUp(code: Word);
var
  ev: TInputEvent;
begin
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_KEY;
  ev.code := code;
  ev.value := KVAL_UP;
  InjectRaw(ev);
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_SYN;
  ev.code := SYN_REPORT;
  InjectRaw(ev);
end;

procedure TUinputBackend.KeyPress(code: Word);
var
  tv: TTimeVal;
begin
  KeyDown(code);
  { 5ms hold }
  tv.tv_sec := 0; tv.tv_usec := 5000;
  fpSelect(0, nil, nil, nil, @tv);
  KeyUp(code);
end;

procedure TUinputBackend.MouseMoveRelative(dx, dy: Integer);
var
  ev: TInputEvent;
begin
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_REL;
  ev.code := REL_X;
  ev.value := dx;
  InjectRaw(ev);
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_REL;
  ev.code := REL_Y;
  ev.value := dy;
  InjectRaw(ev);
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_SYN;
  ev.code := SYN_REPORT;
  InjectRaw(ev);
end;

procedure TUinputBackend.MouseDown(btn: Word);
var
  ev: TInputEvent;
begin
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_KEY;
  ev.code := btn;
  ev.value := KVAL_DOWN;
  InjectRaw(ev);
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_SYN;
  ev.code := SYN_REPORT;
  InjectRaw(ev);
end;

procedure TUinputBackend.MouseUp(btn: Word);
var
  ev: TInputEvent;
begin
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_KEY;
  ev.code := btn;
  ev.value := KVAL_UP;
  InjectRaw(ev);
  FillChar(ev, SizeOf(ev), 0);
  ev.event_type := EV_SYN;
  ev.code := SYN_REPORT;
  InjectRaw(ev);
end;

procedure TUinputBackend.MouseClick(btn: Word);
var
  tv: TTimeVal;
begin
  MouseDown(btn);
  tv.tv_sec := 0; tv.tv_usec := 20000;
  fpSelect(0, nil, nil, nil, @tv);
  MouseUp(btn);
end;

procedure TUinputBackend.TypeText(const text: AnsiString);
const
  digit_codes: array[0..9] of Word = (2,3,4,5,6,7,8,9,10,11);
var
  i: Integer;
  ch: AnsiChar;
  code: Word;
  need_shift: Boolean;
  idx: Integer;
  tv: TTimeVal;
begin
  for i := 1 to Length(text) do
  begin
    ch := text[i];
    need_shift := False;

    { Check if uppercase letter }
    if (ch >= 'A') and (ch <= 'Z') then
    begin
      need_shift := True;
      code := KeyNameToCode(LowerCase(String(ch)));
    end
    { Check if lowercase letter }
    else if (ch >= 'a') and (ch <= 'z') then
    begin
      code := KeyNameToCode(String(ch));
    end
    { Check if digit }
    else if (ch >= '0') and (ch <= '9') then
    begin
      idx := Ord(ch) - Ord('0');
      code := digit_codes[idx];
    end
    { Check if special shifted character }
    else
    begin
      code := KeyNameToCode(String(ch));
      if code = 0 then
      begin
        { Try shifted version — use Ord to avoid string/char mismatch }
        case Ord(ch) of
          33: begin code := digit_codes[0]; need_shift := True; end;
          64: begin code := digit_codes[1]; need_shift := True; end;
          35: begin code := digit_codes[2]; need_shift := True; end;
          36: begin code := digit_codes[3]; need_shift := True; end;
          37: begin code := digit_codes[4]; need_shift := True; end;
          94: begin code := digit_codes[5]; need_shift := True; end;
          38: begin code := digit_codes[6]; need_shift := True; end;
          42: begin code := digit_codes[7]; need_shift := True; end;
          40: begin code := digit_codes[8]; need_shift := True; end;
          41: begin code := digit_codes[9]; need_shift := True; end;
          95: begin code := KEY_MINUS; need_shift := True; end;
          43: begin code := KEY_EQUAL; need_shift := True; end;
          123: begin code := KEY_LEFTBRACE; need_shift := True; end;
          125: begin code := KEY_RIGHTBRACE; need_shift := True; end;
          124: begin code := KEY_BACKSLASH; need_shift := True; end;
          58: begin code := KEY_SEMICOLON; need_shift := True; end;
          34: begin code := KEY_APOSTROPHE; need_shift := True; end;
          60: begin code := KEY_COMMA; need_shift := True; end;
          62: begin code := KEY_DOT; need_shift := True; end;
          63: begin code := KEY_SLASH; need_shift := True; end;
          126: begin code := KEY_GRAVE; need_shift := True; end;
        else
          code := 0;
        end;
      end;
    end;

    if code > 0 then
    begin
      if need_shift then
      begin
        KeyDown(MOD_KEY_SHIFT_L);
        KeyPress(code);
        KeyUp(MOD_KEY_SHIFT_L);
      end
      else
        KeyPress(code);
    end;

    { 5ms delay between keys }
    tv.tv_sec := 0; tv.tv_usec := 5000;
    fpSelect(0, nil, nil, nil, @tv);
  end;
end;

{ ------------------------------------------------------------------- }
function UinputKeyCombo(const combo: AnsiString): Boolean;
var
  uin: TUinputBackend;
  codes: TKeyCodeArray;
  i: Integer;
  n: Integer;
begin
  Result := False;
  codes := ParseKeyCombo(combo);
  n := Length(codes);
  if n = 0 then
    Exit;

  uin := TUinputBackend.Create;
  try
    if not uin.Init then
      Exit;

    { Press modifiers first }
    for i := 0 to n - 2 do
      uin.KeyDown(codes[i]);

    { Press the final key }
    uin.KeyPress(codes[n - 1]);

    { Release modifiers }
    for i := n - 2 downto 0 do
      uin.KeyUp(codes[i]);
  finally
    uin.Free;
  end;
  Result := True;
end;

function UinputTypeText(const text: AnsiString): Boolean;
var
  uin: TUinputBackend;
begin
  uin := TUinputBackend.Create;
  try
    if not uin.Init then
      Exit(False);
    uin.TypeText(text);
  finally
    uin.Free;
  end;
  Result := True;
end;

function UinputMouseMove(dx, dy: Integer): Boolean;
var
  uin: TUinputBackend;
begin
  uin := TUinputBackend.Create;
  try
    if not uin.Init then
      Exit(False);
    uin.MouseMoveRelative(dx, dy);
  finally
    uin.Free;
  end;
  Result := True;
end;

function UinputClick(btn: Word): Boolean;
var
  uin: TUinputBackend;
begin
  uin := TUinputBackend.Create;
  try
    if not uin.Init then
      Exit(False);
    uin.MouseClick(btn);
  finally
    uin.Free;
  end;
  Result := True;
end;

end.
