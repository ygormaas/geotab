-- ============================================================
-- migracao_score_geotab_2026-09-09.sql
-- Score de Comportamento de Motoristas e Veiculos
-- Metodologia Geotab Driver Safety Scorecard, metodo Event Count.
-- Documentacao: guia tecnico v1.0.
--
-- FORMULA OFICIAL (Geotab, white paper "Driver Safety Scorecards"):
--   100 - (Event Rule Event Count x 1000) / Total Driving Distance
--   Calibrada p/ nota 0 com 10 eventos em 100 unidades de distancia
--   -> aplicada em km, a nota zera com 100 eventos / 1.000 km.
--
-- REGRAS E PESOS. Peso = default oficial renormalizado p/ somar 100% (a Geotab
-- define o peso como parametro do cliente). Regras confirmadas no log do sync
-- de 2026-09-09:
--   RulePostedSpeedingId    -> excesso_velocidade   Speeding           20% -> 0.40
--   RuleJackrabbitStartsId  -> aceleracao_brusca    Hard Acceleration  10% -> 0.20
--   RuleHarshBrakingId      -> frenagem_brusca      Harsh Braking      10% -> 0.20
--   RuleHarshCorneringId    -> curva_drastica       Harsh Cornering    10% -> 0.20
--
-- O QUE ESTA MIGRACAO FAZ
--   1-3. Cria as 3 funcoes do calculo.
--   4. vw_saneago_motoristas_anual  + score_geotab, faixa_risco_geotab
--   5. vw_saneago_motoristas        + km_ano, score_geotab_ano, faixa_risco_ano
--   6. vw_saneago_comportamento     + km_ano, score_geotab_ano, faixa_risco_ano
--
-- POR QUE O SUFIXO "_ano" NAS DUAS VIEWS DIARIAS
--   O score so fecha DEPOIS de somar o periodo: por dia o km e baixo e a
--   projecao por 1.000 km vira ruido (1 evento em 8 km ja zera a regra). Nas
--   views diarias a coluna traz o score da ENTIDADE NO ANO, repetido em todas
--   as suas linhas - a coluna fica sempre preenchida e o valor e auditavel pelo
--   km_ano ao lado. O sufixo impede que se leia "score do dia".
--   Para o score de um periodo FILTRADO no painel, use a medida DAX
--   (score_geotab_DAX.md), que recalcula sobre a selecao.
--
-- KM DO VEICULO: vw_saneago_comportamento NAO tem rodagem - "odometro" ali e a
--   LEITURA acumulada do dia, somar da numero absurdo. O km vem de tb_viagens
--   agregado por device_id (mesma janela do ano corrente dos eventos). 1.864
--   dos 1.897 devices com evento tem >= 200 km.
--
-- SEGURANCA: as 3 views nao tem dependentes (verificado em pg_depend) e o
--   CREATE OR REPLACE apenas APENDA colunas no fim, sem renomear nem reordenar
--   as existentes. Sem DROP CASCADE (que ja derrubou uma view por engano).
--
-- Rodar: psql -f migracao_score_geotab_2026-09-09.sql
-- Rollback: no fim do arquivo (comentado).
-- ============================================================

BEGIN;

-- ── 1. Metodo Event Count: nota 0-100 de UMA regra, por 1.000 km ──
--    A escala oficial e 0..100 e a funcao garante isso sozinha: sem o piso, uma
--    regra ruim geraria valor negativo e distorceria o total ponderado.
CREATE OR REPLACE FUNCTION public.nota_regra_geotab(p_qtd bigint, p_km numeric)
RETURNS numeric AS $func$
    -- LEAST/GREATEST prendem a nota na escala oficial 0..100 SEM depender da
    -- qualidade do km. Com km >= 0 a expressao ja nao passaria de 100, mas a
    -- garantia fica local: se um dia entrar distancia negativa (correcao de
    -- odometro), a nota continua valida em vez de estourar.
    SELECT LEAST(100::numeric, GREATEST(0::numeric,
        100::numeric - COALESCE(p_qtd, 0)::numeric * 1000.0 / NULLIF(p_km, 0)))
$func$ LANGUAGE sql IMMUTABLE;

-- ── 2. Score ponderado 0-100. NULL abaixo do piso de rodagem ──
CREATE OR REPLACE FUNCTION public.score_geotab(
    p_km       numeric,
    p_excesso  bigint,
    p_acel     bigint,
    p_fren     bigint,
    p_curva    bigint,
    p_piso_km  numeric DEFAULT 200
) RETURNS numeric AS $func$
    SELECT CASE WHEN COALESCE(p_km, 0) >= p_piso_km THEN
        round(
              nota_regra_geotab(p_excesso, p_km) * 0.40   -- Speeding
            + nota_regra_geotab(p_acel,    p_km) * 0.20   -- Hard Acceleration
            + nota_regra_geotab(p_fren,    p_km) * 0.20   -- Harsh Braking
            + nota_regra_geotab(p_curva,   p_km) * 0.20   -- Harsh Cornering
        , 1)
    END
$func$ LANGUAGE sql IMMUTABLE;

-- ── 3. Faixas de risco ──
--    Limiares default da Geotab (Low 90-100, Mild 75-90, Medium 60-75,
--    High 0-60), com as bordas fechadas - a doc oficial as sobrepoe.
CREATE OR REPLACE FUNCTION public.faixa_risco_geotab(p_score numeric)
RETURNS text AS $func$
    SELECT CASE
        WHEN p_score IS NULL THEN 'Sem base (rodagem insuficiente)'
        WHEN p_score >= 90   THEN 'Baixo risco'
        WHEN p_score >= 75   THEN 'Risco leve'
        WHEN p_score >= 60   THEN 'Risco medio'
        ELSE                      'Alto risco'
    END
$func$ LANGUAGE sql IMMUTABLE;

-- ============================================================
-- 4. vw_saneago_motoristas_anual   (grao = motorista/ano)
--    + score_geotab, faixa_risco_geotab
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
SELECT x.*, faixa_risco_geotab(x.score_geotab) AS faixa_risco_geotab
  FROM (SELECT base.*,
               score_geotab(base.km_total,
                            base.excesso_velocidade,
                            base.aceleracao_brusca,
                            base.frenagem_brusca,
                            base.curva_drastica) AS score_geotab
          FROM base) x;

-- ============================================================
-- 5. vw_saneago_motoristas   (grao = motorista/dia)
--    + km_ano, score_geotab_ano, faixa_risco_ano
--    Score do MOTORISTA NO ANO, repetido em cada linha diaria.
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_motoristas AS
WITH base AS (
 WITH viagens_dia AS (
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
    arrumar_grupos(m.todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos(m.todos_grupos)) AS grupo_id,
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
    COALESCE(ed.excessos_velocidade, 0::bigint) * 3 + COALESCE(ed.aceleracoes_bruscas, 0::bigint) * 2 + COALESCE(ed.frenagens_bruscas, 0::bigint) * 2 + COALESCE(ed.curvas_drasticas, 0::bigint) * 1 AS score_risco,
    COALESCE(vd.motorista_id, ed.motorista_id) AS _mid
   FROM viagens_dia vd
     FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
     LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id)
  WHERE grupo_visivel(m.todos_grupos)
), km_mot AS (
    -- km do ano por motorista, direto de tb_viagens (mesmo filtro do CTE
    -- viagens_dia acima). NAO agrega o CTE base: isso obrigaria a reavaliar o
    -- FULL JOIN + string_agg das placas uma segunda vez.
    SELECT v.motorista_id,
           round(sum(v.distancia_km)::numeric, 1) AS km_ano
      FROM tb_viagens v
     WHERE v.motorista_id <> ''::text
       AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
     GROUP BY v.motorista_id
), ev_mot AS (
    SELECT motorista_id,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'excesso_velocidade'::text), 0)::bigint AS e,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'aceleracao_brusca'::text),  0)::bigint AS a,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'frenagem_brusca'::text),    0)::bigint AS f,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'curva_drastica'::text),     0)::bigint AS c
      FROM tb_comportamento_motorista
     GROUP BY motorista_id
)
SELECT x.motorista_nome, x.motorista_nome_completo, x.motorista_matricula, x.todos_grupos,
       x.grupo_id, x.data, x.ano, x.mes,
       x.qtd_veiculos, x.veiculos, x.viagens, x.km,
       x.horas_movimento, x.horas_ocioso, x.horas_parado, x.excessos_velocidade,
       x.aceleracoes_bruscas, x.frenagens_bruscas, x.curvas_drasticas, x.total_eventos,
       x.score_risco,
       x.km_ano, x.score_geotab_ano,
       faixa_risco_geotab(x.score_geotab_ano) AS faixa_risco_ano
  FROM (SELECT b.*, k.km_ano,
               score_geotab(k.km_ano, e.e, e.a, e.f, e.c) AS score_geotab_ano
          FROM base b
          LEFT JOIN km_mot k ON k.motorista_id = b._mid
          LEFT JOIN ev_mot e ON e.motorista_id = b._mid) x;

-- ============================================================
-- 6. vw_saneago_comportamento   (grao = veiculo/dia)
--    + km_ano, score_geotab_ano, faixa_risco_ano
--    Score do VEICULO NO ANO, repetido em cada linha diaria.
--    km_ano vem de tb_viagens - o "odometro" da view e leitura acumulada.
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_comportamento AS
WITH base AS (
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
     JOIN vw_saneago_cadastro c ON c.id = e.device_id
     LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
  GROUP BY e.device_id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id, e.dia, o.odometro, o.odometro_gps
), kmv AS (
    SELECT device_id, round(sum(distancia_km)::numeric, 1) AS km_ano
      FROM tb_viagens
     GROUP BY device_id
), ev_dev AS (
    -- eventos do ano por device, direto dos buckets. Nao agrega o CTE base
    -- (evita reavaliar o JOIN com vw_saneago_cadastro). O filtro de grupo da
    -- view exclui o DEVICE inteiro, nunca dias isolados, entao o total por
    -- device visivel e identico.
    SELECT device_id,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'excesso_velocidade'::text), 0)::bigint AS e,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'aceleracao_brusca'::text),  0)::bigint AS a,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'frenagem_brusca'::text),    0)::bigint AS f,
           COALESCE(sum(qtd) FILTER (WHERE tipo = 'curva_drastica'::text),     0)::bigint AS c
      FROM tb_comportamento_eventos
     GROUP BY device_id
)
SELECT x.id, x.serial, x.placa, x.veiculo,
       x.todos_grupos, x.grupo_id, x.data, x.ano,
       x.mes, x.excessos_velocidade, x.aceleracoes_bruscas, x.frenagens_bruscas,
       x.curvas_drasticas, x.total_eventos, x.score_risco, x.odometro,
       x.odometro_gps,
       x.km_ano, x.score_geotab_ano,
       faixa_risco_geotab(x.score_geotab_ano) AS faixa_risco_ano
  FROM (SELECT b.*, kmv.km_ano,
               score_geotab(kmv.km_ano, e.e, e.a, e.f, e.c) AS score_geotab_ano
          FROM base b
          LEFT JOIN kmv    ON kmv.device_id = b.id
          LEFT JOIN ev_dev e ON e.device_id = b.id) x;

COMMIT;

-- ============================================================
-- CONFERENCIA (rodar depois do COMMIT)
-- ============================================================
-- Caso real documentado (motorista M162183, 1.014 km):
--   SELECT score_geotab(1014, 124, 25, 2, 51);   -- esperado 44.6
--
-- Motorista/ano - distribuicao esperada (2.234 motoristas com >= 200 km):
--   Baixo 59 | Leve 205 | Medio 370 | Alto 1.600 | Sem base 583
--   SELECT faixa_risco_geotab, count(*)
--     FROM vw_saneago_motoristas_anual GROUP BY 1;
--
-- Motorista/dia - coluna SEMPRE preenchida e igual a da view anual:
--   SELECT motorista_matricula, count(*) AS dias, min(km_ano) AS km_ano,
--          min(score_geotab_ano) AS score, min(faixa_risco_ano) AS faixa
--     FROM vw_saneago_motoristas
--    WHERE motorista_matricula = 'M162183'
--    GROUP BY 1;
--
-- Veiculo/dia:
--   SELECT faixa_risco_ano, count(DISTINCT placa) AS veiculos
--     FROM vw_saneago_comportamento GROUP BY 1 ORDER BY 2 DESC;
--
-- Notas por regra (localiza ONDE perdeu ponto):
--   SELECT motorista_matricula, km_total,
--          nota_regra_geotab(excesso_velocidade, km_total) AS nota_velocidade,
--          nota_regra_geotab(aceleracao_brusca,  km_total) AS nota_aceleracao,
--          nota_regra_geotab(frenagem_brusca,    km_total) AS nota_frenagem,
--          nota_regra_geotab(curva_drastica,     km_total) AS nota_curva,
--          score_geotab, faixa_risco_geotab
--     FROM vw_saneago_motoristas_anual
--    WHERE score_geotab IS NOT NULL
--    ORDER BY score_geotab LIMIT 20;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- CREATE OR REPLACE VIEW nao remove coluna: voltar exige DROP + recriar a
-- partir de views.sql. As 3 views nao tem dependentes (conferir antes).
-- BEGIN;
--   DROP VIEW IF EXISTS vw_saneago_comportamento;
--   DROP VIEW IF EXISTS vw_saneago_motoristas;
--   DROP VIEW IF EXISTS vw_saneago_motoristas_anual;
--   -- recolar de views.sql: linhas 411-433, 580-631 e 636-687
--   DROP FUNCTION IF EXISTS public.faixa_risco_geotab(numeric);
--   DROP FUNCTION IF EXISTS public.score_geotab(numeric,bigint,bigint,bigint,bigint,numeric);
--   DROP FUNCTION IF EXISTS public.nota_regra_geotab(bigint,numeric);
-- COMMIT;
