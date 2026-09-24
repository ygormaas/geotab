-- ============================================================
-- SANEAGO: separacao de cliente robusta a hierarquia (2026-09-14)
-- ============================================================
-- CONTEXTO: o restructuring de grupos no Geotab (SEMAD/COMURG/ECONOMIA viraram
-- hierarquias contrato->secretaria) fez os veiculos de outros clientes perderem o
-- token OPE_<cliente> na FOLHA. grupo_visivel() exclui por OPE_COMURG/OPE_SEMAD...
-- (prefixo na folha) -> deixou de reconhece-los -> VAZARAM p/ o painel SANEAGO
-- (1062 reais -> 1425). Viria na sync diaria de qualquer forma.
--
-- FIX (so no lado VEICULO): saneago_visivel(expandido) = tem OPE_SANEAGO E nenhum
-- marcador de outro cliente, avaliado sobre tb_cadastro.todos_grupos_expandido
-- (folha + ancestrais, coluna nova). Da EXATAMENTE 1062 (a frota de antes).
--   - grupo_id NAO muda: so o WHERE troca; o SELECT segue lendo a FOLHA todos_grupos
--     (hierarquia SUP_/REG_/ULOT_ intacta).
--   - MOTORISTAS: intactos (seguem em grupo_visivel(m.todos_grupos); companyGroups
--     nao foram reestruturados).
--   - Os 333 veiculos DUPLO-MARCADOS (OPE_SANEAGO + outro contrato) ficam de fora
--     ate a marcacao dupla ser resolvida no Geotab.
--
-- Rollback: trocar saneago_visivel(todos_grupos_expandido) de volta p/
--           grupo_visivel(todos_grupos) nas 2 views; DROP FUNCTION saneago_visivel.
-- ============================================================

CREATE OR REPLACE FUNCTION saneago_visivel(p_expandido text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
  SELECT (COALESCE(p_expandido,'') ~ 'OPE_SANEAGO')
     AND (COALESCE(p_expandido,'') !~* 'SEMAD|COMURG|REDEMOB|SECRET\. DA ECONOMIA|OPE_SEINFRA|OPE_PEDREIRA|OPE_AGETUL|OPE_SMT|OPE_SEPLANH|OPE_AMMA|OPE_SECULT|CS_BRASIL|P-CSB');
$fn$;

CREATE OR REPLACE VIEW vw_saneago_cadastro AS
 SELECT id,
    serial,
    placa,
    concat_ws(' | '::text, placa, marca_padrao(marca, modelo), modelo_padrao(marca, modelo)) AS veiculo,
    marca,
    modelo,
    ano,
    tipo_veiculo,
    arrumar_grupos(todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos(todos_grupos)) AS grupo_id,
    ativo,
    atualizado_em,
    marca_padrao(marca, modelo) AS marca_padrao,
    modelo_padrao(marca, modelo) AS modelo_padrao
   FROM tb_cadastro c
  WHERE saneago_visivel(todos_grupos_expandido) AND (placa <> ALL (ARRAY['TFA2G98'::text, 'TFN3B44'::text, 'TFR4E14'::text]));
;

CREATE OR REPLACE VIEW vw_saneago_grupos AS
 WITH combos AS (
         SELECT tb_cadastro.todos_grupos
           FROM tb_cadastro
          WHERE tb_cadastro.todos_grupos_expandido IS NOT NULL AND saneago_visivel(tb_cadastro.todos_grupos_expandido)
        UNION
         SELECT tb_motoristas.todos_grupos
           FROM tb_motoristas
          WHERE tb_motoristas.todos_grupos IS NOT NULL AND grupo_visivel(tb_motoristas.todos_grupos)
        ), base AS (
         SELECT combos.todos_grupos AS orig,
            arrumar_grupos(combos.todos_grupos) AS tg,
            token_nivel(combos.todos_grupos, 'ope'::text) AS ope_bruto,
            split_outros(combos.todos_grupos) AS outros,
            token_nivel(combos.todos_grupos, 'reg'::text) AS reg_bruto,
            token_nivel(combos.todos_grupos, 'ulot'::text) AS ulot_bruto,
            sup_oficial(token_nivel(combos.todos_grupos, 'reg'::text), token_nivel(combos.todos_grupos, 'sup'::text)) AS sup_bruto
           FROM combos
        ), agrupado AS (
         SELECT base.tg AS todos_grupos,
            min(base.orig) AS todos_grupos_original,
            min(base.sup_bruto) AS sup_bruto,
            min(base.reg_bruto) AS reg_bruto,
            min(base.ulot_bruto) AS ulot_bruto,
            min(base.ope_bruto) AS ope_bruto,
            min(base.outros) AS outros
           FROM base
          WHERE base.tg IS NOT NULL
          GROUP BY base.tg
        )
 SELECT hashtext(todos_grupos) AS grupo_id,
    todos_grupos_original,
    todos_grupos,
    ope_bruto AS operacao,
    grupo_codigo(ope_bruto) AS ope_codigo,
    grupo_nome(ope_bruto) AS ope_nome,
    grupo_cod_nome(ope_bruto) AS ope_cod_nome,
    grupo_codigo(sup_bruto) AS sup_codigo,
    grupo_nome(sup_bruto) AS sup_nome,
    grupo_cod_nome(sup_bruto) AS sup_cod_nome,
    grupo_codigo(reg_bruto) AS reg_codigo,
    grupo_nome(reg_bruto) AS reg_nome,
    grupo_cod_nome(reg_bruto) AS reg_cod_nome,
    grupo_codigo(ulot_bruto) AS ulot_codigo,
    grupo_nome(ulot_bruto) AS ulot_nome,
    grupo_cod_nome(ulot_bruto) AS ulot_cod_nome,
    outros,
    grupo_nome(outros) AS outros_nome
   FROM agrupado
  ORDER BY todos_grupos;
;
