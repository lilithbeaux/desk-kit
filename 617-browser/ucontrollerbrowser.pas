unit uControllerBrowser;

{$mode objfpc}{$H+}
{$I cef.inc}

interface

uses
  Classes, SysUtils, Forms, Controls, ExtCtrls, ComCtrls, StdCtrls, Buttons,
  uCEFConstants, uCEFTypes, uCEFInterfaces, uCEFChromiumEvents,
  uCEFChromium, uCEFChromiumWindow, uCEFApplication, 
  fpjson, jsonparser, sockets, baseunix, unix;

const
  CMD_SOCKET     = '/tmp/617_browser.sock';
  BUS_SOCKET     = '/tmp/617_bus.sock';
  PROFILES_FILE  = GetEnv('PROFILES_FILE', GetUserDir + '/.config/617_browser/profiles.json');
  MAX_TABS       = 16;
  BASE_DATA_DIR  = GetEnv('DESKKIT_617_DATA_DIR', GetUserDir + '/.config/617_browser/');

type
  TTabInfo = record
    TabId: Integer;
    ChromiumWindow: TChromiumWindow;
    ProfileName: string;
    UserDataDir: string;
    SessionCookieDir: string;
    LastTitle: string;
  end;
  PTabInfo = ^TTabInfo;

  { TControllerForm }
  TControllerForm = class(TForm)
    edAddress: TEdit;
    btnGo: TSpeedButton;
    btnNewTab: TSpeedButton;
    tbMain: TPageControl;
    Timer1: TTimer;
    StatusBar: TPanel;

    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure btnGoClick(Sender: TObject);
    procedure btnBackClick(Sender: TObject);
    procedure btnForwardClick(Sender: TObject);
    procedure btnNewTabClick(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
    procedure edAddressKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure tbMainChange(Sender: TObject);

  private
    FNextTabId: Integer;
    FTabs: array of TTabInfo;
    FTabCount: Integer;
    FCmdSock: Integer;
    FCmdBuf: string;
    FSpoofJS: array of string;  // Spoof JS per tab index
    FProxyHost: string;
    FProxyPort: Integer;
    FProxyEnabled: Boolean;
    FEvalResult: string;        // Last evaluate_js result (from document.title)
    FEvalResultReady: Boolean;  // True when a new eval result is available

    // IPC
    function SendBusJSON(const topic, mtype, payload: string): Boolean;
    procedure HandleCommand(const cmdLine: string; const ReplySock: Integer = -1);
    procedure ProcessCommands;
    procedure SendReply(const sock: Integer; const json: string);
    procedure WriteProxyConfig;
    function GetProfile(key: string): TJSONObject;

    // Tab Management
    function AddTab(const ProfileName: string = ''): Integer;
    procedure CloseTab(TabId: Integer);
    function GetTabIndex(TabId: Integer): Integer;
    function ActiveTabId: Integer;

    // CEF events
    procedure DoAfterCreated(Sender: TObject; const browser: ICefBrowser);
    procedure DoBeforePopup(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; popup_id: Integer;
      const targetUrl, targetFrameName: ustring;
      targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
      const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
      var client: ICefClient; var settings: TCefBrowserSettings;
      var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
      var Result: Boolean);
    procedure DoLoadEnd(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; httpStatusCode: Integer);
    procedure DoTitleChange(Sender: TObject; const browser: ICefBrowser;
      const title: ustring);
    function GetActiveTitle: string;
    procedure DoAddressChange(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; const url: ustring);

  public
    procedure Navigate(const url: string; TabId: Integer = -1);
    procedure ExecuteJS(const code: string; TabId: Integer = -1);
    function GetActiveURL(TabId: Integer = -1): string;
    procedure SpoofTab(TabId: Integer; const ProfileData: TJSONObject);
  end;

var
  ControllerForm: TControllerForm;

implementation

{$R *.lfm}

uses
  uCEFMiscFunctions;

// ═══════════════════════════════════════════════════════════════
// PROFILE LOADER
// ═══════════════════════════════════════════════════════════════

function TControllerForm.GetProfile(key: string): TJSONObject;
var
  sl: TStringList;
  data, profiles: TJSONData;
  profilesObj: TJSONObject;
begin
  Result := nil;
  if not FileExists(PROFILES_FILE) then Exit;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(PROFILES_FILE);
    data := GetJSON(sl.Text);
    
    // Navigate: data.profiles.<key>
    profiles := data.FindPath('profiles.' + key);
    if profiles <> nil then
      Result := TJSONObject(profiles.Clone)
    else
      WriteLn('[DCv2] Profile not found: ', key);
      
    data.Free;
  finally
    sl.Free;
  end;
end;

// ═══════════════════════════════════════════════════════════════
// EVENT BUS
// ═══════════════════════════════════════════════════════════════

function TControllerForm.SendBusJSON(const topic, mtype, payload: string): Boolean;
var
  sock: Integer;
  msg: string;
  addr: sockaddr_un;
  obj: TJSONObject;
begin
  Result := False;
  sock := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if sock = -1 then Exit;
  FillChar(addr, SizeOf(addr), 0);
  addr.sun_family := AF_UNIX;
  StrPCopy(addr.sun_path, BUS_SOCKET);
  if fpConnect(sock, @addr, SizeOf(addr)) = -1 then
  begin
    fpClose(sock);
    Exit;
  end;

  obj := TJSONObject.Create;
  try
    obj.Add('source', '617_browser');
    obj.Add('topic', topic);
    obj.Add('type', mtype);
    obj.Add('timestamp', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now));
    if (Length(payload) > 0) and (payload[1] = '{') then
      obj.Add('payload', GetJSON(payload))
    else
      obj.Add('payload', payload);
    msg := obj.AsJSON;
  finally
    obj.Free;
  end;

  Result := fpSend(sock, @msg[1], Length(msg), 0) = Length(msg);
  fpClose(sock);
end;

procedure TControllerForm.SendReply(const sock: Integer; const json: string);
var
  msg: string;
begin
  if sock < 0 then Exit;
  msg := json + #10;
  fpSend(sock, @msg[1], Length(msg), 0);
end;

// ═══════════════════════════════════════════════════════════════
// TAB MANAGEMENT
// ═══════════════════════════════════════════════════════════════

function TControllerForm.AddTab(const ProfileName: string = ''): Integer;
var
  ti: PTabInfo;
  ts: TTabSheet;
  i, idx: Integer;
  profile: TJSONObject;
  profileDir: string;
begin
  if FTabCount >= MAX_TABS then
  begin
    Result := -1;
    Exit;
  end;

  // Create tab sheet
  ts := TTabSheet.Create(Self);
  ts.PageControl := tbMain;
  ts.Caption := 'New Tab';
  ts.TabVisible := True;

  // Determine profile
  if ProfileName = '' then
    profileDir := IntToStr(FNextTabId)
  else
    profileDir := StringReplace(ProfileName, ' ', '_', [rfReplaceAll]);

  // Allocate tab info
  idx := FTabCount;
  SetLength(FTabs, idx + 1);
  Inc(FTabCount);
  FTabs[idx].TabId := FNextTabId;
  FTabs[idx].ProfileName := ProfileName;
  FTabs[idx].UserDataDir := BASE_DATA_DIR + 'profile_' + profileDir;
  FTabs[idx].SessionCookieDir := FTabs[idx].UserDataDir + '/cookies';

  // Create user data dir
  ForceDirectories(FTabs[idx].UserDataDir);
  ForceDirectories(FTabs[idx].SessionCookieDir);

  // Create TChromiumWindow embedded in the TabSheet
  FTabs[idx].ChromiumWindow := TChromiumWindow.Create(ts);
  FTabs[idx].ChromiumWindow.Parent := ts;
  FTabs[idx].ChromiumWindow.Align := alClient;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnAfterCreated := @DoAfterCreated;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnBeforePopup := @DoBeforePopup;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnLoadEnd := @DoLoadEnd;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnTitleChange := @DoTitleChange;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.DefaultURL := 'about:blank';
  // Set per-tab user data dir (isolated session)
  // CEF4Delphi uses GlobalCEFApp for global paths; per-browser isolation
  // requires separate ICefRequestContext (handled in SpoofTab)

  // Configure spoofing from profile
  if ProfileName <> '' then
  begin
    profile := GetProfile(ProfileName);
    if profile <> nil then
    begin
      SpoofTab(FTabs[idx].TabId, profile);
      profile.Free;
    end;
  end;

  // Activate and navigate
  tbMain.ActivePage := ts;
  FTabs[idx].ChromiumWindow.CreateBrowser;

  WriteLn('[DCv2] Tab created: id=', FNextTabId, ' profile=', ProfileName, ' dir=', FTabs[idx].UserDataDir);
  SendBusJSON('tab.created', 'info', Format('{"tab_id":%d,"profile":"%s","data_dir":"%s"}',
    [FNextTabId, ProfileName, FTabs[idx].UserDataDir]));

  Result := FNextTabId;
  Inc(FNextTabId);
end;

procedure TControllerForm.CloseTab(TabId: Integer);
var
  idx, i: Integer;
begin
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit;

  // Close browser
  FTabs[idx].ChromiumWindow.CloseBrowser(True);
  FTabs[idx].ChromiumWindow.Free;

  // Remove tab sheet
  if idx < tbMain.PageCount then
    tbMain.Pages[idx].Free;

  // Shift array
  for i := idx to FTabCount - 2 do
    FTabs[i] := FTabs[i + 1];
  Dec(FTabCount);
  SetLength(FTabs, FTabCount);

  WriteLn('[DCv2] Tab closed: id=', TabId);
  SendBusJSON('tab.closed', 'info', Format('{"tab_id":%d}', [TabId]));
end;

function TControllerForm.GetTabIndex(TabId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FTabCount - 1 do
    if FTabs[i].TabId = TabId then Exit(i);
  Result := -1;
end;

function TControllerForm.ActiveTabId: Integer;
var
  idx: Integer;
begin
  idx := tbMain.ActivePageIndex;
  if (idx >= 0) and (idx < FTabCount) then
    Result := FTabs[idx].TabId
  else
    Result := -1;
end;

// ═══════════════════════════════════════════════════════════════
// NAVIGATION
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.Navigate(const url: string; TabId: Integer = -1);
var
  idx: Integer;
  s: string;
  browser: ICefBrowser;
begin
  if TabId < 0 then TabId := ActiveTabId;
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit;

  s := url;
  if (Pos('http://', s) = 0) and (Pos('https://', s) = 0) and (Pos('about:', s) = 0) then
    s := 'https://' + s;

  browser := FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser;
  if browser <> nil then
  begin
    browser.MainFrame.LoadUrl(s);
    WriteLn('[DCv2] Tab ', TabId, ' navigate: ', s);
  end;
end;

procedure TControllerForm.ExecuteJS(const code: string; TabId: Integer = -1);
var
  idx: Integer;
  browser: ICefBrowser;
begin
  if TabId < 0 then TabId := ActiveTabId;
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit;

  browser := FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser;
  if browser <> nil then
  begin
    browser.MainFrame.ExecuteJavaScript(code, '', 0);
    WriteLn('[DCv2] Tab ', TabId, ' JS executed (', Length(code), ' bytes)');
  end;
end;

// Escape string for safe JSON embedding
function EncodeJSON(const s: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(s) do
    case s[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      else Result := Result + s[i];
    end;
end;

function TControllerForm.GetActiveURL(TabId: Integer = -1): string;
var
  idx: Integer;
  browser: ICefBrowser;
begin
  if TabId < 0 then TabId := ActiveTabId;
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit('');

  browser := FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser;
  if (browser <> nil) and (browser.MainFrame <> nil) then
    Result := browser.MainFrame.Url
  else
    Result := '';
end;

// ═══════════════════════════════════════════════════════════════
// SPOOFING (native CEF ExecuteJavaScript)
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.SpoofTab(TabId: Integer; const ProfileData: TJSONObject);
var
  spoof: TJSONObject;
  ua, plat, lang, tz, res: string;
  js: string;
  idx: Integer;
begin
  if ProfileData = nil then Exit;
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit;

  spoof := ProfileData.Get('browser', TJSONObject.Create) as TJSONObject;

  js := '';
  ua := spoof.Get('user_agent', '');
  if ua <> '' then
    js := js + Format('Object.defineProperty(navigator,"userAgent",{get:()=>%s,configurable:true});', [QuotedStr(ua)]);

  plat := spoof.Get('platform', '');
  if plat <> '' then
    js := js + Format('Object.defineProperty(navigator,"platform",{get:()=>%s,configurable:true});', [QuotedStr(plat)]);

  lang := spoof.Get('language', '');
  if lang <> '' then
    js := js + Format('Object.defineProperty(navigator,"languages",{get:()=>["%s","en"],configurable:true});', [lang]);

  res := spoof.Get('screen_resolution', '');
  if res <> '' then
    js := js + Format('var r="%s".split("x");if(r.length==2){Object.defineProperty(screen,"width",{get:()=>parseInt(r[0]),configurable:true});Object.defineProperty(screen,"height",{get:()=>parseInt(r[1]),configurable:true});}', [res]);

  // Canvas anti-fingerprint
  js := js + 'HTMLCanvasElement.prototype.toDataURL=function(){return HTMLCanvasElement.prototype.toDataURL.apply(this).replace(/[a-f0-9]/g,(c,i)=>i%7===0?String.fromCharCode(c.charCodeAt(0)^1):c)};';
  // WebGL spoof
  js := js + 'var gp=WebGLRenderingContext.prototype.getParameter;WebGLRenderingContext.prototype.getParameter=function(p){if(p===0x9245||p===0x8F9D)return"Google Inc.";if(p===0x9246||p===0x8F9C)return"ANGLE (Intel)";return gp.call(this,p)};';

  tz := spoof.Get('timezone', '');
  if tz <> '' then
    js := js + Format('Intl.DateTimeFormat=new Proxy(Intl.DateTimeFormat,{construct:(t,a)=>{var o={...(a[1]||{})};o.timeZone="%s";return Reflect.construct(t,[a[0]||"en-US",o],t)}});', [tz]);

  // Geolocation
  if ProfileData.FindPath('address.lat') <> nil then
    js := js + Format('navigator.geolocation.getCurrentPosition=(s)=>{s({coords:{latitude:%s,longitude:%s,accuracy:10},timestamp:Date.now()})};',
      [ProfileData.FindPath('address.lat').AsString, ProfileData.FindPath('address.lng').AsString]);

  // Store spoof JS for this tab (executed on next LoadEnd)
  if idx >= Length(FSpoofJS) then
    SetLength(FSpoofJS, idx + 1);
  FSpoofJS[idx] := js;
  WriteLn('[DCv2] Spoof JS stored for Tab ', TabId, ': ', Length(js), ' bytes');
end;

// ═══════════════════════════════════════════════════════════════
// COMMAND HANDLER (IPC Socket)
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.WriteProxyConfig;
var
  cfg: TStringList;
  cfgPath: string;
begin
  cfgPath := GetUserDir + '.config/617_browser/proxy.conf';
  cfg := TStringList.Create;
  try
    if FProxyEnabled and (FProxyHost <> '') then
    begin
      cfg.Add('host=' + FProxyHost);
      cfg.Add('port=' + IntToStr(FProxyPort));
      cfg.Add('enabled=true');
    end
    else
    begin
      cfg.Add('enabled=false');
    end;
    cfg.SaveToFile(cfgPath);
  finally
    cfg.Free;
  end;
end;

procedure TControllerForm.HandleCommand(const cmdLine: string; const ReplySock: Integer = -1);
var
  jobj: TJSONObject;
  cmdAction, cmdId, url, jsCode, profName, tabsJson, response, title: string;
  sel, formJSON: string;
  i: Integer;
  arr: TJSONArray;
  obj: TJSONObject;
  newTabId: Integer;
begin
  try
    jobj := TJSONObject(GetJSON(cmdLine));
    try
      cmdAction := jobj.Get('action', '');
      cmdId  := jobj.Get('id', '0');
      WriteLn('[DCv2] Cmd: ', cmdAction, ' id=', cmdId);

      if cmdAction = 'navigate' then
      begin
        url := jobj.Get('url', 'https://google.com');
        if jobj.FindPath('tab_id') <> nil then
          Navigate(url, jobj.Get('tab_id', ActiveTabId))
        else
          Navigate(url);
        response := Format('{"id":"%s","status":"navigating","url":"%s"}', [cmdId, url]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'execute_javascript' then
      begin
        jsCode := jobj.Get('code', '');
        if jsCode <> '' then
        begin
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"executed","bytes":%d}', [cmdId, Length(jsCode)]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"empty code"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'create_tab' then
      begin
        profName := jobj.Get('profile', '');
        newTabId := AddTab(profName);
        if newTabId >= 0 then
          response := Format('{"id":"%s","status":"ok","tab_id":%d,"profile":"%s"}', [cmdId, newTabId, profName])
        else
          response := Format('{"id":"%s","status":"error","error":"max tabs reached"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'close_tab' then
      begin
        CloseTab(jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"ok"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'activate_tab' then
      begin
        i := GetTabIndex(jobj.Get('tab_id', -1));
        if i >= 0 then
        begin
          tbMain.ActivePageIndex := i;
          response := Format('{"id":"%s","status":"ok","tab_id":%d}', [cmdId, FTabs[i].TabId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"tab not found"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'list_tabs' then
      begin
        arr := TJSONArray.Create;
        for i := 0 to FTabCount - 1 do
        begin
          obj := TJSONObject.Create;
          obj.Add('tab_id', FTabs[i].TabId);
          obj.Add('profile', FTabs[i].ProfileName);
          obj.Add('data_dir', FTabs[i].UserDataDir);
          arr.Add(obj);
        end;
        tabsJson := arr.AsJSON;
        arr.Free;
        response := Format('{"id":"%s","status":"ok","tabs":%s}', [cmdId, tabsJson]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'status' then
      begin
        response := Format('{"id":"%s","status":"ok","tabs":%d,"active_tab":%d}',
          [cmdId, FTabCount, ActiveTabId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'get_url' then
      begin
        url := GetActiveURL(jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"ok","url":"%s"}', [cmdId, url]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'get_title' then
      begin
        title := GetActiveTitle;
        response := Format('{"id":"%s","status":"ok","title":"%s"}', [cmdId, EncodeJSON(title)]);
        SendReply(ReplySock, response);
      end

      // ── Automation Commands ────────────────────────────────────────
      else if cmdAction = 'evaluate_js' then
      begin
        jsCode := jobj.Get('code', '');
        if jsCode <> '' then
        begin
          // Executes JS and stores JSON result via FEvalResult (full-length, no truncation)
          FEvalResultReady := False;
          jsCode := 'try{document.title=JSON.stringify((function(){' + jsCode + '})())}catch(e){document.title=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"ok","method":"eval_channel","bytes":%d}', [cmdId, Length(jsCode)]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"empty code"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'get_eval' then
      begin
        if FEvalResultReady then
        begin
          response := Format('{"id":"%s","status":"ok","result":"%s"}', [cmdId, EncodeJSON(FEvalResult)]);
          FEvalResultReady := False;
          FEvalResult := '';
        end
        else
          response := Format('{"id":"%s","status":"pending","result":""}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'click' then
      begin
        sel := jobj.Get('selector', '');
        if sel <> '' then
        begin
          jsCode := 'try{var el=document.querySelector("' + EncodeJSON(sel) + '");if(el){el.click();document.title=JSON.stringify({clicked:true})}else{document.title=JSON.stringify({error:"element not found"})}}catch(e){document.title=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"ok","selector":"%s"}', [cmdId, EncodeJSON(sel)]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no selector"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'form_fill' then
      begin
        formJSON := jobj.Get('fields', '');
        if formJSON <> '' then
        begin
          jsCode := 'try{var f=JSON.parse("' + EncodeJSON(formJSON) + '");Object.keys(f).forEach(function(k){var el=document.querySelector(`[name=''${k}'']`)||document.getElementById(k);if(el){el.value=f[k];el.dispatchEvent(new Event("input",{bubbles:true}));el.dispatchEvent(new Event("change",{bubbles:true}))}});document.title=JSON.stringify({filled:Object.keys(f).length})}catch(e){document.title=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"ok","fields_queued":true}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no fields"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'get_form_fields' then
      begin
        jsCode := 'try{document.title=JSON.stringify(Array.from(document.querySelectorAll("input,select,textarea")).map(function(el){return{tag:el.tagName,name:(el.name||""),id:(el.id||""),type:(el.type||""),placeholder:(el.placeholder||""),required:el.required,value:(el.value||""),form:(el.form?el.form.action:"")}}))}catch(e){document.title=JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"ok","method":"title_channel"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'go_back' then
      begin
        i := GetTabIndex(jobj.Get('tab_id', ActiveTabId));
        if (i >= 0) and (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
          FTabs[i].ChromiumWindow.ChromiumBrowser.Browser.GoBack;
        response := Format('{"id":"%s","status":"ok"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'go_forward' then
      begin
        i := GetTabIndex(jobj.Get('tab_id', ActiveTabId));
        if (i >= 0) and (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
          FTabs[i].ChromiumWindow.ChromiumBrowser.Browser.GoForward;
        response := Format('{"id":"%s","status":"ok"}', [cmdId]);
        SendReply(ReplySock, response);
      end
      // ── End Automation Commands ────────────────────────────────────

      else if cmdAction= 'set_proxy' then
      begin
        FProxyHost := jobj.Get('host', '');
        FProxyPort := jobj.Get('port', 0);
        FProxyEnabled := jobj.Get('enabled', True);
        if FProxyHost <> '' then
          WriteLn('[DCv2] Proxy set: ', FProxyHost, ':', FProxyPort)
        else
          WriteLn('[DCv2] Proxy disabled');
        // Write proxy config to file for BrowserProcessManager on restart
        WriteProxyConfig;
        response := Format('{"id":"%s","status":"ok","proxy":{"host":"%s","port":%d,"enabled":%s}}',
          [cmdId, FProxyHost, FProxyPort, LowerCase(BoolToStr(FProxyEnabled, True))]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'get_proxy' then
      begin
        response := Format('{"id":"%s","status":"ok","proxy":{"host":"%s","port":%d,"enabled":%s}}',
          [cmdId, FProxyHost, FProxyPort, LowerCase(BoolToStr(FProxyEnabled, True))]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'spoof' then
      begin
        profName := jobj.Get('profile', '');
        if profName <> '' then
        begin
          obj := GetProfile(profName);
          if obj <> nil then
          begin
            SpoofTab(jobj.Get('tab_id', ActiveTabId), obj);
            obj.Free;
            response := Format('{"id":"%s","status":"ok","profile":"%s"}', [cmdId, profName]);
          end
          else
            response := Format('{"id":"%s","status":"error","error":"profile not found"}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no profile specified"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else
      begin
        response := Format('{"id":"%s","status":"error","error":"unknown action: %s"}', [cmdId, action]);
        SendReply(ReplySock, response);
      end;

      SendBusJSON('browser.response', 'result', response);
    finally
      jobj.Free;
    end;
  except
    on E: Exception do
      SendBusJSON('browser.response', 'error',
        Format('{"error":"%s"}', [E.Message]));
  end;
end;

procedure TControllerForm.ProcessCommands;
var
  ClientSock, ClientFlags: Integer;
  buf: array[0..65535] of Byte;
  n: Integer;
  line: string;
  p: Integer;
begin
  if FCmdSock >= 0 then
  begin
    ClientSock := fpAccept(FCmdSock, nil, nil);
    if ClientSock >= 0 then
    begin
      n := fpRead(ClientSock, @buf, SizeOf(buf));
      if n > 0 then
      begin
        SetString(line, PChar(@buf), n);
        FCmdBuf := FCmdBuf + line;
        p := Pos(#10, FCmdBuf);
        while p > 0 do
        begin
          HandleCommand(Trim(Copy(FCmdBuf, 1, p - 1)), ClientSock);
          Delete(FCmdBuf, 1, p);
          p := Pos(#10, FCmdBuf);
        end;
      end;
      fpClose(ClientSock);
    end;
  end;
end;

// ═══════════════════════════════════════════════════════════════
// CEF EVENT HANDLERS
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.DoAfterCreated(Sender: TObject; const browser: ICefBrowser);
begin
  WriteLn('[DCv2] Browser ready');
  SendBusJSON('browser.status', 'ready',
    '{"status":"ready","chromium":"131.0.6778.265","version":"617_browser"}');
end;

procedure TControllerForm.DoBeforePopup(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; popup_id: Integer;
  const targetUrl, targetFrameName: ustring;
  targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
  const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
  var client: ICefClient; var settings: TCefBrowserSettings;
  var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
  var Result: Boolean);
var
  newTabId: Integer;
  popupUrl: string;
begin
  // Cancel the rogue popup window
  Result := True;

  popupUrl := targetUrl;
  if popupUrl = '' then
    Exit;

  WriteLn('[DCv2] Popup intercepted: ', popupUrl);

  // Create a new tab and navigate to the popup URL
  newTabId := AddTab('');
  if newTabId >= 0 then
  begin
    Navigate(popupUrl, newTabId);
    SendBusJSON('browser.popup', 'info',
      Format('{"source_tab":%d,"target_tab":%d,"url":"%s"}',
        [ActiveTabId, newTabId, EncodeJSON(popupUrl)]));
    WriteLn('[DCv2] Popup routed to tab ', newTabId, ': ', popupUrl);
  end
  else
    WriteLn('[DCv2] WARNING: Could not create tab for popup (max tabs?)');
end;

procedure TControllerForm.DoLoadEnd(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; httpStatusCode: Integer);
var
  i: Integer;
begin
  if frame.IsMain then
  begin
    WriteLn('[DCv2] Page loaded: ', httpStatusCode);
    SendBusJSON('browser.load', 'info',
      Format('{"status":"loaded","http_code":%d,"url":"%s"}', [httpStatusCode, frame.Url]));

    // Execute spoof JS for this tab
    for i := 0 to FTabCount - 1 do
      if (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser = browser) and (i < Length(FSpoofJS)) then
      begin
        if FSpoofJS[i] <> '' then
        begin
          browser.MainFrame.ExecuteJavaScript(FSpoofJS[i], '', 0);
          WriteLn('[DCv2] Spoof JS executed on Tab ', FTabs[i].TabId);
        end;
        Break;
      end;
  end;
end;

procedure TControllerForm.DoTitleChange(Sender: TObject; const browser: ICefBrowser;
  const title: ustring);
var
  i: Integer;
  bid: Integer;
begin
  if (FTabCount = 0) or (browser = nil) then Exit;
  bid := browser.Identifier;
  for i := 0 to FTabCount - 1 do
    if FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> nil then
      if FTabs[i].ChromiumWindow.ChromiumBrowser.Browser.Identifier = bid then
      begin
        if tbMain.Pages[i] <> nil then
          tbMain.Pages[i].Caption := Copy(title, 1, 30);
        // Store full title for evaluate_js return channel
        if not FEvalResultReady then
        begin
          FEvalResult := title;
          FEvalResultReady := True;
        end;
        Break;
      end;
end;

function TControllerForm.GetActiveTitle: string;
var
  idx: Integer;
begin
  Result := '';
  idx := tbMain.ActivePageIndex;
  if (idx >= 0) and (idx < FTabCount) then
    Result := tbMain.Pages[idx].Caption;
end;

procedure TControllerForm.DoAddressChange(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; const url: ustring);
begin
  if frame.IsMain then
  begin
    edAddress.Text := url;
    SendBusJSON('browser.navigate', 'info', Format('{"url":"%s"}', [url]));
  end;
end;

// ═══════════════════════════════════════════════════════════════
// FORM EVENTS
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.FormCreate(Sender: TObject);
var
  addr: sockaddr_un;
  flags: Integer;
begin
  Caption := '617 Browser — ⎔ Hermaeus Waelon';
  Width := 1200;
  Height := 800;
  Position := poScreenCenter;
  FNextTabId := 1;
  FTabCount := 0;
  FCmdSock := -1;
  FCmdBuf := '';
  FProxyHost := '';
  FProxyPort := 0;
  FProxyEnabled := False;
  FEvalResult := '';
  FEvalResultReady := False;

  // Create Unix command socket
  FpUnlink(CMD_SOCKET);
  FCmdSock := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if FCmdSock >= 0 then
  begin
    FillChar(addr, SizeOf(addr), 0);
    addr.sun_family := AF_UNIX;
    StrPCopy(addr.sun_path, CMD_SOCKET);
    FpUmask(0);
    if fpBind(FCmdSock, @addr, SizeOf(addr)) = 0 then
    begin
      FpChmod(CMD_SOCKET, &777);
      fpListen(FCmdSock, 5);
      flags := fpFcntl(FCmdSock, F_GETFL, 0);
      fpFcntl(FCmdSock, F_SETFL, flags or O_NONBLOCK);
      WriteLn('[DCv2] Command socket: ', CMD_SOCKET);
    end
    else
      WriteLn('[DCv2] Bind failed: ', fpGetErrNo);
  end
  else
    WriteLn('[DCv2] Socket creation failed: ', fpGetErrNo);

  // Create first tab
  AddTab;
  WriteLn('[DCv2] Dual Citizen Browser v2 initialized');
end;

procedure TControllerForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  i: Integer;
begin
  CanClose := True;
  for i := 0 to FTabCount - 1 do
    FTabs[i].ChromiumWindow.CloseBrowser(True);
end;

procedure TControllerForm.FormDestroy(Sender: TObject);
begin
  if FCmdSock >= 0 then
  begin
    fpClose(FCmdSock);
    FpUnlink(CMD_SOCKET);
  end;
end;

procedure TControllerForm.btnGoClick(Sender: TObject);
begin
  Navigate(edAddress.Text);
end;

procedure TControllerForm.btnBackClick(Sender: TObject);
var
  idx: Integer;
begin
  idx := GetTabIndex(ActiveTabId);
  if (idx >= 0) and (FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
    FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser.GoBack;
end;

procedure TControllerForm.btnForwardClick(Sender: TObject);
var
  idx: Integer;
begin
  idx := GetTabIndex(ActiveTabId);
  if (idx >= 0) and (FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
    FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser.GoForward;
end;

procedure TControllerForm.btnNewTabClick(Sender: TObject);
begin
  AddTab;
end;

procedure TControllerForm.Timer1Timer(Sender: TObject);
begin
  ProcessCommands;
end;

procedure TControllerForm.edAddressKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = 13 then // Enter
  begin
    Navigate(edAddress.Text);
    Key := 0;
  end;
end;

procedure TControllerForm.tbMainChange(Sender: TObject);
var
  idx: Integer;
begin
  idx := tbMain.ActivePageIndex;
  if (idx >= 0) and (idx < FTabCount) then
    SendBusJSON('tab.activated', 'info', Format('{"tab_id":%d}', [FTabs[idx].TabId]));
end;

end.
