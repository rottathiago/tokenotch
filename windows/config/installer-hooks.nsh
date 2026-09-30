!include "${__FILEDIR__}/minimum-build.nsh"

!macro NSIS_HOOK_PREINSTALL
  Push $R0
  ReadRegStr $R0 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "CurrentBuildNumber"
  IntCmp $R0 ${TOKENOTCH_MINIMUM_WINDOWS_BUILD} tokenotch_supported tokenotch_unsupported tokenotch_supported
  tokenotch_unsupported:
    MessageBox MB_OK|MB_ICONSTOP "This Tokenotch development build requires Windows 11 24H2 or later." /SD IDOK
    Pop $R0
    Abort
  tokenotch_supported:
    Pop $R0
!macroend
