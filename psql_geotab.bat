@echo off
REM Abre o cliente nativo psql ja conectado no banco local geotab.
REM Duplo-clique ou rode no terminal. Saia com \q
REM Le a senha do .env (SUPABASE_SENHA) em vez de embutir no arquivo --
REM este .bat e versionado e a senha ia junto para o repositorio.
for /f "usebackq tokens=1,* delims==" %%a in ("%~dp0.env") do (
    if /i "%%a"=="SUPABASE_SENHA" set "PGPASSWORD=%%b"
)
if not defined PGPASSWORD (
    echo ERRO: SUPABASE_SENHA nao encontrada em %~dp0.env
    pause & exit /b 1
)
"C:\Users\ygor.kouzak\pgsql\pgsql\bin\psql.exe" -U postgres -h localhost -d geotab
