"""Diagnostico de conexao com o Cloud SQL (migracao 2026-09).

Le as chaves GCP_* do .env e tenta conectar, traduzindo o erro do Postgres
em um diagnostico util. Nao grava nada: so le. Rodar com:

    python testar_cloudsql.py
"""
import os
import sys
import socket
import psycopg2
from dotenv import load_dotenv

load_dotenv()

CFG = {
    "host":     os.environ.get("GCP_HOST", ""),
    "port":     int(os.environ.get("GCP_PORTA", 5432)),
    "dbname":   os.environ.get("GCP_BANCO", ""),
    "user":     os.environ.get("GCP_USUARIO", ""),
    "password": os.environ.get("GCP_SENHA", ""),
    "sslmode":  os.environ.get("GCP_SSLMODE", "require"),
}
SCHEMA = os.environ.get("GCP_SCHEMA", "").strip()

if not CFG["password"]:
    sys.exit("ERRO: GCP_SENHA vazia no .env. Preencha e rode de novo.")

print(f"Alvo: {CFG['user']}@{CFG['host']}:{CFG['port']}/{CFG['dbname']} "
      f"(sslmode={CFG['sslmode']}, schema={SCHEMA or '<padrao>'})\n")

# 1) alcance TCP — separa problema de rede de problema de credencial
try:
    with socket.create_connection((CFG["host"], CFG["port"]), timeout=10):
        print("[1/3] TCP ............ alcancavel")
except Exception as exc:
    sys.exit(f"[1/3] TCP ............ FALHOU ({exc})\n"
             ">> Bloqueio de rede antes do Postgres. Nao e credencial.")

# 2) handshake + autenticacao
opts = f"-c search_path={SCHEMA}" if SCHEMA else None
try:
    conn = psycopg2.connect(connect_timeout=15, options=opts, **CFG)
except psycopg2.OperationalError as exc:
    msg = str(exc).strip()
    print(f"[2/3] Autenticacao .. FALHOU\n{msg}\n")
    baixo = msg.lower()
    if "timeout" in baixo or "timed out" in baixo:
        diag = ("IP nao autorizado na instancia. O TCP passa pelo balanceador do Google, "
                "mas o Postgres nunca responde. Pedir liberacao do IP a T.I.")
    elif "pg_hba" in baixo:
        diag = "Servidor alcancado, mas a regra pg_hba recusou este IP/usuario/metodo."
    elif "password authentication failed" in baixo:
        diag = "REDE OK! Chegou no Postgres. Senha incorreta para este usuario."
    elif "does not exist" in baixo:
        diag = "REDE OK! Chegou no Postgres. Banco ou usuario com nome errado."
    elif "ssl" in baixo:
        diag = "Problema de SSL. A instancia exige criptografia (ENCRYPTED_ONLY)."
    else:
        diag = "Erro nao mapeado — ver mensagem acima."
    sys.exit(f">> {diag}")

# 3) confirmacao de onde caiu
with conn, conn.cursor() as cur:
    cur.execute("SELECT current_user, current_database(), current_setting('search_path'), version()")
    usuario, banco, path, versao = cur.fetchone()
    cur.execute("SELECT count(*) FROM pg_tables WHERE schemaname = %s", (SCHEMA or "public",))
    tabelas = cur.fetchone()[0]
conn.close()

print("[2/3] Autenticacao .. OK")
print("[3/3] Sessao ........ OK\n")
print(f"  usuario ......... {usuario}")
print(f"  banco ........... {banco}")
print(f"  search_path ..... {path}")
print(f"  tabelas em {SCHEMA or 'public'} ... {tabelas}")
print(f"  servidor ........ {versao.split(',')[0]}")
print("\n>> CONEXAO COMPLETA. O sync pode apontar para ca.")
