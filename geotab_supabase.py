import os
import gc
import sys
import time
import calendar
import logging
import threading
import collections
import unicodedata
import requests
import pandas as pd
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from sqlalchemy.engine.url import URL
from sqlalchemy.pool import NullPool

BRT = ZoneInfo("America/Sao_Paulo")


def agora_brt():
    """Retorna o datetime atual em BRT como naive (sem offset).
    Colunas são TIMESTAMP (sem timezone) — o valor é exibido como está."""
    return datetime.now(tz=BRT).replace(tzinfo=None)


def ts_brt(valor):
    """Converte qualquer timestamp UTC (string ou pd.Timestamp) para naive BRT.
    Retorna pd.NaT se inválido — mantém dtype datetime64 no DataFrame."""
    ts = pd.to_datetime(valor, utc=True, errors="coerce")
    if pd.isna(ts):
        return pd.NaT
    return ts.tz_convert(BRT).tz_localize(None)


load_dotenv()

GEOTAB = {
    "servidor": os.environ["GEOTAB_SERVIDOR"],
    "database": os.environ["GEOTAB_DATABASE"],
    "userName": os.environ["GEOTAB_USERNAME"],
    "password": os.environ["GEOTAB_PASSWORD"],
}

# Destino da gravacao (migracao 2026-09-22):
#   "local" (DEFAULT) -> chaves SUPABASE_*  = Postgres da maquina. E a PRODUCAO.
#   "cloud"           -> chaves GCP_*       = Cloud SQL, schema geotab do banco maas_man.
# O ensaio da migracao roda com GEOTAB_DESTINO=cloud e NAO toca nas chaves de producao.
# A tarefa agendada nao define a variavel, entao continua caindo em "local".
DESTINO = os.environ.get("GEOTAB_DESTINO", "local").strip().lower()
if DESTINO not in ("local", "cloud"):
    raise SystemExit(f"GEOTAB_DESTINO invalido: {DESTINO!r}. Use 'local' ou 'cloud'.")
_PFX = "GCP_" if DESTINO == "cloud" else "SUPABASE_"

SUPABASE = {
    "host":    os.environ[f"{_PFX}HOST"],
    "porta":   int(os.environ.get(f"{_PFX}PORTA", 5432)),
    "banco":   os.environ[f"{_PFX}BANCO"],
    "usuario": os.environ[f"{_PFX}USUARIO"],
    "senha":   os.environ[f"{_PFX}SENHA"],
    # require: nuvem (Cloud SQL exige SSL). disable: Postgres local sem SSL.
    "sslmode": os.environ.get(f"{_PFX}SSLMODE", "require"),
    # Schema alvo. Vazio = search_path padrao do banco (Postgres local: public).
    # No Cloud SQL as tabelas moram no schema "geotab" dentro do banco maas_man.
    "schema":  os.environ.get(f"{_PFX}SCHEMA", "").strip(),
}

# GPS: acumulado pelo device Geotab desde a instalação — sempre em metros.
DIAG_GPS = "DiagnosticDeviceTotalDistanceId"

# Odômetro físico via OBD2 — testados em ordem de prioridade.
# A UNIDADE É PROPRIEDADE DO DIAGNÓSTICO, não do valor (corrigido 2026-09-22).
# Antes havia um palpite por leitura (`> 1_000_000 → metros`) que errava em todo
# veículo com menos de 1.000 km — ver _inferir_km. E como o diagnóstico é
# ESCOLHIDO EM TEMPO DE EXECUÇÃO (_selecionar_diag_fisico pega o 1º com dado),
# um palpite global também quebraria se a escolha mudasse: o 1º candidato já
# entrega km pelo próprio nome.
#
# Sondado nesta base em 2026-09-22 (set/26, 20 devices):
#   DiagnosticOdometerInKilometersId → 0 leituras (VAZIO nesta base)
#   DiagnosticOdometerAdjustmentId   → 219 leituras, 9.456.000 a 190.527.798
#                                      (= 9.456 a 190.527 km → metros)
#   DiagnosticOdometer               → 0 leituras
DIAG_ODO_FISICO = [
    "DiagnosticOdometerInKilometersId",
    "DiagnosticOdometerAdjustmentId",
    "DiagnosticOdometer",
]

# Divisor por diagnóstico p/ chegar em km. Default (diag desconhecido) = 1000,
# que é o caso dos dois diagnósticos em metros.
DIVISOR_ODO_KM = {
    "DiagnosticOdometerInKilometersId": 1,      # já vem em km (pelo nome)
    "DiagnosticOdometerAdjustmentId":   1000,   # metros — confirmado por sondagem
    "DiagnosticOdometer":               1000,   # metros
}

# Devices por lote nas consultas de StatusData (odômetro). Cada device pode ter
# milhares de leituras em 30 dias; lote menor = menos leituras seguradas por vez
# = menor pico de memória (essencial no free tier do Render, 512 MB).
ODO_LOTE = int(os.environ.get("GEOTAB_ODO_LOTE", 25))

# Janela (dias) do odômetro no modo INCREMENTAL do comportamento. O odômetro é
# monotônico: basta a leitura mais recente. Quem não reportou nessa janela curta
# mantém o valor anterior (max-merge). No backfill usamos os 6 meses + fallback.
ODO_INCREMENTAL_DIAS = int(os.environ.get("GEOTAB_ODO_INCREMENTAL_DIAS", 7))

# Piso temporal GLOBAL: o projeto só considera dados de ANO_CORTE em diante
# ("somente 2026 em todas as tabelas"). Aplicado como floor nas janelas do sync
# (comportamento, viagens, odômetro, resumo mensal) e na limpeza das tabelas.
# Bump ANO_CORTE (ou a env) para virar o ano.
ANO_CORTE  = int(os.environ.get("ANO_CORTE", 2026))
DATA_CORTE = datetime(ANO_CORTE, 1, 1)

# Piso PRÓPRIO do ODÔMETRO (2026-09-22). O usuário quer hodômetro de 2025 sem
# arrastar comportamento/viagens/resumo junto — baixar ANO_CORTE faria tb_viagens
# (204 MB só de 2026) quase dobrar, desfazendo o enxugamento de 2026-06-15.
# Então o odômetro ganhou uma janela independente: só tb_odometro_dia e
# tb_odometro_mensal a enxergam; DATA_CORTE segue mandando em todo o resto.
#
# Default = DATA_CORTE → sem a env, NADA muda no comportamento do projeto.
# Env ODO_DATA_INICIO = 'AAAA-MM-DD'.
#
# Limite REAL da origem (sondado em 2026-09-22 com 8 devices, mês a mês):
#   jan/25, fev/25, mar/25 → 0 leituras
#   15/abr/2025            → primeira leitura que existe (3 devices)
#   jun/25 em diante       → 5 devices, volume estável
# Ou seja, a Geotab retém ~17 meses. Pedir antes de 2025-04-15 devolve vazio.
_odo_ini = os.environ.get("ODO_DATA_INICIO", "").strip()
ODO_DATA_CORTE = datetime.strptime(_odo_ini, "%Y-%m-%d") if _odo_ini else DATA_CORTE


# ─────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
    handlers=[logging.StreamHandler()],
)
log = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────
# CONEXÃO SUPABASE
# ─────────────────────────────────────────────────────────
def criar_engine():
    cfg = SUPABASE
    url = URL.create(
        drivername="postgresql+psycopg2",
        username=cfg["usuario"],
        password=cfg["senha"],
        host=cfg["host"],
        port=cfg["porta"],
        database=cfg["banco"],
        query={"sslmode": cfg["sslmode"]},
    )
    # NullPool: o app NUNCA segura conexão ociosa — cada checkout abre uma conexão
    # nova e a fecha ao devolver. No pooler do Supabase em TRANSACTION mode (porta
    # 6543) isso é barato (o pooler multiplexa muitos clientes sobre poucas conexões
    # de servidor). Evita o "max clients reached in session mode" que estourava o
    # limite de 15 do session mode (porta 5432), onde cada conexão segura um slot.
    # Os syncs rodam sequencialmente (lock no app.py) — não há concorrência real.
    conectar = {"connect_timeout": 30}
    if cfg["schema"]:
        # -c search_path=<schema>: todo CREATE TABLE/VIEW e to_sql SEM qualificacao
        # cai neste schema. Mantem o script e o views.sql livres de prefixo.
        conectar["options"] = f"-c search_path={cfg['schema']}"
    return create_engine(
        url,
        poolclass=NullPool,
        connect_args=conectar,
    )


def _com_retry(fn, tentativas=4, espera_base=5):
    """Executa fn() com retry exponencial — absorve falhas transientes do pooler."""
    for n in range(1, tentativas + 1):
        try:
            return fn()
        except Exception as exc:
            if n == tentativas:
                raise
            espera = espera_base * (2 ** (n - 1))  # 5s, 10s, 20s
            log.warning(f"  ⚠ Tentativa {n}/{tentativas} falhou: {exc}. Aguardando {espera}s...")
            time.sleep(espera)


def criar_tabelas(engine):
    """Cria as 4 tabelas no Supabase se ainda não existirem.
    Usa TIMESTAMP (sem timezone): os valores são gravados em BRT como estão."""
    ddl = """
        CREATE TABLE IF NOT EXISTS tb_cadastro (
            id              TEXT PRIMARY KEY,
            serial          TEXT,
            placa           TEXT,
            veiculo         TEXT,
            marca           TEXT,
            modelo          TEXT,
            ano             TEXT,
            tipo_veiculo    TEXT,
            grupo           TEXT,
            todos_grupos    TEXT,
            ativo           BOOLEAN,
            atualizado_em   TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS tb_status (
            id               TEXT PRIMARY KEY,
            serial           TEXT,
            placa            TEXT,
            todos_grupos     TEXT,
            comunicando      BOOLEAN,
            ultimo_contato   TIMESTAMP,
            latitude         DOUBLE PRECISION,
            longitude        DOUBLE PRECISION,
            velocidade       DOUBLE PRECISION,
            ignicao_ligada   BOOLEAN,
            motorista_nome   TEXT,
            motorista_email  TEXT,
            motorista_tel    TEXT,
            motorista_matricula TEXT,
            viagem_inicio    TIMESTAMP,
            viagem_fim       TIMESTAMP,
            snapshot_em      TIMESTAMP
        );

        -- tb_comportamento (agregado 6m) FOI REMOVIDA (2026-06-16): vw_comportamento
        -- passou a ser diária (dos buckets) e o odômetro foi p/ tb_odometro_dia.

        -- Enxuta de propósito: placa/veiculo/grupo/todos_grupos NÃO ficam aqui —
        -- são derivados de tb_cadastro (por device_id) nas views. Repetir esse texto
        -- por viagem custava ~190 MB e estourava o free tier do Supabase (500 MB).
        CREATE TABLE IF NOT EXISTS tb_viagens (
            id                  TEXT PRIMARY KEY,   -- device_id + '|' + start
            device_id           TEXT,
            data_partida        TIMESTAMP,
            data_chegada        TIMESTAMP,
            duracao_segundos    INTEGER,
            tempo_ocioso_segundos    INTEGER,   -- idlingDuration: parado c/ motor ligado
            duracao_parada_segundos  INTEGER,   -- stopDuration: tempo parado no destino
            distancia_km        DOUBLE PRECISION,
            hodometro_inicial   DOUBLE PRECISION,
            hodometro_final     DOUBLE PRECISION,
            velocidade_media    DOUBLE PRECISION,
            velocidade_maxima   DOUBLE PRECISION,
            end_partida         TEXT,
            end_chegada         TEXT,
            lat_partida         DOUBLE PRECISION,
            lon_partida         DOUBLE PRECISION,
            lat_chegada         DOUBLE PRECISION,
            lon_chegada         DOUBLE PRECISION,
            motorista_id        TEXT,
            motorista_nome      TEXT,
            motorista_matricula TEXT,
            atualizado_em       TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS ix_viagens_device  ON tb_viagens (device_id);
        CREATE INDEX IF NOT EXISTS ix_viagens_partida ON tb_viagens (data_partida);

        -- Buckets diários de eventos de comportamento (1 linha por device/dia/tipo).
        -- Fonte da vw_comportamento (diária). Janela = ANO CORRENTE (DATA_CORTE),
        -- ALINHADA com tb_viagens; buckets < DATA_CORTE são apagados (_limpar_buckets_antigos).
        CREATE TABLE IF NOT EXISTS tb_comportamento_eventos (
            device_id   TEXT,
            dia         DATE,
            tipo        TEXT,
            qtd         INTEGER,
            ultimo_ts   TIMESTAMP,
            PRIMARY KEY (device_id, dia, tipo)
        );
        CREATE INDEX IF NOT EXISTS ix_comp_eventos_dia ON tb_comportamento_eventos (dia);

        -- Buckets diários de eventos POR MOTORISTA (1 linha por motorista/device/dia/tipo).
        -- Mesmos eventos de tb_comportamento_eventos, mas atribuídos ao motorista que
        -- conduzia (campo 'driver' do ExceptionEvent). device_id é a CHAVE de ligação
        -- com tb_comportamento_eventos: casa em (device_id, dia, tipo). Só eventos com
        -- motorista identificado entram aqui (NoDriver/UnknownDriver são descartados),
        -- então sum(qtd) por (device,dia,tipo) aqui ≤ a qtd do bucket por veículo.
        CREATE TABLE IF NOT EXISTS tb_comportamento_motorista (
            motorista_id  TEXT,
            device_id     TEXT,
            dia           DATE,
            tipo          TEXT,
            qtd           INTEGER,
            ultimo_ts     TIMESTAMP,
            PRIMARY KEY (motorista_id, device_id, dia, tipo)
        );
        CREATE INDEX IF NOT EXISTS ix_comp_mot_dia ON tb_comportamento_motorista (dia);
        CREATE INDEX IF NOT EXISTS ix_comp_mot_mot ON tb_comportamento_motorista (motorista_id);

        -- Cache de geocodificação (coord arredondada → endereço). As views de
        -- viagens trazem o endereço por JOIN, evitando guardar texto de endereço
        -- repetido em cada viagem (que reinflaria tb_viagens). Coords arredondadas
        -- a GEOCODE_CASAS decimais para deduplicar paradas próximas.
        CREATE TABLE IF NOT EXISTS tb_enderecos (
            lat       NUMERIC(8,4),
            lon       NUMERIC(9,4),
            endereco  TEXT,
            PRIMARY KEY (lat, lon)
        );

        -- Agregado MENSAL de viagens por veículo (km/tempo/dias/qtd). Permite
        -- indicadores cobrindo o ano inteiro filtráveis por mês no BI, sem guardar
        -- as viagens cruas do ano (que não cabem no free tier). ~1750 devices × 12
        -- meses ≈ 21k linhas/ano. placa/grupo vêm de tb_cadastro via JOIN nas views.
        CREATE TABLE IF NOT EXISTS tb_resumo_mensal (
            device_id         TEXT,
            ano               INTEGER,
            mes               INTEGER,
            km                DOUBLE PRECISION,
            duracao_segundos  BIGINT,
            dias_utilizados   INTEGER,
            viagens           INTEGER,
            atualizado_em     TIMESTAMP,
            PRIMARY KEY (device_id, ano, mes)
        );

        -- Odômetro POR DIA (último valor lido no dia, por veículo). Substitui o
        -- odômetro que ficava em tb_comportamento (agregado, removido). A
        -- vw_comportamento traz odometro/odometro_gps por JOIN no (device_id, dia).
        CREATE TABLE IF NOT EXISTS tb_odometro_dia (
            device_id     TEXT,
            dia           DATE,
            odometro      DOUBLE PRECISION,
            odometro_gps  DOUBLE PRECISION,
            atualizado_em TIMESTAMP,
            PRIMARY KEY (device_id, dia)
        );
        CREATE INDEX IF NOT EXISTS ix_odo_dia_dia ON tb_odometro_dia (dia);

        -- Odometro por VEICULO x MES (2026-09-22). DERIVADA de tb_odometro_dia
        -- + tb_cadastro: recalculada por inteiro (TRUNCATE+INSERT) no fim do modo
        -- `comportamento`, por `recarregar_odometro_mensal`. Cobre a frota TODA
        -- (sem filtro de cliente); p/ recortar por cliente no painel use
        -- `todos_grupos_expandido` (o token OPE_<cliente> nao esta na folha).
        CREATE TABLE IF NOT EXISTS tb_odometro_mensal (
            device_id        TEXT,
            ano              INTEGER,
            mes              INTEGER,
            ano_mes          TEXT,
            mes_ini          DATE,
            mes_fim          DATE,
            serial           TEXT,
            placa            TEXT,
            veiculo          TEXT,
            todos_grupos     TEXT,
            todos_grupos_expandido TEXT,
            grupo_id         INTEGER,
            odometro_inicio  DOUBLE PRECISION,
            odometro_fim     DOUBLE PRECISION,
            km_periodo       NUMERIC,
            dia_inicio       DATE,
            dia_fim          DATE,
            dias_com_leitura INTEGER,
            origem_inicio    TEXT,
            origem_dado      TEXT,
            atualizado_em    TIMESTAMP,
            PRIMARY KEY (device_id, ano, mes)
        );
        CREATE INDEX IF NOT EXISTS ix_odo_mensal_ano_mes ON tb_odometro_mensal (ano_mes);
        CREATE INDEX IF NOT EXISTS ix_odo_mensal_placa   ON tb_odometro_mensal (placa);
        CREATE INDEX IF NOT EXISTS ix_odo_mensal_device  ON tb_odometro_mensal (device_id);

        -- ABASTECIMENTOS (entidade FuelUpEvent da Geotab) — 2026-08-31.
        -- A Geotab DEDUZ cada abastecimento pela subida do nível do tanque + parada
        -- de viagem; NÃO é dado contábil (a entidade FuelTransaction, que traria R$,
        -- posto e nota, está VAZIA nesta base — sem integração de cartão).
        -- A API não devolve `id` p/ o evento → PK é (device_id, data_hora).
        -- Enxuta como tb_viagens: placa/grupo/motorista_nome vêm por JOIN nas views
        -- (tb_cadastro por device_id, tb_motoristas por motorista_id).
        CREATE TABLE IF NOT EXISTS tb_abastecimento (
            device_id        TEXT,
            data_hora        TIMESTAMP,
            litros           DOUBLE PRECISION,  -- volume (11% vêm 0: use litros_derivado)
            litros_derivado  DOUBLE PRECISION,  -- derivedVolume: recálculo da Geotab
            litros_motor     DOUBLE PRECISION,  -- totalFuelUsed pelo motor desde o anterior
            distancia_km     DOUBLE PRECISION,  -- distance rodada desde o abast. anterior
            odometro_km      DOUBLE PRECISION,  -- odometer no momento do abastecimento
            tanque_litros    DOUBLE PRECISION,  -- tankCapacity: ESTIMADO pela Geotab
            latitude         DOUBLE PRECISION,
            longitude        DOUBLE PRECISION,
            motorista_id     TEXT,              -- ~54% identificado
            tipo_combustivel TEXT,              -- productType (hoje 100% 'Unknown')
            confianca        TEXT,              -- confidence da detecção
            atualizado_em    TIMESTAMP,
            PRIMARY KEY (device_id, data_hora)
        );
        CREATE INDEX IF NOT EXISTS ix_abast_data ON tb_abastecimento (data_hora);

        -- Dimensão de MOTORISTAS (entidade User da Geotab). lotacao = grupo ULOT_
        -- (unidade de lotação) do motorista; todos_grupos = cadeia SUP_|REG_|ULOT_.
        -- Usada pela vw_motoristas (JOIN por id = motorista_id de tb_viagens).
        CREATE TABLE IF NOT EXISTS tb_motoristas (
            id             TEXT PRIMARY KEY,
            nome           TEXT,
            nome_completo  TEXT,
            matricula      TEXT,
            lotacao        TEXT,
            regional       TEXT,
            superintendencia TEXT,
            todos_grupos   TEXT,
            atualizado_em  TIMESTAMP
        );

        -- viagem_fim nasceu em script de migracao avulso e nunca entrou no
        -- criar_tabelas() -- instalacao nova ficava sem a coluna e o views.sql
        -- quebrava (vw_saneago_status a usa). Corrigido em 2026-09-22.
        ALTER TABLE tb_status ADD COLUMN IF NOT EXISTS viagem_fim TIMESTAMP;
    """
    # Migra colunas existentes de TIMESTAMPTZ → TIMESTAMP (converte UTC → BRT)
    migrar = """
        DO $$ BEGIN
            IF EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name = 'tb_status'
                AND column_name = 'snapshot_em'
                AND data_type = 'timestamp with time zone'
            ) THEN
                ALTER TABLE tb_cadastro
                    ALTER COLUMN atualizado_em TYPE TIMESTAMP
                    USING (atualizado_em AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo';

                ALTER TABLE tb_status
                    ALTER COLUMN ultimo_contato TYPE TIMESTAMP
                    USING (ultimo_contato AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN viagem_inicio TYPE TIMESTAMP
                    USING (viagem_inicio AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN snapshot_em TYPE TIMESTAMP
                    USING (snapshot_em AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo';

                ALTER TABLE tb_comportamento
                    ALTER COLUMN ultimo_excesso_vel TYPE TIMESTAMP
                    USING (ultimo_excesso_vel AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN ultima_acel_brusca TYPE TIMESTAMP
                    USING (ultima_acel_brusca AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN ultima_fren_brusca TYPE TIMESTAMP
                    USING (ultima_fren_brusca AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN ultima_curva_drastica TYPE TIMESTAMP
                    USING (ultima_curva_drastica AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN atualizado_em TYPE TIMESTAMP
                    USING (atualizado_em AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo';
            END IF;
        END $$;
    """
    migrar_colunas = """
        ALTER TABLE tb_status
            DROP COLUMN IF EXISTS odometro_inicio;
        ALTER TABLE tb_status
            ADD COLUMN IF NOT EXISTS motorista_matricula TEXT,
            ADD COLUMN IF NOT EXISTS todos_grupos        TEXT;
        -- Enxugamento (2026-06-15): colunas derivadas de tb_cadastro ou não usadas
        -- por nenhuma view saem de tb_viagens p/ caber no free tier. As views passam
        -- a trazer placa/veiculo/grupo/todos_grupos via JOIN com tb_cadastro. Rode
        -- VACUUM FULL tb_viagens depois p/ reaver o espaço em disco.
        ALTER TABLE tb_viagens
            DROP COLUMN IF EXISTS serial,
            DROP COLUMN IF EXISTS placa,
            DROP COLUMN IF EXISTS veiculo,
            DROP COLUMN IF EXISTS grupo,
            DROP COLUMN IF EXISTS todos_grupos,
            DROP COLUMN IF EXISTS regional,
            DROP COLUMN IF EXISTS superintendencia;
        -- Tempo parado c/ motor ligado (idlingDuration) e duração da parada
        -- (stopDuration) — 2026-06-18. Só preenchidas em viagens (re)sincronizadas.
        ALTER TABLE tb_viagens
            ADD COLUMN IF NOT EXISTS tempo_ocioso_segundos   INTEGER,
            ADD COLUMN IF NOT EXISTS duracao_parada_segundos INTEGER;
        -- tb_comportamento (agregado 6m) REMOVIDA (2026-06-16): vw_comportamento virou
        -- diária (buckets) e o odômetro foi p/ tb_odometro_dia. Drop idempotente.
        DROP TABLE IF EXISTS tb_comportamento;
        -- Nome próprio do motorista (User.firstName da Geotab) — 2026-06-19. O campo
        -- `nome` guarda o login/e-mail (User.name); este traz o nome de pessoa.
        ALTER TABLE tb_motoristas
            ADD COLUMN IF NOT EXISTS nome_completo TEXT;
        -- Grupos ANCESTRAIS (folha + todos os pais) p/ o filtro por HIERARQUIA do
        -- SEMAD — 2026-09-14. A frota do SEMAD passou a ficar em subgrupos por
        -- secretaria (SMS, SET, AMMA...) sob o grupo-pai do contrato
        -- (SEMAD - NNN/2026); o `todos_grupos` (só grupos DIRETOS/folha) não carrega
        -- mais o número do contrato. Coluna SEPARADA de propósito: NÃO toca
        -- `todos_grupos`/`grupo_id` (compartilhados com a SANEAGO). Só as views
        -- vw_semad_cadastro/vw_semad_grupos a consomem.
        ALTER TABLE tb_cadastro
            ADD COLUMN IF NOT EXISTS todos_grupos_expandido TEXT;
    """
    def _executar():
        with engine.begin() as conn:
            conn.execute(text(ddl))
            conn.execute(text(migrar))
            conn.execute(text(migrar_colunas))

    _com_retry(_executar)
    log.info("  ✓ Tabelas verificadas no Supabase.")


def gravar_tabela(df, nome_tabela, engine, chave_upsert="id"):
    """Upsert de um DataFrame na tabela. `chave_upsert` aceita uma coluna ("id") ou
    uma chave COMPOSTA separada por vírgula ("device_id, data_hora") — necessário
    para tb_abastecimento, cuja entidade da Geotab não devolve um `id` próprio."""
    if df.empty:
        log.warning(f"DataFrame vazio — {nome_tabela} não atualizada.")
        return

    cols_chave = [c.strip() for c in chave_upsert.split(",")]

    def _executar():
        with engine.begin() as conn:
            temp = f"tmp_{nome_tabela}"
            # chunksize: insere em blocos para não materializar o INSERT inteiro
            # em memória — essencial no free tier do Render (512 MB).
            df.to_sql(temp, conn, if_exists="replace", index=False, chunksize=1000)

            colunas    = df.columns.tolist()
            cols_str   = ", ".join(colunas)
            update_str = ", ".join([
                f"{c} = EXCLUDED.{c}"
                for c in colunas if c not in cols_chave
            ])

            conn.execute(text(f"""
                INSERT INTO {nome_tabela} ({cols_str})
                SELECT DISTINCT ON ({chave_upsert}) {cols_str}
                FROM {temp}
                ORDER BY {chave_upsert}
                ON CONFLICT ({chave_upsert})
                DO UPDATE SET {update_str};
            """))
            conn.execute(text(f"DROP TABLE IF EXISTS {temp}"))

    _com_retry(_executar)
    log.info(f"  ✓ {nome_tabela}: {len(df)} linhas gravadas.")


# ─────────────────────────────────────────────────────────
# HELPERS GEOTAB
# ─────────────────────────────────────────────────────────
FMT = "%Y-%m-%dT%H:%M:%S.000Z"


def sem_acento(texto: str) -> str:
    """Remove acentos para comparação de nomes de regras."""
    return unicodedata.normalize("NFD", texto).encode("ascii", "ignore").decode()


def _mapa_todos_grupos(credentials, veiculos):
    """{device_id: 'GrupoA | GrupoB | ...'} — nomes de TODOS os grupos do device.
    Mesma semântica da coluna todos_grupos de tb_cadastro/tb_viagens."""
    grupos = {g.get("id"): g.get("name", "") for g in geotab_get(credentials, "Group")}
    mapa = {}
    for v in veiculos:
        gnomes = [grupos.get(g.get("id"), g.get("id")) for g in v.get("groups", [])]
        mapa[v.get("id")] = " | ".join(gnomes)
    return mapa


def _indice_grupos(grupos_raw):
    """De uma lista de entidades Group da Geotab, retorna (id2name, parents):
    - id2name[gid] = nome do grupo
    - parents[gid] = set de ids-PAI (invertido do campo children[] de cada grupo)
    Um grupo pode ter mais de um pai (ex.: SET é filho de SEMAD-035 e SEMAD-031)."""
    id2name = {g.get("id"): g.get("name", "") for g in grupos_raw}
    parents = {}
    for g in grupos_raw:
        pid = g.get("id")
        for ch in (g.get("children") or []):
            cid = ch.get("id") if isinstance(ch, dict) else ch
            if cid:
                parents.setdefault(cid, set()).add(pid)
    return id2name, parents


def _grupos_com_ancestrais(gids, parents):
    """Conjunto de ids = os próprios `gids` + TODOS os ancestrais (subindo por
    parents[]). Usado p/ montar `todos_grupos_expandido`, que o filtro do SEMAD
    consulta — a frota do contrato fica em subgrupos por secretaria e só o
    grupo-pai (SEMAD - NNN/2026) identifica o contrato."""
    vistos, pilha = set(), list(gids)
    while pilha:
        gid = pilha.pop()
        if gid in vistos:
            continue
        vistos.add(gid)
        for pid in parents.get(gid, ()):
            if pid not in vistos:
                pilha.append(pid)
    return vistos


def parse_nome_veiculo(nome: str) -> dict:
    """
    O Geotab armazena o nome no formato 'PLACA | MARCA | MODELO | NUMERO'.
    Extrai marca e modelo quando disponíveis.
    """
    partes = [p.strip() for p in nome.split("|")]
    return {
        "marca":  partes[1] if len(partes) > 1 else "",
        "modelo": partes[2] if len(partes) > 2 else "",
    }


# ── Controle de quota da Geotab (limite oficial: 5000 sub-chamadas / 1 min) ──
# Estratégia em duas camadas:
#  1) THROTTLE PROATIVO: janela deslizante de 60s; antes de cada chamada esperamos
#     ter orçamento para as N sub-chamadas que ela consome (multicall conta N).
#     Mantém abaixo do teto sem gerar rejeições — crítico p/ frota de 1729 devices.
#  2) RETRY REATIVO: se ainda assim vier OverLimitException (quota compartilhada
#     com outros clientes), espera e repete — rede de segurança.
QUOTA_LIMITE  = int(os.environ.get("GEOTAB_QUOTA_LIMITE", 4500))   # margem sob 5000
QUOTA_RETRY   = int(os.environ.get("GEOTAB_QUOTA_RETRY", 6))       # tentativas reativas
QUOTA_PAUSA   = int(os.environ.get("GEOTAB_QUOTA_PAUSA", 12))      # s por tentativa reativa

_quota_lock = threading.Lock()
_quota_hist = collections.deque()  # timestamps (monotonic) de sub-chamadas recentes


def _consumir_quota(unidades):
    """Bloqueia até haver orçamento para 'unidades' sub-chamadas na janela de 60s,
    então registra o consumo. Pacing proativo para não estourar a quota."""
    unidades = max(int(unidades), 1)
    with _quota_lock:
        while True:
            agora = time.monotonic()
            while _quota_hist and agora - _quota_hist[0] >= 60:
                _quota_hist.popleft()
            if len(_quota_hist) + unidades <= QUOTA_LIMITE:
                _quota_hist.extend([agora] * unidades)
                return
            espera = 60 - (agora - _quota_hist[0]) + 0.1
            log.info(
                f"  ⏳ Throttle quota: aguardando {espera:.1f}s "
                f"({len(_quota_hist)}/{QUOTA_LIMITE} sub-chamadas na janela de 60s)"
            )
            time.sleep(min(espera, 5))


def _eh_erro_quota(resp):
    """True se a resposta JSON-RPC for um OverLimitException (quota excedida)."""
    err = resp.get("error") if isinstance(resp, dict) else None
    if not isinstance(err, dict):
        return False
    if (err.get("data") or {}).get("type") == "OverLimitException":
        return True
    if any(isinstance(e, dict) and e.get("name") == "OverLimitException"
           for e in (err.get("errors") or [])):
        return True
    return "quota" in str(err.get("message", "")).lower()


# Proxy de saída OPCIONAL para alternar o IP de origem das chamadas Geotab.
# A API fica atrás de Cloudflare e barra (403) IPs de datacenter flagados — caso
# do Render. Defina GEOTAB_PROXY (ex.: "http://user:senha@host:porta") para rotear
# por um IP confiável; deixe vazio para conexão DIRETA (uso local, IP limpo).
# Só afeta as chamadas Geotab (requests); a conexão Supabase usa psycopg2 e não
# passa por aqui. Assim o MESMO código roda local (direto) e no Render (via proxy)
# só trocando a variável de ambiente.
GEOTAB_PROXY = os.environ.get("GEOTAB_PROXY", "").strip()


def _host_proxy(url: str) -> str:
    """Host:porta do proxy SEM expor credenciais (descarta user:senha@)."""
    if not url:
        return ""
    return url.split("://", 1)[-1].split("@", 1)[-1]


def descrever_saida_geotab() -> str:
    """Texto curto de como as chamadas Geotab saem — para logs e /status."""
    return f"proxy:{_host_proxy(GEOTAB_PROXY)}" if GEOTAB_PROXY else "direto"


# Sessão HTTP reutilizada com cabeçalhos "de navegador". A API Geotab fica atrás
# de um WAF (Cloudflare): requisições com o User-Agent padrão 'python-requests/x'
# saindo de IPs de datacenter (ex.: Render) podem ser barradas com 403 + página
# HTML (corpo não-JSON). Um UA de navegador + Accept/Content-Type evita esse filtro.
_HTTP = requests.Session()
_HTTP.headers.update({
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json",
    "Content-Type": "application/json",
})
if GEOTAB_PROXY:
    _HTTP.proxies.update({"http": GEOTAB_PROXY, "https": GEOTAB_PROXY})
log.info(f"  • Saída das chamadas Geotab: {descrever_saida_geotab()}")

# Status HTTP tratados como falha TRANSITÓRIA (vale retry): bloqueios momentâneos
# de WAF (403), rate-limit do edge (429) e indisponibilidades de servidor (5xx).
RETRYABLE_HTTP = {403, 408, 429, 500, 502, 503, 504}


def _post_geotab(method, params, contexto=""):
    """POST único e blindado para a API Geotab.
    - Pacing proativo de quota + retry reativo em OverLimitException.
    - Retry em falhas TRANSITÓRIAS: erro de rede, corpo vazio/não-JSON e HTTP
      403/429/5xx (bloqueio de WAF / rate-limit / servidor indisponível). Erros
      definitivos (ex.: 401 credencial inválida) NÃO são repetidos.
    - Trata corpo vazio / não-JSON sem estourar JSONDecodeError.
    Retorna o dict da resposta JSON-RPC ({"result": ...} ou {"error": ...}),
    ou {"error": {...}} sintético em caso de falha de rede/parse."""
    unidades = len(params.get("calls", [])) if method == "ExecuteMultiCall" else 1

    ultima = None
    for tentativa in range(1, QUOTA_RETRY + 2):
        _consumir_quota(unidades)
        try:
            r = _HTTP.post(
                GEOTAB["servidor"],
                json={"method": method, "params": params},
                timeout=180,
            )
        except Exception as exc:
            # Erro de rede: sem httpStatus → tratado como transitório.
            ultima = {"error": {"message": str(exc)}}
        else:
            corpo = (r.text or "").strip()
            if not corpo:
                ultima = {"error": {"message": "corpo vazio", "httpStatus": r.status_code}}
            else:
                try:
                    resp = r.json()
                except ValueError:
                    ultima = {"error": {
                        "message": "resposta não-JSON",
                        "httpStatus": r.status_code,
                        "corpo": corpo[:120],
                    }}
                else:
                    # Resposta JSON válida: só a quota pede retry; o resto é definitivo.
                    if _eh_erro_quota(resp) and tentativa <= QUOTA_RETRY:
                        espera = QUOTA_PAUSA * tentativa  # 12, 24, 36...
                        log.warning(
                            f"  ⏳ Quota excedida em {method} {contexto} — aguardando {espera}s "
                            f"(retry {tentativa}/{QUOTA_RETRY})"
                        )
                        time.sleep(espera)
                        continue
                    return resp

        # Falha transitória (rede / corpo vazio / não-JSON). Repete se o status
        # for transitório (ou desconhecido, no caso de erro de rede).
        status = (ultima.get("error") or {}).get("httpStatus")
        transitorio = status is None or status in RETRYABLE_HTTP
        if transitorio and tentativa <= QUOTA_RETRY:
            espera = min(QUOTA_PAUSA * tentativa, 30)
            log.warning(
                f"  ⏳ {method} {contexto}: falha transitória "
                f"({ultima['error'].get('message')}, HTTP {status}) — "
                f"retry {tentativa}/{QUOTA_RETRY} em {espera}s"
            )
            time.sleep(espera)
            continue

        log.warning(f"  ⚠ {method} {contexto} falhou (definitivo): {ultima['error']}")
        return ultima

    return ultima


class GeotabAuthError(RuntimeError):
    """Falha de autenticação na API Geotab (bloqueio de WAF ou credencial inválida).
    Levantada em vez de sys.exit para que o erro suba como exceção normal — assim
    o worker do app.py registra ultimo_erro e o erro aparece em /status, em vez de
    a thread morrer silenciosamente com SystemExit."""


def autenticar():
    """Autentica e respeita o redirecionamento de federation da Geotab.
    Se a resposta trouxer 'path' diferente de 'ThisServer', aponta GEOTAB_SERVIDOR
    para o servidor direto do banco — evita respostas vazias nas chamadas seguintes."""
    resp = _post_geotab(
        "Authenticate",
        {
            "database": GEOTAB["database"],
            "userName": GEOTAB["userName"],
            "password": GEOTAB["password"],
        },
        contexto="(login)",
    )
    if "error" in resp:
        err    = resp["error"] if isinstance(resp["error"], dict) else {"message": resp["error"]}
        status = err.get("httpStatus")
        msg    = str(err.get("message", ""))

        # Diagnóstico direcionado: 403 + corpo não-JSON = bloqueio de WAF (não é
        # senha errada); 401/InvalidUser = credencial de fato inválida.
        if status == 403 or (status is None and "não-JSON" in msg):
            motivo = ("bloqueio de WAF (HTTP 403, corpo não-JSON) — IP de saída barrado "
                      "pelo edge (Cloudflare); NÃO é credencial inválida")
            log.error(
                "Falha na autenticação Geotab: BLOQUEIO DE WAF (HTTP 403, corpo não-JSON). "
                "NÃO é credencial inválida — o edge (Cloudflare) barrou a requisição. "
                "Provável bloqueio do IP de saída (datacenter/Render). "
                "Ações: liberar o IP no MyGeotab/suporte ou usar IP de saída fixo/confiável."
            )
        elif status == 401 or "InvalidUserException" in msg or "incorrect" in msg.lower():
            motivo = ("credencial inválida (HTTP 401) — verifique GEOTAB_DATABASE, "
                      "GEOTAB_USERNAME e GEOTAB_PASSWORD")
            log.error(
                "Falha na autenticação Geotab: CREDENCIAL INVÁLIDA (HTTP 401). "
                "Verifique GEOTAB_DATABASE, GEOTAB_USERNAME e GEOTAB_PASSWORD."
            )
        else:
            motivo = str(err)
            log.error(f"Falha na autenticação Geotab: {err}")
        # ANTES era sys.exit(1): SystemExit escapava do except do worker (app.py),
        # a thread morria sem registrar ultimo_erro e o /status ficava "limpo"
        # enquanto a tabela não atualizava. Levantar exceção normal corrige isso.
        raise GeotabAuthError(f"Autenticação Geotab falhou: {motivo}")

    resultado = resp["result"]
    path = resultado.get("path", "")
    if path and path != "ThisServer":
        novo = f"https://{path}/apiv1"
        if novo != GEOTAB["servidor"]:
            log.info(f"  ↪ Federation: redirecionando servidor para {novo}")
            GEOTAB["servidor"] = novo
    return resultado["credentials"]


def geotab_get(credentials, typeName, search=None, resultsLimit=None):
    params = {"credentials": credentials, "typeName": typeName}
    if search:       params["search"]       = search
    if resultsLimit: params["resultsLimit"] = resultsLimit
    resp = _post_geotab("Get", params, contexto=f"({typeName})")
    if "error" in resp:
        log.warning(f"  ⚠ Get {typeName} falhou: {resp['error']}")
        return []
    return resp.get("result", []) or []


def multicall(credentials, chamadas):
    if not chamadas:
        return []
    resp = _post_geotab(
        "ExecuteMultiCall",
        {"credentials": credentials, "calls": chamadas},
        contexto=f"({len(chamadas)} calls)",
    )
    if "error" in resp:
        log.warning(f"Erro no MultiCall: {resp['error']}")
        return []
    return resp.get("result", []) or []


# ─────────────────────────────────────────────────────────
# TABELA 1 — CADASTRO
# ─────────────────────────────────────────────────────────
def extrair_cadastro(credentials):
    log.info("Extraindo cadastro de veículos...")
    veiculos = geotab_get(credentials, "Device")
    # 0 devices = falha de API (WAF/quota) muito mais provável que frota vazia.
    # Sem esta guarda, o DataFrame sai vazio, gravar_tabela só loga "vazio" e
    # retorna, e o /run/cadastro "conclui" sem atualizar nada nem registrar erro.
    if not veiculos:
        raise RuntimeError(
            "Geotab retornou 0 devices — provável falha de API (WAF/quota), não "
            "frota vazia. Abortando o cadastro para o erro aparecer em /status."
        )
    grupos_raw       = geotab_get(credentials, "Group")
    grupos, parents  = _indice_grupos(grupos_raw)
    rows = []
    for v in veiculos:
        gids   = [g.get("id") for g in v.get("groups", [])]
        gnomes = [grupos.get(gid, gid) for gid in gids]
        # Expandido = folhas + TODOS os ancestrais (nomes, únicos, ordenados).
        # Só o filtro do SEMAD usa isto; NÃO altera `todos_grupos` (SANEAGO/grupo_id).
        exp_ids   = _grupos_com_ancestrais(gids, parents)
        exp_nomes = " | ".join(sorted({grupos.get(gid, gid) for gid in exp_ids}))
        # .strip(): a Geotab devolve name/licensePlate com espaco nas bordas em
        # parte da frota (207 placas em 2026-09-24). Isso NAO quebra JOIN -- eles sao
        # por device_id -- mas no Power BI "ABC1D23" e "ABC1D23 " viram valores
        # DISTINTOS: duplicam no filtro e quebram relacionamento por placa.
        nome   = (v.get("name") or "").strip()
        parsed = parse_nome_veiculo(nome)
        rows.append({
            "id":            v.get("id", ""),
            "serial":        v.get("serialNumber", ""),
            "placa":         (v.get("licensePlate") or "").strip(),
            "veiculo":       nome,
            # Geotab não preenche make/model/year — extraímos do nome
            "marca":         v.get("make", "") or parsed["marca"],
            "modelo":        v.get("model", "") or parsed["modelo"],
            "ano":           str(v.get("year", "")),
            "tipo_veiculo":  v.get("vehicleType", ""),
            # gnomes[-1] = grupo mais específico (gnomes[0] seria "Vehicle", raiz)
            "grupo":         gnomes[-1] if gnomes else "",
            "todos_grupos":  " | ".join(gnomes),
            "todos_grupos_expandido": exp_nomes,
            "ativo":         not v.get("isArchived", False),
            "atualizado_em": agora_brt(),
        })
    df = pd.DataFrame(rows)
    log.info(f"  → {len(df)} veículos")
    return df


def extrair_motoristas(credentials):
    """Dimensão de motoristas (entidade User). A lotação vem de companyGroups:
    cada motorista tem a cadeia SUP_<superintendência> | REG_<regional> |
    ULOT_<unidade de lotação>. lotacao = grupo ULOT_ (fallback: 1º grupo útil)."""
    log.info("Extraindo motoristas (cadastro/lotação)...")
    grupos = {g.get("id"): g.get("name", "") for g in geotab_get(credentials, "Group")}
    users  = geotab_get(credentials, "User")
    if not users:
        raise RuntimeError(
            "Geotab retornou 0 users — provável falha de API (WAF/quota). "
            "Abortando p/ não gravar motoristas vazio."
        )
    IGNORAR = ("Company Group", "Entire Organization", "Grupo da empresa")
    rows = []
    for u in users:
        cg     = u.get("companyGroups") or []
        gids   = [x.get("id") if isinstance(x, dict) else x for x in cg]
        gnomes = [grupos.get(gid, gid) for gid in gids if gid]
        def _por_prefixo(pref):
            return next((n for n in gnomes if n.startswith(pref)), "")
        lotacao = _por_prefixo("ULOT_")
        if not lotacao:
            uteis   = [n for n in gnomes if n and n not in IGNORAR]
            lotacao = uteis[0] if uteis else ""
        rows.append({
            "id":               u.get("id", ""),
            "nome":             u.get("name", ""),
            "nome_completo":    (u.get("firstName") or "").strip(),
            "matricula":        u.get("employeeNo", ""),
            "lotacao":          lotacao,
            "regional":         _por_prefixo("REG_"),
            "superintendencia": _por_prefixo("SUP_"),
            "todos_grupos":     " | ".join(gnomes),
            "atualizado_em":    agora_brt(),
        })
    df = pd.DataFrame(rows)
    log.info(f"  → {len(df)} motoristas")
    return df


# ─────────────────────────────────────────────────────────
# TABELA 2 — STATUS
# ─────────────────────────────────────────────────────────
def extrair_status(credentials):
    log.info("Extraindo status em tempo real...")

    veiculos   = geotab_get(credentials, "Device")
    lista_ids  = [v.get("id") for v in veiculos]
    serial_map = {v.get("id"): v.get("serialNumber", "") for v in veiculos}
    placa_map  = {v.get("id"): (v.get("licensePlate") or "").strip() for v in veiculos}
    grupos_map = _mapa_todos_grupos(credentials, veiculos)

    status_map = {}
    for s in geotab_get(credentials, "DeviceStatusInfo"):
        did = s.get("device", {}).get("id")
        if did:
            status_map[did] = s

    agora = agora_brt()
    ontem = agora - timedelta(hours=24)

    # Trips em LOTES de 150 devices: não seguramos os resultados de toda a frota
    # de uma vez (era o que fazia o status picar ~300 MB). Cada lote é processado
    # e descartado.
    motoristas_ativos = {}
    driver_ids = set()
    LOTE = 150
    for ini in range(0, len(lista_ids), LOTE):
        chunk = lista_ids[ini:ini + LOTE]
        res_viagens = multicall(credentials, [
            {
                "method": "Get",
                "params": {
                    "typeName": "Trip",
                    "search": {
                        "deviceSearch": {"id": did},
                        "fromDate": ontem.strftime(FMT),
                        "toDate":   agora.strftime(FMT),
                    },
                },
            }
            for did in chunk
        ])
        for j, resultado in enumerate(res_viagens):
            did     = chunk[j]
            viagens = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            viagem  = next((v for v in viagens if not v.get("stop")), None)
            if viagem and viagem.get("driver", {}).get("id"):
                motoristas_ativos[did] = {
                    "driver_id":     viagem["driver"]["id"],
                    "viagem_inicio": viagem.get("start"),
                }
                driver_ids.add(viagem["driver"]["id"])
        del res_viagens
        gc.collect()

    info_motoristas = {}
    if driver_ids:
        for res in multicall(credentials, [
            {"method": "Get", "params": {"typeName": "User", "search": {"id": did}}}
            for did in driver_ids
        ]):
            usuarios = res if isinstance(res, list) else res.get("result", [])
            if usuarios:
                u = usuarios[0]
                info_motoristas[u.get("id")] = {
                    "nome":     u.get("name", "Desconhecido"),
                    "email":    u.get("email", ""),
                    "telefone": u.get("phone", ""),
                    "matricula": u.get("employeeNo", ""),
                }

    rows = []
    for did in lista_ids:
        s      = status_map.get(did, {})
        viagem = motoristas_ativos.get(did)
        mot    = info_motoristas.get(viagem["driver_id"], {}) if viagem else {}
        rows.append({
            "id":              did,
            "serial":          serial_map.get(did, ""),
            "placa":           placa_map.get(did, ""),
            "todos_grupos":    grupos_map.get(did, ""),
            "comunicando":     s.get("isDeviceCommunicating", False),
            "ultimo_contato":  ts_brt(s.get("dateTime")),
            "latitude":        s.get("latitude")  or 0,
            "longitude":       s.get("longitude") or 0,
            "velocidade":      s.get("speed", 0),
            "ignicao_ligada":  s.get("isDriving", False),
            "motorista_nome":  mot.get("nome", "Nenhum"),
            "motorista_email": mot.get("email", ""),
            "motorista_tel":   mot.get("telefone", ""),
            "motorista_matricula": mot.get("matricula", ""),
            "viagem_inicio":   ts_brt(viagem.get("viagem_inicio") if viagem else None),
            "snapshot_em":     agora_brt(),
        })

    df = pd.DataFrame(rows)
    log.info(f"  → {len(df)} veículos no status")
    return df


# ─────────────────────────────────────────────────────────
# ODÔMETRO — GPS e físico (OBD2)
# ─────────────────────────────────────────────────────────
def _inferir_km(valor_raw: float, diag_id: str | None = None) -> float:
    """Converte o odômetro bruto em km usando o divisor DO DIAGNÓSTICO.

    CORRIGIDO 2026-09-22. A versão anterior decidia a unidade POR LEITURA
    (`raw > 1_000_000 → ÷1000, senão mantém`), assumindo que valores pequenos já
    viessem em km. Não vêm: o diagnóstico em uso nesta base
    (DiagnosticOdometerAdjustmentId) manda metros SEMPRE, então todo veículo com
    odômetro abaixo de 1.000 km (= 1.000.000 m) ficava gravado em metros como se
    fosse km — 1000× maior.

    Medido antes de corrigir (set/2026, odômetro vs km de tb_viagens):
      • 1.656 devices com razão ≈ 1     → raw > 1e6, eram divididos (certos)
      •    57 devices com razão ≈ 1000  → raw < 1e6, NÃO eram divididos (errados),
        todos com odômetro entre 154.000 e 995.700, ou seja, sob o limiar
      •    69 devices com uma queda de ~1000× na série, sempre com o valor
        anterior entre 908.000 e 1.000.000 — o dia em que cruzaram o limiar

    Essa era a causa raiz das 439 leituras "não monotônicas" de tb_odometro_dia
    e dos km_periodo negativos em tb_odometro_mensal.

    O divisor vem de DIVISOR_ODO_KM e NÃO é fixo em 1000 de propósito: o
    diagnóstico é escolhido em tempo de execução por _selecionar_diag_fisico, e
    o 1º candidato (DiagnosticOdometerInKilometersId) já entrega km. Hoje ele
    está vazio nesta base, mas se passar a responder, um ÷1000 fixo deixaria
    todo o hodômetro 1000× MENOR."""
    if not valor_raw:
        return 0.0
    div = DIVISOR_ODO_KM.get(diag_id, 1000)
    return round(float(valor_raw) / div, 2)


def _max_diag_em_lotes(credentials, lista_ids, diag_id, ini, fim, lote=ODO_LOTE):
    """Consulta StatusData em lotes e reduz a {device: max_raw} on-the-fly.
    Nunca acumula todas as leituras em memória — cada lote é processado e
    descartado, mantendo o pico baixo (essencial no free tier do Render)."""
    mapa = {}
    for i in range(0, len(lista_ids), lote):
        sub = lista_ids[i:i + lote]
        resultados = multicall(credentials, [
            {
                "method": "Get",
                "params": {
                    "typeName": "StatusData",
                    "search": {
                        "deviceSearch":     {"id": did},
                        "diagnosticSearch": {"id": diag_id},
                        "fromDate": ini.strftime(FMT),
                        "toDate":   fim.strftime(FMT),
                    },
                },
            }
            for did in sub
        ])
        for j, resultado in enumerate(resultados):
            did      = sub[j]
            leituras = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            mapa[did] = max((r.get("data") or 0 for r in leituras), default=0)
        del resultados
        gc.collect()
    return mapa


# ─────────────────────────────────────────────────────────
# ODÔMETRO POR DIA → tb_odometro_dia (consumido por vw_comportamento)
# ─────────────────────────────────────────────────────────
def _odo_por_dia_em_lotes(credentials, lista_ids, diag_id, ini, fim, lote=ODO_LOTE):
    """Consulta StatusData em lotes e reduz a {(device, 'YYYY-MM-DD'): max_raw} —
    o MAIOR valor lido em cada dia (odômetro é monotônico ⇒ é o último do dia).
    Dia em BRT (mesma convenção dos eventos). Processa e descarta lote a lote."""
    mapa = {}
    total_lotes = (len(lista_ids) + lote - 1) // lote
    for n, i in enumerate(range(0, len(lista_ids), lote), start=1):
        sub = lista_ids[i:i + lote]
        resultados = multicall(credentials, [
            {
                "method": "Get",
                "params": {
                    "typeName": "StatusData",
                    "search": {
                        "deviceSearch":     {"id": did},
                        "diagnosticSearch": {"id": diag_id},
                        "fromDate": ini.strftime(FMT),
                        "toDate":   fim.strftime(FMT),
                    },
                },
            }
            for did in sub
        ])
        for j, resultado in enumerate(resultados):
            did      = sub[j]
            leituras = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            for r in leituras:
                valor = r.get("data") or 0
                if not valor:
                    continue
                dia, _ = _dia_ts_brt(r.get("dateTime"))
                if dia is None:
                    continue
                k = (did, dia)
                if valor > mapa.get(k, 0):
                    mapa[k] = valor
        del resultados
        if n % 10 == 0 or n == total_lotes:
            log.info(f"    → odô/dia lote {n}/{total_lotes} ({len(mapa)} device×dia)")
        gc.collect()
    return mapa


def _selecionar_diag_fisico(credentials, lista_ids, fim):
    """Descobre qual diagnóstico de odômetro físico tem dado. Probe BARATO: só uma
    AMOSTRA de devices numa janela curta (basta achar 1 com leitura por diag).
    Evita pagar uma varredura cheia só para escolher o diagnóstico."""
    amostra = lista_ids[:200]
    ini = fim - timedelta(days=7)
    for diag in DIAG_ODO_FISICO:
        m = _max_diag_em_lotes(credentials, amostra, diag, ini, fim)
        if any(v for v in m.values()):
            log.info(f"  ✓ Odômetro físico (diário) via '{diag}'")
            return diag
    log.warning("  ⚠ Nenhum diagnóstico físico com dado p/ odômetro diário.")
    return None


def sincronizar_odometro_dia(credentials, engine, lista_ids, data_inicio, data_fim):
    """Preenche tb_odometro_dia com o último odômetro (físico e GPS) de cada
    device por dia, na janela [data_inicio, data_fim]. Upsert por (device, dia):
    re-execução de um dia atualiza o valor. Substitui o odômetro que vivia em
    tb_comportamento — agora consultável por dia e exposto na vw_comportamento."""
    if data_inicio < ODO_DATA_CORTE:   # piso PRÓPRIO do odômetro (não o global)
        data_inicio = ODO_DATA_CORTE
    log.info(f"Odômetro/dia: {data_inicio:%Y-%m-%d} → {data_fim:%Y-%m-%d}")

    gps_raw = _odo_por_dia_em_lotes(credentials, lista_ids, DIAG_GPS, data_inicio, data_fim)
    diag_fis = _selecionar_diag_fisico(credentials, lista_ids, data_fim)
    fis_raw  = (_odo_por_dia_em_lotes(credentials, lista_ids, diag_fis, data_inicio, data_fim)
                if diag_fis else {})

    # GPS sempre em metros (÷1000); físico com unidade inferida.
    linhas = {}
    for (did, dia), v in gps_raw.items():
        linhas.setdefault((did, dia), {"odometro": 0.0, "odometro_gps": 0.0})["odometro_gps"] = round(v / 1000, 2)
    for (did, dia), v in fis_raw.items():
        linhas.setdefault((did, dia), {"odometro": 0.0, "odometro_gps": 0.0})["odometro"] = _inferir_km(v, diag_fis)

    if not linhas:
        log.info("  • Odômetro/dia: nada a gravar.")
        return

    df = pd.DataFrame([
        {"device_id": did, "dia": dia, "odometro": v["odometro"],
         "odometro_gps": v["odometro_gps"], "atualizado_em": agora_brt()}
        for (did, dia), v in linhas.items()
    ])

    def _exec():
        with engine.begin() as conn:
            df.to_sql("tmp_odo_dia", conn, if_exists="replace", index=False, chunksize=5000)
            conn.execute(text("""
                INSERT INTO tb_odometro_dia (device_id, dia, odometro, odometro_gps, atualizado_em)
                SELECT device_id, dia::date, odometro, odometro_gps, atualizado_em FROM tmp_odo_dia
                ON CONFLICT (device_id, dia) DO UPDATE SET
                    odometro=EXCLUDED.odometro, odometro_gps=EXCLUDED.odometro_gps,
                    atualizado_em=EXCLUDED.atualizado_em
            """))
            conn.execute(text("DROP TABLE IF EXISTS tmp_odo_dia"))

    _com_retry(_exec)
    log.info(f"  ✓ tb_odometro_dia: {len(df)} linhas (device×dia) gravadas.")

    # Piso do ODÔMETRO (ODO_DATA_CORTE, não o global): remove o que ficou antes
    # da janela pedida — ex.: vazamento de fuso. Se a env ODO_DATA_INICIO não
    # estiver setada, ODO_DATA_CORTE == DATA_CORTE e a regra é a de sempre.
    def _poda_corte():
        with engine.begin() as conn:
            return conn.execute(
                text("DELETE FROM tb_odometro_dia WHERE dia < :corte"),
                {"corte": ODO_DATA_CORTE.date()},
            ).rowcount
    n = _com_retry(_poda_corte)
    if n:
        log.info(f"  ✓ odômetro/dia: {n} linhas < {ODO_DATA_CORTE:%Y-%m-%d} removidas (piso).")


SQL_ODOMETRO_MENSAL = """
INSERT INTO tb_odometro_mensal (
    device_id, ano, mes, ano_mes, mes_ini, mes_fim,
    serial, placa, veiculo, todos_grupos, todos_grupos_expandido, grupo_id,
    odometro_inicio, odometro_fim, km_periodo,
    dia_inicio, dia_fim, dias_com_leitura, origem_inicio, origem_dado, atualizado_em)
WITH meses AS (
    SELECT d::date AS mes_ini,
           (d + INTERVAL '1 month' - INTERVAL '1 day')::date AS mes_fim
      FROM generate_series(
             (SELECT date_trunc('month', min(dia)) FROM tb_odometro_dia),
             (SELECT date_trunc('month', max(dia)) FROM tb_odometro_dia),
             INTERVAL '1 month') d
), grade AS (
    -- btrim na placa: a Geotab devolve licensePlate com espaco nas bordas em parte
    -- da frota. O JOIN nao sofre (e por device_id), mas no Power BI "ABC1D23" e
    -- "ABC1D23 " sao valores DISTINTOS -- duplicam no filtro e quebram relacionamento.
    SELECT c.id, c.serial, btrim(c.placa) AS placa,
           concat_ws(' | ', btrim(c.placa), marca_padrao(c.marca, c.modelo),
                            modelo_padrao(c.marca, c.modelo)) AS veiculo,
           arrumar_grupos(c.todos_grupos)                     AS todos_grupos,
           c.todos_grupos_expandido,
           hashtext(arrumar_grupos(c.todos_grupos))           AS grupo_id,
           m.mes_ini, m.mes_fim
      FROM tb_cadastro c CROSS JOIN meses m
)
SELECT g.id,
       EXTRACT(year FROM g.mes_ini)::int, EXTRACT(month FROM g.mes_ini)::int,
       to_char(g.mes_ini, 'YYYY-MM'), g.mes_ini, g.mes_fim,
       g.serial, g.placa, g.veiculo, g.todos_grupos, g.todos_grupos_expandido, g.grupo_id,
       COALESCE(ant.odometro, prim.odometro),
       fim.odometro,
       round((fim.odometro - COALESCE(ant.odometro, prim.odometro))::numeric, 1),
       COALESCE(ant.dia, prim.dia), fim.dia, COALESCE(dias.qtd, 0),
       CASE WHEN fim.odometro IS NULL    THEN 'sem leitura'
            WHEN ant.odometro IS NOT NULL THEN 'fechamento do mes anterior'
            ELSE 'primeira leitura do veiculo' END,
       CASE WHEN fim.odometro IS NULL THEN 'sem leitura'
            -- suspeita se QUALQUER das duas pontas do mes veio da carga legada:
            -- um fechamento novo com abertura legada ainda produz km errado
            WHEN fim.atualizado_em  < TIMESTAMP '2026-09-22 13:59'
              OR ant.atualizado_em  < TIMESTAMP '2026-09-22 13:59'
              OR prim.atualizado_em < TIMESTAMP '2026-09-22 13:59' THEN 'legado (unidade suspeita)'
            ELSE 'carga corrigida' END,
       now()
  FROM grade g
  LEFT JOIN LATERAL (
       SELECT o.odometro, o.dia, o.atualizado_em FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia < g.mes_ini
          AND o.odometro > 0 AND o.odometro < 3000000
        ORDER BY o.dia DESC LIMIT 1) ant ON TRUE
  LEFT JOIN LATERAL (
       SELECT o.odometro, o.dia, o.atualizado_em FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia BETWEEN g.mes_ini AND g.mes_fim
          AND o.odometro > 0 AND o.odometro < 3000000
        ORDER BY o.dia ASC LIMIT 1) prim ON TRUE
  LEFT JOIN LATERAL (
       SELECT o.odometro, o.dia, o.atualizado_em FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia <= g.mes_fim
          AND o.odometro > 0 AND o.odometro < 3000000
        ORDER BY o.dia DESC LIMIT 1) fim ON TRUE
  LEFT JOIN LATERAL (
       SELECT count(*) AS qtd FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia BETWEEN g.mes_ini AND g.mes_fim
          AND o.odometro > 0 AND o.odometro < 3000000) dias ON TRUE
"""


def recarregar_odometro_mensal(engine):
    """Recalcula tb_odometro_mensal (hodometro por veiculo x mes) a partir de
    tb_odometro_dia + tb_cadastro. TRUNCATE + INSERT: sao ~18k linhas e ~3 s,
    nao compensa incremental — e assim um veiculo novo no cadastro ou uma
    leitura corrigida entram sem tratamento especial.

    Grade COMPLETA (cadastro CROSS JOIN meses): todo veiculo aparece em todo
    mes, mesmo parado. A abertura do mes e a ULTIMA leitura ANTERIOR a ele
    (carry-forward), nao a 1a do mes — so ha leitura em dia rodado, entao a 1a
    do mes perderia km e os meses nao emendariam.

    A guarda `odometro < 3000000` corta a sentinela 2^31/10 (overflow INT32)
    que o device b12B emite. Ver migracao_odometro_mensal_2026-09-22.sql."""
    def _exec():
        with engine.begin() as conn:
            conn.execute(text("TRUNCATE tb_odometro_mensal"))
            conn.execute(text(SQL_ODOMETRO_MENSAL))
            return conn.execute(text("SELECT count(*) FROM tb_odometro_mensal")).scalar()

    n = _com_retry(_exec)
    log.info(f"  ✓ tb_odometro_mensal: {n} linhas (veículo×mês) recalculadas.")


# ─────────────────────────────────────────────────────────
# TABELA 3 — COMPORTAMENTO
# ─────────────────────────────────────────────────────────
def _meses_atras(dt, n):
    """Subtrai n meses de calendário de dt, com guarda p/ dia inexistente
    (ex.: 31 de mês → mês com 30/28 dias). Mantém hora/min/seg."""
    mes = dt.month - n
    ano = dt.year
    while mes <= 0:
        mes += 12
        ano -= 1
    ultimo_dia = calendar.monthrange(ano, mes)[1]
    return dt.replace(year=ano, month=mes, day=min(dt.day, ultimo_dia))


# Os 4 tipos de evento, na ordem usada em todo o módulo (chave dos buckets).
TIPOS_EVENTO = ["excesso_velocidade", "aceleracao_brusca", "frenagem_brusca", "curva_drastica"]


def _dia_ts_brt(iso_utc):
    """A partir de um ISO UTC da Geotab ('2024-06-01T12:34:56.000Z') devolve
    ('YYYY-MM-DD' em BRT, datetime naive BRT). Brasil sem horário de verão desde
    2019 → offset fixo UTC-3. Retorna (None, None) se a string for inválida."""
    if not iso_utc or len(iso_utc) < 19:
        return None, None
    try:
        dt_utc = datetime.strptime(iso_utc[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None, None
    dt_brt = dt_utc - timedelta(hours=3)
    return dt_brt.strftime("%Y-%m-%d"), dt_brt


def _identificar_regras(credentials):
    """Devolve (ids_velocidade, regras_simples) resolvendo nomes/ids das regras
    Geotab para cada tipo de evento de comportamento."""
    todas_regras = geotab_get(
        credentials, "Rule",
        search={"fromDate": "2000-01-01T00:00:00.000Z"}
    )

    TERMOS_VELOCIDADE     = {"excesso velocidade"}
    IDS_VELOCIDADE_PADRAO = {"RuleSpeedingId", "RulePostedSpeedingId"}
    TIPOS_SIMPLES = {
        "aceleracao_brusca": (
            {"RuleHarshAccelerationId", "RuleJackrabbitStartsId"},
            ["aceleracao brusca", "jackrabbit", "harsh acceleration", "hard acceleration"],
        ),
        "frenagem_brusca": (
            {"RuleHarshBrakingId"},
            ["frenagem brusca", "harsh braking"],
        ),
        "curva_drastica": (
            {"RuleHarshCorneringId"},
            ["curva drastica", "harsh cornering"],
        ),
    }

    ids_velocidade = [
        r.get("id") for r in todas_regras
        if r.get("id") in IDS_VELOCIDADE_PADRAO
        or any(t in sem_acento(r.get("name", "").lower()) for t in TERMOS_VELOCIDADE)
    ]
    log.info(f"  • Regras de velocidade encontradas ({len(ids_velocidade)}): {ids_velocidade}")

    regras_simples = {}
    for tipo, (ids_padrao, termos) in TIPOS_SIMPLES.items():
        regras_simples[tipo] = next(
            (r.get("id") for r in todas_regras
             if r.get("id") in ids_padrao
             or any(t in sem_acento(r.get("name", "").lower()) for t in termos)),
            None,
        )
        log.info(f"  • Regra '{tipo}' → {regras_simples[tipo]}")

    return ids_velocidade, regras_simples


def _ler_ultimo_dia_buckets(engine):
    """Maior 'dia' já presente em tb_comportamento_eventos (date) ou None se vazia."""
    def _exec():
        with engine.connect() as conn:
            return conn.execute(
                text("SELECT MAX(dia) FROM tb_comportamento_eventos")
            ).scalar()
    return _com_retry(_exec)


def _upsert_buckets(engine, buckets):
    """Grava/atualiza os buckets {(did, dia, tipo): {qtd, ultimo_ts}}.
    Re-sincronizações de um dia já existente SOBRESCREVEM a contagem (o dia é
    recontado por inteiro), então o ON CONFLICT usa o valor novo."""
    if not buckets:
        log.info("  • Nenhum bucket novo de evento.")
        return
    df = pd.DataFrame([
        {"device_id": did, "dia": dia, "tipo": tipo,
         "qtd": v["qtd"], "ultimo_ts": v["ultimo_ts"]}
        for (did, dia, tipo), v in buckets.items()
    ])

    def _exec():
        with engine.begin() as conn:
            df.to_sql("tmp_comp_eventos", conn, if_exists="replace", index=False, chunksize=5000)
            conn.execute(text("""
                INSERT INTO tb_comportamento_eventos (device_id, dia, tipo, qtd, ultimo_ts)
                SELECT device_id, dia::date, tipo, qtd, ultimo_ts FROM tmp_comp_eventos
                ON CONFLICT (device_id, dia, tipo)
                DO UPDATE SET qtd = EXCLUDED.qtd, ultimo_ts = EXCLUDED.ultimo_ts
            """))
            conn.execute(text("DROP TABLE IF EXISTS tmp_comp_eventos"))

    _com_retry(_exec)
    log.info(f"  ✓ {len(df)} buckets (device/dia/tipo) gravados.")


def _limpar_buckets_antigos(engine, limite_dia):
    """Apaga buckets anteriores a limite_dia ('YYYY-MM-DD') = DATA_CORTE — mantém a
    janela do ano corrente e impede a tabela de crescer indefinidamente."""
    def _exec():
        with engine.begin() as conn:
            r = conn.execute(
                text("DELETE FROM tb_comportamento_eventos WHERE dia < CAST(:lim AS date)"),
                {"lim": limite_dia},
            )
            return r.rowcount
    apagados = _com_retry(_exec)
    log.info(f"  ✓ {apagados} buckets fora da janela (dia < {limite_dia}) removidos.")


def _upsert_buckets_motorista(engine, buckets_mot):
    """Grava/atualiza os buckets por motorista {(mid, did, dia, tipo): {qtd, ultimo_ts}}.
    Mesma lógica de _upsert_buckets: o dia é recontado por inteiro, então o
    ON CONFLICT sobrescreve a contagem."""
    if not buckets_mot:
        log.info("  • Nenhum bucket de evento por motorista.")
        return
    df = pd.DataFrame([
        {"motorista_id": mid, "device_id": did, "dia": dia, "tipo": tipo,
         "qtd": v["qtd"], "ultimo_ts": v["ultimo_ts"]}
        for (mid, did, dia, tipo), v in buckets_mot.items()
    ])

    def _exec():
        with engine.begin() as conn:
            df.to_sql("tmp_comp_mot", conn, if_exists="replace", index=False, chunksize=5000)
            conn.execute(text("""
                INSERT INTO tb_comportamento_motorista (motorista_id, device_id, dia, tipo, qtd, ultimo_ts)
                SELECT motorista_id, device_id, dia::date, tipo, qtd, ultimo_ts FROM tmp_comp_mot
                ON CONFLICT (motorista_id, device_id, dia, tipo)
                DO UPDATE SET qtd = EXCLUDED.qtd, ultimo_ts = EXCLUDED.ultimo_ts
            """))
            conn.execute(text("DROP TABLE IF EXISTS tmp_comp_mot"))

    _com_retry(_exec)
    log.info(f"  ✓ {len(df)} buckets (motorista/device/dia/tipo) gravados.")


def _limpar_buckets_motorista_antigos(engine, limite_dia):
    """Mantém a janela do ano corrente (DATA_CORTE) em tb_comportamento_motorista."""
    def _exec():
        with engine.begin() as conn:
            r = conn.execute(
                text("DELETE FROM tb_comportamento_motorista WHERE dia < CAST(:lim AS date)"),
                {"lim": limite_dia},
            )
            return r.rowcount
    apagados = _com_retry(_exec)
    log.info(f"  ✓ {apagados} buckets/motorista fora da janela (dia < {limite_dia}) removidos.")


def sincronizar_comportamento(credentials, engine):
    """Sincroniza o comportamento (ano corrente, desde DATA_CORTE) de forma incremental.

    Janela ALINHADA com tb_viagens (ambos cobrem o ano). 1ª execução
    (tb_comportamento_eventos vazia) = BACKFILL: conta o ano inteiro. Execuções
    seguintes = INCREMENTAL: recontam só do último dia já
    gravado (que pode ter ficado parcial) até agora. Os eventos viram buckets
    diários (device/dia/tipo) — consumidos pela vw_comportamento (diária). O
    odômetro do dia vai p/ tb_odometro_dia. Buckets fora da janela são apagados.
    serial/placa/grupos NÃO são gravados aqui — vêm de tb_cadastro na view."""
    log.info("Sincronizando comportamento (ano corrente, incremental por buckets diários)...")

    veiculos   = geotab_get(credentials, "Device")
    lista_ids  = [v.get("id") for v in veiculos]
    ids_set    = set(lista_ids)
    del veiculos

    ids_velocidade, regras_simples = _identificar_regras(credentials)

    data_fim       = agora_brt()
    # Janela = ANO CORRENTE (DATA_CORTE, somente 2026+), ALINHADA com tb_viagens
    # (que também acumula o ano todo). Antes eram 6 meses móveis, o que descasava do
    # km das viagens no score por motorista a partir de ~julho. Agora ambos cobrem
    # o ano. _limpar_buckets_antigos(janela_ini_str) remove o que ficou < DATA_CORTE.
    janela_ini     = DATA_CORTE
    janela_ini_str = janela_ini.strftime("%Y-%m-%d")

    # COMPORTAMENTO_BACKFILL=1 força a recontagem dos 6 meses (re-upsert idempotente
    # dos buckets por veículo + preenche tb_comportamento_motorista no histórico).
    forcar_backfill = os.environ.get("COMPORTAMENTO_BACKFILL", "0") not in ("0", "false", "False", "")
    ultimo_dia = _ler_ultimo_dia_buckets(engine)
    if ultimo_dia is None or forcar_backfill:
        backfill = True
        desde    = janela_ini
        motivo   = "carga única" if ultimo_dia is None else "forçado por COMPORTAMENTO_BACKFILL"
        log.info(f"  • BACKFILL ({motivo}): {janela_ini:%Y-%m-%d} → {data_fim:%Y-%m-%d}")
    else:
        backfill = False
        # Reconta desde 00:00 do último dia gravado (pode ter ficado parcial),
        # nunca antes do início da janela de 6 meses.
        desde = datetime.combine(ultimo_dia, datetime.min.time())
        if desde < janela_ini:
            desde = janela_ini
        log.info(f"  • INCREMENTAL: {desde:%Y-%m-%d} → {data_fim:%Y-%m-%d} (último dia gravado: {ultimo_dia})")

    # Dia-piso da contagem. A busca na Geotab usa horário BRT rotulado como UTC
    # (convenção do módulo), o que alcança ~3h a mais para trás e "vaza" eventos
    # para o dia anterior. Descartamos buckets antes do piso para não sobrescrever
    # com contagem parcial um dia anterior já completo (no backfill o que sobrar
    # antes da janela é removido por _limpar_buckets_antigos).
    floor_dia = desde.strftime("%Y-%m-%d")

    # ── Conta eventos em buckets diários {(did, 'YYYY-MM-DD', tipo): {qtd, ultimo_ts}} ──
    # buckets      = por VEÍCULO (device/dia/tipo) → tb_comportamento_eventos
    # buckets_mot  = por MOTORISTA (motorista/device/dia/tipo) → tb_comportamento_motorista
    #                (só eventos com driver identificado; base do score por motorista)
    buckets = {}
    buckets_mot = {}

    def processar(eventos, tipo):
        contados, ignorados = 0, 0
        for ev in eventos:
            did = (
                ev["device"].get("id")
                if isinstance(ev.get("device"), dict)
                else ev.get("device")
            )
            if not did or did not in ids_set:
                ignorados += 1
                continue
            dia, ts = _dia_ts_brt(ev.get("activeFrom") or ev.get("dateTime"))
            if dia is None:
                ignorados += 1
                continue
            if dia < floor_dia:
                continue  # vazamento de fuso p/ dia anterior já consolidado
            k = (did, dia, tipo)
            b = buckets.get(k)
            if b is None:
                buckets[k] = {"qtd": 1, "ultimo_ts": ts}
            else:
                b["qtd"] += 1
                if ts > b["ultimo_ts"]:
                    b["ultimo_ts"] = ts
            # Atribuição por motorista (campo driver do evento). Só quando há motorista
            # identificado — NoDriver/UnknownDriver ficam de fora do score.
            drv = ev.get("driver")
            drv_id = drv.get("id") if isinstance(drv, dict) else (drv if isinstance(drv, str) else None)
            if drv_id and drv_id not in ("NoDriver", "UnknownDriverId"):
                km = (drv_id, did, dia, tipo)
                bm = buckets_mot.get(km)
                if bm is None:
                    buckets_mot[km] = {"qtd": 1, "ultimo_ts": ts}
                else:
                    bm["qtd"] += 1
                    if ts > bm["ultimo_ts"]:
                        bm["ultimo_ts"] = ts
            contados += 1
        return contados, ignorados

    # Teto por chamada da Geotab. Quando atingido, a janela é fracionada — assim
    # NENHUM evento é perdido (contagem completa) e cada chamada continua leve.
    LIMIT      = 50000
    MIN_JANELA = timedelta(minutes=5)  # piso do fracionamento recursivo

    def contar_regra(rid, tipo, ini, fim):
        """Conta TODOS os eventos da regra em [ini, fim] para buckets diários.
        Se a janela satura (>= LIMIT), divide pela metade e recursa. Retorna
        (total, contados, ignorados)."""
        eventos = geotab_get(
            credentials, "ExceptionEvent",
            search={
                "ruleSearch": {"id": rid},
                "fromDate": ini.strftime(FMT),
                "toDate":   fim.strftime(FMT),
            },
            resultsLimit=LIMIT,
        )
        n = len(eventos)

        if n >= LIMIT and (fim - ini) > MIN_JANELA:
            del eventos
            gc.collect()
            meio = ini + (fim - ini) / 2
            t1, c1, i1 = contar_regra(rid, tipo, ini, meio)
            t2, c2, i2 = contar_regra(rid, tipo, meio, fim)
            return t1 + t2, c1 + c2, i1 + i2

        if n >= LIMIT:
            log.warning(
                f"  ⚠ Janela mínima {ini:%Y-%m-%d %H:%M}–{fim:%H:%M} ainda saturada "
                f"({n} eventos, regra {rid}) — caso extremo, reduza MIN_JANELA"
            )
        c, i = processar(eventos, tipo)
        del eventos
        return n, c, i

    # Velocidade (todas as regras) — fracionamento adaptativo sobre a janela.
    total_vel, contados_vel, ignorados_vel = 0, 0, 0
    for rid in ids_velocidade:
        t, c, i = contar_regra(rid, "excesso_velocidade", desde, data_fim)
        total_vel += t
        contados_vel += c
        ignorados_vel += i
        gc.collect()
    log.info(f"  • excesso_velocidade: {total_vel} eventos ({contados_vel} atribuídos, {ignorados_vel} sem match)")

    # Demais tipos
    for tipo, rid in regras_simples.items():
        if not rid:
            log.warning(f"  • Regra '{tipo}' não encontrada — pulando")
            continue
        t, c, i = contar_regra(rid, tipo, desde, data_fim)
        gc.collect()
        log.info(f"  • {tipo}: {t} eventos ({c} atribuídos, {i} sem match)")

    # ── Persiste buckets e mantém a janela móvel ──
    _upsert_buckets(engine, buckets)
    del buckets
    gc.collect()
    _limpar_buckets_antigos(engine, janela_ini_str)

    # ── Buckets por MOTORISTA (mesmos eventos, atribuídos ao driver) ──
    _upsert_buckets_motorista(engine, buckets_mot)
    del buckets_mot
    gc.collect()
    _limpar_buckets_motorista_antigos(engine, janela_ini_str)

    # ── Odômetro POR DIA → tb_odometro_dia (exposto na vw_comportamento por JOIN) ──
    # backfill = mesma janela de 6 meses dos buckets; incremental = só os dias novos
    # (desde o último dia gravado). Não há mais reconstrução de tb_comportamento.
    sincronizar_odometro_dia(credentials, engine, lista_ids, desde, data_fim)

    # ── Hodômetro por VEÍCULO × MÊS → tb_odometro_mensal (2026-09-22) ──
    # Derivada 100% do que acabou de ser gravado acima + tb_cadastro; nenhuma
    # chamada à Geotab. Recalculada por inteiro (~18k linhas, ~3 s).
    recarregar_odometro_mensal(engine)

    log.info(f"  → comportamento sincronizado ({'backfill' if backfill else 'incremental'}).")


# ─────────────────────────────────────────────────────────
# TABELA 4 — VIAGENS  (base do Relatório de Viagem estilo SANEAGO)
# ─────────────────────────────────────────────────────────
# Janela de extração. Padrão = ANO CORRENTE (de 1º/jan às 00:00 até agora).
# VIAGENS_DIAS > 0 sobrescreve com uma janela móvel de N dias (útil p/ smoke test:
# ex. VIAGENS_DIAS=2). VIAGENS_DIAS=0 (padrão) → ano corrente.
VIAGENS_DIAS = int(os.environ.get("VIAGENS_DIAS", 0))

# INCREMENTAL (só vale no modo ano-corrente, VIAGENS_DIAS=0): em vez de rebaixar a
# janela sempre p/ 1º/jan e re-buscar o ano inteiro todo dia (~70 lotes), começa
# da última viagem já gravada menos uma margem de segurança. A margem cobre viagens
# que ainda estavam em curso (sem data_chegada final) ou que foram revisadas na
# rodada anterior — elas são re-buscadas e re-upsertadas (sem duplicar, chave=id).
# Se tb_viagens estiver vazia, cai automaticamente p/ 1º/jan (primeira carga).
# VIAGENS_INCREMENTAL=0 força a recarga total do ano corrente.
VIAGENS_INCREMENTAL = os.environ.get("VIAGENS_INCREMENTAL", "1") not in ("0", "false", "False", "")
VIAGENS_MARGEM_DIAS = int(os.environ.get("VIAGENS_MARGEM_DIAS", 3))

# Reverse geocode (GetAddresses) dobra o volume de chamadas e é o trecho mais
# lento. Desligue na primeira carga com VIAGENS_GEOCODE=0 e ligue depois.
VIAGENS_GEOCODE = os.environ.get("VIAGENS_GEOCODE", "1") not in ("0", "false", "False", "")

# Dispositivos processados por lote no modo viagens. Cada lote é buscado,
# geocodificado, gravado (upsert) e descartado antes do próximo — mantém o pico
# de memória limitado a um lote (essencial no free tier do Render, 512 MB).
VIAGENS_DEVICE_LOTE = int(os.environ.get("VIAGENS_DEVICE_LOTE", 25))

# Lookback (dias) para semear o ponto/hodômetro de PARTIDA da 1ª viagem de cada
# device na janela. O Trip não traz coord de início — ela é o stopPoint da viagem
# anterior; para a 1ª viagem da janela, buscamos a última viagem nos N dias que a
# antecedem. 0 desliga o seed (a 1ª viagem fica sem endereço de partida).
VIAGENS_SEED_DIAS = int(os.environ.get("VIAGENS_SEED_DIAS", 30))


def _coord(ponto):
    """Extrai (lat, lon) de um StopPoint/Coordinate da Geotab (x=lon, y=lat)."""
    if not isinstance(ponto, dict):
        return None, None
    return ponto.get("y"), ponto.get("x")


def _duracao_para_segundos(valor):
    """Converte drivingDuration ('PT1H30M', 'HH:MM:SS', ticks .NET ou número) → segundos."""
    if valor in (None, ""):
        return 0
    try:
        td = pd.to_timedelta(valor)
        if not pd.isna(td):
            return int(td.total_seconds())
    except Exception:
        pass
    try:
        n = float(valor)
        return int(n / 1e7) if n > 1e7 else int(n)
    except Exception:
        return 0


def _buscar_pontos_anteriores(credentials, chunk_ids, data_inicio, lookback_dias):
    """Para cada device, busca a ÚLTIMA viagem nos 'lookback_dias' que antecedem
    data_inicio e devolve {did: {"coord": (lat, lon), "odo": km}}.

    Serve para semear o ponto/hodômetro de partida da 1ª viagem da janela — que,
    no modelo da Geotab, é a chegada (stopPoint) da viagem imediatamente anterior.
    Devices sem viagem no período ficam fora do mapa (partida indefinida, como antes)."""
    if lookback_dias <= 0:
        return {}
    desde = data_inicio - timedelta(days=lookback_dias)
    resultados = multicall(credentials, [
        {
            "method": "Get",
            "params": {
                "typeName": "Trip",
                "search": {
                    "deviceSearch": {"id": did},
                    "fromDate": desde.strftime(FMT),
                    "toDate":   data_inicio.strftime(FMT),
                },
            },
        }
        for did in chunk_ids
    ])
    seeds = {}
    for j, resultado in enumerate(resultados):
        did = chunk_ids[j]
        raw = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
        viagens = [v for v in raw if isinstance(v, dict) and v.get("start")]
        if not viagens:
            continue
        anterior = max(viagens, key=lambda v: v.get("start") or "")
        lat, lon = _coord(anterior.get("stopPoint"))
        if not (lat and lon):
            continue
        odo_m = anterior.get("odometer") or 0
        seeds[did] = {
            "coord": (lat, lon),
            "odo":   round(odo_m / 1000, 2) if odo_m else None,
        }
    del resultados
    return seeds


def reverse_geocode(credentials, coordenadas):
    """Converte uma lista de (lat, lon) em endereços via GetAddresses.
    Usa _post_geotab — corpo vazio/não-JSON nunca derruba o sync; apenas
    deixa o endereço em branco. Coordenadas (0,0)/None são puladas."""
    enderecos = [""] * len(coordenadas)
    pedidos, indices = [], []
    for i, (lat, lon) in enumerate(coordenadas):
        if lat in (None, 0) or lon in (None, 0):
            continue
        pedidos.append({"x": lon, "y": lat})
        indices.append(i)
    if not pedidos:
        return enderecos

    LOTE = 100
    total_lotes = (len(pedidos) + LOTE - 1) // LOTE
    for n, ini in enumerate(range(0, len(pedidos), LOTE), start=1):
        sub_pedidos = pedidos[ini:ini + LOTE]
        sub_indices = indices[ini:ini + LOTE]
        log.info(f"    → geocode lote {n}/{total_lotes} ({len(sub_pedidos)} coords)")
        resp = _post_geotab(
            "GetAddresses",
            {
                "credentials": credentials,
                "coordinates": sub_pedidos,
                "movingAddresses": True,
            },
            contexto=f"(geocode lote {ini})",
        )
        if "error" in resp:
            continue  # mantém endereços em branco neste lote, segue adiante
        for j, addr in enumerate(resp.get("result", []) or []):
            if j < len(sub_indices):
                enderecos[sub_indices[j]] = (addr or {}).get("formattedAddress", "")
    return enderecos


# Casas decimais p/ deduplicar coordenadas no cache de endereços. 3 ≈ 110 m
# (paradas próximas viram um ponto), o que torna o geocode viável: ~83k coords
# distintas em vez de ~1,4M trip-a-trip. Aumente p/ 4 (~11 m) se precisar de mais
# precisão (mais chamadas/tempo). O JOIN nas views usa a MESMA arredondamento.
GEOCODE_CASAS = int(os.environ.get("GEOCODE_CASAS", 3))


def geocodificar_enderecos(credentials, engine, casas=None, bloco=5000):
    """Backfill INCREMENTAL do cache tb_enderecos (coord arredondada → endereço).

    Geocodifica só as coordenadas distintas (partida+chegada de tb_viagens,
    arredondadas a `casas` decimais) que ainda NÃO estão em tb_enderecos. As views
    de viagens trazem o endereço por JOIN nessa tabela, então o texto não infla
    tb_viagens. Idempotente/resumível: cada execução cobre apenas o que falta;
    persiste em blocos para não perder progresso se cair no meio."""
    casas = GEOCODE_CASAS if casas is None else casas

    def _pendentes():
        with engine.connect() as conn:
            return conn.execute(text(f"""
                WITH coords AS (
                    SELECT round(lat_partida::numeric, {casas}) la,
                           round(lon_partida::numeric, {casas}) lo
                      FROM tb_viagens WHERE lat_partida <> 0 AND lon_partida <> 0
                    UNION
                    SELECT round(lat_chegada::numeric, {casas}),
                           round(lon_chegada::numeric, {casas})
                      FROM tb_viagens WHERE lat_chegada <> 0 AND lon_chegada <> 0
                )
                SELECT c.la, c.lo
                  FROM coords c
                  LEFT JOIN tb_enderecos e ON e.lat = c.la AND e.lon = c.lo
                 WHERE e.lat IS NULL
            """)).all()

    pendentes = _com_retry(_pendentes)
    if not pendentes:
        log.info("  • Geocode: tb_enderecos já em dia (nada pendente).")
        return
    log.info(f"  • Geocode: {len(pendentes):,} coordenadas distintas pendentes "
             f"(arredondadas a {casas} casas decimais).")

    total = 0
    for i in range(0, len(pendentes), bloco):
        sub    = pendentes[i:i + bloco]
        # API quer floats; o cache guarda os Decimals arredondados (casam no JOIN).
        coords = [(float(la), float(lo)) for la, lo in sub]
        addrs  = reverse_geocode(credentials, coords)
        df = pd.DataFrame([
            {"lat": la, "lon": lo, "endereco": a}
            for (la, lo), a in zip(sub, addrs)
        ])

        def _grava():
            with engine.begin() as conn:
                df.to_sql("tmp_enderecos", conn, if_exists="replace", index=False, chunksize=2000)
                # lat/lon chegam como TEXT na tmp (Decimal vira object/text no to_sql);
                # cast explícito p/ numeric — Postgres não faz text→numeric implícito.
                conn.execute(text("""
                    INSERT INTO tb_enderecos (lat, lon, endereco)
                    SELECT lat::numeric, lon::numeric, endereco FROM tmp_enderecos
                    ON CONFLICT (lat, lon) DO UPDATE SET endereco = EXCLUDED.endereco
                """))
                conn.execute(text("DROP TABLE IF EXISTS tmp_enderecos"))

        _com_retry(_grava)
        total += len(df)
        log.info(f"    → {total:,}/{len(pendentes):,} endereços no cache")
        gc.collect()

    log.info(f"  ✓ Geocode concluído: +{total:,} endereços em tb_enderecos.")


def _montar_viagem_row(v, did, info_motoristas, odo_anterior, coord_anterior):
    """Monta a row de UMA viagem e devolve
    (row, lat_p, lon_p, lat_c, lon_c, novo_odo_anterior, novo_coord_anterior).
    Mantém a continuidade do hodômetro via odo_anterior e do ponto de partida via
    coord_anterior — ambos encadeados por device.

    O objeto Trip da Geotab NÃO traz coordenada de início; só o stopPoint (chegada).
    O ponto de partida de uma viagem é, portanto, o stopPoint da viagem anterior do
    mesmo device (as viagens chegam ordenadas por start)."""
    start = v.get("start")
    stop  = v.get("stop")

    odo_final_m = v.get("odometer") or 0
    odo_final   = round(odo_final_m / 1000, 2) if odo_final_m else None
    dist        = round(float(v.get("distance") or 0), 2)

    if odo_anterior is not None:
        odo_inicial = odo_anterior
    elif odo_final is not None:
        odo_inicial = round(odo_final - dist, 2)
    else:
        odo_inicial = None
    if odo_final is not None:
        odo_anterior = odo_final

    drv    = v.get("driver")
    drv_id = drv.get("id") if isinstance(drv, dict) else (drv if isinstance(drv, str) else "")
    mot    = info_motoristas.get(drv_id, {})

    # Chegada = stopPoint desta viagem. Partida = chegada da viagem anterior
    # (Trip não traz coord de início). Na 1ª viagem do device, partida fica indefinida.
    lat_c, lon_c = _coord(v.get("stopPoint"))
    lat_p, lon_p = coord_anterior if coord_anterior else (None, None)

    # placa/veiculo/grupo/todos_grupos NÃO são gravados aqui — são derivados de
    # tb_cadastro (por device_id) nas views, evitando repetir ~190 MB de texto por
    # todas as viagens (o free tier do Supabase não comporta). Ver views *_viagens.
    row = {
        "id":                  f"{did}|{start}",
        "device_id":           did,
        "data_partida":        ts_brt(start),
        "data_chegada":        ts_brt(stop),
        "duracao_segundos":    _duracao_para_segundos(v.get("drivingDuration")),
        "tempo_ocioso_segundos":   _duracao_para_segundos(v.get("idlingDuration")),
        "duracao_parada_segundos": _duracao_para_segundos(v.get("stopDuration")),
        "distancia_km":        dist,
        "hodometro_inicial":   odo_inicial,
        "hodometro_final":     odo_final,
        "velocidade_media":    round(float(v.get("averageSpeed") or 0), 1),
        "velocidade_maxima":   round(float(v.get("maximumSpeed") or 0), 1),
        "end_partida":         "",
        "end_chegada":         "",
        "lat_partida":         lat_p or 0,
        "lon_partida":         lon_p or 0,
        "lat_chegada":         lat_c or 0,
        "lon_chegada":         lon_c or 0,
        "motorista_id":        drv_id,
        "motorista_nome":      mot.get("nome", "Nenhum"),
        "motorista_matricula": mot.get("matricula", ""),
        "atualizado_em":       agora_brt(),
    }
    novo_coord_anterior = (lat_c, lon_c) if (lat_c and lon_c) else coord_anterior
    return row, lat_p, lon_p, lat_c, lon_c, odo_anterior, novo_coord_anterior


def _ultima_partida_gravada(engine):
    """Retorna o maior data_partida já gravado em tb_viagens (ou None se vazia).
    Base do modo incremental — janela começa daqui menos a margem de segurança."""
    try:
        with engine.connect() as conn:
            return conn.execute(text("SELECT max(data_partida) FROM tb_viagens")).scalar()
    except Exception as e:
        log.warning(f"  • Não consegui ler a última viagem gravada ({e}); usando carga do ano.")
        return None


def sincronizar_viagens(credentials, engine):
    """Extrai e grava viagens (Trips) dos últimos VIAGENS_DIAS dias em LOTES de
    dispositivos. Cada lote é buscado, geocodificado, gravado (upsert por id) e
    descartado antes do próximo — o pico de memória fica limitado a um lote, não
    à frota inteira (essencial no free tier do Render, 512 MB).

    Roda APENAS no modo 'viagens' (não faz parte do 'all'). Geocode controlado
    por VIAGENS_GEOCODE. Retorna o total de viagens gravadas.

    A continuidade do hodômetro é preservada porque cada device é processado por
    inteiro dentro de um único lote (odo_anterior encadeia as viagens do device)."""
    periodo = f"{VIAGENS_DIAS} dias" if VIAGENS_DIAS > 0 else "ano corrente"
    log.info(
        f"Extraindo viagens ({periodo}, geocode={'on' if VIAGENS_GEOCODE else 'off'}, "
        f"lote={VIAGENS_DEVICE_LOTE} devices)..."
    )

    # Só precisamos dos IDs dos devices: placa/veículo/grupo/todos_grupos vêm de
    # tb_cadastro via JOIN nas views, não são mais gravados por viagem. (Antes este
    # bloco buscava Group e montava maps de texto p/ cada device — desnecessário.)
    veiculos  = geotab_get(credentials, "Device")
    lista_ids = [v.get("id") for v in veiculos]
    del veiculos

    data_fim = agora_brt()
    modo_janela = "ano corrente"
    if VIAGENS_DIAS > 0:
        data_inicio = data_fim - timedelta(days=VIAGENS_DIAS)
        modo_janela = f"janela móvel {VIAGENS_DIAS}d"
    else:
        # Ano corrente: de 1º de janeiro às 00:00 até agora.
        data_inicio = data_fim.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0)
        # INCREMENTAL: se já há viagens gravadas, sobe o início p/ a última partida
        # gravada menos a margem — assim só re-buscamos o trecho recente em vez do
        # ano inteiro. Vazio → mantém 1º/jan (primeira carga).
        if VIAGENS_INCREMENTAL:
            ultima = _ultima_partida_gravada(engine)
            if ultima is not None:
                desde = ultima - timedelta(days=VIAGENS_MARGEM_DIAS)
                if desde > data_inicio:
                    data_inicio = desde
                    modo_janela = (
                        f"incremental (última partida {ultima:%Y-%m-%d %H:%M} "
                        f"− {VIAGENS_MARGEM_DIAS}d de margem)"
                    )
    # Piso global: nunca antes de 2026 (a poda DELETE data_partida < data_inicio
    # então remove o que ficou de 2025).
    if data_inicio < DATA_CORTE:
        data_inicio = DATA_CORTE
    log.info(f"  • Janela: {data_inicio:%Y-%m-%d %H:%M} → {data_fim:%Y-%m-%d %H:%M}  [{modo_janela}]")

    total_lotes    = (len(lista_ids) + VIAGENS_DEVICE_LOTE - 1) // VIAGENS_DEVICE_LOTE
    total_gravadas = 0

    for n, ini in enumerate(range(0, len(lista_ids), VIAGENS_DEVICE_LOTE), start=1):
        chunk_ids = lista_ids[ini:ini + VIAGENS_DEVICE_LOTE]
        log.info(f"  • Lote {n}/{total_lotes} — {len(chunk_ids)} dispositivos")

        resultados = multicall(credentials, [
            {
                "method": "Get",
                "params": {
                    "typeName": "Trip",
                    "search": {
                        "deviceSearch": {"id": did},
                        "fromDate": data_inicio.strftime(FMT),
                        "toDate":   data_fim.strftime(FMT),
                    },
                },
            }
            for did in chunk_ids
        ])

        driver_ids = set()
        viagens_por_device = {}
        for j, resultado in enumerate(resultados):
            did = chunk_ids[j]
            raw = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            viagens = [v for v in raw if isinstance(v, dict)]
            viagens.sort(key=lambda v: v.get("start") or "")
            viagens_por_device[did] = viagens
            for v in viagens:
                drv = v.get("driver")
                if isinstance(drv, dict) and drv.get("id"):
                    driver_ids.add(drv["id"])
                elif isinstance(drv, str) and drv not in ("NoDriver", "UnknownDriverId"):
                    driver_ids.add(drv)
        del resultados

        info_motoristas = {}
        if driver_ids:
            for res in multicall(credentials, [
                {"method": "Get", "params": {"typeName": "User", "search": {"id": did}}}
                for did in driver_ids
            ]):
                usuarios = res if isinstance(res, list) else (res or {}).get("result", [])
                if usuarios:
                    u = usuarios[0]
                    info_motoristas[u.get("id")] = {
                        "nome":      u.get("name", "Desconhecido"),
                        "matricula": u.get("employeeNo", ""),
                    }

        # Semeia partida/hodômetro da 1ª viagem de cada device com a viagem
        # imediatamente anterior à janela (stopPoint = ponto de partida).
        seeds = _buscar_pontos_anteriores(
            credentials, chunk_ids, data_inicio, VIAGENS_SEED_DIAS
        )

        # Coords (lat/lon) já vão dentro de cada row → tb_viagens. O endereço NÃO
        # é geocodificado por viagem aqui (era o gargalo, dias de execução); é
        # resolvido depois, deduplicado, em tb_enderecos (ver geocodificar_enderecos).
        rows = []
        for did in chunk_ids:
            seed = seeds.get(did, {})
            odo_anterior = seed.get("odo")
            coord_anterior = seed.get("coord")
            for v in viagens_por_device.get(did, []):
                if not v.get("start"):
                    continue
                row, lat_p, lon_p, lat_c, lon_c, odo_anterior, coord_anterior = _montar_viagem_row(
                    v, did, info_motoristas, odo_anterior, coord_anterior
                )
                rows.append(row)
        del viagens_por_device, info_motoristas, seeds

        if rows:
            gravar_tabela(pd.DataFrame(rows), "tb_viagens", engine, chave_upsert="id")
            total_gravadas += len(rows)
        del rows
        gc.collect()

    # Janela móvel: o upsert por id NUNCA apaga, então sem esta poda a tabela
    # cresceria a cada execução (a janela desliza, adiciona um dia novo e mantém
    # os antigos) e reencheria o free tier do Supabase. Só poda quando há janela
    # (VIAGENS_DIAS > 0); no modo ano-corrente (=0) mantém tudo da janela.
    if VIAGENS_DIAS > 0:
        def _podar():
            with engine.begin() as conn:
                r = conn.execute(
                    text("DELETE FROM tb_viagens WHERE data_partida < :ini"),
                    {"ini": data_inicio},
                )
                return r.rowcount
        apagadas = _com_retry(_podar)
        log.info(f"  ✓ {apagadas} viagens fora da janela (< {data_inicio:%Y-%m-%d}) removidas.")

    # Geocode incremental e deduplicado: preenche tb_enderecos com as coordenadas
    # ainda não conhecidas. O relatório traz o endereço por JOIN, sem inflar
    # tb_viagens. Controlado por VIAGENS_GEOCODE (off = pula).
    if VIAGENS_GEOCODE:
        geocodificar_enderecos(credentials, engine)

    # Atualiza o MÊS CORRENTE do agregado mensal a partir de tb_viagens (sem nova
    # chamada Geotab). Meses passados ficam congelados (preenchidos uma vez por
    # backfill_resumo_mensal). É o que mantém vw_indicadores_mensal vivo no dia a dia.
    atualizar_resumo_mes_corrente(engine)

    log.info(f"  → {total_gravadas} viagens gravadas em tb_viagens")
    return total_gravadas


# ─────────────────────────────────────────────────────────
# TABELA — ABASTECIMENTO (FuelUpEvent)
# ─────────────────────────────────────────────────────────
# Margem de segurança do modo incremental: a Geotab REVISA eventos recentes (a
# detecção depende de leituras de nível que chegam com atraso), então re-buscamos
# alguns dias já gravados. O upsert por (device_id, data_hora) não duplica.
ABASTECIMENTO_MARGEM_DIAS = int(os.environ.get("ABASTECIMENTO_MARGEM_DIAS", 3))

# Tamanho do bloco de dias por chamada. O Get de FuelUpEvent é por JANELA (uma
# chamada cobre a frota toda, ao contrário das viagens, que são por device), mas a
# primeira carga cobre o ano inteiro (~53 mil eventos em 2026) — fatiar em blocos
# mensais evita qualquer teto de resultados do servidor e limita o pico de memória.
ABASTECIMENTO_LOTE_DIAS = int(os.environ.get("ABASTECIMENTO_LOTE_DIAS", 31))


def _ultimo_abastecimento_gravado(engine):
    """Maior data_hora já gravada em tb_abastecimento (ou None se vazia).
    Base do modo incremental — a janela começa aqui menos a margem."""
    try:
        with engine.connect() as conn:
            return conn.execute(text("SELECT max(data_hora) FROM tb_abastecimento")).scalar()
    except Exception as e:
        log.warning(f"  • Não consegui ler o último abastecimento gravado ({e}); "
                    f"usando carga do ano.")
        return None


def _montar_abastecimento_row(ev):
    """Converte um FuelUpEvent da API na linha de tb_abastecimento.
    Retorna None se o evento não tem device/data (sem chave, não há o que gravar).

    UNIDADES (verificadas contra tb_odometro_dia em 2026-08-31): `odometer` e
    `distance` vêm em METROS — o odômetro da API bate com o do projeto na razão
    ~1000. Convertidos p/ km aqui, para a tabela ficar na mesma unidade das viagens."""
    did = (ev.get("device") or {}).get("id")
    ts  = ts_brt(ev.get("dateTime"))
    if not did or pd.isna(ts):
        return None

    # driver vem como dict {'id': ...} quando identificado e como a STRING
    # 'UnknownDriverId' quando não — mesmo padrão dos eventos de comportamento.
    drv = ev.get("driver")
    drv_id = drv.get("id") if isinstance(drv, dict) else None

    loc = ev.get("location") or {}
    return {
        "device_id":        did,
        "data_hora":        ts,
        "litros":           ev.get("volume"),
        "litros_derivado":  ev.get("derivedVolume"),
        "litros_motor":     ev.get("totalFuelUsed"),
        "distancia_km":     (ev.get("distance") or 0) / 1000.0,
        "odometro_km":      (ev.get("odometer") or 0) / 1000.0,
        "tanque_litros":    (ev.get("tankCapacity") or {}).get("volume"),
        # y = latitude, x = longitude (padrão da Geotab, igual ao reverse_geocode)
        "latitude":         loc.get("y"),
        "longitude":        loc.get("x"),
        "motorista_id":     drv_id,
        "tipo_combustivel": ev.get("productType"),
        "confianca":        ev.get("confidence"),
        "atualizado_em":    agora_brt(),
    }


def sincronizar_abastecimento(credentials, engine):
    """Extrai os abastecimentos (FuelUpEvent) e grava em tb_abastecimento.

    A Geotab deduz cada abastecimento pela subida do nível do tanque combinada com
    a parada da viagem — é telemetria, NÃO extrato de cartão (FuelTransaction está
    vazia nesta base, então não há valor em R$, posto nem nota fiscal).

    Janela = ano corrente (piso DATA_CORTE), INCREMENTAL a partir do último evento
    gravado menos ABASTECIMENTO_MARGEM_DIAS. Barato: o Get é por janela (uma chamada
    cobre a frota inteira), fatiado em blocos de ABASTECIMENTO_LOTE_DIAS dias.
    Retorna o total de eventos gravados."""
    data_fim    = agora_brt()
    data_inicio = data_fim.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0)
    modo_janela = "ano corrente"

    ultimo = _ultimo_abastecimento_gravado(engine)
    if ultimo is not None:
        desde = ultimo - timedelta(days=ABASTECIMENTO_MARGEM_DIAS)
        if desde > data_inicio:
            data_inicio = desde
            modo_janela = (f"incremental (último {ultimo:%Y-%m-%d %H:%M} "
                           f"− {ABASTECIMENTO_MARGEM_DIAS}d de margem)")

    # Piso global: nunca antes de ANO_CORTE (mesma regra das outras tabelas).
    if data_inicio < DATA_CORTE:
        data_inicio = DATA_CORTE

    log.info(f"Extraindo abastecimentos ({modo_janela}: "
             f"{data_inicio:%Y-%m-%d} → {data_fim:%Y-%m-%d})...")

    total = 0
    bloco_ini = data_inicio
    while bloco_ini < data_fim:
        bloco_fim = min(bloco_ini + timedelta(days=ABASTECIMENTO_LOTE_DIAS), data_fim)
        eventos = geotab_get(credentials, "FuelUpEvent", search={
            "fromDate": bloco_ini.strftime(FMT),
            "toDate":   bloco_fim.strftime(FMT),
        })
        linhas = [r for r in (_montar_abastecimento_row(e) for e in eventos) if r]
        log.info(f"  • {bloco_ini:%Y-%m-%d} → {bloco_fim:%Y-%m-%d}: "
                 f"{len(eventos)} eventos, {len(linhas)} válidos")
        if linhas:
            df = pd.DataFrame(linhas)
            # Um device pode ter 2 eventos no MESMO segundo entre blocos vizinhos
            # (a janela se sobrepõe em 1 instante); o DISTINCT ON do upsert resolve.
            gravar_tabela(df, "tb_abastecimento", engine,
                          chave_upsert="device_id, data_hora")
            total += len(df)
            del df, linhas, eventos
            gc.collect()
        bloco_ini = bloco_fim

    # Piso temporal: o upsert nunca apaga, então eventos de anos anteriores que
    # tenham entrado numa carga antiga sairiam só aqui (mesma regra dos buckets).
    def _podar():
        with engine.begin() as conn:
            r = conn.execute(
                text("DELETE FROM tb_abastecimento WHERE data_hora < CAST(:corte AS timestamp)"),
                {"corte": DATA_CORTE},
            )
            return r.rowcount
    apagados = _com_retry(_podar)
    if apagados:
        log.info(f"  ✓ {apagados} abastecimentos anteriores a "
                 f"{DATA_CORTE:%Y-%m-%d} removidos.")

    log.info(f"  → {total} abastecimentos gravados em tb_abastecimento")
    return total


def _upsert_resumo_mensal(engine, agg):
    """Grava/atualiza tb_resumo_mensal a partir de agg
    {(device_id, ano, mes): {'km', 'dur', 'dias'(set), 'viagens'}}."""
    if not agg:
        log.info("  • Resumo mensal: nada a agregar.")
        return
    df = pd.DataFrame([
        {"device_id": did, "ano": ano, "mes": mes,
         "km": round(b["km"], 2), "duracao_segundos": int(b["dur"]),
         "dias_utilizados": len(b["dias"]), "viagens": b["viagens"],
         "atualizado_em": agora_brt()}
        for (did, ano, mes), b in agg.items()
    ])

    def _exec():
        with engine.begin() as conn:
            df.to_sql("tmp_resumo_mensal", conn, if_exists="replace", index=False, chunksize=5000)
            conn.execute(text("""
                INSERT INTO tb_resumo_mensal
                    (device_id, ano, mes, km, duracao_segundos, dias_utilizados, viagens, atualizado_em)
                SELECT device_id, ano, mes, km, duracao_segundos, dias_utilizados, viagens, atualizado_em
                FROM tmp_resumo_mensal
                ON CONFLICT (device_id, ano, mes) DO UPDATE SET
                    km=EXCLUDED.km, duracao_segundos=EXCLUDED.duracao_segundos,
                    dias_utilizados=EXCLUDED.dias_utilizados, viagens=EXCLUDED.viagens,
                    atualizado_em=EXCLUDED.atualizado_em
            """))
            conn.execute(text("DROP TABLE IF EXISTS tmp_resumo_mensal"))

    _com_retry(_exec)
    log.info(f"  ✓ resumo mensal: {len(df)} linhas (device×mês) gravadas.")


def backfill_resumo_mensal(credentials, engine, data_inicio, data_fim):
    """Agrega as Trips de [data_inicio, data_fim] por (device, ano, mês) e faz
    upsert em tb_resumo_mensal — SEM guardar viagens cruas. Usado p/ o backfill do
    ano (uma vez). Pesado na Geotab (busca Trips de todos os devices na janela),
    então rode isolado de outros jobs p/ não dividir a quota."""
    log.info(f"Backfill resumo mensal: {data_inicio:%Y-%m-%d} → {data_fim:%Y-%m-%d}")
    veiculos  = geotab_get(credentials, "Device")
    lista_ids = [v.get("id") for v in veiculos]
    del veiculos

    agg = {}
    LOTE = VIAGENS_DEVICE_LOTE
    total_lotes = (len(lista_ids) + LOTE - 1) // LOTE
    for n, ini in enumerate(range(0, len(lista_ids), LOTE), start=1):
        chunk = lista_ids[ini:ini + LOTE]
        resultados = multicall(credentials, [
            {"method": "Get", "params": {"typeName": "Trip", "search": {
                "deviceSearch": {"id": did},
                "fromDate": data_inicio.strftime(FMT),
                "toDate":   data_fim.strftime(FMT)}}}
            for did in chunk
        ])
        for j, resultado in enumerate(resultados):
            did = chunk[j]
            raw = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            for v in raw:
                if not isinstance(v, dict) or not v.get("start"):
                    continue
                ts = ts_brt(v.get("start"))
                if pd.isna(ts) or ts.year < ANO_CORTE:   # piso: somente 2026+
                    continue
                k = (did, ts.year, ts.month)
                b = agg.get(k)
                if b is None:
                    b = agg[k] = {"km": 0.0, "dur": 0, "dias": set(), "viagens": 0}
                b["km"]      += float(v.get("distance") or 0)
                b["dur"]     += _duracao_para_segundos(v.get("drivingDuration"))
                b["dias"].add(ts.date())
                b["viagens"] += 1
        del resultados
        if n % 10 == 0 or n == total_lotes:
            log.info(f"  • backfill mensal: lote {n}/{total_lotes} ({len(agg)} device×mês até agora)")
        gc.collect()

    _upsert_resumo_mensal(engine, agg)
    log.info(f"  → backfill resumo mensal concluído ({len(agg)} device×mês).")


def atualizar_resumo_mes_corrente(engine):
    """Recalcula SÓ o mês corrente de tb_resumo_mensal a partir de tb_viagens (já
    no banco — sem nova chamada Geotab). Mantém o mês vigente fresco a cada sync;
    meses anteriores ficam congelados (vieram do backfill)."""
    def _exec():
        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO tb_resumo_mensal
                    (device_id, ano, mes, km, duracao_segundos, dias_utilizados, viagens, atualizado_em)
                SELECT device_id,
                       EXTRACT(year  FROM data_partida)::int,
                       EXTRACT(month FROM data_partida)::int,
                       round(sum(distancia_km)::numeric, 2)::float8,
                       sum(duracao_segundos)::bigint,
                       count(DISTINCT data_partida::date),
                       count(*),
                       :agora
                  FROM tb_viagens
                 WHERE data_partida >= date_trunc('month', CURRENT_DATE)
                   AND data_partida <  date_trunc('month', CURRENT_DATE) + interval '1 month'
                 GROUP BY device_id,
                       EXTRACT(year FROM data_partida),
                       EXTRACT(month FROM data_partida)
                ON CONFLICT (device_id, ano, mes) DO UPDATE SET
                    km=EXCLUDED.km, duracao_segundos=EXCLUDED.duracao_segundos,
                    dias_utilizados=EXCLUDED.dias_utilizados, viagens=EXCLUDED.viagens,
                    atualizado_em=EXCLUDED.atualizado_em
            """), {"agora": agora_brt()})
    _com_retry(_exec)
    log.info("  ✓ resumo mensal: mês corrente atualizado de tb_viagens.")


# ─────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────
def resolver_placas_duplicadas(engine, tabela):
    """Grava o sufixo " -OFF" nas placas duplicadas de `tabela` (2026-09-24).

    A mesma placa aparece em mais de um device_id quando o rastreador do veiculo
    e trocado: o registro antigo fica com o historico e o novo segue rodando.
    A REGRA vive na view `vw_placa_resolvida` (criada pelo views.sql) -- aqui so
    aplicamos o resultado dela, para nao ter duas copias da logica.

    POR QUE ISTO RODA A CADA SYNC: o upsert de tb_cadastro/tb_status traz a placa
    crua da API e desfaz o sufixo. Sem este passo logo depois, a tabela volta a
    ter duplicadas todo dia -- as VIEWS ficariam certas e a TABELA errada.

    NAO-FATAL: banco novo ainda nao tem a view (o views.sql roda depois).
    """
    try:
        with engine.begin() as conn:
            n = conn.execute(text(f"""
                WITH alvo AS MATERIALIZED (SELECT id, placa FROM vw_placa_resolvida)
                UPDATE {tabela} t SET placa = a.placa
                  FROM alvo a
                 WHERE a.id = t.id AND t.placa IS DISTINCT FROM a.placa
            """)).rowcount
        if n:
            log.info(f"  ✓ {tabela}: {n} placa(s) duplicada(s) marcada(s) com -OFF.")
    except Exception as exc:
        log.warning(f"  ! resolucao de placas em {tabela} falhou (nao-fatal): "
                    f"{str(exc).strip()[:200]}")


def atualizar_mv_comportamento(engine):
    """Recalcula a mv_saneago_comportamento apos o sync dos eventos.

    CONCURRENTLY nao bloqueia leitores: o Power BI e o exportar_csv.py seguem
    lendo o retrato anterior enquanto o novo e construido. Exige o indice unico
    em (id, data), criado pelo views.sql.

    NAO-FATAL: banco recem-criado ainda nao tem a MV (o views.sql roda depois).
    Falhar aqui nao pode desfazer o sync, que ja esta gravado.
    """
    t0 = time.time()
    try:
        with engine.connect().execution_options(isolation_level="AUTOCOMMIT") as conn:
            conn.execute(text("REFRESH MATERIALIZED VIEW CONCURRENTLY mv_saneago_comportamento"))
        log.info(f"  ✓ mv_saneago_comportamento atualizada ({time.time() - t0:.0f}s).")
    except Exception as exc:
        log.warning("  ! REFRESH da mv_saneago_comportamento falhou (nao-fatal): "
                    f"{str(exc).strip()[:200]}")


def main(modo=None):
    if modo is None:
        modo = sys.argv[1] if len(sys.argv) > 1 else "all"

    alvo = (f"{SUPABASE['usuario']}@{SUPABASE['host']}:{SUPABASE['porta']}"
            f"/{SUPABASE['banco']}" + (f" [schema {SUPABASE['schema']}]" if SUPABASE["schema"] else ""))
    log.info(f"{'='*55}")
    log.info(f"  Geotab → Postgres  |  modo: {modo}")
    log.info(f"  DESTINO: {DESTINO.upper()}  →  {alvo}")
    log.info(f"{'='*55}")

    engine = criar_engine()
    criar_tabelas(engine)

    credentials = autenticar()
    log.info("  ✓ Autenticado no Geotab\n")

    try:
        if modo in ("all", "cadastro"):
            df = extrair_cadastro(credentials)
            gravar_tabela(df, "tb_cadastro", engine, chave_upsert="id")
            # logo apos o upsert: a API traz a placa crua e desfaz o sufixo
            resolver_placas_duplicadas(engine, "tb_cadastro")
            del df
            gc.collect()
            # Dimensão de motoristas (lotação) — mesma fonte de grupos do cadastro.
            df = extrair_motoristas(credentials)
            gravar_tabela(df, "tb_motoristas", engine, chave_upsert="id")
            del df
            gc.collect()

        if modo in ("all", "status"):
            df = extrair_status(credentials)
            gravar_tabela(df, "tb_status", engine, chave_upsert="id")
            resolver_placas_duplicadas(engine, "tb_status")
            del df
            gc.collect()

        if modo in ("all", "comportamento"):
            sincronizar_comportamento(credentials, engine)
            gc.collect()
            # A view de comportamento e materializada (custava 103s no local e
            # NAO rodava no Cloud SQL). Quem a mantem fresca e este refresh.
            atualizar_mv_comportamento(engine)

        # IMPORTANTE: viagens NÃO entra no 'all' — só roda no modo explícito.
        # É o trecho mais pesado (Trips por device + geocode) e travava o 'all'.
        # sincronizar_viagens já grava em lotes e libera memória a cada lote.
        if modo == "viagens":
            sincronizar_viagens(credentials, engine)

        # Abastecimento entra no 'all': é BARATO (o Get é por janela, não por
        # device — uma chamada por bloco mensal cobre a frota inteira).
        if modo in ("all", "abastecimento"):
            sincronizar_abastecimento(credentials, engine)
            gc.collect()

    finally:
        engine.dispose()

    log.info("\n✅ Sincronização concluída.")


if __name__ == "__main__":
    main()