@echo off
rem WLED mapping layer host tests (MSVC). No ESP32 / PlatformIO build needed.
rem Needs: Visual Studio "Desktop development with C++" and ArduinoJson downloaded by PlatformIO (.pio\libdeps).
setlocal
set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
  echo vcvars64.bat not found: %VCVARS%
  exit /b 2
)
call "%VCVARS%" >nul 2>nul
set "HERE=%~dp0"
set "OUT=%TEMP%\wled_host_test"
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /std:c++17 /EHsc /W3 /Fo"%OUT%\\" /Fe"%OUT%\wled_map_test.exe" ^
  /I"%HERE%..\src\wled" /I"%HERE%..\.pio\libdeps\esp32dev\ArduinoJson\src" ^
  "%HERE%wled_map_test.cpp" "%HERE%..\src\wled\wled_map.cpp"
if errorlevel 1 exit /b 1
"%OUT%\wled_map_test.exe" %*
exit /b %errorlevel%
