@echo off
rem ====================================================================
rem  World Rally - pull changed files from the Mac share, then compile
rem  locally on the Desktop (Quartus is unhappy compiling over SMB).
rem  Run this from anywhere in the VM each iteration.
rem ====================================================================

set SRC=\\MacBook-Pro-de-Dani.local\wrallya\WorldRally_MiSTer
set DST=C:\Users\kagig\Desktop\WorldRally_MiSTer

echo === syncing changed source files from share ===
robocopy "%SRC%" "%DST%" /E /XO /XD output_files db incremental_db .qsys_edit greybox_tmp /XF *.bak /NFL /NDL /NJH /NJS /R:2 /W:3

echo === compiling locally ===
cd /d "%DST%"
call compile.bat

echo === copying RBF + reports back to share for the agent ===
copy /Y "%DST%\wrally.rbf" "%SRC%\wrally.rbf" >nul 2>&1
robocopy "%DST%\output_files" "%SRC%\output_files" *.summary *.rpt /NFL /NDL /NJH /NJS /R:1 /W:1 >nul

echo === DONE ===
