-- ============================================================================
-- MIGRACAO 2026-09-02 — NIVEL DE GRUPO PELO CODIGO (nao pelo prefixo do token)
--                     + ORDEM CANONICA em arrumar_grupos()
--
-- PROBLEMA 1 (fragmentacao por ORDEM):  arrumar_grupos() preservava a ordem
--   original dos tokens vinda da Geotab. O MESMO conjunto de grupos chegava em
--   varias ordens, gerando varias linhas em vw_saneago_grupos e varios
--   grupo_id (hashtext) para a MESMA unidade. Ex.: SUP_S0072|REG_G0032|ULOT_G0032
--   existia em 5 ordens = 5 grupo_id, com 3+4+9+6+1 = 23 veiculos espalhados.
--   No BI, escolher um item do filtro trazia so uma fatia da frota.
--   Medido: 1.733 linhas na dimensao para 793 hierarquias reais (940 duplicadas);
--   967 de 1.063 veiculos e 2.546 de 2.808 motoristas em hierarquias fragmentadas.
--
-- PROBLEMA 2 (mesmo codigo em niveis diferentes): o nivel vinha do PREFIXO do
--   token (SUP_/REG_/ULOT_), que na Geotab e preenchido de forma inconsistente.
--   O MESMO codigo aparecia ora como regional, ora como lotacao (21 codigos),
--   e ai a regra de "niveis repetidos" (2026-08-26) zerava o nivel de baixo —
--   as vezes zerando justamente o unico lugar onde a gerencia estava.
--   Ex.: "REG_S0088 - SUPER. DE COMERCIALIZACAO | ULOT_G0087 - GERENCIA DE
--   FATURAMENTO | SUP_S0088 - ..." -> reg zerado (repetia a sup) e a gerencia
--   G0087 ficou presa na lotacao: o veiculo sumia do filtro de regional.
--
-- SOLUCAO: o nivel passa a vir da LETRA DO CODIGO, que na SANEAGO e o
--   indicador confiavel (evidencia medida na base):
--     S / D     -> superintendencia / diretoria  (S: 1.660 usos como sup, 2 vazados)
--     G         -> gerencia = regional           (G: 1.582 como reg,     25 vazados)
--     V/T/C/USE -> supervisao/distrito/coord/unidade = lotacao
--     OPE_      -> operacao/contrato (mantido pelo prefixo, nao tem codigo)
--   Excecoes nomeadas ficam em tb_grupo_nivel_excecao.
--
-- EFEITO MEDIDO (simulado): 1.733 -> 793 linhas na dimensao, 0 colisao de
--   grupo_id, 0 codigo em mais de um nivel, +142 lotacoes e +31 regionais
--   recuperadas. A regra de "niveis repetidos" fica DESNECESSARIA (um codigo
--   so pode ocupar um nivel por construcao) e sai da view.
--
-- ATENCAO PARA O POWER BI: os valores de `todos_grupos` e de `grupo_id` MUDAM
--   (mesma unidade, texto/hash novo). As duas pontas (fato e dimensao) mudam
--   juntas, entao os relacionamentos continuam validos, mas filtros/bookmarks
--   salvos que citam o texto antigo precisam ser refeitos. Dar refresh completo.
-- ============================================================================

BEGIN;

-- ------------------------------------------------------------------
-- 1) Excecoes de nivel (codigo cuja letra nao reflete o nivel real)
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tb_grupo_nivel_excecao (
    codigo text PRIMARY KEY,
    nivel  text NOT NULL CHECK (nivel IN ('ope','sup','reg','ulot','outros')),
    obs    text
);

INSERT INTO public.tb_grupo_nivel_excecao (codigo, nivel, obs) VALUES
  ('T8000', 'reg',
   'T8000 - GER. NEG. DESEV. M. OPERAC. SIST. AGUAS LINDAS: codigo T (distrito) mas e gerencia; fica acima de G8100/V810x sob a SUP S0060'),
  ('G8100', 'ulot',
   'G8100 - GERENCIA TECNICA DO SAA - SIST. AGUAS LINDAS: codigo G mas sempre aparece como lotacao (sob T8000 ou sob G0149)')
ON CONFLICT (codigo) DO NOTHING;

-- ------------------------------------------------------------------
-- 2) nivel_grupo(token) -> ope | sup | reg | ulot | outros
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nivel_grupo(p_token text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT e.nivel FROM public.tb_grupo_nivel_excecao e
      WHERE e.codigo = public.grupo_codigo(p_token)),
    CASE
      WHEN btrim(COALESCE(p_token,'')) LIKE 'OPE\_%'     THEN 'ope'
      -- convencao de codigo da SANEAGO
      WHEN public.grupo_codigo(p_token) ~ '^[SD]'        THEN 'sup'
      WHEN public.grupo_codigo(p_token) ~ '^G'           THEN 'reg'
      WHEN public.grupo_codigo(p_token) ~ '^(V|T|C|USE)' THEN 'ulot'
      -- fallback p/ codigos fora da convencao (outros clientes, ex. SEMAD):
      -- volta a usar o prefixo do token, como era antes.
      WHEN btrim(COALESCE(p_token,'')) LIKE 'SUP\_%'     THEN 'sup'
      WHEN btrim(COALESCE(p_token,'')) LIKE 'REG\_%'     THEN 'reg'
      WHEN btrim(COALESCE(p_token,'')) LIKE 'ULOT\_%'    THEN 'ulot'
      ELSE 'outros'
    END);
$function$
;

-- nivel que o PREFIXO do token declara (SUP_/REG_/ULOT_/OPE_). Usado so como
-- criterio de DESEMPATE quando dois tokens caem no mesmo nivel: ganha aquele
-- cujo prefixo concorda com o nivel. Sem isso o desempate alfabetico podia
-- descartar o token certo (ex.: SUP_S0062 - SUPER. DE LOGISTICA perdia para
-- PRE_D2000 - PRESIDENCIA, e SUP_S0085 perdia para REG_D6000).
CREATE OR REPLACE FUNCTION public.nivel_prefixo(p_token text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN btrim(COALESCE(p_token,'')) LIKE 'OPE\_%'  THEN 'ope'
    WHEN btrim(COALESCE(p_token,'')) LIKE 'SUP\_%'  THEN 'sup'
    WHEN btrim(COALESCE(p_token,'')) LIKE 'REG\_%'  THEN 'reg'
    WHEN btrim(COALESCE(p_token,'')) LIKE 'ULOT\_%' THEN 'ulot'
    ELSE 'outros'
  END;
$function$
;

-- ordem de exibicao do nivel (usada no ORDER BY do string_agg)
CREATE OR REPLACE FUNCTION public.nivel_ordem(p_nivel text)
 RETURNS int
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_nivel WHEN 'ope' THEN 1 WHEN 'sup' THEN 2
                      WHEN 'reg' THEN 3 WHEN 'ulot' THEN 4 ELSE 5 END;
$function$
;

-- ------------------------------------------------------------------
-- 3) arrumar_grupos() — ORDEM CANONICA (ope > sup > reg > ulot > outros,
--    depois alfabetica) e tokens deduplicados. Chave estavel do grupo.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.arrumar_grupos(p_todos text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT NULLIF(string_agg(s.tok, ' | '
             ORDER BY public.nivel_ordem(public.nivel_grupo(s.tok)), s.tok), '')
    FROM (
        SELECT DISTINCT btrim(t.tok) AS tok
        FROM unnest(string_to_array(p_todos, '|')) AS t(tok)
    ) s
    WHERE s.tok <> ''
      AND NOT EXISTS (SELECT 1 FROM public.tb_grupo_token_ignorado i WHERE i.token = s.tok);
$function$
;

-- ------------------------------------------------------------------
-- 4) token_nivel() — substitui split_grupo(): escolhe o token pelo NIVEL
--    (nao pelo prefixo) e de forma DETERMINISTICA (ORDER BY, nao LIMIT 1 solto).
--    split_grupo() continua no banco por compatibilidade, mas as views param
--    de usa-la.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.token_nivel(p_todos text, p_nivel text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT btrim(tok)
    FROM unnest(string_to_array(p_todos, '|')) AS tok
    WHERE btrim(tok) <> ''
      AND public.nivel_grupo(btrim(tok)) = p_nivel
    ORDER BY CASE WHEN public.nivel_prefixo(btrim(tok)) = p_nivel THEN 0 ELSE 1 END,
             btrim(tok)
    LIMIT 1;
$function$
;

-- ------------------------------------------------------------------
-- 5) split_outros() — passa a usar nivel_grupo() em vez da lista de prefixos
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.split_outros(p_todos text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT NULLIF(string_agg(btrim(tok), ' | ' ORDER BY btrim(tok)), '')
    FROM unnest(string_to_array(p_todos, '|')) AS tok
    WHERE btrim(tok) <> ''
      AND public.nivel_grupo(btrim(tok)) = 'outros'
      AND btrim(tok) NOT IN (
          'Vehicle', 'Diesel', 'Ethanol', 'Gasoline or Petrol',
          'Hybrid', 'Electric', 'Manually Classified Powertrain'
      );
$function$
;

-- ------------------------------------------------------------------
-- 6) vw_saneago_grupos — sem a regra de "niveis repetidos" (virou desnecessaria)
-- ------------------------------------------------------------------
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
            arrumar_grupos(combos.todos_grupos)      AS tg,
            token_nivel(combos.todos_grupos, 'ope')  AS ope_bruto,
            split_outros(combos.todos_grupos)        AS outros,
            token_nivel(combos.todos_grupos, 'reg')  AS reg_bruto,
            token_nivel(combos.todos_grupos, 'ulot') AS ulot_bruto,
            sup_oficial(token_nivel(combos.todos_grupos, 'reg'),
                        token_nivel(combos.todos_grupos, 'sup')) AS sup_bruto
           FROM combos
        ), agrupado AS (
         SELECT base.tg AS todos_grupos,
            min(base.orig)       AS todos_grupos_original,
            min(base.sup_bruto)  AS sup_bruto,
            min(base.reg_bruto)  AS reg_bruto,
            min(base.ulot_bruto) AS ulot_bruto,
            min(base.ope_bruto)  AS ope_bruto,
            min(base.outros)     AS outros
           FROM base
          WHERE base.tg IS NOT NULL
          GROUP BY base.tg
        )
 SELECT hashtext(todos_grupos) AS grupo_id,
    todos_grupos_original,
    todos_grupos,
    ope_bruto AS operacao,
    grupo_codigo(ope_bruto)    AS ope_codigo,
    grupo_nome(ope_bruto)      AS ope_nome,
    grupo_cod_nome(ope_bruto)  AS ope_cod_nome,
    grupo_codigo(sup_bruto)    AS sup_codigo,
    grupo_nome(sup_bruto)      AS sup_nome,
    grupo_cod_nome(sup_bruto)  AS sup_cod_nome,
    grupo_codigo(reg_bruto)    AS reg_codigo,
    grupo_nome(reg_bruto)      AS reg_nome,
    grupo_cod_nome(reg_bruto)  AS reg_cod_nome,
    grupo_codigo(ulot_bruto)   AS ulot_codigo,
    grupo_nome(ulot_bruto)     AS ulot_nome,
    grupo_cod_nome(ulot_bruto) AS ulot_cod_nome,
    outros,
    grupo_nome(outros)         AS outros_nome
   FROM agrupado
  ORDER BY todos_grupos;

COMMIT;

-- ------------------------------------------------------------------
-- VERIFICACAO (rodar depois do COMMIT)
-- ------------------------------------------------------------------
-- 1733 -> 793 linhas, ids == linhas (0 colisao)
-- SELECT count(*) linhas, count(DISTINCT grupo_id) ids FROM vw_saneago_grupos;
--
-- 0 = nenhum codigo em mais de um nivel
-- WITH n AS (SELECT 'sup' lv, sup_codigo cod FROM vw_saneago_grupos WHERE sup_codigo IS NOT NULL
--            UNION ALL SELECT 'reg', reg_codigo FROM vw_saneago_grupos WHERE reg_codigo IS NOT NULL
--            UNION ALL SELECT 'ulot', ulot_codigo FROM vw_saneago_grupos WHERE ulot_codigo IS NOT NULL)
-- SELECT count(*) FROM (SELECT cod FROM n GROUP BY cod HAVING count(DISTINCT lv) > 1) x;
--
-- 0 = nenhum veiculo/motorista orfao da dimensao
-- SELECT count(*) FROM vw_saneago_cadastro c
--  WHERE NOT EXISTS (SELECT 1 FROM vw_saneago_grupos g WHERE g.todos_grupos = c.todos_grupos);
-- SELECT count(*) FROM vw_saneago_motoristas_anual m
--  WHERE NOT EXISTS (SELECT 1 FROM vw_saneago_grupos g WHERE g.todos_grupos = m.todos_grupos);
