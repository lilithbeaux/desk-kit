program 617_browser_headless;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Interfaces,
  Forms,
  uControllerBrowser,
  uCEFApplication;

// {$R *.res}  // No .res file for headless mode

begin
  GlobalCEFApp := TCefApplication.Create;

  // Configure headless CEF
  GlobalCEFApp.FrameworkDirPath := GetEnv('CEF4DELPHI_DIR', './CEF4Delphi') + '/cef_binary_131.4.1+g437feba+chromium-131.0.6778.265_linux64/Release/';
  GlobalCEFApp.ResourcesDirPath := GetEnv('CEF4DELPHI_DIR', './CEF4Delphi') + '/cef_binary_131.4.1+g437feba+chromium-131.0.6778.265_linux64/Release/';
  GlobalCEFApp.LocalesDirPath   := GetEnv('CEF4DELPHI_DIR', './CEF4Delphi') + '/cef_binary_131.4.1+g437feba+chromium-131.0.6778.265_linux64/Release/locales/';
  GlobalCEFApp.EnableGPU        := False;  // Headless, no GPU needed
  GlobalCEFApp.LogFile          := '/tmp/cef_controller.log';
  GlobalCEFApp.LogSeverity      := 3;  // LOGSEVERITY_WARNING

  // Critical flags for headless Linux/Xvfb operation
  GlobalCEFApp.AddCustomCommandLine('--no-sandbox');
  GlobalCEFApp.AddCustomCommandLine('--disable-gpu');
  GlobalCEFApp.AddCustomCommandLine('--disable-gpu-compositing');
  GlobalCEFApp.AddCustomCommandLine('--disable-software-rasterizer');
  GlobalCEFApp.AddCustomCommandLine('--remote-debugging-port=9222');

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
