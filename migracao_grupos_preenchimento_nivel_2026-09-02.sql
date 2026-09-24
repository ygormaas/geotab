-- ============================================================================
-- MIGRACAO 2026-09-02 (parte 2) — PADRAO DE PREENCHIMENTO DAS COLUNAS DE NIVEL
--
-- REGRA DO USUARIO (2026-09-02): "se em `todos_grupos` da p/ ver a informacao
--   daquele nivel, a coluna daquele nivel TEM que estar preenchida com a sua
--   respectiva informacao". Vale p/ sup, reg e ulot, sempre.
--
-- CASO QUE GEROU A REGRA:
--   todos_grupos = REG_G0084 - GERENCIA DE ARRECADACAO | ULOT_G0084 - GERENCIA
--                  DE ARRECADACAO
--   Resultado ANTES desta migracao: reg = G0084, ulot = VAZIO.
--   Motivo: token_nivel() escolhia o token pelo NIVEL DO CODIGO. Os dois tokens
--   tem codigo G0084 (= gerencia = nivel 'reg'), entao nenhum sobrava p/ 'ulot'
--   e a coluna ficava nula. O usuario quer os DOIS preenchidos: o texto mostra
--   a informacao de lotacao, logo a coluna de lotacao deve exibi-la.
--
-- MUDANCA: token_nivel() ganha um FALLBACK POR PREFIXO.
--   1o) o token cujo CODIGO pertence ao nivel  (mantem a promocao correta:
--       ULOT_G0087 - GERENCIA... continua indo p/ a coluna de REGIONAL);
--   2o) se nao houver nenhum, o token cujo PREFIXO declara o nivel
--       (ULOT_ -> lotacao, REG_ -> regional, SUP_ -> superintendencia).
--   Assim a coluna so fica vazia quando NAO EXISTE token daquele nivel.
--
-- EFEITO MEDIDO (793 grupos, view SANEAGO):
--   coluna vazia -> preenchida:  ulot 160 grupos (210 veiculos)
--                                reg   38 grupos ( 23 veiculos)
--                                sup    1 grupo
--   sem_ulot 186 -> 26 | sem_reg 96 -> 58 | sem_sup 55 -> 54
--   Nenhuma coluna JA preenchida muda de valor. Nenhuma linha da dimensao
--   aparece ou some (a chave `todos_grupos` nao e' tocada — 793 continua 793).
--   sup_oficial()/tb_hierarquia_grupo seguem envolvendo o resultado, entao a
--   correcao do caso Palmeiras (G0155 -> S0071, e nao S0062) esta preservada.
--
-- CONSEQUENCIA A CONFERIR (era o sintoma reportado em 2026-08-26):
--   34 grupos passam a exibir codigo de superintendencia/diretoria na coluna
--   REGIONAL e 29 na coluna LOTACAO — sao os casos em que a Geotab cadastrou a
--   mesma unidade nos tres campos (ex.: REG_S0021 | ULOT_S0021 | SUP_S0021).
--   Pela regra nova isso e' o esperado: existe token REG_, logo a coluna
--   regional o exibe. Se algum desses precisar ficar vazio, tratar caso a caso.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.token_nivel(p_todos text, p_nivel text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    -- 1) token cujo CODIGO pertence a este nivel (desempate: prefixo concordante)
    (SELECT btrim(tok)
       FROM unnest(string_to_array(p_todos, '|')) AS tok
      WHERE btrim(tok) <> ''
        AND public.nivel_grupo(btrim(tok)) = p_nivel
      ORDER BY CASE WHEN public.nivel_prefixo(btrim(tok)) = p_nivel THEN 0 ELSE 1 END,
               btrim(tok)
      LIMIT 1),
    -- 2) fallback: token cujo PREFIXO declara este nivel
    (SELECT btrim(tok)
       FROM unnest(string_to_array(p_todos, '|')) AS tok
      WHERE btrim(tok) <> ''
        AND public.nivel_prefixo(btrim(tok)) = p_nivel
      ORDER BY btrim(tok)
      LIMIT 1));
$function$
;

COMMIT;

-- ------------------------------------------------------------------
-- VERIFICACAO
-- ------------------------------------------------------------------
-- O caso G0084 deve sair com reg E ulot preenchidos:
-- SELECT todos_grupos, sup_cod_nome, reg_cod_nome, ulot_cod_nome
--   FROM vw_saneago_grupos WHERE todos_grupos LIKE '%G0084%';
--
-- Contagem de colunas vazias (esperado 54 / 58 / 26):
-- SELECT count(*) FILTER (WHERE sup_codigo  IS NULL) sem_sup,
--        count(*) FILTER (WHERE reg_codigo  IS NULL) sem_reg,
--        count(*) FILTER (WHERE ulot_codigo IS NULL) sem_ulot
--   FROM vw_saneago_grupos;
--
-- Palmeiras preservado (deve continuar S0071, nao S0062):
-- SELECT DISTINCT sup_cod_nome FROM vw_saneago_grupos WHERE reg_codigo = 'G0155';

-- ------------------------------------------------------------------
-- ROLLBACK (volta ao comportamento sem fallback)
-- ------------------------------------------------------------------
-- CREATE OR REPLACE FUNCTION public.token_nivel(p_todos text, p_nivel text)
--  RETURNS text LANGUAGE sql STABLE AS $function$
--     SELECT btrim(tok)
--     FROM unnest(string_to_array(p_todos, '|')) AS tok
--     WHERE btrim(tok) <> ''
--       AND public.nivel_grupo(btrim(tok)) = p_nivel
--     ORDER BY CASE WHEN public.nivel_prefixo(btrim(tok)) = p_nivel THEN 0 ELSE 1 END,
--              btrim(tok)
--     LIMIT 1;
-- $function$;
