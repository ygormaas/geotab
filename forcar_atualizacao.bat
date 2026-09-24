@echo off
REM ============================================================
REM  Forcar atualizacao da base Geotab (ignora a trava diaria).
REM
REM  O atualizar_local.py so sincroniza UMA vez por dia: se o
REM  marcador .ultima_atualizacao ja tem a data de hoje, ele sai
REM  sem fazer nada. Este .bat apaga esse marcador e roda a sync
REM  completa de novo, para trazer os dados novos do dia.
REM
REM  Uso: duplo-clique ou rodar no terminal.
REM  Obs.: em fim de semana o proprio script nao sincroniza.
REM ============================================================
setlocal
cd /d "%~dp0"

set "PY=C:\Users\ygor.kouzak\AppData\Local\Python\pythoncore-3.14-64\python.exe"

echo.
echo Removendo marcador diario (.ultima_atualizacao)...
if exist ".ultima_atualizacao" del /f /q ".ultima_atualizacao"

echo Iniciando sincronizacao completa da Geotab...
echo (isso pode levar varios minutos - nao feche esta janela)
echo.

"%PY%" "%~dp0atualizar_local.py"
set "RC=%ERRORLEVEL%"

echo.
echo Concluido (codigo %RC%). Detalhes em: atualizacao_local.log
echo.
pause
endlocal
