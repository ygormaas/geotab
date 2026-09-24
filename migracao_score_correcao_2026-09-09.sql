-- ============================================================
-- migracao_score_correcao_2026-09-09.sql
--
-- CORRIGE uma regressao de desempenho introduzida por
-- migracao_score_geotab_2026-09-09.sql.
--
-- O QUE DEU ERRADO
--   As colunas de score nas 2 views DIARIAS foram calculadas com CTEs que
--   agregam tb_comportamento_eventos e tb_viagens INTEIRAS. Hash aggregate
--   consome toda a entrada antes de emitir a 1a linha, entao "SELECT * ...
--   LIMIT 200" (o que o DBeaver e qualquer exploracao fazem) deixou de
--   terminar rapido:
--       vw_saneago_comportamento   0,1 s -> 21,9 s   (219x)
--       vw_saneago_motoristas     29,2 s -> 45,8 s   (1,6x)
--   A medicao que eu havia feito usou count(*) (varredura completa), onde o
--   impacto parecia de 5% - metrica errada para o uso interativo.
--
-- O QUE ESTA MIGRACAO FAZ
--   1. Restaura vw_saneago_comportamento ao original (sem score).
--   2. Restaura vw_saneago_motoristas ao original (sem score).
--   3. Cria vw_saneago_veiculos_anual: 1 linha por veiculo, com km do ano,
--      contadores, as 4 notas por regra e o score. E o grao correto - o score
--      so fecha depois de somar o periodo, e o veiculo nao tinha view anual
--      (foi por isso que eu o pendurei na diaria).
--   vw_saneago_motoristas_anual FICA como esta: 1 linha/motorista, sem
--   regressao medida (20,3 -> 22,3 s na varredura completa).
--
-- ONDE FICA O SCORE DEPOIS DISTO
--   motorista -> vw_saneago_motoristas_anual  (score_geotab, faixa_risco_geotab)
--   veiculo   -> vw_saneago_veiculos_anual    (score_geotab, faixa_risco_geotab)
--   periodo filtrado no painel -> medidas DAX (score_geotab_DAX.md)
--
-- Rodar: psql -f migracao_score_correcao_2026-09-09.sql
-- ============================================================

BEGIN;

-- ── 1. Restaura a view diaria de VEICULOS (sem score) ──
DROP VIEW IF EXISTS vw_saneago_comportamento;
CREATE OR REPLACE VIEW vw_saneago_comportamento AS
 SELECT e.device_id AS id,
    c.serial,
    c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    e.dia AS data,
    EXTRACT(year FROM e.dia)::integer AS ano,
    EXTRACT(month FROM e.dia)::integer AS mes,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'::text), 0::bigint) AS excessos_velocidade,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracoes_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagens_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'::text), 0::bigint) AS curvas_drasticas,
    COALESCE(sum(e.qtd), 0::bigint) AS total_eventos,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'::text), 0::bigint) * 3 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'::text), 0::bigint) * 2 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'::text), 0::bigint) * 2 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'::text), 0::bigint) * 1 AS score_risco,
    o.odometro,
    o.odometro_gps
   FROM tb_comportamento_eventos e
     JOIN vw_saneago_cadastro c ON c.id = e.device_id
     LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
  GROUP BY e.device_id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id, e.dia, o.odometro, o.odometro_gps;

-- ── 2. Restaura a view diaria de MOTORISTAS (sem score) ──
DROP VIEW IF EXISTS vw_saneago_motoristas;
CREATE OR REPLACE VIEW vw_saneago_motoristas AS
 WITH viagens_dia AS (
         SELECT v.motorista_id,
            v.data_partida::date AS dia,
            count(*) AS viagens,
            count(DISTINCT v.device_id) AS qtd_veiculos,
            string_agg(DISTINCT c.placa, ', '::text ORDER BY c.placa) AS veiculos,
            round(sum(v.distancia_km)::numeric, 1) AS km,
            round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
            round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
            round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
           FROM tb_viagens v
             LEFT JOIN tb_cadastro c ON c.id = v.device_id
          WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
          GROUP BY v.motorista_id, (v.data_partida::date)
        ), eventos_dia AS (
         SELECT tb_comportamento_motorista.motorista_id,
            tb_comportamento_motorista.dia,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'excesso_velocidade'::text), 0::bigint) AS excessos_velocidade,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracoes_bruscas,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagens_bruscas,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'curva_drastica'::text), 0::bigint) AS curvas_drasticas,
            COALESCE(sum(tb_comportamento_motorista.qtd), 0::bigint) AS total_eventos
           FROM tb_comportamento_motorista
          GROUP BY tb_comportamento_motorista.motorista_id, tb_comportamento_motorista.dia
        )
 SELECT m.nome AS motorista_nome,
    m.nome_completo AS motorista_nome_completo,
    m.matricula AS motorista_matricula,
    arrumar_grupos(m.todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos(m.todos_grupos)) AS grupo_id,
    COALESCE(vd.dia, ed.dia) AS data,
    EXTRACT(year FROM COALESCE(vd.dia, ed.dia))::integer AS ano,
    EXTRACT(month FROM COALESCE(vd.dia, ed.dia))::integer AS mes,
    vd.qtd_veiculos,
    vd.veiculos,
    vd.viagens,
    vd.km,
    vd.horas_movimento,
    vd.horas_ocioso,
    vd.horas_parado,
    COALESCE(ed.excessos_velocidade, 0::bigint) AS excessos_velocidade,
    COALESCE(ed.aceleracoes_bruscas, 0::bigint) AS aceleracoes_bruscas,
    COALESCE(ed.frenagens_bruscas, 0::bigint) AS frenagens_bruscas,
    COALESCE(ed.curvas_drasticas, 0::bigint) AS curvas_drasticas,
    COALESCE(ed.total_eventos, 0::bigint) AS total_eventos,
    COALESCE(ed.excessos_velocidade, 0::bigint) * 3 + COALESCE(ed.aceleracoes_bruscas, 0::bigint) * 2 + COALESCE(ed.frenagens_bruscas, 0::bigint) * 2 + COALESCE(ed.curvas_drasticas, 0::bigint) * 1 AS score_risco
   FROM viagens_dia vd
     FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
     LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id)
  WHERE grupo_visivel(m.todos_grupos);

-- ── 3. Score do VEICULO no grao certo: 1 linha por veiculo/ano ──
--    Espelha vw_saneago_motoristas_anual. Herda o filtro de grupo via
--    vw_saneago_cadastro. km vem de tb_viagens (o odometro e leitura
--    acumulada, nao rodagem).
CREATE OR REPLACE VIEW vw_saneago_veiculos_anual AS
 WITH km_dev AS (
         SELECT tb_viagens.device_id,
            count(*) AS viagens,
            round(sum(tb_viagens.distancia_km)::numeric, 1) AS km_ano,
            round(sum(tb_viagens.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento
           FROM tb_viagens
          GROUP BY tb_viagens.device_id
        ), ev_dev AS (
         SELECT tb_comportamento_eventos.device_id,
            COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
            COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracao_brusca,
            COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagem_brusca,
            COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'curva_drastica'::text), 0::bigint) AS curva_drastica,
            COALESCE(sum(tb_comportamento_eventos.qtd), 0::bigint) AS total_eventos
           FROM tb_comportamento_eventos
          GROUP BY tb_comportamento_eventos.device_id
        )
 SELECT x.id,
    x.serial,
    x.placa,
    x.veiculo,
    x.todos_grupos,
    x.grupo_id,
    x.viagens,
    x.km_ano,
    x.horas_movimento,
    x.excesso_velocidade,
    x.aceleracao_brusca,
    x.frenagem_brusca,
    x.curva_drastica,
    x.total_eventos,
    x.nota_velocidade,
    x.nota_aceleracao,
    x.nota_frenagem,
    x.nota_curva,
    x.score_geotab,
    faixa_risco_geotab(x.score_geotab) AS faixa_risco_geotab
   FROM ( SELECT c.id,
            c.serial,
            c.placa,
            c.veiculo,
            c.todos_grupos,
            c.grupo_id,
            k.viagens,
            k.km_ano,
            k.horas_movimento,
            COALESCE(e.excesso_velocidade, 0::bigint) AS excesso_velocidade,
            COALESCE(e.aceleracao_brusca, 0::bigint) AS aceleracao_brusca,
            COALESCE(e.frenagem_brusca, 0::bigint) AS frenagem_brusca,
            COALESCE(e.curva_drastica, 0::bigint) AS curva_drastica,
            COALESCE(e.total_eventos, 0::bigint) AS total_eventos,
            round(nota_regra_geotab(COALESCE(e.excesso_velocidade, 0::bigint), k.km_ano), 1) AS nota_velocidade,
            round(nota_regra_geotab(COALESCE(e.aceleracao_brusca, 0::bigint), k.km_ano), 1) AS nota_aceleracao,
            round(nota_regra_geotab(COALESCE(e.frenagem_brusca, 0::bigint), k.km_ano), 1) AS nota_frenagem,
            round(nota_regra_geotab(COALESCE(e.curva_drastica, 0::bigint), k.km_ano), 1) AS nota_curva,
            score_geotab(k.km_ano,
                         COALESCE(e.excesso_velocidade, 0::bigint),
                         COALESCE(e.aceleracao_brusca, 0::bigint),
                         COALESCE(e.frenagem_brusca, 0::bigint),
                         COALESCE(e.curva_drastica, 0::bigint)) AS score_geotab
           FROM vw_saneago_cadastro c
             LEFT JOIN km_dev k ON k.device_id = c.id
             LEFT JOIN ev_dev e ON e.device_id = c.id) x;
;

COMMIT;

-- ============================================================
-- CONFERENCIA
-- ============================================================
-- As diarias voltaram a abrir rapido?
--   EXPLAIN ANALYZE SELECT * FROM vw_saneago_comportamento LIMIT 200;
--   -- esperado: ~0,1 s
--
-- As colunas de score sairam das diarias?
--   SELECT table_name, column_name FROM information_schema.columns
--    WHERE column_name IN ('km_ano','score_geotab_ano','faixa_risco_ano');
--   -- esperado: 0 linhas
--
-- Score do veiculo:
--   SELECT faixa_risco_geotab, count(*) FROM vw_saneago_veiculos_anual GROUP BY 1;
--
-- Bate com o que a view diaria mostrava antes da correcao?
--   SELECT placa, km_ano, total_eventos, nota_velocidade, nota_frenagem, score_geotab
--     FROM vw_saneago_veiculos_anual
--    WHERE score_geotab IS NOT NULL ORDER BY score_geotab LIMIT 10;
