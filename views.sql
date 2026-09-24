-- Views do projeto Geotab (geradas do banco em 2026-09-02)
-- ============================================================================
-- HIERARQUIA DE GRUPOS — nível vem da LETRA DO CÓDIGO (2026-09-02)
--   Substitui a regra de "níveis repetidos" de 2026-08-26 (removida).
--   Ver `migracao_grupos_nivel_por_codigo_2026-09-02.sql` e
--   `VALIDACAO_GRUPOS_2026-09-02.md` (diff completo antes×depois).
--
--   PROBLEMA 1 — FRAGMENTAÇÃO POR ORDEM: arrumar_grupos() preservava a ordem
--     dos tokens vinda da Geotab. O MESMO conjunto de grupos chegava em várias
--     ordens => várias linhas em vw_saneago_grupos e vários grupo_id p/ a MESMA
--     unidade. Ex.: SUP_S0072|REG_G0032|ULOT_G0032 existia em 5 ordens, com os
--     veículos espalhados 3+4+9+6+1. No BI o filtro trazia só uma fatia.
--     1.733 linhas p/ 793 hierarquias reais; 91% dos veículos/motoristas afetados.
--   FIX: arrumar_grupos() ORDENA CANONICAMENTE (ope > sup > reg > ulot > outros,
--     depois alfabética) e deduplica. `todos_grupos`/`grupo_id` viram chave estável.
--
--   PROBLEMA 2 — MESMO CÓDIGO EM NÍVEIS DIFERENTES: o nível vinha do PREFIXO do
--     token (SUP_/REG_/ULOT_), preenchido de forma inconsistente na Geotab.
--     21 códigos apareciam ora como regional, ora como lotação; a regra de
--     "níveis repetidos" então zerava o de baixo — às vezes o único lugar onde a
--     gerência estava (ex. REG_S0088 + ULOT_G0087 => G0087 sumia do filtro).
--   FIX: nivel_grupo() decide pela LETRA DO CÓDIGO (convenção SANEAGO):
--     S/D = superintendência/diretoria | G = gerência (regional) |
--     V/T/C/USE = supervisão/distrito/coordenação/unidade (lotação) |
--     OPE_ = operação/contrato. Fallback no prefixo do token p/ códigos fora da
--     convenção (mantém SEMAD e futuros clientes). Exceções em
--     tb_grupo_nivel_excecao (hoje: T8000 -> reg, G8100 -> ulot).
--     Desempate quando 2 tokens caem no mesmo nível: ganha o de prefixo
--     concordante (nivel_prefixo), depois alfabética. NÃO é aleatório como o
--     split_grupo() antigo (LIMIT 1 sem ORDER BY).
--
--   PADRÃO DE PREENCHIMENTO DAS COLUNAS (regra do usuário, 2026-09-02 parte 2,
--     `migracao_grupos_preenchimento_nivel_2026-09-02.sql`): se `todos_grupos`
--     mostra a informação de um nível, a COLUNA daquele nível TEM que exibi-la.
--     token_nivel() faz COALESCE: (1) token cujo CÓDIGO é do nível; (2) se não
--     houver, token cujo PREFIXO declara o nível. Coluna só fica vazia quando
--     não existe token daquele nível. Ex.: `REG_G0084 | ULOT_G0084` (mesmo
--     código) → reg E ulot exibem G0084; antes ulot ficava nulo.
--     Vazios: sup 55->54, reg 96->58, ulot 186->26. Chave não muda (793 linhas).
--     ✅ CONFIRMADO PELO USUÁRIO (2026-09-02): 34 grupos exibem código de
--     superintendência na coluna REGIONAL e 29 na de LOTAÇÃO (casos
--     `REG_S0021 | ULOT_S0021 | SUP_S0021`, mesma unidade nos 3 campos).
--     ISSO É O CORRETO, NÃO É DEFEITO. Palavras dele: "antes eu estava errado,
--     os nomes se repetem, e às vezes a coluna de regional vai ter o nome da
--     superintendência". A regra de "níveis repetidos" de 2026-08-26 fica
--     REVOGADA PELO PRÓPRIO USUÁRIO. NUNCA voltar a zerar coluna de nível por
--     repetição de código ou de nome.
--
--   RESULTADO: 1.733 -> 793 linhas, 0 colisão de grupo_id, 0 órfão,
--     0 código em 2 níveis, +20 regionais / +6 lotações / +4 superintendências
--     recuperadas. Perda residual: 3 veículos e 7 motoristas em combos com 2+
--     tokens do mesmo nível (só um cabe na coluna) — texto cru continua em
--     todos_grupos / todos_grupos_original.
--   As RESSALVAS ULOT_S0086 / ULOT_S0090 de 2026-08-26 deixaram de existir:
--     agora vão corretamente p/ a coluna de superintendência.
--
-- MARCA / MODELO — corrigir SÓ erro de escrita, PRESERVANDO modelos distintos.
--   De-para por par (marca, modelo) em `tb_veiculo_correcao` (15 linhas).
--   9 modelos distintos. NÃO colapsar: ARGO / ARGO 1.0 / ARGO DRIVE /
--   ARGO DRIVE 1.0 são versões DIFERENTES. Divergimos de propósito da sugestão
--   da SANEAGO (pág. 4 pedia nomes canônicos) — decisão do usuário.
--   PENDÊNCIA: tb_modelo_canonico segue no banco (obsoleta). DROP trava com
--   refresh do BI ativo — rodar depois.
--
-- REGRA DO USUÁRIO: TODAS as 9 views expõem `todos_grupos` (tratado).
--   NÃO remover de nenhuma. `grupo_id` (int) fica ao lado como chave leve
--   OPCIONAL. 793 grupos -> 793 ids, 0 colisão, 0 órfãos (2026-09-02).
--
-- COLUNAS DE EXIBIÇÃO
--   `veiculo` = concat_ws(' | ', placa, marca_padrao, modelo_padrao), nas 5
--      views que têm placa.
--   `motorista_nome_completo` (3ª col.) em viagens e status — motorista_nome
--      guarda o LOGIN; o nome vem de tb_motoristas via motorista_id (100%).
--
-- PERFORMANCE DA VIAGENS (5,3M linhas / ~2,5 GB)
--   SEM ORDER BY (crítico): custava 88 s p/ ler 200 mil linhas e derrubava a
--   conexão do BI ("Exception while reading from stream"). Depois: 0,77 s.
--   NÃO reintroduzir (idem motoristas). No M: remover Table.AddIndexColumn
--   (bufferiza a tabela toda) e definir CommandTimeout.
--
-- COLUNAS DE GRUPO: só vw_saneago_grupos tem a quebra por nível. UNIÃO de
--   veículos E motoristas (sem os motoristas, 81% ficariam órfãos).
--   ARMADILHA: NUNCA transformar todos_grupos/grupo_id nas tabelas de FATO.
--
-- HISTÓRICO  2026-08-24 rename + grupo_visivel | 2026-08-25 itens_7a9,
--   grupos_tratados, grupos_motoristas, todos_grupos_limpo, grupos_organizados,
--   remove_lotacao, perf_e_compat | 2026-08-26 grupo_id, veiculo_e_motorista,
--   modelo_so_typos, restauro de todos_grupos, niveis_repetidos
--   2026-08-27 views vw_semad_* | 2026-08-31 abastecimento
--   2026-09-02 nivel_por_codigo + ordem canonica (rollback:
--   rollback_grupos_2026-09-02.sql)
--   Backups: views_backup_2026-08-24.sql
-- TABELAS DE APOIO: tb_veiculo_correcao, tb_hierarquia_grupo,
--   tb_grupo_nome_excecao, tb_grupo_token_ignorado, tb_grupo_nivel_excecao
-- ============================================================================

-- ============================================================
-- Funções auxiliares
-- ============================================================
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

-- saneago_visivel (2026-09-14): separacao de cliente ROBUSTA A HIERARQUIA, p/ o
-- lado VEICULO. Apos o restructuring do Geotab (SEMAD/COMURG/ECONOMIA viraram
-- contrato->secretaria), a folha todos_grupos perdeu o token OPE_<cliente> e o
-- grupo_visivel() (exclusao por prefixo na folha) passou a deixar outros clientes
-- VAZAREM p/ a SANEAGO. Aqui usa-se a coluna todos_grupos_expandido (folha +
-- ancestrais): SANEAGO = tem OPE_SANEAGO E nenhum marcador de outro cliente.
-- Da exatamente a frota conhecida (1062). Os motoristas seguem em grupo_visivel()
-- (companyGroups nao foram reestruturados). Ver migracao_saneago_visivel_2026-09-14.sql.
CREATE OR REPLACE FUNCTION saneago_visivel(p_expandido text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT (COALESCE(p_expandido,'') ~ 'OPE_SANEAGO')
     AND (COALESCE(p_expandido,'') !~* 'SEMAD|COMURG|REDEMOB|SECRET\. DA ECONOMIA|OPE_SEINFRA|OPE_PEDREIRA|OPE_AGETUL|OPE_SMT|OPE_SEPLANH|OPE_AMMA|OPE_SECULT|CS_BRASIL|P-CSB');
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

-- nivel_grupo (2026-09-02) — o NIVEL vem da LETRA DO CODIGO, nao do prefixo do
-- token (SUP_/REG_/ULOT_), que a Geotab preenche de forma inconsistente.
-- Convencao SANEAGO: S/D = superintendencia/diretoria, G = gerencia (regional),
-- V/T/C/USE = supervisao/distrito/coordenacao/unidade (lotacao).
-- Fallback no prefixo do token p/ codigos fora da convencao (ex. SEMAD).
-- Excecoes nomeadas em tb_grupo_nivel_excecao.
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
      WHEN grupo_codigo(p_token) ~ '^[SD]'        THEN 'sup'
      WHEN grupo_codigo(p_token) ~ '^G'           THEN 'reg'
      WHEN grupo_codigo(p_token) ~ '^(V|T|C|USE)' THEN 'ulot'
      WHEN btrim(COALESCE(p_token,'')) LIKE 'SUP\_%'     THEN 'sup'
      WHEN btrim(COALESCE(p_token,'')) LIKE 'REG\_%'     THEN 'reg'
      WHEN btrim(COALESCE(p_token,'')) LIKE 'ULOT\_%'    THEN 'ulot'
      ELSE 'outros'
    END);
$function$
;

-- nivel declarado pelo PREFIXO — so criterio de DESEMPATE quando dois tokens
-- caem no mesmo nivel (sem isso SUP_S0062 perdia p/ PRE _ D2000 no alfabetico).
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

CREATE OR REPLACE FUNCTION nivel_ordem(p_nivel text)
 RETURNS int
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_nivel WHEN 'ope' THEN 1 WHEN 'sup' THEN 2
                      WHEN 'reg' THEN 3 WHEN 'ulot' THEN 4 ELSE 5 END;
$function$
;

-- token_nivel (2026-09-02) — substitui split_grupo() nas views: escolhe pelo
-- NIVEL e de forma DETERMINISTICA. split_grupo() segue no banco por compat.
--
-- PADRAO DE PREENCHIMENTO (regra do usuario, 2026-09-02, parte 2):
--   "se em todos_grupos da p/ ver a informacao daquele nivel, a coluna daquele
--    nivel TEM que estar preenchida com a sua respectiva informacao."
--   Por isso o COALESCE: (1) token cujo CODIGO pertence ao nivel — mantem a
--   promocao correta (ULOT_G0087 - GERENCIA... vai p/ a coluna REGIONAL);
--   (2) se nao houver, token cujo PREFIXO declara o nivel. A coluna so fica
--   vazia quando NAO EXISTE token daquele nivel.
--   Caso que gerou a regra: REG_G0084 | ULOT_G0084 (mesmo codigo nos dois) —
--   antes ulot ficava NULO; agora reg E ulot exibem G0084.
--   Ver `migracao_grupos_preenchimento_nivel_2026-09-02.sql`.
CREATE OR REPLACE FUNCTION token_nivel(p_todos text, p_nivel text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT btrim(tok)
       FROM unnest(string_to_array(p_todos, '|')) AS tok
      WHERE btrim(tok) <> ''
        AND nivel_grupo(btrim(tok)) = p_nivel
      ORDER BY CASE WHEN nivel_prefixo(btrim(tok)) = p_nivel THEN 0 ELSE 1 END,
               btrim(tok)
      LIMIT 1),
    (SELECT btrim(tok)
       FROM unnest(string_to_array(p_todos, '|')) AS tok
      WHERE btrim(tok) <> ''
        AND nivel_prefixo(btrim(tok)) = p_nivel
      ORDER BY btrim(tok)
      LIMIT 1));
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

-- arrumar_grupos (2026-09-02) — ORDEM CANONICA (ope > sup > reg > ulot > outros,
-- depois alfabetica) + tokens deduplicados. E a CHAVE do grupo: antes preservava
-- a ordem da Geotab e o mesmo conjunto virava varios grupo_id.
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

CREATE OR REPLACE FUNCTION grupo_cod_nome(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(concat_ws(' - ', grupo_codigo(p), grupo_nome(p)), '');
$function$
;

-- ============================================================
-- vw_saneago_cadastro
-- ============================================================

-- ============================================================
-- combustivel_veiculo(todos_grupos)  -- 2026-09-23
-- ============================================================
-- A Geotab NAO informa o combustivel do abastecimento: FuelUpEvent.productType
-- vem 'Unknown' em 100% dos eventos (ela DEDUZ o abastecimento pela subida do
-- nivel do tanque -- e telemetria, nao extrato de cartao; a FuelTransaction,
-- que traria posto/valor/produto, esta vazia nesta base).
--
-- MAS a Geotab classifica o VEICULO na hierarquia de grupos, sob
-- "Powertrain and Fuel Type" > "Internal Combustion Engine" > Diesel/Ethanol/
-- Gasoline or Petrol. Esses tokens ja estavam em tb_grupo_token_ignorado (o
-- projeto os descartava de proposito, p/ nao poluirem a coluna de grupos).
--
-- LE A COLUNA CRUA tb_cadastro.todos_grupos -- nao o todos_grupos das views, que
-- ja passou por arrumar_grupos() e teve o combustivel removido. O cru cobre 1.914
-- dos 1.988 veiculos; o expandido cobre menos (1.872).
--
-- Etanol + Gasolina no mesmo veiculo -> 'Flex'.
CREATE OR REPLACE FUNCTION combustivel_veiculo(p_todos text)
RETURNS text LANGUAGE sql STABLE AS $fn$
  WITH t AS (
      SELECT DISTINCT CASE btrim(tok)
               WHEN 'Diesel'                 THEN 'Diesel'
               WHEN 'Ethanol'                THEN 'Etanol'
               WHEN 'Gasoline or Petrol'     THEN 'Gasolina'
               WHEN 'Compressed Natural Gas' THEN 'GNV'
               WHEN 'Electric'               THEN 'Eletrico'
               WHEN 'Hybrid'                 THEN 'Hibrido'
             END AS c
        FROM unnest(string_to_array(COALESCE(p_todos, ''), '|')) AS tok
  ), f AS (SELECT array_agg(c ORDER BY c) AS cs FROM t WHERE c IS NOT NULL)
  SELECT CASE
           WHEN cs IS NULL THEN NULL
           WHEN cs @> ARRAY['Etanol','Gasolina'] THEN 'Flex'
           ELSE array_to_string(cs, ' | ')
         END
    FROM f;
$fn$;

-- ============================================================
-- vw_placa_resolvida  -- 2026-09-24
-- ============================================================
-- Resolve PLACAS DUPLICADAS: a mesma placa aparece em mais de um device_id
-- quando o rastreador do veiculo e trocado -- o registro antigo fica com o
-- historico e o novo segue rodando. Sao 8 pares hoje. No Power BI isso quebra
-- o relacionamento um-para-muitos de uma dimensao de veiculo.
--
-- REGRA (definida pelo usuario em 2026-09-24):
--   * TROCA DE DEVICE (os dois lados tem viagem) -> o device ATUAL (mais ativo)
--     mantem a placa LIMPA; o device ANTIGO recebe o sufixo " -OFF".
--     Ex.: "RGB1293" (atual) e "RGB1293 -OFF" (o que saiu).
--     Se um dia houver 3+ devices na mesma placa, o terceiro em diante vira
--     " -OFF 2", " -OFF 3"... so para nao voltar a duplicar. Hoje sao todos pares.
--   * LINHA FANTASMA (o outro lado tem ZERO viagem) -> `ocultar` = true, e as
--     views de cadastro a descartam. Como nao ha fato ligado a esse device_id,
--     nada se perde e a placa volta a ter UMA linha.
--
-- ORDENACAO: tem_viagem DESC, depois ultimo_contato DESC. Confere nos 8 pares.
-- O EXISTS sobre tb_viagens so roda para as placas DUPLICADAS (16 linhas), via
-- ix_viagens_device -- a view inteira custa 0,01s.
--
-- NAO da p/ corrigir isto na tabela: o sync faz upsert de tb_cadastro pela API
-- todo dia e sobrescreveria qualquer UPDATE em placa.
CREATE OR REPLACE VIEW vw_placa_resolvida AS
WITH base AS (
    -- Tira um " -OFF" que a propria tabela ja carregue: desde 2026-09-24 o sync
    -- grava o sufixo em tb_cadastro. Sem esta normalizacao a view deixaria de
    -- ver o par como duplicado e PARARIA de ocultar as linhas fantasma.
    -- Efeito colateral bom: a view fica idempotente -- da o mesmo resultado com
    -- a tabela crua ou ja resolvida.
    SELECT c.id,
           regexp_replace(btrim(c.placa), '\s*-OFF( \d+)?$', '') AS placa
      FROM tb_cadastro c
), dup AS (
    SELECT placa FROM base WHERE placa <> '' GROUP BY 1 HAVING count(*) > 1
), marcado AS (
    SELECT b.id, b.placa,
           EXISTS (SELECT 1 FROM tb_viagens v WHERE v.device_id = b.id) AS tem_viagem,
           s.ultimo_contato
      FROM base b
      JOIN dup d ON d.placa = b.placa
      LEFT JOIN tb_status s ON s.id = b.id
), ordenado AS (
    SELECT m.*, row_number() OVER (PARTITION BY m.placa
             ORDER BY m.tem_viagem DESC, m.ultimo_contato DESC NULLS LAST, m.id) AS ord
      FROM marcado m
)
SELECT b.id,
       b.placa AS placa_original,
       CASE WHEN o.ord IS NULL OR o.ord = 1 THEN b.placa
            WHEN o.ord = 2 THEN b.placa || ' -OFF'
            ELSE b.placa || ' -OFF ' || (o.ord - 1) END AS placa,
       COALESCE(o.ord > 1 AND NOT o.tem_viagem, false) AS ocultar
  FROM base b
  LEFT JOIN ordenado o ON o.id = b.id;

-- ============================================================
-- SCORE DE COMPORTAMENTO (padrao Geotab, metodo Event Count) — 2026-09-09
-- migracao_score_geotab_2026-09-09.sql
-- ============================================================

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
$function$;
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
$function$;
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
$function$;
;

-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_cadastro AS
 -- btrim na placa: cinto de seguranca. A origem ja e limpa (o sync faz .strip()
 -- e a migracao de 2026-09-24 limpou o passivo), mas se a Geotab devolver
 -- licensePlate com espaco de novo, o Power BI nao sofre: la "ABC1D23" e
 -- "ABC1D23 " sao valores DISTINTOS e quebram relacionamento por placa.
 SELECT c.id,
    c.serial,
    pr.placa,
    concat_ws(' | '::text, pr.placa, marca_padrao(c.marca, c.modelo), modelo_padrao(c.marca, c.modelo)) AS veiculo,
    c.marca,
    c.modelo,
    c.ano,
    c.tipo_veiculo,
    arrumar_grupos(c.todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos(c.todos_grupos)) AS grupo_id,
    c.ativo,
    c.atualizado_em,
    marca_padrao(c.marca, c.modelo) AS marca_padrao,
    modelo_padrao(c.marca, c.modelo) AS modelo_padrao,
    -- combustivel do VEICULO (classificacao da Geotab). Le a coluna CRUA: o
    -- c.todos_grupos acima ja passou por arrumar_grupos() e perdeu o token.
    -- Fica aqui, e nao so na view de abastecimento, porque e atributo do
    -- veiculo -- assim qualquer view que use a cadastro herda o campo.
    combustivel_veiculo(c.todos_grupos) AS combustivel
   FROM tb_cadastro c
   JOIN vw_placa_resolvida pr ON pr.id = c.id
  WHERE NOT pr.ocultar
    AND saneago_visivel(c.todos_grupos_expandido) AND (c.placa <> ALL (ARRAY['TFA2G98'::text, 'TFN3B44'::text, 'TFR4E14'::text]));
;

-- ============================================================
-- vw_saneago_status
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_status AS
 -- placa vem da CADASTRO (c.placa), nao da tb_status: e la que mora a regra de
 -- placa resolvida (duplicada por troca de rastreador ganha " -OFF"). Usar
 -- s.placa deixava esta view fora da regra (corrigido 2026-09-24).
 SELECT s.id,
    s.serial,
    c.placa,
    c.veiculo,
    s.comunicando,
    s.ultimo_contato,
    s.latitude,
    s.longitude,
    s.velocidade,
    s.ignicao_ligada,
    s.motorista_nome,
    mo.nome_completo AS motorista_nome_completo,
    s.motorista_email,
    s.motorista_tel,
    s.viagem_inicio,
    s.snapshot_em,
    s.viagem_fim,
    c.todos_grupos,
    c.grupo_id
   FROM tb_status s
     JOIN vw_saneago_cadastro c ON c.id = s.id
     LEFT JOIN tb_motoristas mo ON mo.nome = s.motorista_nome;
;

-- ============================================================
-- vw_saneago_comportamento

-- ============================================================
-- FIXA O search_path DE CADA FUNCAO (obrigatorio -- 2026-09-23)
-- ============================================================
-- As funcoes deste arquivo sao agnosticas de schema: resolvem tb_* pelo
-- search_path da sessao. Isso funciona em SELECT normal, mas QUEBRA em
-- CREATE MATERIALIZED VIEW e REFRESH MATERIALIZED VIEW: o PostgreSQL executa
-- os dois com search_path restrito (pg_catalog, pg_temp), por seguranca.
-- Sintoma: "relacao tb_veiculo_correcao nao existe", dentro de marca_padrao.
-- O mesmo vale para indices com expressao que chamem estas funcoes.
--
-- POR QUE ESTE BLOCO FICA AQUI, E NAO NO FIM DO ARQUIVO: ele precisa rodar
-- DEPOIS das funcoes e ANTES da MV. E `CREATE OR REPLACE FUNCTION` DESCARTA
-- as clausulas SET -- entao toda reexecucao do views.sql desfixa as 22 funcoes
-- e precisa refixa-las antes de chegar na MV. Com o bloco no fim, a criacao da
-- MV falhava em toda reexecucao (observado em 2026-09-23).
--
-- current_schema() resolve sozinho o destino: `public` no Postgres local,
-- `geotab` no Cloud SQL. Por isso o arquivo continua servindo aos dois.
DO $fix$
DECLARE r record;
BEGIN
  FOR r IN
      SELECT p.oid::regprocedure AS assinatura
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = current_schema()
         AND p.prokind = 'f'
  LOOP
      EXECUTE format('ALTER FUNCTION %s SET search_path = %I, pg_temp',
                     r.assinatura, current_schema());
  END LOOP;
END
$fix$;

-- ============================================================
-- MATERIALIZADA (2026-09-23): custava 103s no local e NAO RODAVA no Cloud SQL
-- (>300s numa instancia de 1 vCPU; a construcao inicial la levou 383s). O
-- gargalo sao arrumar_grupos()/nivel_grupo() por linha, via vw_saneago_cadastro,
-- e ha agregacao bloqueante -- um LIMIT 200 custava os MESMOS 103s. Depois de
-- materializar: 0,02s no local e 0,19s na nuvem.
--
-- A VIEW virou uma casca sobre a MV, entao NADA a jusante mudou de nome:
-- Power BI, exportar_csv.py e consultas manuais seguem em vw_saneago_comportamento.
--
-- O indice unico em (id, data) e REQUISITO do REFRESH ... CONCURRENTLY, que
-- atualiza sem bloquear leitores. Quem dispara o refresh e o geotab_supabase.py,
-- ao final do modo `comportamento`.
--
-- AO MUDAR A LOGICA ABAIXO: `CREATE MATERIALIZED VIEW IF NOT EXISTS` NAO
-- substitui o corpo de uma MV existente. E preciso:
--     DROP MATERIALIZED VIEW mv_saneago_comportamento CASCADE;
-- e rodar este arquivo de novo (o CASCADE derruba a view-casca, recriada logo
-- abaixo). Sem isso, a alteracao passa despercebida.
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_saneago_comportamento AS
-- WITH cad AS MATERIALIZED -- NAO E ENFEITE, e o que faz esta consulta ser viavel.
-- Sem isso, o planejador inlineia a vw_saneago_cadastro dentro do JOIN e reavalia
-- arrumar_grupos()/nivel_grupo()/marca_padrao() UMA VEZ POR LINHA DE SAIDA (139 mil),
-- em vez das 1.061 linhas de cadastro. Medido em 2026-09-23 no banco local:
--   sem MATERIALIZED: 121,1s      com MATERIALIZED: 4,4s      -> 27,6x
-- As linhas de saida sao identicas (139.694 nos dois casos).
WITH cad AS MATERIALIZED (SELECT * FROM vw_saneago_cadastro)
 SELECT e.device_id AS id,
    c.serial,
    c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    e.dia AS data,
    EXTRACT(year FROM e.dia)::integer AS ano,
    EXTRACT(month FROM e.dia)::integer AS mes,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'::text), 0::bigint) AS excessos_velocidade,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracoes_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagens_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'::text), 0::bigint) AS curvas_drasticas,
    COALESCE(sum(e.qtd), 0::bigint) AS total_eventos,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'::text), 0::bigint) * 3 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'::text), 0::bigint) * 2 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'::text), 0::bigint) * 2 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'::text), 0::bigint) * 1 AS score_risco,
    o.odometro,
    o.odometro_gps
   FROM tb_comportamento_eventos e
     JOIN cad c ON c.id = e.device_id
     LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
  GROUP BY e.device_id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id, e.dia, o.odometro, o.odometro_gps;

CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_saneago_comportamento
    ON mv_saneago_comportamento (id, data);

CREATE OR REPLACE VIEW vw_saneago_comportamento AS
 SELECT * FROM mv_saneago_comportamento;
;

-- ============================================================
-- vw_saneago_relatorio_viagens
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_relatorio_viagens AS
-- CTE MATERIALIZED (2026-09-23): sem isso o planejador inlineia a vw_saneago_cadastro
-- e reavalia as funcoes de grupo POR LINHA DE SAIDA. Medido no local: 100,5s -> 9,9s (10x) lendo 1 mes com todas as colunas.
WITH cad AS MATERIALIZED (SELECT * FROM vw_saneago_cadastro)

 SELECT c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    v.data_partida,
    v.data_chegada,
    v.duracao_segundos,
    to_char((v.duracao_segundos || ' seconds'::text)::interval, 'HH24:MI'::text) AS duracao_hhmm,
    v.tempo_ocioso_segundos,
    v.duracao_parada_segundos,
    v.distancia_km,
    v.hodometro_inicial,
    v.hodometro_final,
    v.velocidade_media,
    v.velocidade_maxima,
    limpar_endereco(ep.endereco) AS end_partida,
    limpar_endereco(ec.endereco) AS end_chegada,
    v.motorista_nome,
    mo.nome_completo AS motorista_nome_completo,
    v.motorista_matricula,
        CASE
            WHEN v.velocidade_media > 150::double precision THEN 0::double precision
            ELSE v.velocidade_media
        END AS velocidade_media_2,
        CASE
            WHEN v.velocidade_maxima > 200::double precision THEN 0::double precision
            ELSE v.velocidade_maxima
        END AS velo_max_2,
    c.marca_padrao,
    c.modelo_padrao
   FROM tb_viagens v
     JOIN cad c ON c.id = v.device_id
     LEFT JOIN tb_motoristas mo ON mo.id = v.motorista_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3);;
-- ============================================================
-- vw_saneago_resumo_frota_mensal
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_resumo_frota_mensal AS
-- CTE MATERIALIZED (2026-09-23): sem isso o planejador inlineia a vw_saneago_cadastro
-- e reavalia as funcoes de grupo POR LINHA DE SAIDA. Medido no local: 2,0s -> 0,3s (5,8x).
WITH cad AS MATERIALIZED (SELECT * FROM vw_saneago_cadastro),
base AS (
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
             JOIN cad c ON c.id = r.device_id
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
CREATE OR REPLACE VIEW vw_saneago_indicadores_mensal AS
-- CTE MATERIALIZED (2026-09-23): sem isso o planejador inlineia a vw_saneago_cadastro
-- e reavalia as funcoes de grupo POR LINHA DE SAIDA. Medido no local: 2,0s -> 0,3s (6,0x).
WITH cad AS MATERIALIZED (SELECT * FROM vw_saneago_cadastro),
base AS (
         SELECT r.device_id,
            r.ano,
            r.mes,
            r.km,
            r.duracao_segundos,
            r.dias_utilizados,
            c.todos_grupos,
            c.grupo_id,
            LEAST((date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone) + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE) - date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone)::date + 1 AS dias_no_periodo
           FROM tb_resumo_mensal r
             JOIN cad c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        )
 SELECT todos_grupos,
    grupo_id,
    ano,
    mes,
    to_char(make_date(ano, mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
    count(*) AS qtd_veiculos,
    round(sum(km)::numeric, 0) AS km_total,
    round((sum(km) / NULLIF(count(*), 0)::double precision)::numeric, 0) AS media_km_veiculo,
    round(sum(duracao_segundos) / 3600.0, 0) AS tempo_movimento_h,
    round(avg(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo, 0)::numeric * 100::numeric), 0) AS taxa_media_utilizacao_pct
   FROM base
  GROUP BY todos_grupos, grupo_id, ano, mes
  ORDER BY todos_grupos, ano, mes;;
-- ============================================================
-- vw_saneago_motoristas
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_motoristas AS
-- CTE MATERIALIZED (2026-09-23): arrumar_grupos() e grupo_visivel() sao aplicadas
-- a tb_motoristas (5.713 linhas), mas dentro de um JOIN que devolve 182 mil linhas --
-- entao rodavam 182 mil vezes. Pre-calculadas na CTE, rodam 5.713. Medido no local
-- lendo todas as colunas: 43,0s -> 9,7s (4,5x), resultado identico.
-- As outras views de motoristas foram testadas e NAO ganham (algumas pioram):
-- motoristas_mensal 1,2x, motoristas_anual 0,9x, semad_motoristas 1,1x. Nao mexer.
WITH mot AS MATERIALIZED (SELECT *, arrumar_grupos(todos_grupos) AS _grupos,
                           grupo_visivel(todos_grupos) AS _visivel
                      FROM tb_motoristas),
viagens_dia AS (
         SELECT v.motorista_id,
            v.data_partida::date AS dia,
            count(*) AS viagens,
            count(DISTINCT v.device_id) AS qtd_veiculos,
            string_agg(DISTINCT c.placa, ', '::text ORDER BY c.placa) AS veiculos,
            round(sum(v.distancia_km)::numeric, 1) AS km,
            round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
            round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
            round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
           FROM tb_viagens v
             LEFT JOIN tb_cadastro c ON c.id = v.device_id
          WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
          GROUP BY v.motorista_id, (v.data_partida::date)
        ), eventos_dia AS (
         SELECT tb_comportamento_motorista.motorista_id,
            tb_comportamento_motorista.dia,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'excesso_velocidade'::text), 0::bigint) AS excessos_velocidade,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracoes_bruscas,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagens_bruscas,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'curva_drastica'::text), 0::bigint) AS curvas_drasticas,
            COALESCE(sum(tb_comportamento_motorista.qtd), 0::bigint) AS total_eventos
           FROM tb_comportamento_motorista
          GROUP BY tb_comportamento_motorista.motorista_id, tb_comportamento_motorista.dia
        )
 SELECT m.nome AS motorista_nome,
    m.nome_completo AS motorista_nome_completo,
    m.matricula AS motorista_matricula,
    m._grupos AS todos_grupos,
    hashtext(m._grupos) AS grupo_id,
    COALESCE(vd.dia, ed.dia) AS data,
    EXTRACT(year FROM COALESCE(vd.dia, ed.dia))::integer AS ano,
    EXTRACT(month FROM COALESCE(vd.dia, ed.dia))::integer AS mes,
    vd.qtd_veiculos,
    vd.veiculos,
    vd.viagens,
    vd.km,
    vd.horas_movimento,
    vd.horas_ocioso,
    vd.horas_parado,
    COALESCE(ed.excessos_velocidade, 0::bigint) AS excessos_velocidade,
    COALESCE(ed.aceleracoes_bruscas, 0::bigint) AS aceleracoes_bruscas,
    COALESCE(ed.frenagens_bruscas, 0::bigint) AS frenagens_bruscas,
    COALESCE(ed.curvas_drasticas, 0::bigint) AS curvas_drasticas,
    COALESCE(ed.total_eventos, 0::bigint) AS total_eventos,
    COALESCE(ed.excessos_velocidade, 0::bigint) * 3 + COALESCE(ed.aceleracoes_bruscas, 0::bigint) * 2 + COALESCE(ed.frenagens_bruscas, 0::bigint) * 2 + COALESCE(ed.curvas_drasticas, 0::bigint) * 1 AS score_risco
   FROM viagens_dia vd
     FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
     LEFT JOIN mot m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id)
  WHERE m._visivel;;
-- ============================================================
-- vw_saneago_motoristas_anual
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_motoristas_anual AS
 WITH base AS (
         WITH viagens_mot AS (
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
                     LEFT JOIN tb_cadastro c ON c.id = v.device_id
                  WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
                  GROUP BY v.motorista_id
                ), eventos_mot AS (
                 SELECT tb_comportamento_motorista.motorista_id,
                    COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
                    COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracao_brusca,
                    COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagem_brusca,
                    COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'curva_drastica'::text), 0::bigint) AS curva_drastica,
                    COALESCE(sum(tb_comportamento_motorista.qtd), 0::bigint) AS total_eventos
                   FROM tb_comportamento_motorista
                  GROUP BY tb_comportamento_motorista.motorista_id
                )
         SELECT vm.motorista_nome,
            m.nome_completo AS motorista_nome_completo,
            vm.motorista_matricula,
            arrumar_grupos(m.todos_grupos) AS todos_grupos,
            hashtext(arrumar_grupos(m.todos_grupos)) AS grupo_id,
            vm.qtd_veiculos,
            vm.veiculos,
            vm.viagens,
            vm.km_total,
            vm.horas_movimento,
            vm.horas_ocioso,
            vm.horas_parado,
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
             LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id
          WHERE grupo_visivel(m.todos_grupos)
        )
 SELECT motorista_nome,
    motorista_nome_completo,
    motorista_matricula,
    todos_grupos,
    grupo_id,
    qtd_veiculos,
    veiculos,
    viagens,
    km_total,
    horas_movimento,
    horas_ocioso,
    horas_parado,
    excesso_velocidade,
    aceleracao_brusca,
    frenagem_brusca,
    curva_drastica,
    total_eventos,
    score_seguranca,
    score_geotab,
    faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM ( SELECT base.motorista_nome,
            base.motorista_nome_completo,
            base.motorista_matricula,
            base.todos_grupos,
            base.grupo_id,
            base.qtd_veiculos,
            base.veiculos,
            base.viagens,
            base.km_total,
            base.horas_movimento,
            base.horas_ocioso,
            base.horas_parado,
            base.excesso_velocidade,
            base.aceleracao_brusca,
            base.frenagem_brusca,
            base.curva_drastica,
            base.total_eventos,
            base.score_seguranca,
            score_geotab(base.km_total, base.excesso_velocidade, base.aceleracao_brusca, base.frenagem_brusca, base.curva_drastica) AS score_geotab
           FROM base) x;
;

-- ============================================================
-- vw_saneago_veiculos_anual
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_veiculos_anual AS
-- CTE MATERIALIZED (2026-09-23): sem isso o planejador inlineia a vw_saneago_cadastro
-- e reavalia as funcoes de grupo POR LINHA DE SAIDA. Medido no local: 4,8s -> 1,5s (3,1x).
WITH cad AS MATERIALIZED (SELECT * FROM vw_saneago_cadastro),
km_dev AS (
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
 SELECT id,
    serial,
    placa,
    veiculo,
    todos_grupos,
    grupo_id,
    viagens,
    km_ano,
    horas_movimento,
    excesso_velocidade,
    aceleracao_brusca,
    frenagem_brusca,
    curva_drastica,
    total_eventos,
    nota_velocidade,
    nota_aceleracao,
    nota_frenagem,
    nota_curva,
    score_geotab,
    faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM ( SELECT c.id,
            c.serial,
            c.placa,
            c.veiculo,
            c.todos_grupos,
            c.grupo_id,
            k.viagens,
            k.km_ano,
            k.horas_movimento,
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
           FROM cad c
             LEFT JOIN km_dev k ON k.device_id = c.id
             LEFT JOIN ev_dev e ON e.device_id = c.id) x;;
-- ============================================================
-- vw_saneago_grupos
-- ============================================================
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
 -- 2026-09-02: as CTEs `codigos`/`limpo` (regra de "niveis repetidos" de
 -- 2026-08-26, que zerava reg quando reg_codigo = sup_codigo e ulot quando
 -- ulot_codigo = sup/reg) FORAM REMOVIDAS. Com nivel_grupo() um codigo so
 -- pode ocupar um nivel, entao nao existe mais repeticao para zerar.
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

-- ============================================================================
-- 10ª view (2026-08-31) — ABASTECIMENTO. Fonte: tb_abastecimento (FuelUpEvent).
-- É TELEMETRIA, não contabilidade: a Geotab deduz o abastecimento pela subida
-- do nível do tanque + parada da viagem. NÃO há dado financeiro (a entidade
-- FuelTransaction está vazia nesta base — sem integração de cartão).
-- A gêmea do SEMAD (vw_semad_abastecimento) vive em
-- migracao_abastecimento_2026-08-31.sql, junto com o racional completo das
-- decisões (litro coalesced, guarda do km/L, LEFT JOIN de motorista).
-- ============================================================================
CREATE OR REPLACE VIEW vw_saneago_abastecimento
WITH (security_invoker = on) AS
-- CTE MATERIALIZED (2026-09-23): sem isso o planejador inlineia a vw_saneago_cadastro e
-- reavalia as funcoes de grupo POR LINHA DE SAIDA. Medido no local: 10,4s -> 1,1s (9,5x).
WITH cad AS MATERIALIZED (SELECT * FROM vw_saneago_cadastro)
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
    -- LITROS: use esta (o campo cru vem 0 em ~19% dos eventos; o derivado da
    -- Geotab cobre o resto). As duas seguintes são auditoria.
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
    CASE WHEN a.litros_ok > 5 AND a.distancia_km > 1
         THEN round((a.distancia_km / a.litros_ok)::numeric, 2)
    END                                                     AS km_por_litro,
    -- Medida correta do período no BI: SUM(distancia_km_valida)/SUM(litros_validos).
    -- NÃO usar AVERAGE(km_por_litro).
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
    -- tipo_combustivel vem do FuelUpEvent e e SEMPRE 'Unknown' (a Geotab nao
    -- informa). Mantido por compatibilidade; use `combustivel`, abaixo.
    a.tipo_combustivel,
    a.confianca,
    c.marca_padrao,
    c.modelo_padrao,
    c.combustivel
  FROM (SELECT ab.*, coalesce(nullif(ab.litros, 0), ab.litros_derivado) AS litros_ok
          FROM tb_abastecimento ab) a
  JOIN cad c ON c.id = a.device_id
  LEFT JOIN tb_motoristas mo ON mo.id = a.motorista_id
  LEFT JOIN tb_enderecos  e  ON e.lat = round(a.latitude::numeric, 3)
                            AND e.lon = round(a.longitude::numeric, 3);
-- ============================================================
-- vw_saneago_veiculos_mensal   (score Geotab por VEICULO x mes) -- 2026-09-14
--   Espelha vw_saneago_veiculos_anual no grao (device x ano,mes).
--   km de tb_viagens; eventos de tb_comportamento_eventos; piso 200 km (default).
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_veiculos_mensal AS
 SELECT id, serial, placa, veiculo, todos_grupos, grupo_id,
        ano, mes, ano_mes,
        viagens, km_mes, horas_movimento,
        excesso_velocidade, aceleracao_brusca, frenagem_brusca, curva_drastica, total_eventos,
        nota_velocidade, nota_aceleracao, nota_frenagem, nota_curva,
        score_geotab,
        faixa_risco_geotab(score_geotab) AS faixa_risco_geotab
   FROM ( WITH km_dev AS (
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
                        FULL JOIN ev_dev e ON e.device_id = k.device_id AND e.ano = k.ano AND e.mes = k.mes
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
                JOIN vw_saneago_cadastro c ON c.id = g.device_id ) x;
;

-- ============================================================
-- vw_saneago_motoristas_mensal (score Geotab por MOTORISTA x mes) -- 2026-09-14
--   Espelha vw_saneago_motoristas_anual no grao (motorista x ano,mes).
--   km de tb_viagens; eventos de tb_comportamento_motorista; piso 200 km (default).
-- ============================================================
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
   FROM ( WITH viagens_mot AS (
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
                LEFT JOIN eventos_mot em ON em.motorista_id = vm.motorista_id AND em.ano = vm.ano AND em.mes = vm.mes
                LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id
          WHERE grupo_visivel(m.todos_grupos) ) x;
;
