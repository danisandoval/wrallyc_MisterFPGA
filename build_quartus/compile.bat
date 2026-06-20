@echo off
rem World Rally MiSTer core - command line compile
rem Adjust QUARTUS_DIR if Quartus 17.0 is installed elsewhere.

set QUARTUS_DIR=C:\intelFPGA\17.0\quartus\bin64
if not exist "%QUARTUS_DIR%\quartus_sh.exe" set QUARTUS_DIR=C:\intelFPGA_lite\17.0\quartus\bin64

"%QUARTUS_DIR%\quartus_sh.exe" --flow compile WorldRally

if exist output_files\WorldRally.rbf (
    copy /Y output_files\WorldRally.rbf wrally.rbf
    echo.
    echo === SUCCESS: wrally.rbf ready ===
) else (
    echo.
    echo === FAILED: check output_files\*.rpt ===
)
