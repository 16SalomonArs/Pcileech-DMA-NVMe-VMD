@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "VIVADO_EXE="
for /f "delims=" %%I in ('where vivado 2^>nul') do if not defined VIVADO_EXE set "VIVADO_EXE=%%I"
if not defined VIVADO_EXE (
    for %%V in (2025.1 2024.2 2024.1 2023.2 2023.1) do (
        if not defined VIVADO_EXE if exist "C:\Xilinx\Vivado\%%V\bin\vivado.bat" set "VIVADO_EXE=C:\Xilinx\Vivado\%%V\bin\vivado.bat"
        if not defined VIVADO_EXE if exist "C:\Xilinx\Vivado\%%V\bin\vivado.exe" set "VIVADO_EXE=C:\Xilinx\Vivado\%%V\bin\vivado.exe"
    )
    if not defined VIVADO_EXE (
        echo vivado was not found. Open a Vivado Tcl Shell, add Vivado bin to PATH, or install Vivado under C:\Xilinx\Vivado.
        exit /b 1
    )
)
call "%VIVADO_EXE%" -source "%SCRIPT_DIR%vivado_generate_project_captaindma_100T.tcl" -notrace -nolog -nojournal
