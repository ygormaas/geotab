@echo off
REM Backup diario do banco geotab (formato custom -Fc). Nome por data: um arquivo/dia.
REM Roda no logon; espera o Postgres subir; mantem so os ultimos 14 dias.
ping -n 21 127.0.0.1 >nul
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set DT=%%i
if not exist "C:\Users\ygor.kouzak\backups" mkdir "C:\Users\ygor.kouzak\backups"
REM Le a senha do .env (SUPABASE_SENHA) em vez de embutir no arquivo --
REM este .bat e versionado e a senha ia junto para o repositorio.
for /f "usebackq tokens=1,* delims==" %%a in ("%~dp0.env") do (
    if /i "%%a"=="SUPABASE_SENHA" set "PGPASSWORD=%%b"
)
if not defined PGPASSWORD (
    echo ERRO: SUPABASE_SENHA nao encontrada em %~dp0.env
    pause & exit /b 1
)
"C:\Users\ygor.kouzak\pgsql\pgsql\bin\pg_dump.exe" -U postgres -h localhost -Fc -f "C:\Users\ygor.kouzak\backups\geotab_%DT%.dump" geotab
forfiles /p "C:\Users\ygor.kouzak\backups" /m geotab_*.dump /d -14 /c "cmd /c del @path" 2>nul
