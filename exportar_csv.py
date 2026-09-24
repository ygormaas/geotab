"""
exportar_csv.py — exporta cada view do banco local p/ CSV e sobe no Supabase Storage.

Para clientes EXTERNOS baixarem sem depender do notebook estar ligado: roda no FIM da
sync diária (chamado por atualizar_local.py) e grava cada view como um arquivo de NOME
FIXO no Storage (sobrescreve o de ontem, x-upsert) → o link público NUNCA muda. O
cliente guarda o link uma vez.

Tamanhos reais (medidos 2026-06-22): as 8 views "dashboard" somam ~70 MB (a maior,
vw_motoristas, 39 MB). A vw_relatorio_viagens é o elefante: 1,6 GB / 3,58M linhas (ano
inteiro no local). Por isso ela é DIVIDIDA POR MÊS e cada mês é compactado (.csv.gz,
~11 MB) — assim cabe no free tier de 1 GB do Storage e o cliente baixa só o mês que quer.
Excel (Power Query), Power BI e pandas leem .csv.gz direto.

Config (no .env):
  SUPABASE_STORAGE_URL  = https://<ref>.supabase.co     (base do projeto)
  SUPABASE_SERVICE_KEY  = <service_role JWT>            (escrita no bucket)
  SUPABASE_BUCKET       = geotab-csv                    (opcional; default geotab-csv)
  PSQL                  = caminho do psql.exe           (opcional; default abaixo)
SE SUPABASE_SERVICE_KEY não estiver setada, o upload é PULADO: os CSVs ainda são gerados
em ./exports (útil p/ testar antes de ter a chave).
"""
import os
import gzip
import subprocess
import pathlib
import datetime
import html

import requests
from dotenv import load_dotenv

load_dotenv()
BASE = pathlib.Path(__file__).resolve().parent
OUT = BASE / "exports"

# ── Conexão Postgres local (mesmas chaves SUPABASE_* do resto do projeto) ──────
PSQL = os.environ.get("PSQL", r"C:\Users\ygor.kouzak\pgsql\pgsql\bin\psql.exe")
# Destino da LEITURA, mesma chave do geotab_supabase.py:
#   "local" (DEFAULT) -> chaves SUPABASE_*  (Postgres da maquina)
#   "cloud"           -> chaves GCP_*       (Cloud SQL, schema geotab)
# Este script NAO usa o criar_engine() -- chama o psql.exe direto -- entao sem
# este seletor ele continuaria lendo o banco LOCAL depois da virada p/ a nuvem,
# publicando CSV velho para os clientes externos sem erro nenhum.
DESTINO = os.environ.get("GEOTAB_DESTINO", "local").strip().lower()
if DESTINO not in ("local", "cloud"):
    raise SystemExit("GEOTAB_DESTINO invalido: " + repr(DESTINO) + ". Use 'local' ou 'cloud'.")
_PFX = "GCP_" if DESTINO == "cloud" else "SUPABASE_"

PGHOST = os.environ.get(_PFX + "HOST", "127.0.0.1")
PGPORT = os.environ.get(_PFX + "PORTA", "5432")
PGDB = os.environ.get(_PFX + "BANCO", "geotab")
PGUSER = os.environ.get(_PFX + "USUARIO", "postgres")
PGPASS = os.environ.get(_PFX + "SENHA", "")
PGSSL = os.environ.get(_PFX + "SSLMODE", "disable" if DESTINO == "local" else "require")
PGSCHEMA = os.environ.get(_PFX + "SCHEMA", "").strip()

# ── Supabase Storage ──────────────────────────────────────────────────────────
STORAGE_URL = os.environ.get("SUPABASE_STORAGE_URL", "").rstrip("/")
SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
BUCKET = os.environ.get("SUPABASE_BUCKET", "geotab-csv")

# Views "dashboard": pequenas, exportadas inteiras como .csv.
# (view_no_banco, nome_do_arquivo). As views foram renomeadas p/ vw_saneago_*
# em 2026-08-24, mas o ARQUIVO CSV mantém o nome antigo p/ não quebrar os links
# públicos que os clientes externos já têm.
VIEWS = [
    ("vw_saneago_cadastro",            "vw_cadastro"),
    ("vw_saneago_status",              "vw_status"),
    ("vw_saneago_grupos",              "vw_grupos"),
    ("vw_saneago_comportamento",       "vw_comportamento"),
    ("vw_saneago_motoristas",          "vw_motoristas"),
    ("vw_saneago_motoristas_anual",    "vw_motoristas_anual"),
    ("vw_saneago_indicadores_mensal",  "vw_indicadores_mensal"),
    ("vw_saneago_resumo_frota_mensal", "vw_resumo_frota_mensal"),
]
# View grande: dividida por mês e compactada. (view_no_banco, coluna_de_data, nome_do_arquivo)
VIEW_MENSAL = ("vw_saneago_relatorio_viagens", "data_partida", "vw_relatorio_viagens")

# Free tier do Supabase Storage: 50 MB POR ARQUIVO (não-negociável no plano grátis).
# Particionamos cada mês em pedaços cujo CSV cru fica <= ALVO_CSV; o gzip dessa
# base (~5x p/ esses dados) garante folga sob os 50 MB. Mês pequeno = 1 arquivo.
LIMITE_ARQUIVO = 50 * 1024 * 1024
ALVO_CSV = 180 * 1024 * 1024  # ~180 MB cru → ~36 MB gzip, bem abaixo do limite


def _env_psql():
    # PGCLIENTENCODING=UTF8 é OBRIGATÓRIO: sem isso o psql assume WIN1252 do console
    # Windows e o \copy aborta no 1º acento (testado 2026-06-22).
    env = dict(os.environ, PGPASSWORD=PGPASS, PGCLIENTENCODING="UTF8", PGSSLMODE=PGSSL)
    if PGSCHEMA:
        # o psql nao passa pelo criar_engine(); o schema alvo vai por aqui
        env["PGOPTIONS"] = "-c search_path=" + PGSCHEMA
    return env


def _psql_query(sql):
    """Roda um SELECT e devolve a saída crua (modo -At, sem cabeçalho/alinhamento)."""
    cmd = [PSQL, "-h", PGHOST, "-p", str(PGPORT), "-U", PGUSER, "-d", PGDB,
           "-v", "ON_ERROR_STOP=1", "-At", "-c", sql]
    return subprocess.run(cmd, env=_env_psql(), capture_output=True, text=True,
                          check=True).stdout


def _psql_copy(sql):
    """Roda um meta-comando \\copy (escreve arquivo no lado cliente)."""
    cmd = [PSQL, "-h", PGHOST, "-p", str(PGPORT), "-U", PGUSER, "-d", PGDB,
           "-v", "ON_ERROR_STOP=1", "-c", sql]
    subprocess.run(cmd, env=_env_psql(), check=True)


def _gzip_particionado(csv_path, base):
    """Compacta um .csv em 1+ .csv.gz de forma que cada parte (CSV cru) fique <= ALVO_CSV,
    cada uma com o cabeçalho. Remove o .csv original. `base` = Path sem extensão.
    1 parte → `base.csv.gz`; várias → `base_p1.csv.gz`, `base_p2.csv.gz`, ..."""
    partes, fo, bytes_parte, idx = [], None, 0, 0
    with open(csv_path, "r", encoding="utf-8", newline="") as fi:
        header = fi.readline()
        hbytes = len(header.encode("utf-8"))
        for linha in fi:
            if fo is None or bytes_parte >= ALVO_CSV:
                if fo:
                    fo.close()
                idx += 1
                p = base.with_name(f"{base.name}_p{idx}.csv.gz")
                partes.append(p)
                fo = gzip.open(p, "wt", encoding="utf-8", newline="", compresslevel=6)
                fo.write(header)
                bytes_parte = hbytes
            fo.write(linha)
            bytes_parte += len(linha.encode("utf-8"))
        if fo:
            fo.close()
    csv_path.unlink()
    if len(partes) == 1:  # sem split: nome limpo, sem _p1
        final = base.with_name(f"{base.name}.csv.gz")
        partes[0].replace(final)
        return [final]
    return partes


def exportar_view(view, arquivo):
    """Exporta uma view inteira como .csv. `view` = nome no banco; `arquivo` = nome
    do CSV (mantido antigo p/ não quebrar links). Retorna o caminho do arquivo."""
    arq = OUT / f"{arquivo}.csv"
    _psql_copy(
        rf"\copy (SELECT * FROM {view}) TO '{arq.as_posix()}' "
        r"WITH (FORMAT csv, HEADER true)"
    )
    return arq


def exportar_view_mensal(view, col, arquivo):
    """Exporta a view dividida por mês, cada mês compactado. `view` = nome no banco;
    `arquivo` = base do nome do CSV. Retorna lista de .csv.gz."""
    meses = [m for m in _psql_query(
        f"SELECT DISTINCT to_char({col},'YYYY-MM') FROM {view} "
        f"WHERE {col} IS NOT NULL ORDER BY 1"
    ).splitlines() if m.strip()]
    arqs = []
    for ym in meses:
        csv = OUT / f"{arquivo}_{ym}.csv"
        _psql_copy(
            rf"\copy (SELECT * FROM {view} "
            rf"WHERE {col} >= '{ym}-01'::date "
            rf"AND {col} < ('{ym}-01'::date + INTERVAL '1 month') "
            rf"ORDER BY {col}) TO '{csv.as_posix()}' WITH (FORMAT csv, HEADER true)"
        )
        arqs += _gzip_particionado(csv, OUT / f"{arquivo}_{ym}")
    return arqs


def garantir_bucket():
    """Cria o bucket público (idempotente). Sem creds, não faz nada."""
    if not (STORAGE_URL and SERVICE_KEY):
        return
    r = requests.post(
        f"{STORAGE_URL}/storage/v1/bucket",
        json={"id": BUCKET, "name": BUCKET, "public": True,
              "file_size_limit": LIMITE_ARQUIVO},
        headers={"Authorization": f"Bearer {SERVICE_KEY}", "apikey": SERVICE_KEY,
                 "Content-Type": "application/json"},
        timeout=30,
    )
    # 200 = criado; 400/409 "already exists" = ok; outros = problema real.
    if r.status_code not in (200, 400, 409):
        r.raise_for_status()


def limpar_bucket():
    """Apaga TODOS os objetos do bucket antes de subir o snapshot do dia. Garante que
    nomes que mudaram (ex.: mês que vira mais partes) não deixem órfãos acumulando."""
    if not (STORAGE_URL and SERVICE_KEY):
        return
    h = {"Authorization": f"Bearer {SERVICE_KEY}", "apikey": SERVICE_KEY,
         "Content-Type": "application/json"}
    r = requests.post(f"{STORAGE_URL}/storage/v1/object/list/{BUCKET}",
                      json={"prefix": "", "limit": 1000, "offset": 0}, headers=h, timeout=30)
    r.raise_for_status()
    nomes = [o["name"] for o in r.json() if o.get("name")]
    if nomes:
        d = requests.delete(f"{STORAGE_URL}/storage/v1/object/{BUCKET}",
                            json={"prefixes": nomes}, headers=h, timeout=60)
        d.raise_for_status()


def upload(arq):
    """Sobe um arquivo (upsert) e devolve a URL pública. Sem creds, devolve None."""
    if not (STORAGE_URL and SERVICE_KEY):
        return None
    nome = arq.name
    ctype = "application/gzip" if nome.endswith(".gz") else "text/csv; charset=utf-8"
    with open(arq, "rb") as f:
        r = requests.post(
            f"{STORAGE_URL}/storage/v1/object/{BUCKET}/{nome}",
            data=f,
            headers={"Authorization": f"Bearer {SERVICE_KEY}",
                     "Content-Type": ctype, "x-upsert": "true"},
            timeout=600,
        )
    r.raise_for_status()
    return f"{STORAGE_URL}/storage/v1/object/public/{BUCKET}/{nome}"


def gerar_index(links):
    """Página HTML única com todos os links — é ESSE link que se manda ao cliente."""
    agora = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
    linhas = "\n".join(
        f'<tr><td>{html.escape(n)}</td>'
        f'<td><a href="{html.escape(u)}">baixar</a></td></tr>'
        for n, u in sorted(links.items())
    )
    return (
        "<!doctype html><meta charset='utf-8'>"
        "<title>Downloads Geotab</title>"
        "<style>body{font-family:sans-serif;max-width:680px;margin:40px auto}"
        "td{padding:6px 12px;border-bottom:1px solid #eee}</style>"
        f"<h2>Downloads Geotab (CSV)</h2><p>Atualizado em {agora}</p>"
        f"<table>{linhas}</table>"
    )


def main():
    if OUT.exists():
        for f in OUT.glob("*"):
            f.unlink()
    OUT.mkdir(exist_ok=True)

    garantir_bucket()
    limpar_bucket()  # remove o snapshot de ontem (evita órfãos de nomes que mudaram)
    gerados = [exportar_view(v, arq) for v, arq in VIEWS]
    gerados += exportar_view_mensal(*VIEW_MENSAL)

    links = {}
    for arq in gerados:
        url = upload(arq)
        if url:
            links[arq.name] = url
        print(("UP " if url else "EXPORTADO ") + arq.name + (f" -> {url}" if url else ""))

    if links:
        idx = OUT / "index.html"
        idx.write_text(gerar_index(links), encoding="utf-8")
        url_idx = upload(idx)
        print(f"\nÍNDICE (link p/ o cliente): {url_idx}")
    else:
        print("\n(Upload pulado: defina SUPABASE_STORAGE_URL e SUPABASE_SERVICE_KEY "
              "no .env. CSVs gerados em ./exports.)")


if __name__ == "__main__":
    main()
