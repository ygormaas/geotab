"""Copia os dados do Postgres LOCAL para o Cloud SQL (schema geotab).

Streaming CSV via os.pipe(): o COPY TO STDOUT da origem alimenta direto o
COPY FROM STDIN do destino, sem arquivo intermediario e com memoria constante
-- importante para a tb_viagens (6 milhoes de linhas).

Por que COPY e nao pg_dump: o DDL ja existe na nuvem (criado pelo
geotab_supabase.py e pelos migracao_gcp_*.sql). Falta so dado, e CSV nao tem
acoplamento de versao -- contorna o Postgres 18 local vs 16 do Cloud SQL.

Idempotente: tabela cuja contagem ja bate na origem e no destino e pulada.
Rodar: python copiar_para_cloudsql.py [tabela ...]
"""
import os
import sys
import time
import threading
import psycopg2
from dotenv import load_dotenv

load_dotenv(r"C:\Users\ygor.kouzak\Downloads\ProjetosPy\geotab\.env")

# menores primeiro: falha na ultima nao desfaz o resto
TABELAS = [
    "tb_cadastro", "tb_status", "tb_motoristas", "tb_resumo_mensal",
    "tb_odometro_mensal", "tb_abastecimento", "tb_enderecos",
    "tb_comportamento_motorista", "tb_odometro_dia", "tb_comportamento_eventos",
    "tb_viagens",
]


def conectar(pfx, schema):
    c = psycopg2.connect(
        host=os.environ[f"{pfx}HOST"], port=os.environ[f"{pfx}PORTA"],
        dbname=os.environ[f"{pfx}BANCO"], user=os.environ[f"{pfx}USUARIO"],
        password=os.environ[f"{pfx}SENHA"],
        sslmode=os.environ.get(f"{pfx}SSLMODE", "require"),
        options=f"-c search_path={schema}",
    )
    c.set_session(autocommit=True)
    return c


def contar(conn, schema, tabela):
    with conn.cursor() as cur:
        cur.execute(f'SELECT count(*) FROM {schema}."{tabela}"')
        return cur.fetchone()[0]


def colunas(conn, schema, tabela):
    with conn.cursor() as cur:
        cur.execute("""SELECT column_name FROM information_schema.columns
                       WHERE table_schema=%s AND table_name=%s
                       ORDER BY ordinal_position""", (schema, tabela))
        return [r[0] for r in cur.fetchall()]


def comuns(origem, destino, tabela):
    """Colunas presentes nos dois lados, na ordem da ORIGEM.

    CRITICO: sem lista explicita, o COPY casa coluna por POSICAO. As tabelas do
    local evoluiram por ALTER TABLE ADD COLUMN (coluna nova vai p/ o fim); as da
    nuvem nasceram na ordem atual do DDL. Em tb_viagens isso alinhava
    hodometro_final (local) com distancia_km (nuvem) -- mesmos tipos, nenhum
    erro, dado errado gravado em silencio.
    """
    a, b = colunas(origem, "public", tabela), colunas(destino, "geotab", tabela)
    so_a, so_b = [c for c in a if c not in b], [c for c in b if c not in a]
    if so_a:
        print(chr(10) + f"    ! so na origem (serao ignoradas): {so_a}", flush=True)
    if so_b:
        print(chr(10) + f"    ! so no destino (ficarao nulas):  {so_b}", flush=True)
    return [c for c in a if c in b]


def copiar(origem, destino, tabela):
    """COPY TO STDOUT -> COPY FROM STDIN atraves de um pipe do SO."""
    cols = comuns(origem, destino, tabela)
    lista = ", ".join(f'"{c}"' for c in cols)
    ler_fd, escrever_fd = os.pipe()
    erro = {}

    def produtor():
        try:
            with os.fdopen(escrever_fd, "wb") as saida, origem.cursor() as cur:
                cur.copy_expert(f'COPY public."{tabela}" ({lista}) TO STDOUT WITH CSV', saida)
        except Exception as exc:              # fecha o pipe p/ nao travar o consumidor
            erro["origem"] = exc

    t = threading.Thread(target=produtor, daemon=True)
    t.start()
    with os.fdopen(ler_fd, "rb") as entrada, destino.cursor() as cur:
        cur.execute(f'TRUNCATE geotab."{tabela}"')
        cur.copy_expert(f'COPY geotab."{tabela}" ({lista}) FROM STDIN WITH CSV', entrada)
    t.join()
    if erro:
        raise erro["origem"]


def main():
    alvos = sys.argv[1:] or TABELAS
    origem = conectar("SUPABASE_", "public")
    destino = conectar("GCP_", "geotab")
    print(f"origem : {origem.get_dsn_parameters()['host']}/public")
    print(f"destino: {destino.get_dsn_parameters()['host']}/geotab\n")

    falhas = []
    for tabela in alvos:
        n_orig = contar(origem, "public", tabela)
        n_dest = contar(destino, "geotab", tabela)
        if n_orig == n_dest:
            print(f"  = {tabela:<28} {n_orig:>9,} linhas (ja igual, pulando)", flush=True)
            continue
        print(f"  > {tabela:<28} {n_orig:>9,} linhas ...", end=" ", flush=True)
        t0 = time.time()
        try:
            copiar(origem, destino, tabela)
            final = contar(destino, "geotab", tabela)
            seg = time.time() - t0
            ok = "OK" if final == n_orig else f"DIVERGENTE (destino={final:,})"
            print(f"{ok} em {seg:,.1f}s ({n_orig/max(seg,0.01):,.0f} linhas/s)", flush=True)
            if final != n_orig:
                falhas.append(tabela)
        except Exception as exc:
            print(f"ERRO: {str(exc).strip()[:200]}", flush=True)
            falhas.append(tabela)

    origem.close()
    destino.close()
    print("\n" + ("FALHARAM: " + ", ".join(falhas) if falhas else "TODAS AS TABELAS OK."))
    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
