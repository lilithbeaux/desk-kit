program browser_617;

{$mode objfpc}{$H+}
{$I cef.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Forms,
  uControllerBrowser in 'ucontrollerbrowser.pas',
  uCEFApplication;

{$R *.res}

begin
  GlobalCEFApp := TCefApplication.Create;

  // ── CEF Configuration ────────────────────────────────────
  GlobalCEFApp.FrameworkDirPath := GetEnv('CEF4DELPHI_DIR', './CEF4Delphi') + '/cef_binary_131.4.1+g437feba+chromium-131.0.6778.265_linux64/Release/';
  GlobalCEFApp.ResourcesDirPath := GetEnv('CEF4DELPHI_DIR', './CEF4Delphi') + '/cef_binary_131.4.1+g437feba+chromium-131.0.6778.265_linux64/Release/';
  GlobalCEFApp.LocalesDirPath   := GetEnv('CEF4DELPHI_DIR', './CEF4Delphi') + '/cef_binary_131.4.1+g437feba+chromium-131.0.6778.265_linux64/Release/locales/';
  GlobalCEFApp.LogFile          := '/tmp/617_browser.log';
  GlobalCEFApp.LogSeverity      := 3;  // LOGSEVERITY_WARNING
  GlobalCEFApp.EnableGPU        := False;
  GlobalCEFApp.EnablePrintPreview := False;
  GlobalCEFApp.EnableMediaStream  := True;

  // ── Command-line flags ───────────────────────────────────
  GlobalCEFApp.AddCustomCommandLine('--no-sandbox');
  GlobalCEFApp.AddCustomCommandLine('--disable-gpu');
  GlobalCEFApp.AddCustomCommandLine('--disable-gpu-compositing');
  // NOTE: --disable-software-rasterizer was REMOVED because it blocks ALL rendering
  // when GPU is disabled. Software rasterization is the only render path left.
  GlobalCEFApp.AddCustomCommandLine('--disable-extensions');
  GlobalCEFApp.AddCustomCommandLine('--no-zygote-sandbox');
  GlobalCEFApp.AddCustomCommandLine('--remote-debugging-port=9224');

  // ── Start CEF ────────────────────────────────────────────
  if GlobalCEFApp.StartMainProcess then
  begin
    CustomWidgetSetInitialization;
    RequireDerivedFormResource := True;
    Application.Scaled := True;
    Application.Initialize;
    Application.CreateForm(TControllerForm, ControllerForm);
    Application.Run;
    CustomWidgetSetFinalization;
  end;

  DestroyGlobalCEFApp;
end.
