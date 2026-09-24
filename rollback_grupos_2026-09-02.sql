-- ROLLBACK do estado ANTERIOR a migracao_grupos_nivel_por_codigo_2026-09-02.sql
-- Gerado em 2026-09-02.
BEGIN;
CREATE OR REPLACE FUNCTION public.arrumar_grupos(p_todos text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT NULLIF(string_agg(tok, ' | ' ORDER BY ord), '')
    FROM (
        SELECT btrim(t.tok) AS tok, t.ord
        FROM unnest(string_to_array(p_todos, '|')) WITH ORDINALITY AS t(tok, ord)
    ) s
    WHERE s.tok <> ''
      AND NOT EXISTS (SELECT 1 FROM public.tb_grupo_token_ignorado i WHERE i.token = s.tok);
$function$
;
CREATE OR REPLACE FUNCTION public.split_outros(p_todos text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT NULLIF(string_agg(trim(tok), ' | '), '')
    FROM unnest(string_to_array(p_todos, '|')) AS tok
    WHERE trim(tok) <> ''
      AND trim(tok) NOT LIKE 'OPE\_%'
      AND trim(tok) NOT LIKE 'SUP\_%'
      AND trim(tok) NOT LIKE 'REG\_%'
      AND trim(tok) NOT LIKE 'ULOT\_%'
      AND trim(tok) NOT IN (
          'Vehicle', 'Diesel', 'Ethanol', 'Gasoline or Petrol',
          'Hybrid', 'Electric', 'Manually Classified Powertrain'
      );
$function$
;
CREATE OR REPLACE FUNCTION public.split_grupo(p_todos text, p_prefixo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT trim(tok)
    FROM unnest(string_to_array(p_todos, '|')) AS tok
    WHERE trim(tok) LIKE p_prefixo || '\_%'
    LIMIT 1;
$function$
;
CREATE OR REPLACE VIEW public.vw_saneago_grupos AS
 WITH combos AS (
         SELECT tb_cadastro.todos_grupos
           FROM tb_cadastro
          WHERE tb_cadastro.todos_grupos IS NOT NULL AND grupo_visivel(tb_cadastro.todos_grupos)
        UNION
         SELECT tb_motoristas.todos_grupos
           FROM tb_motoristas
          WHERE tb_motoristas.todos_grupos IS NOT NULL AND grupo_visivel(tb_motoristas.todos_grupos)
        ), base AS (
         SELECT combos.todos_grupos AS orig,
            arrumar_grupos(combos.todos_grupos) AS tg,
            split_grupo(combos.todos_grupos, 'OPE'::text) AS ope_bruto,
            split_outros(combos.todos_grupos) AS outros,
            split_grupo(combos.todos_grupos, 'REG'::text) AS reg_bruto,
            split_grupo(combos.todos_grupos, 'ULOT'::text) AS ulot_bruto,
            sup_oficial(split_grupo(combos.todos_grupos, 'REG'::text), split_grupo(combos.todos_grupos, 'SUP'::text)) AS sup_bruto
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
        ), codigos AS (
         SELECT a.todos_grupos,
            a.todos_grupos_original,
            a.sup_bruto,
            a.reg_bruto,
            a.ulot_bruto,
            a.ope_bruto,
            a.outros,
            grupo_codigo(a.sup_bruto) AS c_sup,
            grupo_codigo(a.reg_bruto) AS c_reg,
            grupo_codigo(a.ulot_bruto) AS c_ulot
           FROM agrupado a
        ), limpo AS (
         SELECT c.todos_grupos,
            c.todos_grupos_original,
            c.sup_bruto,
            c.reg_bruto,
            c.ulot_bruto,
            c.ope_bruto,
            c.outros,
            c.c_sup,
            c.c_reg,
            c.c_ulot,
                CASE
                    WHEN c.c_reg IS NOT NULL AND c.c_reg = c.c_sup THEN NULL::text
                    ELSE c.reg_bruto
                END AS reg_ok,
                CASE
                    WHEN c.c_ulot IS NOT NULL AND (c.c_ulot = c.c_sup OR c.c_ulot = c.c_reg) THEN NULL::text
                    ELSE c.ulot_bruto
                END AS ulot_ok
           FROM codigos c
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
    grupo_codigo(reg_ok) AS reg_codigo,
    grupo_nome(reg_ok) AS reg_nome,
    grupo_cod_nome(reg_ok) AS reg_cod_nome,
    grupo_codigo(ulot_ok) AS ulot_codigo,
    grupo_nome(ulot_ok) AS ulot_nome,
    grupo_cod_nome(ulot_ok) AS ulot_cod_nome,
    outros,
    grupo_nome(outros) AS outros_nome
   FROM limpo
  ORDER BY todos_grupos;
DROP FUNCTION IF EXISTS public.token_nivel(text,text);
DROP FUNCTION IF EXISTS public.nivel_grupo(text);
DROP FUNCTION IF EXISTS public.nivel_prefixo(text);
DROP FUNCTION IF EXISTS public.nivel_ordem(text);
-- tb_grupo_nivel_excecao fica no banco (inofensiva sem as funcoes)
COMMIT;
