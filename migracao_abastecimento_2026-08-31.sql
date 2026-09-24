-- ============================================================================
-- MIGRAÇÃO — views de ABASTECIMENTO (SANEAGO + SEMAD)              2026-08-31
-- ============================================================================
-- Fonte: tb_abastecimento (entidade FuelUpEvent da Geotab), populada pelo modo
-- `python geotab_supabase.py abastecimento`.
--
-- NATUREZA DO DADO — leia antes de usar no painel:
--   A Geotab DEDUZ cada abastecimento pela subida do nível do tanque combinada
--   com a parada da viagem. É TELEMETRIA, não contabilidade. A entidade
--   FuelTransaction (que traria R$, preço/litro, posto e nota fiscal) está
--   VAZIA nesta base — não existe integração de cartão de combustível. Não há,
--   portanto, NENHUMA coluna financeira aqui, e os litros não batem litro a
--   litro com a nota do posto.
--
-- PADRÕES DO PROJETO respeitados:
--   • Escopo do cliente pelo VEÍCULO (JOIN vw_<cliente>_cadastro) — herda
--     grupo_visivel()/grupo_semad() sem repetir regra de filtro.
--   • `todos_grupos` (tratado) + `grupo_id` (hashtext, chave leve) em TODA view.
--   • placa/veiculo/marca_padrao/modelo_padrao vêm do cadastro por JOIN.
--   • SEM ORDER BY (regra de PERF de 2026-08-25 — ORDER BY em view obriga o PG a
--     ordenar tudo antes da 1ª linha e estourava o refresh do Power BI).
--   • security_invoker = on, igual às demais.
--
-- DECISÕES DESTA VIEW (medidas nos dados, ano 2026 / 53.237 eventos):
--   • `litros` = coalesce(nullif(litros,0), litros_derivado). O campo cru vem 0
--     em 1 de cada 5 eventos (80,5% > 0); o derivado da Geotab cobre 95,8%.
--     `litros_medido` / `litros_derivado` / `origem_litros` ficam expostos para
--     auditoria — mas o que se SOMA no BI é `litros`.
--   • `km_por_litro` só é calculado com litros > 5 e distancia_km > 1 (senão
--     NULL). Sem essa guarda o indicador distorce: p10 = 2,2 e p90 = 11,3 km/L
--     na frota toda por causa de abastecimentos parciais e detecções fracas.
--     A guarda usa o litro COALESCED (`litros_ok` da subconsulta), não o cru —
--     usar o cru descartaria o consumo dos 19% de eventos que só têm o derivado.
--     ATENÇÃO NO BI: a média correta do período NÃO é AVERAGE(km_por_litro) —
--     é SUM(distancia_km) / SUM(litros) sobre as linhas com km_por_litro
--     preenchido (por isso `distancia_km_valida` e `litros_validos` existem).
--   • LEFT JOIN em tb_motoristas: 23 motorista_id não existem na dimensão
--     (motoristas apagados ou fora do escopo da API). Com JOIN normal essas
--     linhas desapareceriam.
--   • Endereço do abastecimento pelo cache tb_enderecos (round 3 casas, igual
--     às views de viagens): 99,4% de cobertura SEM geocode novo — os
--     abastecimentos são detectados em paradas de viagem, já geocodificadas.
--   • `tipo_combustivel` (productType) vem 100% "Unknown" hoje. Mantido para
--     não ter de recriar a view se a Geotab passar a preencher.
-- ============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- SANEAGO
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW vw_saneago_abastecimento
WITH (security_invoker = on) AS
SELECT
    c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    a.data_hora,
    a.data_hora::date                                       AS data,
    date_part('year',  a.data_hora)::int                    AS ano,
    date_part('month', a.data_hora)::int                    AS mes,
    to_char(a.data_hora, 'YYYY-MM')                         AS ano_mes,
    -- LITROS: use esta. As duas seguintes são auditoria.
    a.litros_ok                                             AS litros,
    a.litros                                                AS litros_medido,
    a.litros_derivado,
    CASE
        WHEN a.litros > 0                THEN 'medido'
        WHEN a.litros_derivado > 0       THEN 'derivado'
        ELSE 'indefinido'
    END                                                     AS origem_litros,
    a.litros_motor,
    a.distancia_km,
    a.odometro_km,
    a.tanque_litros,
    -- Consumo do evento. NULL quando os números não sustentam a conta.
    CASE WHEN a.litros_ok > 5 AND a.distancia_km > 1
         THEN round((a.distancia_km / a.litros_ok)::numeric, 2)
    END                                                     AS km_por_litro,
    -- Numerador/denominador da MEDIDA correta do período no BI:
    -- SUM(distancia_km_valida) / SUM(litros_validos).
    CASE WHEN a.litros_ok > 5 AND a.distancia_km > 1 THEN a.distancia_km END
                                                            AS distancia_km_valida,
    CASE WHEN a.litros_ok > 5 AND a.distancia_km > 1 THEN a.litros_ok END
                                                            AS litros_validos,
    limpar_endereco(e.endereco)                             AS end_abastecimento,
    a.latitude,
    a.longitude,
    mo.nome                                                 AS motorista_nome,
    mo.nome_completo                                        AS motorista_nome_completo,
    mo.matricula                                            AS motorista_matricula,
    a.tipo_combustivel,
    a.confianca,
    c.marca_padrao,
    c.modelo_padrao
  -- Subconsulta só para nomear o litro utilizável UMA vez (o planejador a
  -- achata; não é CTE, não materializa).
  FROM (SELECT ab.*, coalesce(nullif(ab.litros, 0), ab.litros_derivado) AS litros_ok
          FROM tb_abastecimento ab) a
  JOIN vw_saneago_cadastro c ON c.id = a.device_id
  LEFT JOIN tb_motoristas mo ON mo.id = a.motorista_id
  LEFT JOIN tb_enderecos  e  ON e.lat = round(a.latitude::numeric, 3)
                            AND e.lon = round(a.longitude::numeric, 3);

-- ─────────────────────────────────────────────────────────────────────────────
-- SEMAD — espelho, trocando apenas a dimensão de escopo (vw_semad_cadastro).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW vw_semad_abastecimento
WITH (security_invoker = on) AS
SELECT
    c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    a.data_hora,
    a.data_hora::date                                       AS data,
    date_part('year',  a.data_hora)::int                    AS ano,
    date_part('month', a.data_hora)::int                    AS mes,
    to_char(a.data_hora, 'YYYY-MM')                         AS ano_mes,
    coalesce(nullif(a.litros, 0), a.litros_derivado)        AS litros,
    a.litros                                                AS litros_medido,
    a.litros_derivado,
    CASE
        WHEN a.litros > 0                THEN 'medido'
        WHEN a.litros_derivado > 0       THEN 'derivado'
        ELSE 'indefinido'
    END                                                     AS origem_litros,
    a.litros_motor,
    a.distancia_km,
    a.odometro_km,
    a.tanque_litros,
    CASE WHEN a.litros > 5 AND a.distancia_km > 1
         THEN round((a.distancia_km / a.litros)::numeric, 2)
    END                                                     AS km_por_litro,
    CASE WHEN a.litros > 5 AND a.distancia_km > 1 THEN a.distancia_km END
                                                            AS distancia_km_valida,
    CASE WHEN a.litros > 5 AND a.distancia_km > 1 THEN a.litros END
                                                            AS litros_validos,
    limpar_endereco(e.endereco)                             AS end_abastecimento,
    a.latitude,
    a.longitude,
    mo.nome                                                 AS motorista_nome,
    mo.nome_completo                                        AS motorista_nome_completo,
    mo.matricula                                            AS motorista_matricula,
    a.tipo_combustivel,
    a.confianca,
    c.marca_padrao,
    c.modelo_padrao
  FROM (SELECT ab.*, coalesce(nullif(ab.litros, 0), ab.litros_derivado) AS litros_ok
          FROM tb_abastecimento ab) a
  JOIN vw_semad_cadastro c ON c.id = a.device_id
  LEFT JOIN tb_motoristas mo ON mo.id = a.motorista_id
  LEFT JOIN tb_enderecos  e  ON e.lat = round(a.latitude::numeric, 3)
                            AND e.lon = round(a.longitude::numeric, 3);

COMMIT;
