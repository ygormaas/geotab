"""
Rotina de atualização LOCAL (dispara no logon via Agendador de Tarefas do Windows).

Por que local: o IP de saída do Render está bloqueado pelo WAF da Geotab (403);
a máquina do usuário não está bloqueada. Roda os 5 modos do sync em sequência,
cada um isolado num subprocesso (uma falha não derruba os outros).

Regras:
- Só em DIAS ÚTEIS (seg-sex). Fim de semana: sai sem fazer nada.
- UMA VEZ por dia: se já rodou com sucesso hoje, sai (evita re-rodar a cada logon).
  Se algum modo falhar, o marcador NÃO é gravado → tenta de novo no próximo logon.
- Tudo é logado em atualizacao_local.log (e a saída de cada modo também).
"""
import os
import sys
import socket
import time
import subprocess
import datetime
import pathlib

from dotenv import load_dotenv

BASE   = pathlib.Path(__file__).resolve().parent
# Carrega o .env no orquestrador (os modos e o exportar_csv.py já fazem isso por
# conta própria, mas o GUARD do export — if env.get("SUPABASE_SERVICE_KEY") — roda
# AQUI; sem o load_dotenv a chave nunca aparece e o export é pulado por engano).
load_dotenv(BASE / ".env")
LOG    = BASE / "atualizacao_local.log"
MARKER = BASE / ".ultima_atualizacao"          # guarda a data do último sucesso
# Ordem leve → pesado. São as planilhas que mudam diariamente; cadastro/status são
# snapshots rápidos, comportamento/viagens são incrementais (e atualizam, de quebra,
# o odômetro/dia e o resumo mensal do mês corrente). `abastecimento` (FuelUpEvent)
# fecha a fila: é incremental e barato (Get por janela, não por device).
MODOS  = ["cadastro", "status", "comportamento", "viagens", "abastecimento"]
NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW: não pisca janela de console

# ── Postgres local: auto-cura ────────────────────────────────────────────────
# O banco roda local e NÃO pode virar serviço do Windows (precisa de admin; GPO
# bloqueia) nem ser lançado sem console (WSH e janela-oculta bloqueados na máquina
# corporativa). Por isso ele morre quando alguém fecha a janela/terminal que o
# hospeda (CTRL_CLOSE → exceção 0xC000013A; aconteceu em 2026-06-18 e derrubou a
# sync no meio). Defesa: antes de cada sync (e após uma falha) garantimos o banco
# no ar via pg_ctl e repetimos a fase. Caminhos configuráveis por env.
PG_CTL   = os.environ.get("PG_CTL",   r"C:\Users\ygor.kouzak\pgsql\pgsql\bin\pg_ctl.exe")
PGDATA   = os.environ.get("PGDATA",   r"C:\Users\ygor.kouzak\pgdata")
PG_HOST  = os.environ.get("PG_HOST",  "127.0.0.1")
PG_PORT  = int(os.environ.get("PG_PORT", 5432))


def stamp(fh, msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    fh.write(f"{ts}  {msg}\n")
    fh.flush()


def _porta_aberta(timeout=2):
    """True se o Postgres está aceitando conexões em PG_HOST:PG_PORT."""
    try:
        with socket.create_connection((PG_HOST, PG_PORT), timeout=timeout):
            return True
    except OSError:
        return False


def garantir_postgres(fh, tentativas=2):
    """Garante o Postgres aceitando conexões. Se a porta está fechada, sobe via
    pg_ctl e espera o socket abrir (a recuperação automática pode levar dezenas de
    segundos). Retorna True se, ao fim, está no ar."""
    if _porta_aberta():
        return True
    stamp(fh, "  ⚠ Postgres fora do ar — subindo via pg_ctl...")
    server_log = str(pathlib.Path(PGDATA) / "server.log")
    for i in range(1, tentativas + 1):
        try:
            subprocess.run(
                [PG_CTL, "-D", PGDATA, "-l", server_log, "start"],
                stdout=fh, stderr=subprocess.STDOUT,
                creationflags=NO_WINDOW, timeout=120,
            )
        except Exception as exc:
            stamp(fh, f"  pg_ctl start falhou ({exc})")
        for _ in range(30):                 # espera até ~60s o socket abrir
            if _porta_aberta():
                stamp(fh, "  ✓ Postgres no ar.")
                return True
            time.sleep(2)
        stamp(fh, f"  ainda fora do ar (tentativa {i}/{tentativas})")
    return _porta_aberta()


def _rodar_modo(modo, fh, env):
    """Roda um modo do sync num subprocesso. Retorna True se exit 0."""
    rc = None
    try:
        rc = subprocess.run(
            [sys.executable, str(BASE / "geotab_supabase.py"), modo],
            cwd=str(BASE), env=env,
            stdout=fh, stderr=subprocess.STDOUT,
            creationflags=NO_WINDOW,
        ).returncode
    except Exception as exc:
        stamp(fh, f"  exceção ao rodar {modo}: {exc}")
    return rc == 0


def _exportar_csv(fh, env):
    """Exporta as views p/ CSV e sobe no Supabase Storage (links p/ clientes externos).
    NÃO-FATAL: roda só após as 4 fases OK e nunca desmarca a sync se falhar. Pulado se
    SUPABASE_SERVICE_KEY não estiver no ambiente (sem chave, não há p/ onde subir)."""
    if not env.get("SUPABASE_SERVICE_KEY"):
        stamp(fh, "  export CSV pulado (sem SUPABASE_SERVICE_KEY no .env).")
        return
    stamp(fh, "---- export CSV (Supabase Storage) ----")
    try:
        rc = subprocess.run(
            [sys.executable, str(BASE / "exportar_csv.py")],
            cwd=str(BASE), env=env,
            stdout=fh, stderr=subprocess.STDOUT,
            creationflags=NO_WINDOW,
        ).returncode
        stamp(fh, f"  {'OK' if rc == 0 else 'FALHOU (não-fatal)'} export CSV")
    except Exception as exc:
        stamp(fh, f"  exceção no export CSV (não-fatal): {exc}")


def main():
    hoje = datetime.date.today()
    with open(LOG, "a", encoding="utf-8") as fh:
        # weekday(): seg=0 ... sex=4, sáb=5, dom=6
        if hoje.weekday() >= 5:
            stamp(fh, f"Fim de semana ({hoje:%a}) — nada a fazer.")
            return

        if MARKER.exists() and MARKER.read_text(encoding="utf-8").strip() == hoje.isoformat():
            stamp(fh, "Já atualizado hoje — pulando.")
            return

        stamp(fh, "================ Atualização local iniciada ================")
        env = dict(os.environ, PYTHONIOENCODING="utf-8")

        # Banco no ar ANTES de começar (pode ter morrido por janela fechada / logoff).
        if not garantir_postgres(fh):
            stamp(fh, "================ ABORTADO: Postgres não subiu "
                      "(marcador não gravado; tenta de novo no próximo logon) ===")
            return

        falhas = []
        for modo in MODOS:
            stamp(fh, f"---- {modo} ----")
            ok = _rodar_modo(modo, fh, env)
            if not ok:
                # Falha pode ser o banco caindo no meio (CTRL_CLOSE de janela fechada):
                # religa o Postgres e tenta a fase mais uma vez.
                stamp(fh, f"  {modo} falhou — checando Postgres e tentando de novo...")
                if garantir_postgres(fh):
                    ok = _rodar_modo(modo, fh, env)
            stamp(fh, f"  {'OK' if ok else 'FALHOU'} {modo}")
            if not ok:
                falhas.append(modo)

        if falhas:
            stamp(fh, f"================ Concluído COM FALHAS: {falhas} "
                      f"(marcador não gravado; tenta de novo no próximo logon) ===")
        else:
            MARKER.write_text(hoje.isoformat(), encoding="utf-8")
            stamp(fh, "================ Concluído (todos OK) ================")
            # Snapshot do dia p/ download externo — depois da sync, nunca antes.
            _exportar_csv(fh, env)


if __name__ == "__main__":
    main()
