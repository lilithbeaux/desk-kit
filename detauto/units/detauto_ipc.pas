{ ===================================================================
  detauto_ipc — Unix-socket IPC + CLI dispatcher.
  The daemon listens on /tmp/detauto.sock.  The CLI connects, sends
  a single command line, reads a response line, disconnects.
  Protocol:  each message is a newline-terminated ASCII string.
  ------------------------------------------------------------------ }
unit detauto_ipc;

{$MODE OBJFPC}{$H+}

interface

uses
  Classes, SysUtils,
  Unix, BaseUnix, UnixType,
  sockets,
  detauto_types;

const
  IPC_SOCKET_PATH = '/tmp/detauto.sock';
  IPC_MAX_CMD     = 1024;
  IPC_MAX_RESP    = 4096;

{ Command result codes }
  IPC_RC_OK         = 'OK';
  IPC_RC_ERR        = 'ERR';
  IPC_RC_RESULT     = 'RESULT';

{ Command dispatch — fills CmdResult }
  IPC_CMD_PING      = 'ping';
  IPC_CMD_HOTKEY    = 'hotkey';
  IPC_CMD_TYPE      = 'type';
  IPC_CMD_MOUSE     = 'mouse';
  IPC_CMD_CLICK     = 'click';
  IPC_CMD_WINDOWS   = 'windows';
  IPC_CMD_FOCUS     = 'focus';
  IPC_CMD_TRIM      = 'trim';
  IPC_CMD_QUIT      = 'quit';

type
  { Parsed IPC command }
  TIpcCmd = record
    command : array[0..31] of AnsiChar;
    args    : array[0..15] of array[0..127] of AnsiChar;
    nargs   : Integer;
  end;

  { Unix-socket server: daemon side }
  TIpcServer = class
  private
    FSocket: cint;
    FAddr  : TSockAddrUn;
  public
    procedure CloseClient(s: cint);
    constructor Create;
    destructor Destroy; override;
    function Listen: Boolean;
    procedure Stop;
    { Blocking accept — returns client fd or -1 on error/shutdown }
    function AcceptClient: cint;
    { Read a line from fd; returns string or ' on EOF/error }
    function ReadLine(fd: cint): AnsiString;
    { Write a line to fd }
    procedure WriteLine(fd: cint; const msg: AnsiString);
    { Parse an incoming command }
    function ParseCmd(const line: AnsiString): TIpcCmd;
    { Format a result response }
    function FormatResult(rc: AnsiString; const detail: AnsiString = ''): AnsiString;
    property SocketFd: cint read FSocket;
  end;

  { Unix-socket client: CLI side }
  TIpcClient = class
  private
    FSocket: cint;
  public
    constructor Create;
    destructor Destroy; override;
    { Returns True if connected }
    function Connect: Boolean;
    procedure Disconnect;
    { Send command line, return response or empty string on error }
    function SendCommand(const cmd: AnsiString): AnsiString;
    property SocketFd: cint read FSocket;
  end;

  { CLI argument parser / dispatcher }
  TCliApp = class
  public
    class function ParseArgs(argc: Integer; argv: array of AnsiString): TIpcCmd;
    class function BuildCmd(const cmd: TIpcCmd): AnsiString;
    class procedure Run(const cmd: TIpcCmd);
  end;

implementation

uses
  dynlibs, ctypes;

var
  GServerShutdown : Boolean = False;

{ ------------------------------------------------------------------ }
constructor TIpcServer.Create;
begin
  FSocket := -1;
  FillChar(FAddr, SizeOf(FAddr), 0);
  FAddr.sun_family := AF_UNIX;
  StrPCopy(FAddr.sun_path, IPC_SOCKET_PATH);
  { Remove stale socket file }
  fpUnlink(IPC_SOCKET_PATH);
end;

destructor TIpcServer.Destroy;
begin
  Stop;
  inherited;
end;

{ ------------------------------------------------------------------ }
procedure TIpcServer.CloseClient(s: cint);
begin
  if s >= 0 then
    fpClose(s);
end;

{ ------------------------------------------------------------------ }
function TIpcServer.Listen: Boolean;
var
  ret: cint;
begin
  Result := False;
  FSocket := fpsocket(AF_UNIX, SOCK_STREAM, 0);
  if FSocket < 0 then
  begin
    WriteLn(stderr, 'det-auto[ipc]: socket() failed: ', fpGetErrNo);
    Exit;
  end;

  ret := fpbind(FSocket, @FAddr, SizeOf(FAddr));
  if ret < 0 then
  begin
    WriteLn(stderr, 'det-auto[ipc]: bind() failed: ', fpGetErrNo);
    fpClose(FSocket);
    FSocket := -1;
    Exit;
  end;

  ret := fpListen(FSocket, 8);
  if ret < 0 then
  begin
    WriteLn(stderr, 'det-auto[ipc]: listen() failed: ', fpGetErrNo);
    fpClose(FSocket);
    FSocket := -1;
    Exit;
  end;

  Result := True;
  WriteLn('[det-auto[ipc]] listening on ', IPC_SOCKET_PATH);
end;

{ ------------------------------------------------------------------ }
procedure TIpcServer.Stop;
begin
  if FSocket >= 0 then
  begin
    fpClose(FSocket);
    FSocket := -1;
  end;
  fpUnlink(IPC_SOCKET_PATH);
end;

{ ------------------------------------------------------------------ }
function TIpcServer.AcceptClient: cint;
var
  len: TSockLen;
begin
  len := SizeOf(TSockAddr);
  Result := fpAccept(FSocket, nil, @len);
  if Result < 0 then
    WriteLn(stderr, 'det-auto[ipc]: accept() failed: ', fpGetErrNo);
end;

{ ------------------------------------------------------------------ }
function TIpcServer.ReadLine(fd: cint): AnsiString;
var
  n: cint;
  buf: array[0..IPC_MAX_RESP-1] of AnsiChar;
  pos: Integer;
begin
  Result := '';
  pos := 0;
  FillChar(buf, SizeOf(buf), 0);
  while pos < IPC_MAX_CMD - 1 do
  begin
    n := fpRecv(fd, @buf[pos], 1, 0);
    if n <= 0 then
      Break;
    if buf[pos] = #10 then
    begin
      buf[pos] := #0;
      Break;
    end;
    if buf[pos] = #13 then
      Continue;
    Inc(pos);
  end;
  buf[pos] := #0;
  Result := AnsiString(buf);
end;

{ ------------------------------------------------------------------ }
procedure TIpcServer.WriteLine(fd: cint; const msg: AnsiString);
var
  line: AnsiString;
  sent: cint;
begin
  line := msg + #10;
  sent := fpSend(fd, PChar(line), Length(line), 0);
  if sent < 0 then
    WriteLn(stderr, 'det-auto[ipc]: send() failed: ', fpGetErrNo);
end;

{ ------------------------------------------------------------------ }
function TIpcServer.ParseCmd(const line: AnsiString): TIpcCmd;
var
  parts: array[0..15] of AnsiString;
  i, np: Integer;
  cmd: AnsiString;
  sl: TStringList;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Trim(line) = '' then
    Exit;

  sl := TStringList.Create;
  try
    sl.Delimiter := ' ';
    sl.DelimitedText := Trim(line);
    np := 0;
    for i := 0 to sl.Count - 1 do
    begin
      if (sl[i] <> '') and (np < 16) then
      begin
        if np = 0 then
          StrPCopy(Result.command, sl[i])
        else
          StrPCopy(Result.args[np - 1], sl[i]);
        Inc(np);
      end;
    end;
    Result.nargs := np - 1;
  finally
    sl.Free;
  end;
end;

{ ------------------------------------------------------------------ }
function TIpcServer.FormatResult(rc: AnsiString; const detail: AnsiString): AnsiString;
begin
  if detail <> '' then
    Result := rc + ' ' + detail
  else
    Result := rc;
end;

{ ------------------------------------------------------------------ }
constructor TIpcClient.Create;
begin
  FSocket := -1;
end;

destructor TIpcClient.Destroy;
begin
  Disconnect;
  inherited;
end;

{ ------------------------------------------------------------------ }
function TIpcClient.Connect: Boolean;
var
  addr: TSockAddrUn;
  ret: cint;
  len: TSockLen;
begin
  Result := False;
  if FSocket >= 0 then
    Exit(True);

  FSocket := fpsocket(AF_UNIX, SOCK_STREAM, 0);
  if FSocket < 0 then
    Exit;

  FillChar(addr, SizeOf(addr), 0);
  addr.sun_family := AF_UNIX;
  StrPCopy(addr.sun_path, IPC_SOCKET_PATH);

  len := SizeOf(addr);
  ret := fpConnect(FSocket, PSockAddr(@addr), len);
  if ret < 0 then
  begin
    WriteLn(stderr, 'det-auto[ipc]: connect() failed: ', fpGetErrNo,
      ' — is the daemon running?');
    fpClose(FSocket);
    FSocket := -1;
    Exit;
  end;

  Result := True;
end;

{ ------------------------------------------------------------------ }
procedure TIpcClient.Disconnect;
begin
  if FSocket >= 0 then
  begin
    fpClose(FSocket);
    FSocket := -1;
  end;
end;

{ ------------------------------------------------------------------ }
function TIpcClient.SendCommand(const cmd: AnsiString): AnsiString;
var
  line: AnsiString;
  n, pos: cint;
  buf: array[0..IPC_MAX_RESP-1] of AnsiChar;
begin
  Result := '';
  if FSocket < 0 then
    Exit;

  line := cmd + #10;
  n := fpSend(FSocket, PChar(line), Length(line), 0);
  if n < 0 then
  begin
    WriteLn(stderr, 'det-auto[ipc]: send() failed: ', fpGetErrNo);
    Exit;
  end;

  { Read response inline }
  pos := 0;
  FillChar(buf, SizeOf(buf), 0);
  while pos < IPC_MAX_RESP - 1 do
  begin
    n := fpRecv(FSocket, @buf[pos], 1, 0);
    if n <= 0 then
      Break;
    if buf[pos] = #10 then
    begin
      buf[pos] := #0;
      Break;
    end;
    if buf[pos] = #13 then
      Continue;
    Inc(pos);
  end;
  buf[pos] := #0;
  Result := AnsiString(buf);
end;

{ ------------------------------------------------------------------ }
class function TCliApp.ParseArgs(argc: Integer; argv: array of AnsiString): TIpcCmd;
var
  i, cmdIdx: Integer;
  cmdParts: array[0..15] of AnsiString;
  nparts: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if argc < 2 then
  begin
    StrPCopy(Result.command, IPC_CMD_PING);
    Exit;
  end;

  nparts := 0;
  cmdIdx := -1;
  for i := 1 to argc - 1 do
  begin
    if argv[i] = '--daemon' then
    begin
      StrPCopy(Result.command, IPC_CMD_QUIT);
      StrPCopy(Result.args[0], 'daemon');
      Result.nargs := 1;
      Exit;
    end
    else if argv[i] = '--help' then
    begin
      WriteLn('det-auto IPC CLI');
      WriteLn('  ping               Check daemon health');
      WriteLn('  hotkey <combo> <action>  Register a hotkey');
      WriteLn('  type <text...>     Type text via uinput');
      WriteLn('  mouse <x> <y>      Move mouse to coordinates');
      WriteLn('  click [button]     Mouse click (default 1=left)');
      WriteLn('  windows            List active windows');
      WriteLn('  focus <name|id>    Focus window by name or ID');
      WriteLn('  trim               Trim phantom windows');
      WriteLn('  quit               Shut down daemon');
      halt(0);
    end
    else
    begin
      if nparts < 16 then
      begin
        cmdParts[nparts] := argv[i];
        Inc(nparts);
      end;
    end;
  end;

  if nparts > 0 then
  begin
    StrPCopy(Result.command, cmdParts[0]);
    for i := 1 to nparts - 1 do
      StrPCopy(Result.args[i - 1], cmdParts[i]);
    Result.nargs := nparts - 1;
  end
  else
  begin
    StrPCopy(Result.command, IPC_CMD_PING);
  end;
end;

{ ------------------------------------------------------------------ }
class function TCliApp.BuildCmd(const cmd: TIpcCmd): AnsiString;
var
  i: Integer;
  s: AnsiString;
begin
  s := AnsiString(StrPas(@cmd.command));
  for i := 0 to cmd.nargs - 1 do
    s := s + ' ' + AnsiString(StrPas(@cmd.args[i]));
  Result := s;
end;

{ ------------------------------------------------------------------ }
class procedure TCliApp.Run(const cmd: TIpcCmd);
var
  client: TIpcClient;
  line: AnsiString;
  rc: Integer;
begin
  client := TIpcClient.Create;
  try
    if not client.Connect then
    begin
      WriteLn('ERR daemon not running');
      Exit;
    end;
    line := client.SendCommand(BuildCmd(cmd));
    if line <> '' then
      WriteLn(Trim(line))
    else
      WriteLn('ERR no response');
  finally
    client.Free;
  end;
end;

end.
