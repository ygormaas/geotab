-- ============================================================
-- SCORE GEOTAB POR MES/ANO (2026-09-14)
-- ============================================================
-- Motivo: o grao ANUAL nao serve p/ o painel; o usuario quer o score
-- estilo Geotab (Event Count) no grao MES/ANO (ano, mes), por VEICULO
-- e por MOTORISTA. Espelha vw_saneago_veiculos_anual /
-- vw_saneago_motoristas_anual, trocando o grao p/ (device|motorista) x mes.
--
-- Fonte dos totais (mesma metodologia das anuais):
--   km        -> tb_viagens         (NAO tb_resumo_mensal, que esta defasada 11-14%)
--   eventos   -> tb_comportamento_eventos (veiculo) / tb_comportamento_motorista (motorista)
--
-- PERF: as views ja SAO agregadas por mes (saida pequena), entao o
-- score computado dentro delas NAO reproduz a regressao de 219x que ocorreu
-- ao pendurar CTE-de-agregacao nas views DIARIAS (129k linhas, LIMIT 200
-- interativo). Aqui o proprio resultado e agregado -> LIMIT 200 instantaneo.
--
-- Piso de km = 200 (default de score_geotab, decisao do usuario).
--   -> mes com < 200 km rodados = score NULL ("Sem base"), nunca nota 0.
--
-- Funcoes (globais, ja existentes, 2026-09-09):
--   nota_regra_geotab(qtd bigint, km numeric)
--   score_geotab(km, exc, acel, fren, curva, piso_km DEFAULT 200)
--   faixa_risco_geotab(score numeric)
--
-- Reversao: DROP VIEW IF EXISTS vw_saneago_veiculos_mensal, vw_saneago_motoristas_mensal;
-- ============================================================

-- ------------------------------------------------------------
-- 1) vw_saneago_veiculos_mensal  (veiculo x mes)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_saneago_veiculos_mensal AS
 SELECT id, serial, placa, veiculo, todos_grupos, grupo_id,
        ano, mes, ano_mes,
        viagens, km_mes, horas_movimento,
        excesso_velocidade, aceleracao_brusca, frenagem_brusca, curva_drastica, total_eventos,
        nota_velocidade, nota_aceleracao, nota_frenagem, nota_curva,
        score_geotab,
        faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM (
     WITH km_dev AS (
             SELECT device_id,
                    EXTRACT(year  FROM data_partida)::int AS ano,
                    EXTRACT(month FROM data_partida)::int AS mes,
                    count(*) AS viagens,
                    round(sum(distancia_km)::numeric, 1) AS km_mes,
                    round(sum(duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento
               FROM tb_viagens
              GROUP BY device_id, EXTRACT(year FROM data_partida), EXTRACT(month FROM data_partida)
          ), ev_dev AS (
             SELECT device_id,
                    EXTRACT(year  FROM dia)::int AS ano,
                    EXTRACT(month FROM dia)::int AS mes,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'aceleracao_brusca'::text),  0::bigint) AS aceleracao_brusca,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'frenagem_brusca'::text),    0::bigint) AS frenagem_brusca,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'curva_drastica'::text),     0::bigint) AS curva_drastica,
                    COALESCE(sum(qtd), 0::bigint) AS total_eventos
               FROM tb_comportamento_eventos
              GROUP BY device_id, EXTRACT(year FROM dia), EXTRACT(month FROM dia)
          ), grade AS (
             SELECT COALESCE(k.device_id, e.device_id) AS device_id,
                    COALESCE(k.ano, e.ano) AS ano,
                    COALESCE(k.mes, e.mes) AS mes,
                    COALESCE(k.viagens, 0::bigint) AS viagens,
                    COALESCE(k.km_mes, 0::numeric) AS km_mes,
                    COALESCE(k.horas_movimento, 0::numeric) AS horas_movimento,
                    COALESCE(e.excesso_velocidade, 0::bigint) AS excesso_velocidade,
                    COALESCE(e.aceleracao_brusca, 0::bigint) AS aceleracao_brusca,
                    COALESCE(e.frenagem_brusca, 0::bigint) AS frenagem_brusca,
                    COALESCE(e.curva_drastica, 0::bigint) AS curva_drastica,
                    COALESCE(e.total_eventos, 0::bigint) AS total_eventos
               FROM km_dev k
                    FULL JOIN ev_dev e
                      ON e.device_id = k.device_id AND e.ano = k.ano AND e.mes = k.mes
          )
     SELECT c.id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id,
            g.ano, g.mes,
            to_char(make_date(g.ano, g.mes, 1), 'YYYY-MM') AS ano_mes,
            g.viagens, g.km_mes, g.horas_movimento,
            g.excesso_velocidade, g.aceleracao_brusca, g.frenagem_brusca, g.curva_drastica, g.total_eventos,
            round(nota_regra_geotab(g.excesso_velocidade, g.km_mes), 1) AS nota_velocidade,
            round(nota_regra_geotab(g.aceleracao_brusca,  g.km_mes), 1) AS nota_aceleracao,
            round(nota_regra_geotab(g.frenagem_brusca,    g.km_mes), 1) AS nota_frenagem,
            round(nota_regra_geotab(g.curva_drastica,     g.km_mes), 1) AS nota_curva,
            score_geotab(g.km_mes, g.excesso_velocidade, g.aceleracao_brusca, g.frenagem_brusca, g.curva_drastica) AS score_geotab
       FROM grade g
            JOIN vw_saneago_cadastro c ON c.id = g.device_id
   ) x;
;

-- ------------------------------------------------------------
-- 2) vw_saneago_motoristas_mensal  (motorista x mes)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_saneago_motoristas_mensal AS
 SELECT motorista_nome, motorista_nome_completo, motorista_matricula,
        todos_grupos, grupo_id,
        ano, mes, ano_mes,
        qtd_veiculos, veiculos, viagens, km_mes,
        horas_movimento, horas_ocioso, horas_parado,
        excesso_velocidade, aceleracao_brusca, frenagem_brusca, curva_drastica, total_eventos,
        nota_velocidade, nota_aceleracao, nota_frenagem, nota_curva,
        score_geotab,
        faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM (
     WITH viagens_mot AS (
             SELECT v.motorista_id,
                    EXTRACT(year  FROM v.data_partida)::int AS ano,
                    EXTRACT(month FROM v.data_partida)::int AS mes,
                    max(v.motorista_nome) AS motorista_nome,
                    max(v.motorista_matricula) AS motorista_matricula,
                    count(*) AS viagens,
                    count(DISTINCT v.device_id) AS qtd_veiculos,
                    string_agg(DISTINCT c.placa, ', '::text ORDER BY c.placa) AS veiculos,
                    round(sum(v.distancia_km)::numeric, 1) AS km_mes,
                    round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
                    round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
                    round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
               FROM tb_viagens v
                    LEFT JOIN tb_cadastro c ON c.id = v.device_id
              WHERE v.motorista_id <> ''::text
                AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
              GROUP BY v.motorista_id, EXTRACT(year FROM v.data_partida), EXTRACT(month FROM v.data_partida)
          ), eventos_mot AS (
             SELECT motorista_id,
                    EXTRACT(year  FROM dia)::int AS ano,
                    EXTRACT(month FROM dia)::int AS mes,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'aceleracao_brusca'::text),  0::bigint) AS aceleracao_brusca,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'frenagem_brusca'::text),    0::bigint) AS frenagem_brusca,
                    COALESCE(sum(qtd) FILTER (WHERE tipo = 'curva_drastica'::text),     0::bigint) AS curva_drastica,
                    COALESCE(sum(qtd), 0::bigint) AS total_eventos
               FROM tb_comportamento_motorista
              GROUP BY motorista_id, EXTRACT(year FROM dia), EXTRACT(month FROM dia)
          )
     SELECT vm.motorista_nome,
            m.nome_completo AS motorista_nome_completo,
            vm.motorista_matricula,
            arrumar_grupos(m.todos_grupos) AS todos_grupos,
            hashtext(arrumar_grupos(m.todos_grupos)) AS grupo_id,
            vm.ano, vm.mes,
            to_char(make_date(vm.ano, vm.mes, 1), 'YYYY-MM') AS ano_mes,
            vm.qtd_veiculos, vm.veiculos, vm.viagens, vm.km_mes,
            vm.horas_movimento, vm.horas_ocioso, vm.horas_parado,
            COALESCE(em.excesso_velocidade, 0::bigint) AS excesso_velocidade,
            COALESCE(em.aceleracao_brusca, 0::bigint) AS aceleracao_brusca,
            COALESCE(em.frenagem_brusca, 0::bigint) AS frenagem_brusca,
            COALESCE(em.curva_drastica, 0::bigint) AS curva_drastica,
            COALESCE(em.total_eventos, 0::bigint) AS total_eventos,
            round(nota_regra_geotab(COALESCE(em.excesso_velocidade, 0::bigint), vm.km_mes), 1) AS nota_velocidade,
            round(nota_regra_geotab(COALESCE(em.aceleracao_brusca,  0::bigint), vm.km_mes), 1) AS nota_aceleracao,
            round(nota_regra_geotab(COALESCE(em.frenagem_brusca,    0::bigint), vm.km_mes), 1) AS nota_frenagem,
            round(nota_regra_geotab(COALESCE(em.curva_drastica,     0::bigint), vm.km_mes), 1) AS nota_curva,
            score_geotab(vm.km_mes,
                         COALESCE(em.excesso_velocidade, 0::bigint),
                         COALESCE(em.aceleracao_brusca, 0::bigint),
                         COALESCE(em.frenagem_brusca, 0::bigint),
                         COALESCE(em.curva_drastica, 0::bigint)) AS score_geotab
       FROM viagens_mot vm
            LEFT JOIN eventos_mot em
              ON em.motorista_id = vm.motorista_id AND em.ano = vm.ano AND em.mes = vm.mes
            LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id
      WHERE grupo_visivel(m.todos_grupos)
   ) x;
;
