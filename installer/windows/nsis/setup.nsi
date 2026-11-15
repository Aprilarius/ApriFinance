Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WordFunc.nsh"
!include "x64.nsh"
!include "WinVer.nsh"
!include "Sections.nsh"
!insertmacro VersionCompare

!ifdef InstallerQA
  !define AppTitle "ApriFinance — QA"
  !define AppKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\ApriFinance.InstallerQA"
  !define OldKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\MyFinances.Personal.Desktop.InstallerQA_is1"
  !define RunMutex "Local\MyFinances.InstallerQA.Running"
  !define SetupMutex "Local\MyFinances.InstallerQA.Setup"
  !define DefaultFolder "ApriFinance-QA"
!else
  !define AppTitle "ApriFinance"
  !define AppKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\ApriFinance"
  !define OldKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\MyFinances.Personal.Desktop_is1"
  ; Stable mutex keeps compatibility with the previous application and installer.
  !define RunMutex "Local\MyFinances.Desktop.Running"
  !define SetupMutex "Local\MyFinances.Desktop.Setup"
  !define DefaultFolder "ApriFinance"
!endif

Name "${AppTitle} ${AppVersion}"
OutFile "${OutputFile}"
InstallDir "$LOCALAPPDATA\Programs\${DefaultFolder}"
InstallDirRegKey HKCU "${AppKey}" "InstallLocation"
RequestExecutionLevel user
ManifestDPIAware true
SetCompressor /SOLID lzma
CRCCheck force
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${AppInternalVersion}"
VIAddVersionKey /LANG=1049 "ProductName" "ApriFinance"
VIAddVersionKey /LANG=1049 "FileDescription" "ApriFinance — установка"
VIAddVersionKey /LANG=1049 "FileVersion" "${AppVersion}"
VIAddVersionKey /LANG=1049 "ProductVersion" "${AppVersion}"
VIAddVersionKey /LANG=1049 "LegalCopyright" "Copyright 2026 Bahadur"
!define MUI_ICON "${AppIcon}"
!define MUI_UNICON "${AppIcon}"
!define MUI_ABORTWARNING
!define MUI_CUSTOMFUNCTION_GUIINIT SetupGui
!define MUI_WELCOMEPAGE_TITLE "ApriFinance 1.0"
!define MUI_WELCOMEPAGE_TEXT "Личный учёт доходов, расходов, платежей и гарантий.$\r$\n$\r$\nПрограмма устанавливается для текущего пользователя. Права администратора не требуются.$\r$\n$\r$\nПеред обновлением закройте приложение. При переходе с «Мои финансы» прежняя программа будет удалена, а база и резервные копии сохранятся."
!define MUI_FINISHPAGE_TEXT "ApriFinance установлен.$\r$\n$\r$\nЗапустите приложение из меню «Пуск». Данные хранятся отдельно от программы."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"
!insertmacro MUI_LANGUAGE "English"

Var SetupHandle
Var PreviousLocation

!macro CheckRunning Prefix
  System::Call 'kernel32::OpenMutexW(i 0x100000, i 0, w "${RunMutex}")p.r0'
  ${If} $0 != 0
    System::Call 'kernel32::CloseHandle(p r0)'
    MessageBox MB_OK|MB_ICONEXCLAMATION "Закройте ApriFinance / «Мои финансы» и повторите действие. Данные не изменены." /SD IDOK
    SetErrorLevel 10
    Quit
  ${EndIf}
!macroend

Function .onInit
  SetShellVarContext current
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Нужна 64-разрядная Windows 10 или новее." /SD IDOK
    SetErrorLevel 11
    Quit
  ${EndIf}
  SetRegView 64
  ${IfNot} ${AtLeastWin10}
    SetErrorLevel 11
    Quit
  ${EndIf}
  ${IfNot} ${AtLeastBuild} 19041
    SetErrorLevel 11
    Quit
  ${EndIf}
  !insertmacro CheckRunning ""
  System::Call 'kernel32::CreateMutexW(p 0, i 0, w "${SetupMutex}")p.s ?e'
  Pop $0
  Pop $SetupHandle
  ${If} $0 = 183
    MessageBox MB_OK|MB_ICONEXCLAMATION "Установка или удаление уже выполняется." /SD IDOK
    SetErrorLevel 12
    Quit
  ${EndIf}
  ReadRegStr $0 HKCU "${AppKey}" "DisplayVersion"
  ${VersionCompare} $0 "${AppInternalVersion}" $1
  ${If} $1 = 1
    MessageBox MB_OK|MB_ICONEXCLAMATION "Установлена более новая версия ApriFinance. Понижение версии не выполняется." /SD IDOK
    SetErrorLevel 13
    Quit
  ${EndIf}
FunctionEnd

Function .onVerifyInstDir
  IfFileExists "$INSTDIR\finance.sqlite" 0 +2
    Abort
FunctionEnd

Section "ApriFinance (обязательно)" MainSection
  SectionIn RO
  !insertmacro CheckRunning ""
  IfFileExists "$INSTDIR\finance.sqlite" 0 +4
    MessageBox MB_OK|MB_ICONSTOP "В выбранной папке находится finance.sqlite. Выберите отдельную папку для программы." /SD IDOK
    SetErrorLevel 14
    Quit
  ; Also guard a newer portable executable when the destination was overridden.
  ClearErrors
  GetDLLVersion "$INSTDIR\ApriFinance.exe" $0 $1
  ${IfNot} ${Errors}
    IntOp $2 $0 >> 16
    IntOp $3 $0 & 0xFFFF
    IntOp $4 $1 >> 16
    IntOp $6 $1 & 0xFFFF
    ${VersionCompare} "$2.$3.$4.$6" "${AppInternalVersion}" $5
    ${If} $5 = 1
      SetErrorLevel 13
      Quit
    ${EndIf}
  ${EndIf}
  ReadRegStr $PreviousLocation HKCU "${OldKey}" "InstallLocation"
  ${If} $PreviousLocation != ""
    ; The old installer owns its files; never use recursive deletion here.
    IfFileExists "$PreviousLocation\unins000.exe" 0 legacy_missing
    ExecWait '"$PreviousLocation\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' $0
    ${If} $0 != 0
      MessageBox MB_OK|MB_ICONSTOP "Не удалось удалить прежнюю программу. Установка остановлена; данные сохранены." /SD IDOK
      SetErrorLevel 15
      Quit
    ${EndIf}
    Goto legacy_done
    legacy_missing:
      MessageBox MB_OK|MB_ICONSTOP "Не найден деинсталлятор прежней версии. Удалите её через настройки Windows и повторите установку. Финансовые данные сохранятся." /SD IDOK
      SetErrorLevel 15
      Quit
    legacy_done:
  ${EndIf}
  SetOverwrite on
  SetOutPath "$INSTDIR"
  ClearErrors
  File /r "${PayloadDir}\*"
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONSTOP "Не удалось записать файлы. Закройте приложение и повторите установку." /SD IDOK
    SetErrorLevel 16
    Quit
  ${EndIf}
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\${AppTitle}"
  SetOutPath "$INSTDIR"
  CreateShortcut "$SMPROGRAMS\${AppTitle}\${AppTitle}.lnk" "$INSTDIR\ApriFinance.exe"
  ClearErrors
  ${GetParameters} $0
  ${GetOptions} $0 "/DESKTOP=1" $1
  ${IfNot} ${Errors}
    CreateShortcut "$DESKTOP\${AppTitle}.lnk" "$INSTDIR\ApriFinance.exe"
  ${EndIf}
  WriteRegStr HKCU "${AppKey}" "DisplayName" "${AppTitle}"
  WriteRegStr HKCU "${AppKey}" "DisplayVersion" "${AppInternalVersion}"
  WriteRegStr HKCU "${AppKey}" "Publisher" "Bahadur"
  WriteRegStr HKCU "${AppKey}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${AppKey}" "DisplayIcon" "$INSTDIR\ApriFinance.exe"
  WriteRegStr HKCU "${AppKey}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "${AppKey}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "${AppKey}" "NoModify" 1
  WriteRegDWORD HKCU "${AppKey}" "NoRepair" 1
SectionEnd

Section /o "Ярлык на рабочем столе" DesktopSection
  CreateShortcut "$DESKTOP\${AppTitle}.lnk" "$INSTDIR\ApriFinance.exe"
SectionEnd

Function SetupGui
  ${GetParameters} $0
  ${GetOptions} $0 "/DESKTOP=1" $1
  ${IfNot} ${Errors}
    SectionSetFlags ${DesktopSection} ${SF_SELECTED}
  ${EndIf}
FunctionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  !insertmacro CheckRunning "un."
  System::Call 'kernel32::CreateMutexW(p 0, i 0, w "${SetupMutex}")p.s ?e'
  Pop $0
  Pop $SetupHandle
  ${If} $0 = 183
    MessageBox MB_OK|MB_ICONEXCLAMATION "Установка или удаление уже выполняется." /SD IDOK
    SetErrorLevel 12
    Quit
  ${EndIf}
FunctionEnd

Section "Uninstall"
  !insertmacro CheckRunning "un."
  ; Generated from the exact payload: explicit files and empty directories only.
  !include "${UninstallFiles}"
  Delete "$SMPROGRAMS\${AppTitle}\${AppTitle}.lnk"
  RMDir "$SMPROGRAMS\${AppTitle}"
  Delete "$DESKTOP\${AppTitle}.lnk"
  DeleteRegKey HKCU "${AppKey}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
