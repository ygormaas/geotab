-- ============================================================================
-- SEMAD — SCORE GEOTAB (0-100, método oficial Event Count) — 2026-09-15
-- ============================================================================
-- PEDIDO DO USUÁRIO: trazer o "formato SANEAGO" (score_geotab 0-100) para o
-- SEMAD, que até aqui só tinha soma (score_risco, ilimitada) e média simples
-- (score_seguranca). Nada muda nas views diárias — score_risco fica como está
-- (é CONTAGEM ponderada de eventos, "Eventos Ponderados"; passar de 100 é
-- natural). O score 0-100 passa a ser o score_geotab, igual à SANEAGO.
--
-- As 3 funções (nota_regra_geotab / score_geotab / faixa_risco_geotab) são
-- GLOBAIS (criadas em migracao_score_geotab_2026-09-09.sql) — aqui só se usam.
-- Metodologia: nota_regra = 100 - eventos*1000/km (0..100); score = média
-- ponderada veloc 0.40 + acel/fren/curva 0.20; piso 200 km => NULL "Sem base".
--
-- GRÃO: por VEÍCULO (anual + mensal) tem dado real; por MOTORISTA fica 0 linhas
-- (viagens do SEMAD sem condutor identificado) — score_geotab add em
-- motoristas_anual só por PARIDADE com a SANEAGO.
--
-- ESPELHO EXATO das views SANEAGO (vw_saneago_veiculos_anual/_mensal e o bloco
-- de score de vw_saneago_motoristas_anual), com 2 diferenças:
--   (1) JOIN em vw_semad_cadastro (herda grupo_semad + o grupo_id COMPOSTO
--       grupo|contrato de migracao_semad_grupos_contrato_2026-09-15.sql);
--   (2) coluna `contrato` exposta (SEMAD tem a dimensão de contrato; casa com a
--       chave composta e permite fatiar o score por 031 vs 035).
-- CREATE OR REPLACE em todas (motoristas_anual só GANHA colunas no fim) -> sem
-- DROP, sem lock exclusivo brigando com refresh do BI. Frota 91 -> custo baixo.
-- ============================================================================

-- 1) VEÍCULOS × ANO
CREATE OR REPLACE VIEW vw_semad_veiculos_anual AS
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
 SELECT id, serial, placa, veiculo, todos_grupos, grupo_id, contrato,
    viagens, km_ano, horas_movimento,
    excesso_velocidade, aceleracao_brusca, frenagem_brusca, curva_drastica, total_eventos,
    nota_velocidade, nota_aceleracao, nota_frenagem, nota_curva, score_geotab,
    faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM ( SELECT c.id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id, c.contrato,
            k.viagens, k.km_ano, k.horas_movimento,
            COALESCE(e.excesso_velocidade, 0::bigint) AS excesso_velocidade,
            COALESCE(e.aceleracao_brusca, 0::bigint) AS aceleracao_brusca,
            COALESCE(e.frenagem_brusca, 0::bigint) AS frenagem_brusca,
            COALESCE(e.curva_drastica, 0::bigint) AS curva_drastica,
            COALESCE(e.total_eventos, 0::bigint) AS total_eventos,
            round(nota_regra_geotab(COALESCE(e.excesso_velocidade, 0::bigint), k.km_ano), 1) AS nota_velocidade,
            round(nota_regra_geotab(COALESCE(e.aceleracao_brusca, 0::bigint), k.km_ano), 1) AS nota_aceleracao,
            round(nota_regra_geotab(COALESCE(e.frenagem_brusca, 0::bigint), k.km_ano), 1) AS nota_frenagem,
            round(nota_regra_geotab(COALESCE(e.curva_drastica, 0::bigint), k.km_ano), 1) AS nota_curva,
            score_geotab(k.km_ano, COALESCE(e.excesso_velocidade, 0::bigint), COALESCE(e.aceleracao_brusca, 0::bigint), COALESCE(e.frenagem_brusca, 0::bigint), COALESCE(e.curva_drastica, 0::bigint)) AS score_geotab
           FROM vw_semad_cadastro c
             LEFT JOIN km_dev k ON k.device_id = c.id
             LEFT JOIN ev_dev e ON e.device_id = c.id) x;

-- 2) VEÍCULOS × MÊS
CREATE OR REPLACE VIEW vw_semad_veiculos_mensal AS
 SELECT id, serial, placa, veiculo, todos_grupos, grupo_id, contrato,
    ano, mes, ano_mes,
    viagens, km_mes, horas_movimento,
    excesso_velocidade, aceleracao_brusca, frenagem_brusca, curva_drastica, total_eventos,
    nota_velocidade, nota_aceleracao, nota_frenagem, nota_curva, score_geotab,
    faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM ( WITH km_dev AS (
                 SELECT tb_viagens.device_id,
                    EXTRACT(year FROM tb_viagens.data_partida)::integer AS ano,
                    EXTRACT(month FROM tb_viagens.data_partida)::integer AS mes,
                    count(*) AS viagens,
                    round(sum(tb_viagens.distancia_km)::numeric, 1) AS km_mes,
                    round(sum(tb_viagens.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento
                   FROM tb_viagens
                  GROUP BY tb_viagens.device_id, (EXTRACT(year FROM tb_viagens.data_partida)), (EXTRACT(month FROM tb_viagens.data_partida))
                ), ev_dev AS (
                 SELECT tb_comportamento_eventos.device_id,
                    EXTRACT(year FROM tb_comportamento_eventos.dia)::integer AS ano,
                    EXTRACT(month FROM tb_comportamento_eventos.dia)::integer AS mes,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracao_brusca,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagem_brusca,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'curva_drastica'::text), 0::bigint) AS curva_drastica,
                    COALESCE(sum(tb_comportamento_eventos.qtd), 0::bigint) AS total_eventos
                   FROM tb_comportamento_eventos
                  GROUP BY tb_comportamento_eventos.device_id, (EXTRACT(year FROM tb_comportamento_eventos.dia)), (EXTRACT(month FROM tb_comportamento_eventos.dia))
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
                     FULL JOIN ev_dev e ON e.device_id = k.device_id AND e.ano = k.ano AND e.mes = k.mes
                )
         SELECT c.id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id, c.contrato,
            g.ano, g.mes,
            to_char(make_date(g.ano, g.mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
            g.viagens, g.km_mes, g.horas_movimento,
            g.excesso_velocidade, g.aceleracao_brusca, g.frenagem_brusca, g.curva_drastica, g.total_eventos,
            round(nota_regra_geotab(g.excesso_velocidade, g.km_mes), 1) AS nota_velocidade,
            round(nota_regra_geotab(g.aceleracao_brusca, g.km_mes), 1) AS nota_aceleracao,
            round(nota_regra_geotab(g.frenagem_brusca, g.km_mes), 1) AS nota_frenagem,
            round(nota_regra_geotab(g.curva_drastica, g.km_mes), 1) AS nota_curva,
            score_geotab(g.km_mes, g.excesso_velocidade, g.aceleracao_brusca, g.frenagem_brusca, g.curva_drastica) AS score_geotab
           FROM grade g
             JOIN vw_semad_cadastro c ON c.id = g.device_id) x;

-- 3) MOTORISTAS × ANO — adiciona score_geotab + faixa_risco_geotab (paridade;
--    0 linhas hoje). Mantém o grupo_id COMPOSTO grupo|contrato. score_seguranca
--    (média simples) preservada, igual à SANEAGO.
CREATE OR REPLACE VIEW vw_semad_motoristas_anual AS
 SELECT motorista_nome, motorista_nome_completo, motorista_matricula,
    todos_grupos, grupo_id,
    qtd_veiculos, veiculos, viagens, km_total,
    horas_movimento, horas_ocioso, horas_parado,
    excesso_velocidade, aceleracao_brusca, frenagem_brusca, curva_drastica, total_eventos,
    score_seguranca, score_geotab,
    faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM ( SELECT b.motorista_nome, b.motorista_nome_completo, b.motorista_matricula,
            b.todos_grupos, b.grupo_id,
            b.qtd_veiculos, b.veiculos, b.viagens, b.km_total,
            b.horas_movimento, b.horas_ocioso, b.horas_parado,
            b.excesso_velocidade, b.aceleracao_brusca, b.frenagem_brusca, b.curva_drastica, b.total_eventos,
            b.score_seguranca,
            score_geotab(b.km_total, b.excesso_velocidade, b.aceleracao_brusca, b.frenagem_brusca, b.curva_drastica) AS score_geotab
           FROM ( WITH viagens_mot AS (
                         SELECT v.motorista_id,
                            max(v.motorista_nome) AS motorista_nome,
                            max(v.motorista_matricula) AS motorista_matricula,
                            count(*) AS viagens,
                            count(DISTINCT v.device_id) AS qtd_veiculos,
                            string_agg(DISTINCT c.placa, ', '::text ORDER BY c.placa) AS veiculos,
                            round(sum(v.distancia_km)::numeric, 1) AS km_total,
                            round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
                            round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
                            round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
                           FROM tb_viagens v
                             JOIN vw_semad_cadastro c ON c.id = v.device_id
                          WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
                          GROUP BY v.motorista_id
                        ), eventos_mot AS (
                         SELECT cm.motorista_id,
                            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
                            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracao_brusca,
                            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagem_brusca,
                            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'curva_drastica'::text), 0::bigint) AS curva_drastica,
                            COALESCE(sum(cm.qtd), 0::bigint) AS total_eventos
                           FROM tb_comportamento_motorista cm
                             JOIN vw_semad_cadastro c ON c.id = cm.device_id
                          GROUP BY cm.motorista_id
                        )
                 SELECT vm.motorista_nome,
                    m.nome_completo AS motorista_nome_completo,
                    vm.motorista_matricula,
                    arrumar_grupos_semad(m.todos_grupos) AS todos_grupos,
                    hashtext(arrumar_grupos_semad(m.todos_grupos) || '|' || COALESCE(contrato_semad(m.todos_grupos), ''::text)) AS grupo_id,
                    vm.qtd_veiculos, vm.veiculos, vm.viagens, vm.km_total,
                    vm.horas_movimento, vm.horas_ocioso, vm.horas_parado,
                    COALESCE(em.excesso_velocidade, 0::bigint) AS excesso_velocidade,
                    COALESCE(em.aceleracao_brusca, 0::bigint) AS aceleracao_brusca,
                    COALESCE(em.frenagem_brusca, 0::bigint) AS frenagem_brusca,
                    COALESCE(em.curva_drastica, 0::bigint) AS curva_drastica,
                    COALESCE(em.total_eventos, 0::bigint) AS total_eventos,
                        CASE
                            WHEN vm.km_total >= 1::numeric THEN round((GREATEST(0::numeric, 100::numeric - COALESCE(em.excesso_velocidade, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.aceleracao_brusca, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.frenagem_brusca, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.curva_drastica, 0::bigint)::numeric * 1000.0 / vm.km_total)) / 4.0, 1)
                            ELSE NULL::numeric
                        END AS score_seguranca
                   FROM viagens_mot vm
                     LEFT JOIN eventos_mot em ON em.motorista_id = vm.motorista_id
                     LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id) b) x;
