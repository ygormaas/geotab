-- 22 funcoes SQL customizadas do projeto, extraidas do Postgres local em 2026-09-22.
-- O geotab_supabase.py NAO as cria: nasceram nos scripts de migracao avulsos.
-- O SQL do sync (tb_odometro_mensal) e as 13 views do views.sql dependem delas.
--
-- ATENCAO: o prefixo "public." foi REMOVIDO de todas as referencias. O
-- pg_get_functiondef() qualifica o corpo com o schema de origem; mantido, isso
-- faria as funcoes lerem o schema public do banco maas_man (sistema de
-- manutencao) em vez do schema geotab. Sem prefixo, quem decide e o search_path.
--
-- check_function_bodies = off: dispensa ordem de dependencia entre as funcoes.

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION arrumar_grupos(p_todos text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT NULLIF(string_agg(s.tok, ' | '
             ORDER BY nivel_ordem(nivel_grupo(s.tok)), s.tok), '')
    FROM (
        SELECT DISTINCT btrim(t.tok) AS tok
        FROM unnest(string_to_array(p_todos, '|')) AS t(tok)
    ) s
    WHERE s.tok <> ''
      AND NOT EXISTS (SELECT 1 FROM tb_grupo_token_ignorado i WHERE i.token = s.tok);
$function$
;

CREATE OR REPLACE FUNCTION arrumar_grupos_semad(p_todos text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT NULLIF(string_agg(s.tok, ' | ' ORDER BY s.ord), '')
    FROM (
        SELECT btrim(t.tok) AS tok, t.ord
        FROM unnest(string_to_array(arrumar_grupos(p_todos), '|'))
             WITH ORDINALITY AS t(tok, ord)
    ) s
    WHERE s.tok <> ''
      AND (
            s.tok !~ '[0-9]+/[0-9]{4}$'
            OR EXISTS (SELECT 1 FROM tb_contrato_semad c WHERE c.token = s.tok)
          );
$function$
;

CREATE OR REPLACE FUNCTION contrato_semad(p_expandido text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT string_agg(DISTINCT c.token, ', ' ORDER BY c.token)
  FROM unnest(string_to_array(COALESCE(p_expandido,''), '|')) AS tok
  JOIN tb_contrato_semad c ON c.token = btrim(tok);
$function$
;

CREATE OR REPLACE FUNCTION faixa_risco_geotab(p_score numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE
        WHEN p_score IS NULL THEN 'Sem base (rodagem insuficiente)'
        WHEN p_score >= 90   THEN 'Baixo risco'
        WHEN p_score >= 75   THEN 'Risco leve'
        WHEN p_score >= 60   THEN 'Risco medio'
        ELSE                      'Alto risco'
    END
$function$
;

CREATE OR REPLACE FUNCTION grupo_cod_nome(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(concat_ws(' - ', grupo_codigo(p), grupo_nome(p)), '');
$function$
;

CREATE OR REPLACE FUNCTION grupo_codigo(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(btrim(COALESCE(
    (regexp_match(COALESCE(p, ''), '^[A-Za-z]+\s*_\s*([^-\s]+)'))[1], '')), '');
$function$
;

CREATE OR REPLACE FUNCTION grupo_nome(p text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT e.nome_exibicao FROM tb_grupo_nome_excecao e
      WHERE e.codigo = grupo_codigo(p)),
    NULLIF(initcap(btrim(COALESCE(
      (regexp_match(COALESCE(p, ''), '^[A-Za-z]+\s*_\s*[^-\s]+\s*-\s*(.*)$'))[1], ''))), ''),
    NULLIF(initcap(btrim(COALESCE(p, ''))), '')
  );
$function$
;

CREATE OR REPLACE FUNCTION grupo_semad(p_todos text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM unnest(string_to_array(COALESCE(p_todos, ''), '|')) AS tok
        JOIN tb_contrato_semad c ON c.token = btrim(tok)
    );
$function$
;

CREATE OR REPLACE FUNCTION grupo_visivel(p_todos text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NOT EXISTS (
    SELECT 1
    FROM unnest(string_to_array(COALESCE(p_todos, ''), '|')) AS tok
    CROSS JOIN (VALUES
      ('OPE_COMURG'),
      ('OPE_SEINFRA'),
      ('OPE_PEDREIRA'),
      ('OPE_CS_BRASIL'),
      ('P-CSB'),
      ('OPE_AGETUL'),
      ('OPE_SMT'),
      ('OPE_SEPLANH'),
      ('OPE_AMMA'),
      ('OPE_SEMAD'),
      ('OPE_SECULT'),
      ('OPE_SECRET. DA ECONOMIA'),
      ('OPE - SERVIÇOS EM CAMPO'),
      ('OPE - ADMINISTRATIVO'),
      ('OPE - ASSISTÊNCIA SOCIAL'),
      ('OPE - RECOLHIMENTO DE ANIMAIS'),
      ('OPE - DIRETORIA/GERÊNCIA'),
      ('OPE - ATERRO SANITÁRIO'),
      ('REDEMOB')
    ) AS ex(prefixo)
    WHERE left(btrim(tok), length(ex.prefixo)) = ex.prefixo
  );
$function$
;

CREATE OR REPLACE FUNCTION limpar_endereco(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(btrim(
           regexp_replace(
             regexp_replace(COALESCE(p, ''), '^[0-9A-Z]{4,}\+[0-9A-Z]+\s*[-,]?\s*', ''),
             '^[0-9]+(-[0-9]+)*\s*[-,]\s*', ''
           )
         ), '');
$function$
;

CREATE OR REPLACE FUNCTION marca_padrao(p_marca text, p_modelo text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT c.marca_ok FROM tb_veiculo_correcao c
      WHERE c.marca_raw  = COALESCE(p_marca, '')
        AND c.modelo_raw = COALESCE(p_modelo, '')),
    NULLIF(btrim(upper(COALESCE(p_marca, ''))), '')
  );
$function$
;

CREATE OR REPLACE FUNCTION modelo_padrao(p_marca text, p_modelo text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT c.modelo_ok FROM tb_veiculo_correcao c
      WHERE c.marca_raw  = COALESCE(p_marca, '')
        AND c.modelo_raw = COALESCE(p_modelo, '')),
    NULLIF(btrim(upper(COALESCE(p_modelo, ''))), '')
  );
$function$
;

CREATE OR REPLACE FUNCTION nivel_grupo(p_token text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT e.nivel FROM tb_grupo_nivel_excecao e
      WHERE e.codigo = grupo_codigo(p_token)),
    CASE
      WHEN btrim(COALESCE(p_token,'')) LIKE 'OPE\_%'     THEN 'ope'
      -- convencao de codigo da SANEAGO
      WHEN grupo_codigo(p_token) ~ '^[SD]'        THEN 'sup'
      WHEN grupo_codigo(p_token) ~ '^G'           THEN 'reg'
      WHEN grupo_codigo(p_token) ~ '^(V|T|C|USE)' THEN 'ulot'
      -- fallback p/ codigos fora da convencao (outros clientes, ex. SEMAD):
      -- volta a usar o prefixo do token, como era antes.
      WHEN btrim(COALESCE(p_token,'')) LIKE 'SUP\_%'     THEN 'sup'
      WHEN btrim(COALESCE(p_token,'')) LIKE 'REG\_%'     THEN 'reg'
      WHEN btrim(COALESCE(p_token,'')) LIKE 'ULOT\_%'    THEN 'ulot'
      ELSE 'outros'
    END);
$function$
;

CREATE OR REPLACE FUNCTION nivel_ordem(p_nivel text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_nivel WHEN 'ope' THEN 1 WHEN 'sup' THEN 2
                      WHEN 'reg' THEN 3 WHEN 'ulot' THEN 4 ELSE 5 END;
$function$
;

CREATE OR REPLACE FUNCTION nivel_prefixo(p_token text)
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

CREATE OR REPLACE FUNCTION nota_regra_geotab(p_qtd bigint, p_km numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- LEAST/GREATEST prendem a nota na escala oficial 0..100 SEM depender da
    -- qualidade do km. Com km >= 0 a expressao ja nao passaria de 100, mas a
    -- garantia fica local: se um dia entrar distancia negativa (correcao de
    -- odometro), a nota continua valida em vez de estourar.
    SELECT LEAST(100::numeric, GREATEST(0::numeric,
        100::numeric - COALESCE(p_qtd, 0)::numeric * 1000.0 / NULLIF(p_km, 0)))
$function$
;

CREATE OR REPLACE FUNCTION saneago_visivel(p_expandido text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT (COALESCE(p_expandido,'') ~ 'OPE_SANEAGO')
     AND (COALESCE(p_expandido,'') !~* 'SEMAD|COMURG|REDEMOB|SECRET\. DA ECONOMIA|OPE_SEINFRA|OPE_PEDREIRA|OPE_AGETUL|OPE_SMT|OPE_SEPLANH|OPE_AMMA|OPE_SECULT|CS_BRASIL|P-CSB');
$function$
;

CREATE OR REPLACE FUNCTION score_geotab(p_km numeric, p_excesso bigint, p_acel bigint, p_fren bigint, p_curva bigint, p_piso_km numeric DEFAULT 200)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN COALESCE(p_km, 0) >= p_piso_km THEN
        round(
              nota_regra_geotab(p_excesso, p_km) * 0.40   -- Speeding
            + nota_regra_geotab(p_acel,    p_km) * 0.20   -- Hard Acceleration
            + nota_regra_geotab(p_fren,    p_km) * 0.20   -- Harsh Braking
            + nota_regra_geotab(p_curva,   p_km) * 0.20   -- Harsh Cornering
        , 1)
    END
$function$
;

CREATE OR REPLACE FUNCTION split_grupo(p_todos text, p_prefixo text)
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

CREATE OR REPLACE FUNCTION split_outros(p_todos text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT NULLIF(string_agg(btrim(tok), ' | ' ORDER BY btrim(tok)), '')
    FROM unnest(string_to_array(p_todos, '|')) AS tok
    WHERE btrim(tok) <> ''
      AND nivel_grupo(btrim(tok)) = 'outros'
      AND btrim(tok) NOT IN (
          'Vehicle', 'Diesel', 'Ethanol', 'Gasoline or Petrol',
          'Hybrid', 'Electric', 'Manually Classified Powertrain'
      );
$function$
;

CREATE OR REPLACE FUNCTION sup_oficial(p_reg text, p_sup text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
           (SELECT h.sup_oficial FROM tb_hierarquia_grupo h WHERE h.reg = btrim(p_reg)),
           p_sup
         );
$function$
;

CREATE OR REPLACE FUNCTION token_nivel(p_todos text, p_nivel text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    -- 1) token cujo CODIGO pertence a este nivel (desempate: prefixo concordante)
    (SELECT btrim(tok)
       FROM unnest(string_to_array(p_todos, '|')) AS tok
      WHERE btrim(tok) <> ''
        AND nivel_grupo(btrim(tok)) = p_nivel
      ORDER BY CASE WHEN nivel_prefixo(btrim(tok)) = p_nivel THEN 0 ELSE 1 END,
               btrim(tok)
      LIMIT 1),
    -- 2) fallback: token cujo PREFIXO declara este nivel
    (SELECT btrim(tok)
       FROM unnest(string_to_array(p_todos, '|')) AS tok
      WHERE btrim(tok) <> ''
        AND nivel_prefixo(btrim(tok)) = p_nivel
      ORDER BY btrim(tok)
      LIMIT 1));
$function$
;
