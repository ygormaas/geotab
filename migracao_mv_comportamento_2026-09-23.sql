-- vw_saneago_comportamento vira MATERIALIZED VIEW (2026-09-23)
--
-- MOTIVO: a view custava 103s no Postgres local e NAO RODAVA no Cloud SQL
-- (>300s, instancia de 1 vCPU). O gargalo sao arrumar_grupos()/nivel_grupo()
-- chamadas por linha, via vw_saneago_cadastro. Um LIMIT 200 custava os MESMOS
-- 103s -- ha agregacao bloqueante, entao a view e calculada inteira antes da
-- primeira linha. E ela esta na lista do exportar_csv.py: depois da virada p/
-- a nuvem, seria um relatorio que simplesmente nao sai.
--
-- DESENHO: a logica pesada vai para a MV; a VIEW vira uma casca sobre ela.
-- Assim NADA a jusante muda de nome -- Power BI, exportar_csv.py e consultas
-- manuais continuam chamando vw_saneago_comportamento.
--
-- O indice unico em (id, data) NAO e enfeite: e requisito do
-- REFRESH ... CONCURRENTLY, que atualiza sem bloquear quem esta lendo.
-- Conferido em 2026-09-23: 139.694 linhas, 139.694 pares (id, data) distintos.
--
-- QUEM ATUALIZA: o geotab_supabase.py, ao final do modo `comportamento`.
--
-- ATENCAO AO REEXECUTAR: `CREATE MATERIALIZED VIEW IF NOT EXISTS` NAO atualiza
-- o corpo se a MV ja existe. Para mudar a logica:
--     DROP MATERIALIZED VIEW mv_saneago_comportamento CASCADE;
-- e rodar o views.sql de novo (o CASCADE derruba a view-casca, que o views.sql
-- recria em seguida).

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_saneago_comportamento AS
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

CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_saneago_comportamento
    ON mv_saneago_comportamento (id, data);

CREATE OR REPLACE VIEW vw_saneago_comportamento AS
 SELECT * FROM mv_saneago_comportamento;
