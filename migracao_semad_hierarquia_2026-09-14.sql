-- ============================================================
-- SEMAD: filtro por HIERARQUIA de grupos + coluna de contrato (2026-09-14)
-- ============================================================
-- A frota do SEMAD passou a ficar em SUBGRUPOS por secretaria (SMS, SET, AMMA...)
-- sob o grupo-PAI do contrato (SEMAD - 035/2026 / SEMAD - 031/2026). O campo
-- tb_cadastro.todos_grupos (grupos DIRETOS/folha) nao carrega mais o numero do
-- contrato -> o filtro grupo_semad() nao pegava a frota (0 linhas).
--
-- FIX: coluna tb_cadastro.todos_grupos_expandido (folha + TODOS os ancestrais),
-- preenchida no sync (extrair_cadastro). As views SEMAD FILTRAM por ela
-- (grupo_semad(todos_grupos_expandido)); o DISPLAY/grupo_id continua na FOLHA
-- (todos_grupos) -> quebra limpa por secretaria, sem lixo de ancestral de sistema.
-- todos_grupos/grupo_id da SANEAGO: INTOCADOS (coluna separada).
--
-- tb_contrato_semad: tokens = nomes reais dos grupos-pai ('SEMAD - 035/2026',
-- 'SEMAD - 031/2026'). Resultado: 91 veiculos (035=90, 031=1).
--
-- COLUNA 'contrato' (contrato_semad): identifica 035 vs 031 no grao veiculo.
--
-- vw_semad_grupos ENXUTA (2026-09-14, parte 3): so grupo_id, grupo, contrato.
-- As colunas de hierarquia SUP_/REG_/ULOT_/OPE_ eram TODAS vazias no SEMAD
-- (os grupos sao so as secretarias, sem esses prefixos). Ha 2 grupos distintos
-- de nome "SET" (um por contrato) -> a linha SET mostra os 2 contratos.
--
-- Só vw_semad_cadastro e vw_semad_grupos filtram direto; as outras 7 herdam via
-- JOIN vw_semad_cadastro. Rollback: predicados de volta p/ grupo_semad(todos_grupos);
-- DROP FUNCTION contrato_semad; remover a coluna contrato.
-- ============================================================

CREATE OR REPLACE FUNCTION contrato_semad(p_expandido text)
RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT string_agg(DISTINCT c.token, ', ' ORDER BY c.token)
  FROM unnest(string_to_array(COALESCE(p_expandido,''), '|')) AS tok
  JOIN tb_contrato_semad c ON c.token = btrim(tok);
$fn$;

CREATE OR REPLACE VIEW vw_semad_cadastro AS
 SELECT id,
    serial,
    placa,
    concat_ws(' | '::text, placa, marca_padrao(marca, modelo), modelo_padrao(marca, modelo)) AS veiculo,
    marca,
    modelo,
    ano,
    tipo_veiculo,
    arrumar_grupos_semad(todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos_semad(todos_grupos)) AS grupo_id,
    ativo,
    atualizado_em,
    marca_padrao(marca, modelo) AS marca_padrao,
    modelo_padrao(marca, modelo) AS modelo_padrao,
    contrato_semad(todos_grupos_expandido) AS contrato
   FROM tb_cadastro c
  WHERE grupo_semad(todos_grupos_expandido);
;

-- ENXUTA: apenas grupo_id, grupo, contrato (DROP+CREATE remove as colunas vazias).
DROP VIEW IF EXISTS vw_semad_grupos;
CREATE VIEW vw_semad_grupos AS
 WITH combos AS (
   SELECT arrumar_grupos_semad(todos_grupos)          AS grupo,
          contrato_semad(todos_grupos_expandido)      AS contrato
   FROM tb_cadastro
   WHERE todos_grupos_expandido IS NOT NULL AND grupo_semad(todos_grupos_expandido)
 )
 SELECT hashtext(grupo) AS grupo_id,
        grupo,
        string_agg(DISTINCT contrato, ', ' ORDER BY contrato) AS contrato
 FROM combos
 WHERE grupo IS NOT NULL
 GROUP BY grupo;
;
