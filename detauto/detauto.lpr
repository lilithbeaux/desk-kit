{ ===================================================================
  detauto.lpr — Main program: daemon + CLI dispatcher.
  Usage:
    detauto --daemon         Run as daemon (IPC server + event loop)
    detauto <command> [args] Send command to running daemon
    detauto                  Ping daemon health
  ------------------------------------------------------------------ }
program detauto;

{$MODE OBJFPC}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  ctypes, Unix, BaseUnix, unixtype,

  detauto_types,
  detauto_uinput,
  detauto_inputevt,
  detauto_x11keys,
  detauto_ipc,
  xlib;

var
  GUInput      : TUinputBackend;
  GX11         : TX11Backend;
  GInputEvt    : TInputEvtDaemon;
  GServer      : TIpcServer;
  GRunning     : Boolean = True;

{ ------------------------------------------------------------------ }
{ Format an IPC result string: "rc" or "rc detail" if detail given. }
function FormatResult(rc: AnsiString; const detail: AnsiString = ''): AnsiString;
begin
  if detail <> '' then
    Result := rc + ' ' + detail
  else
    Result := rc;
end;

{ ------------------------------------------------------------------ }
{ Command handler — dispatches IPC commands to the right backend.    }
function HandleCommand(const cmd: TIpcCmd): AnsiString;
var
  x, y, btn: Integer;
  text: AnsiString;
  i: Integer;
  s: AnsiString;
  windows: TX11WindowList;
  w: TX11Window;
  h: THotkeyRec;
  combo, action: AnsiString;
begin
  if cmd.command = nil then
  begin
    Result := FormatResult(IPC_RC_ERR, 'empty command');
    Exit;
  end;

  s := LowerCase(AnsiString(StrPas(@cmd.command)));

  if s = IPC_CMD_PING then
  begin
    Result := IPC_RC_OK;
  end
  else if s = IPC_CMD_HOTKEY then
  begin
    if cmd.nargs < 2 then
    begin
      Result := FormatResult(IPC_RC_ERR, 'usage: hotkey <combo> <action>');
      Exit;
    end;
    combo := AnsiString(StrPas(@cmd.args[0]));
    action := AnsiString(StrPas(@cmd.args[1]));
    if (GInputEvt <> nil) then
      GInputEvt.RegisterHotkey(combo, action);
    Result := FormatResult(IPC_RC_OK, 'registered: ' + combo);
  end
  else if s = IPC_CMD_TYPE then
  begin
    text := '';
    for i := 0 to cmd.nargs - 1 do
    begin
      if i > 0 then
        text := text + ' ';
      text := text + AnsiString(StrPas(@cmd.args[i]));
    end;
    if (GUInput <> nil) and GUInput.IsActive then
    begin
      GUInput.TypeText(text);
      Result := IPC_RC_OK;
    end
    else
      Result := FormatResult(IPC_RC_ERR, 'uinput not active');
  end
  else if s = IPC_CMD_MOUSE then
  begin
    if cmd.nargs < 2 then
    begin
      Result := FormatResult(IPC_RC_ERR, 'usage: mouse <x> <y>');
      Exit;
    end;
    x := StrToIntDef(AnsiString(StrPas(@cmd.args[0])), 0);
    y := StrToIntDef(AnsiString(StrPas(@cmd.args[1])), 0);
    if (GUInput <> nil) and GUInput.IsActive then
    begin
      GUInput.MouseMoveRelative(x, y);
      Result := IPC_RC_OK;
    end
    else
      Result := FormatResult(IPC_RC_ERR, 'uinput not active');
  end
  else if s = IPC_CMD_CLICK then
  begin
    btn := 1;
    if cmd.nargs >= 1 then
      btn := StrToIntDef(AnsiString(StrPas(@cmd.args[0])), 1);
    if (GUInput <> nil) and GUInput.IsActive then
    begin
      GUInput.MouseClick(btn);
      Result := IPC_RC_OK;
    end
    else
      Result := FormatResult(IPC_RC_ERR, 'uinput not active');
  end
  else if s = IPC_CMD_WINDOWS then
  begin
    if (GX11 <> nil) and GX11.IsConnected then
    begin
      windows := GX11.EnumerateWindows;
      s := '';
      for i := 0 to High(windows) do
      begin
        w := windows[i];
        s := s + AnsiString(Format('id=%d name="%s" class="%s" pid=%d phantom=%s focus=%s importance=%d',
          [w.id, w.name, w.wm_class, w.pid,
           IfThen(w.is_phantom, 'true', 'false'),
           IfThen(w.is_focus, 'true', 'false'),
           w.importance])) + #10;
      end;
      Result := Trim(s);
    end
    else
      Result := FormatResult(IPC_RC_ERR, 'X11 not connected');
  end
  else if s = IPC_CMD_FOCUS then
  begin
    if (GX11 <> nil) and GX11.IsConnected then
    begin
      if cmd.nargs < 1 then
      begin
        Result := FormatResult(IPC_RC_ERR, 'usage: focus <name|id>');
        Exit;
      end;
      s := AnsiString(StrPas(@cmd.args[0]));
      { Try ID first }
      x := StrToIntDef(s, -1);
      if x >= 0 then
      begin
        if GX11.FocusWindow(TWindow(x)) then
          Result := IPC_RC_OK
        else
          Result := FormatResult(IPC_RC_ERR, 'focus failed');
      end
      else
      begin
        if GX11.FocusWindowByName(s) then
          Result := IPC_RC_OK
        else
          Result := FormatResult(IPC_RC_ERR, 'window not found: ' + s);
      end;
    end
    else
      Result := FormatResult(IPC_RC_ERR, 'X11 not connected');
  end
  else if s = IPC_CMD_TRIM then
  begin
    if (GX11 <> nil) and GX11.IsConnected then
    begin
      windows := GX11.EnumerateWindows;
      y := 0;
      for i := 0 to High(windows) do
      begin
        if windows[i].is_phantom then
        begin
          GX11.ForceUnmap(TWindow(windows[i].id));
          Inc(y);
        end;
      end;
      Result := FormatResult(IPC_RC_OK, IntToStr(y) + ' phantom windows trimmed');
    end
    else
      Result := FormatResult(IPC_RC_ERR, 'X11 not connected');
  end
  else if s = IPC_CMD_QUIT then
  begin
    Result := IPC_RC_OK;
  end
  else
  begin
    Result := FormatResult(IPC_RC_ERR, 'unknown command: ' + s);
  end;
end;

{ ------------------------------------------------------------------ }
{ Event loop for daemon mode.
  Multiplexes: IPC socket, X11 events, input event epoll.          }
procedure RunDaemon;
var
  server: TIpcServer;
  uinput: TUinputBackend;
  x11: TX11Backend;
  inputEvt: TInputEvtDaemon;
  clientFd: cint;
  fds: TfdSet;
  maxFd, ret, x11Fd: cint;
  tv: TTimeVal;
  line, resp: AnsiString;
  cmd: TIpcCmd;
  hotkeyCb: THotkeyCallback;

  procedure HandleHotkey(const action: AnsiString);
  var
    act: AnsiString;
    w: TWindow;
  begin
    act := LowerCase(action);
    WriteLn('[det-auto] hotkey action: ', action);
    if act = 'close' then
    begin
      if (x11 <> nil) and x11.IsConnected then
      begin
        w := x11.GetFocusedWindow;
        x11.ForceUnmap(w);
      end;
    end
    else if Pos('type:', act) = 1 then
    begin
      if (uinput <> nil) and uinput.IsActive then
        uinput.TypeText(Copy(action, 6, MaxInt));
    end
    else if Pos('focus:', act) = 1 then
    begin
      if (x11 <> nil) and x11.IsConnected then
        x11.FocusWindowByName(Copy(action, 7, MaxInt));
    end;
  end;

  procedure OnHotkey(const action: AnsiString);
  begin
    HandleHotkey(action);
  end;

begin
  { Initialize uinput backend }
  uinput := TUinputBackend.Create;
  if not uinput.Init then
    WriteLn('[det-auto] uinput setup failed, continuing without injection')
  else
    WriteLn('[det-auto] uinput device created: ', uinput.GetDeviceName);

  { Initialize X11 backend }
  x11 := TX11Backend.Create;
  if not x11.Connect then
    WriteLn('[det-auto] X11 connection failed, running without X11')
  else
    WriteLn('[det-auto] X11 connected: display ', x11.GetDisplayString);

  { Initialize input event daemon (below X11) }
  inputEvt := TInputEvtDaemon.Create;
  try
    inputEvt.SetCallback(@OnHotkey);
  except
    on e: Exception do
      WriteLn('[det-auto] inputevt callback setup failed: ', e.Message);
  end;

  if not inputEvt.Start then
    WriteLn('[det-auto] input event daemon start failed')
  else
    WriteLn('[det-auto] input event daemon started');

  { Start IPC server }
  server := TIpcServer.Create;
  if not server.Listen then
  begin
    WriteLn(stderr, 'det-auto: failed to start IPC server');
    Halt(1);
  end;

  { Global references for HandleCommand }
  GUInput := uinput;
  GX11 := x11;
  GInputEvt := inputEvt;
  GServer := server;
  GRunning := True;

  WriteLn('[det-auto] daemon running — Ctrl-C to stop');

  { Main event loop }
  while GRunning do
  begin
    { Build fd set }
    fpFD_ZERO(fds);
    fpFD_SET(server.SocketFd, fds);
    maxFd := server.SocketFd;

    if x11.IsConnected then
    begin
      x11Fd := x11.GetConnectionFd;
      if x11Fd >= 0 then
      begin
        fpFD_SET(x11Fd, fds);
        if x11Fd > maxFd then
          maxFd := x11Fd;
      end;
    end;

    { 10ms timeout }
    tv.tv_sec := 0;
    tv.tv_usec := 10000;

    ret := fpSelect(maxFd + 1, @fds, nil, nil, @tv);

    if ret < 0 then
    begin
      if fpGetErrNo = ESysEINTR then
        Continue;
      WriteLn(stderr, 'det-auto: select() failed: ', fpGetErrNo);
      Break;
    end;

    if ret = 0 then
    begin
      { Timeout — poll event devices }
      inputEvt.PollOnce;
      Continue;
    end;

    { Check IPC }
    if fpFD_ISSET(server.SocketFd, fds) <> 0 then
    begin
      clientFd := server.AcceptClient;
      if clientFd >= 0 then
      begin
        line := server.ReadLine(clientFd);
        cmd := server.ParseCmd(line);
        if LowerCase(AnsiString(StrPas(@cmd.command))) = IPC_CMD_QUIT then
        begin
          resp := HandleCommand(cmd);
          server.WriteLine(clientFd, resp);
          server.CloseClient(clientFd);
          server.Stop;
          GRunning := False;
          Continue;
        end;
        resp := HandleCommand(cmd);
        if resp <> '' then
          server.WriteLine(clientFd, resp);
        server.CloseClient(clientFd);
      end;
    end;

    { Check X11 }
    if x11.IsConnected and (x11Fd >= 0) and (fpFD_ISSET(x11Fd, fds) <> 0) then
    begin
      x11.X11PollEvents(uinput);
    end;

    { Always poll event devices }
    inputEvt.PollOnce;
  end;

  { Cleanup }
  server.Stop;
  server.Free;
  if x11.IsConnected then
    x11.Disconnect;
  x11.Free;
  uinput.Shutdown;
  uinput.Free;
  inputEvt.Stop;
  inputEvt.Free;

  WriteLn('[det-auto] daemon stopped');
end;

{ ------------------------------------------------------------------ }
begin
  try
    if (ParamCount >= 1) and (ParamStr(1) = '--daemon') then
      RunDaemon
    else
      TCliApp.Run(TCliApp.ParseArgs(ParamCount, ParamStr(1)));
  except
    on e: Exception do
    begin
      WriteLn(stderr, 'det-auto: ', e.Message);
      Halt(1);
    end;
  end;
end.
