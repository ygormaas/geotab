-- ============================================================================
-- MIGRAÇÃO — abastecimento na view de consumo/utilização           2026-08-31
--            (versão FINAL, simplificada a pedido do usuário)
-- ============================================================================
-- PEDIDO: "não quero view separada de abastecimento; quero a informação na view
-- que mostra consumo e utilização do veículo" e, depois, "confunde — quero
-- somente a informação correta para a situação de frota. Quanto cada veículo
-- andou e consumiu, muito simples."
--
-- RESULTADO: 3 colunas no fim de `vw_<cliente>_resumo_frota_mensal`
-- (grão veículo × mês, onde já existem km_rodado / dias_utilizados / taxa):
--
--   abastecimentos      — quantas vezes o veículo abasteceu no mês
--   litros_abastecidos  — QUANTO CONSUMIU: litros no mês
--   km_por_litro        — CONSUMO = km_rodado / litros_abastecidos
--
-- "quanto andou" já era `km_rodado`. Nenhuma coluna nova para isso.
--
-- ── O QUE FOI REMOVIDO nesta versão e POR QUÊ ───────────────────────────────
-- A versão anterior trazia também km_por_litro_evento / km_base_consumo /
-- litros_base_consumo — uma SEGUNDA métrica de consumo, calculada tanque a
-- tanque (pela distância que a Geotab mede entre dois abastecimentos). Estava
-- tecnicamente mais bem emparelhada, mas cobria menos linhas, e conviver com
-- duas métricas de consumo na mesma view confundia quem monta o visual.
-- Removida a pedido. Se um dia precisar, a fórmula é
--   DIVIDE(SUM(km_base), SUM(litros_base)) sobre tb_abastecimento,
-- filtrando litros > 5 AND distancia_km > 1.
--
-- ── GUARDA DE PLAUSIBILIDADE no km_por_litro (a parte importante) ───────────
-- km_rodado e litros_abastecidos são ambos "o que aconteceu dentro do mês", mas
-- NÃO são o mesmo combustível: o que foi abastecido dia 31 é queimado no mês
-- seguinte. Em veículo-mês isolado isso produz absurdo. Medido na SANEAGO
-- (7.846 linhas com valor): 537 davam < 1 km/L e 413 davam > 20 km/L, com p99
-- em 606 km/L — 12% de lixo que apareceria no painel como se fosse dado.
-- POR ISSO: km_por_litro só é preenchido quando o resultado é plausível para
-- esta frota (1 a 20 km/L; a mediana real é 6,9). Fora dessa faixa fica NULL —
-- a linha mostra branco em vez de número errado.
-- A GUARDA NÃO PREJUDICA O TOTAL: km_rodado e litros_abastecidos continuam
-- íntegros em TODAS as linhas, então a medida agregada do painel
--   DIVIDE(SUM([km_rodado]), SUM([litros_abastecidos]))
-- usa tudo e dá o número certo da frota (7,33 km/L no ano da SANEAGO).
-- NO BI, NUNCA faça média de média — sempre SUM/SUM.
--
-- ── COMO ────────────────────────────────────────────────────────────────────
-- DROP + CREATE (não CREATE OR REPLACE): remover coluna exige recriar a view.
-- DROP sem CASCADE de propósito — se algo dependesse da view, o script FALHA em
-- vez de derrubar a dependência em silêncio (foi o acidente de 2026-08-26, em
-- que um DROP CASCADE levou a vw_saneago_indicadores_mensal junto). Verificado
-- em 31/08: 0 objetos dependem destas duas views.
-- lock_timeout evita a transação ficar pendurada atrás de um refresh do BI.
--
-- ── NATUREZA DO DADO ────────────────────────────────────────────────────────
-- Telemetria, não contabilidade: a Geotab DEDUZ o abastecimento pela subida do
-- nível do tanque + parada de viagem. NÃO há dado financeiro (a entidade
-- FuelTransaction está vazia nesta base — sem integração de cartão), então
-- nenhuma coluna de R$ é possível. `litros_abastecidos` usa o litro coalesced
-- (o campo cru da Geotab vem 0 em ~19% dos eventos; o derivado cobre o resto).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '15s';

-- ─────────────────────────────────────────────────────────────────────────────
-- SANEAGO
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW vw_saneago_resumo_frota_mensal;

CREATE VIEW vw_saneago_resumo_frota_mensal AS
 WITH base AS (
         SELECT r.device_id,
            r.ano,
            r.mes,
            r.km,
            r.duracao_segundos,
            r.dias_utilizados,
            r.viagens,
            c.placa,
            c.veiculo,
            c.marca,
            c.modelo,
            c.todos_grupos,
            c.grupo_id,
            c.marca_padrao,
            c.modelo_padrao,
            LEAST((date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone) + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE) - date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone)::date + 1 AS dias_no_periodo
           FROM tb_resumo_mensal r
             JOIN vw_saneago_cadastro c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        ), abast AS (
         -- tb_abastecimento é 1 linha por evento; aqui vira veículo × mês.
         SELECT a.device_id,
            date_part('year',  a.data_hora)::int AS ano,
            date_part('month', a.data_hora)::int AS mes,
            count(*)                                              AS abastecimentos,
            sum(coalesce(nullif(a.litros, 0), a.litros_derivado)) AS litros
           FROM tb_abastecimento a
          GROUP BY a.device_id, 2, 3
        )
 SELECT base.placa,
    base.veiculo,
    base.marca,
    base.modelo,
    base.todos_grupos,
    base.grupo_id,
    base.ano,
    base.mes,
    to_char(make_date(base.ano, base.mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
    base.dias_no_periodo,
    base.dias_utilizados,
    round(base.km::numeric, 1) AS km_rodado,
    round((base.km / NULLIF(base.dias_utilizados, 0)::double precision)::numeric, 1) AS media_km_dia,
    round(base.duracao_segundos::numeric / 3600.0, 1) AS tempo_movimento_h,
    round(LEAST(base.dias_utilizados, base.dias_no_periodo)::numeric / NULLIF(base.dias_no_periodo, 0)::numeric * 100::numeric, 0) AS taxa_utilizacao_pct,
    base.viagens,
        CASE
            WHEN base.modelo IS NULL OR base.modelo = ''::text THEN base.marca
            ELSE base.modelo
        END AS modelo2,
    base.marca_padrao,
    base.modelo_padrao,
    -- ── ABASTECIMENTO ───────────────────────────────────────────────────────
    ab.abastecimentos,
    round(ab.litros::numeric, 1) AS litros_abastecidos,
    -- Só preenche quando o resultado é plausível (1 a 20 km/L). Fora da faixa é
    -- efeito do mês-calendário, não consumo real — melhor branco que errado.
    CASE
        WHEN round((base.km / NULLIF(ab.litros, 0))::numeric, 2) BETWEEN 1 AND 20
        THEN round((base.km / NULLIF(ab.litros, 0))::numeric, 2)
    END AS km_por_litro
   FROM base
     LEFT JOIN abast ab ON ab.device_id = base.device_id
                       AND ab.ano = base.ano
                       AND ab.mes = base.mes
  ORDER BY base.placa, base.ano, base.mes;

-- ─────────────────────────────────────────────────────────────────────────────
-- SEMAD — idêntica, trocando a dimensão de escopo.
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW vw_semad_resumo_frota_mensal;

CREATE VIEW vw_semad_resumo_frota_mensal AS
 WITH base AS (
         SELECT r.device_id,
            r.ano,
            r.mes,
            r.km,
            r.duracao_segundos,
            r.dias_utilizados,
            r.viagens,
            c.placa,
            c.veiculo,
            c.marca,
            c.modelo,
            c.todos_grupos,
            c.grupo_id,
            c.marca_padrao,
            c.modelo_padrao,
            LEAST((date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone) + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE) - date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone)::date + 1 AS dias_no_periodo
           FROM tb_resumo_mensal r
             JOIN vw_semad_cadastro c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        ), abast AS (
         SELECT a.device_id,
            date_part('year',  a.data_hora)::int AS ano,
            date_part('month', a.data_hora)::int AS mes,
            count(*)                                              AS abastecimentos,
            sum(coalesce(nullif(a.litros, 0), a.litros_derivado)) AS litros
           FROM tb_abastecimento a
          GROUP BY a.device_id, 2, 3
        )
 SELECT base.placa,
    base.veiculo,
    base.marca,
    base.modelo,
    base.todos_grupos,
    base.grupo_id,
    base.ano,
    base.mes,
    to_char(make_date(base.ano, base.mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
    base.dias_no_periodo,
    base.dias_utilizados,
    round(base.km::numeric, 1) AS km_rodado,
    round((base.km / NULLIF(base.dias_utilizados, 0)::double precision)::numeric, 1) AS media_km_dia,
    round(base.duracao_segundos::numeric / 3600.0, 1) AS tempo_movimento_h,
    round(LEAST(base.dias_utilizados, base.dias_no_periodo)::numeric / NULLIF(base.dias_no_periodo, 0)::numeric * 100::numeric, 0) AS taxa_utilizacao_pct,
    base.viagens,
        CASE
            WHEN base.modelo IS NULL OR base.modelo = ''::text THEN base.marca
            ELSE base.modelo
        END AS modelo2,
    base.marca_padrao,
    base.modelo_padrao,
    ab.abastecimentos,
    round(ab.litros::numeric, 1) AS litros_abastecidos,
    CASE
        WHEN round((base.km / NULLIF(ab.litros, 0))::numeric, 2) BETWEEN 1 AND 20
        THEN round((base.km / NULLIF(ab.litros, 0))::numeric, 2)
    END AS km_por_litro
   FROM base
     LEFT JOIN abast ab ON ab.device_id = base.device_id
                       AND ab.ano = base.ano
                       AND ab.mes = base.mes
  ORDER BY base.placa, base.ano, base.mes;

COMMIT;
