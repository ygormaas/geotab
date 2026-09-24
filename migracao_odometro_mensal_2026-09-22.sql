-- ============================================================
-- HODOMETRO POR VEICULO x MES -- TABELA tb_odometro_mensal (2026-09-22)
-- ============================================================
-- Pedido: tabela onde se ve o hodometro de cada veiculo no periodo
-- filtrado (grao ano-mes), com TODOS os veiculos cadastrados na
-- telemetria, id, placa/veiculo, hodometro do inicio e do fim.
--
-- REVISAO (mesma data): a 1a entrega criou DUAS VIEWS separadas por
-- cliente (vw_saneago_odometro_mensal / vw_semad_odometro_mensal).
-- O usuario pediu p/ APAGAR as views e ter UMA TABELA FISICA com
-- TODOS os veiculos -- sem filtro de cliente. Este arquivo faz isso.
--
-- Fonte: tb_odometro_dia (device_id, dia, odometro) -- ultimo valor
-- lido no dia. 324.016 linhas / 1.961 devices / 2026-01-01..hoje.
-- Grade: tb_cadastro INTEIRA (1.988 veiculos) x meses -> 17.892 linhas.
-- 0 orfaos: todo device de tb_odometro_dia casa com tb_cadastro.
--
-- DECISOES:
-- 1) TABELA, nao view: o usuario pediu tabela. Recalculada por inteiro
--    (TRUNCATE + INSERT) no fim do modo `comportamento`, logo apos
--    sincronizar_odometro_dia -- que e de onde ela deriva. 17.892
--    linhas, recalculo em ~0,4 s: nao compensa incremental.
-- 2) SEM FILTRO DE CLIENTE: parte de tb_cadastro cru, nao de
--    vw_saneago_cadastro/vw_semad_cadastro. Cobre SANEAGO, SEMAD,
--    COMURG, ECONOMIA e qualquer outro.
--    P/ recortar por cliente no painel, use `todos_grupos_expandido`
--    (LIKE '%OPE_SANEAGO%'), NAO `todos_grupos`: apos o restructuring
--    de grupos de 2026-09-14 o token OPE_<cliente> vive so no ANCESTRAL,
--    e a folha (`todos_grupos`) nao o tem -- medido: filtrar
--    `todos_grupos LIKE '%OPE_SANEAGO%'` devolve ZERO veiculos.
-- 3) placa/veiculo/todos_grupos DENORMALIZADOS na tabela (o usuario
--    pediu placa/veiculo nela). Contraria o padrao "tabela enxuta +
--    JOIN na view" adotado em tb_viagens, mas ali eram ~200 MB de
--    texto repetido em milhoes de linhas; aqui sao 17.892 linhas.
-- 4) GRADE COMPLETA: cadastro CROSS JOIN meses. Todo veiculo aparece
--    em todo mes, mesmo sem leitura. Sem isso o veiculo parado sumiria
--    do filtro.
-- 5) ABERTURA COM CARRY-FORWARD: `odometro_inicio` = ULTIMA leitura
--    ANTERIOR ao mes (fechamento do mes passado), nao a 1a leitura do
--    mes. Motivo: so ha leitura nos dias em que o veiculo rodou; usar
--    a 1a leitura do mes perderia o km do 1o dia e os meses nao
--    emendariam (fim de um <> inicio do seguinte). Se nao existe
--    leitura anterior (1o mes do veiculo), cai na 1a leitura do mes
--    -- sinalizado na coluna `origem_inicio`.
-- 6) MES SEM LEITURA: carrega a ultima conhecida -> inicio = fim e
--    km_periodo = 0 (veiculo parado), em vez de linha vazia.
-- 7) GUARDA DE SANIDADE `odometro > 0 AND odometro < 3000000`:
--    o device b12B (placa SGZ8B71) tem 16 dias com 214.749.636,49 km
--    = 2^31/10, sentinela de overflow INT32 da telemetria. A faixa real
--    dele e 5.169 -> 11.413 km. Sem o filtro, o hodometro final desse
--    veiculo estouraria o painel.
-- 8) `odometro_gps` NAO entra: e 0,0 em 100% das 324.016 linhas
--    (coluna morta na origem). So o odometro fisico e usado.
-- 9) CRONOLOGICO, nao min/max: o odometro NAO e monotonico -- 439
--    leituras (363 devices, 0,14%) caem em relacao ao dia anterior
--    (troca/reset de equipamento). Por isso abertura e fechamento sao
--    a leitura mais ANTIGA/RECENTE por DATA, nunca min()/max().
--    Consequencia: `km_periodo` pode vir NEGATIVO nesses casos -- e
--    dado de origem, fica visivel de proposito.
--
-- No BI: km de varios meses = SUM(km_periodo). Hodometro de abertura/
-- fechamento de um INTERVALO de meses: ver DAX no fim do arquivo.
-- ============================================================

BEGIN;

-- ── 1. Apaga as views da 1a entrega ────────────────────────
DROP VIEW IF EXISTS vw_saneago_odometro_mensal;
DROP VIEW IF EXISTS vw_semad_odometro_mensal;

-- ── 2. Tabela ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tb_odometro_mensal (
    device_id        TEXT,              -- = tb_cadastro.id
    ano              INTEGER,
    mes              INTEGER,
    ano_mes          TEXT,              -- 'YYYY-MM'
    mes_ini          DATE,
    mes_fim          DATE,
    serial           TEXT,
    placa            TEXT,
    veiculo          TEXT,              -- 'PLACA | MARCA | MODELO' (padronizado)
    todos_grupos     TEXT,
    todos_grupos_expandido TEXT,        -- folha + ancestrais; e AQUI que vive o token OPE_<cliente>
    grupo_id         INTEGER,
    odometro_inicio  DOUBLE PRECISION,  -- km na abertura do mes
    odometro_fim     DOUBLE PRECISION,  -- km no fechamento do mes
    km_periodo       NUMERIC,           -- fim - inicio
    dia_inicio       DATE,              -- data da leitura de abertura
    dia_fim          DATE,              -- data da leitura de fechamento
    dias_com_leitura INTEGER,
    origem_inicio    TEXT,              -- fechamento do mes anterior | primeira leitura do veiculo | sem leitura
    origem_dado      TEXT,              -- 'carga corrigida' | 'legado (unidade suspeita)' | 'sem leitura'
    atualizado_em    TIMESTAMP,
    PRIMARY KEY (device_id, ano, mes)
);
CREATE INDEX IF NOT EXISTS ix_odo_mensal_ano_mes ON tb_odometro_mensal (ano_mes);
CREATE INDEX IF NOT EXISTS ix_odo_mensal_placa   ON tb_odometro_mensal (placa);
CREATE INDEX IF NOT EXISTS ix_odo_mensal_device  ON tb_odometro_mensal (device_id);

-- ── 3. Carga (o mesmo SQL roda na sync diaria) ─────────────
TRUNCATE tb_odometro_mensal;

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
    SELECT c.id, c.serial, c.placa,
           concat_ws(' | ', c.placa, marca_padrao(c.marca, c.modelo),
                            modelo_padrao(c.marca, c.modelo))  AS veiculo,
           arrumar_grupos(c.todos_grupos)                      AS todos_grupos,
           c.todos_grupos_expandido,
           hashtext(arrumar_grupos(c.todos_grupos))            AS grupo_id,
           m.mes_ini, m.mes_fim
      FROM tb_cadastro c
      CROSS JOIN meses m
)
SELECT g.id,
       EXTRACT(year  FROM g.mes_ini)::int,
       EXTRACT(month FROM g.mes_ini)::int,
       to_char(g.mes_ini, 'YYYY-MM'),
       g.mes_ini,
       g.mes_fim,
       g.serial,
       g.placa,
       g.veiculo,
       g.todos_grupos,
       g.todos_grupos_expandido,
       g.grupo_id,
       COALESCE(ant.odometro, prim.odometro),
       fim.odometro,
       round((fim.odometro - COALESCE(ant.odometro, prim.odometro))::numeric, 1),
       COALESCE(ant.dia, prim.dia),
       fim.dia,
       COALESCE(dias.qtd, 0),
       CASE WHEN fim.odometro  IS NULL     THEN 'sem leitura'
            WHEN ant.odometro IS NOT NULL  THEN 'fechamento do mes anterior'
            ELSE                                'primeira leitura do veiculo'
       END,
       CASE WHEN fim.odometro IS NULL THEN 'sem leitura'
            -- suspeita se QUALQUER das duas pontas do mes veio da carga legada:
            -- um fechamento novo com abertura legada ainda produz km errado
            WHEN fim.atualizado_em  < TIMESTAMP '2026-09-22 13:59'
              OR ant.atualizado_em  < TIMESTAMP '2026-09-22 13:59'
              OR prim.atualizado_em < TIMESTAMP '2026-09-22 13:59' THEN 'legado (unidade suspeita)'
            ELSE 'carga corrigida' END,
       now()
  FROM grade g
  -- abertura: ultima leitura ANTES do mes (carry-forward)
  LEFT JOIN LATERAL (
       SELECT o.odometro, o.dia, o.atualizado_em FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia < g.mes_ini
          AND o.odometro > 0 AND o.odometro < 3000000
        ORDER BY o.dia DESC LIMIT 1) ant ON TRUE
  -- fallback: 1a leitura DENTRO do mes (so vale quando nao ha anterior)
  LEFT JOIN LATERAL (
       SELECT o.odometro, o.dia, o.atualizado_em FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia BETWEEN g.mes_ini AND g.mes_fim
          AND o.odometro > 0 AND o.odometro < 3000000
        ORDER BY o.dia ASC LIMIT 1) prim ON TRUE
  -- fechamento: ultima leitura ATE o fim do mes (carrega se o mes nao teve)
  LEFT JOIN LATERAL (
       SELECT o.odometro, o.dia, o.atualizado_em FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia <= g.mes_fim
          AND o.odometro > 0 AND o.odometro < 3000000
        ORDER BY o.dia DESC LIMIT 1) fim ON TRUE
  LEFT JOIN LATERAL (
       SELECT count(*) AS qtd FROM tb_odometro_dia o
        WHERE o.device_id = g.id AND o.dia BETWEEN g.mes_ini AND g.mes_fim
          AND o.odometro > 0 AND o.odometro < 3000000) dias ON TRUE;

COMMIT;

-- ============================================================
-- DAX (Power BI) -- hodometro de ABERTURA/FECHAMENTO do intervalo filtrado
-- ============================================================
-- Km rodado no periodo filtrado (resolve a maioria dos casos):
--   Km Periodo = SUM(tb_odometro_mensal[km_periodo])
--
-- Hodometro inicial do intervalo (1o mes filtrado, por veiculo):
--   Hod Inicial =
--   VAR ini = CALCULATE(MIN(tb_odometro_mensal[ano_mes]), ALLSELECTED(tb_odometro_mensal))
--   RETURN CALCULATE(SUM(tb_odometro_mensal[odometro_inicio]),
--                    tb_odometro_mensal[ano_mes] = ini)
--
-- Hodometro final do intervalo (ultimo mes filtrado, por veiculo):
--   Hod Final =
--   VAR fim = CALCULATE(MAX(tb_odometro_mensal[ano_mes]), ALLSELECTED(tb_odometro_mensal))
--   RETURN CALCULATE(SUM(tb_odometro_mensal[odometro_fim]),
--                    tb_odometro_mensal[ano_mes] = fim)
