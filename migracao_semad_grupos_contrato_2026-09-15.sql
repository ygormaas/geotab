-- ============================================================================
-- SEMAD — coluna de CONTRATOS na dimensão de grupos: 1 LINHA POR grupo×contrato
-- 2026-09-15
-- ============================================================================
-- PEDIDO DO USUÁRIO: no grupo SET, a coluna de contratos deve virar UMA linha
-- para o contrato 031/2026 e OUTRA para o 035/2026 (o SET tem 1 veículo em cada:
-- TGG0G28 -> SEMAD - 031/2026, TFD2H94 -> SEMAD - 035/2026).
--
-- ANTES: vw_semad_grupos agrupava só por `grupo` e fazia string_agg dos
-- contratos -> SET saía em 1 linha com contrato = "SEMAD - 031/2026, SEMAD - 035/2026".
--
-- DEPOIS: agrupa por (grupo, contrato) -> 1 linha por combinação. Qualquer grupo
-- que abranja mais de um contrato passa a ter 1 linha por contrato (hoje só o SET).
--
-- CHAVE grupo_id AGORA É COMPOSTA (grupo + contrato):
--   hashtext(arrumar_grupos_semad(todos_grupos) || '|' || COALESCE(contrato,''))
-- Sem isso, as 2 linhas de SET teriam o mesmo grupo_id e o relacionamento
-- muitos-para-um do Power BI quebraria (o lado "um" tem que ser único).
-- Aplicada na DIMENSÃO e nas 3 views que DEFINEM grupo_id (cadastro, motoristas,
-- motoristas_anual). As demais herdam grupo_id por JOIN.
--
-- IMPACTO POWER BI: o relacionamento fato->vw_semad_grupos[grupo_id] segue válido,
-- mas os VALORES de grupo_id mudam -> filtros/bookmarks salvos com o id antigo no
-- painel do SEMAD precisam ser refeitos. Dar refresh.
--
-- RESSALVA (motoristas): tb_motoristas NÃO tem `todos_grupos_expandido` e as 2
-- views de motoristas do SEMAD estão com 0 linhas. A chave composta usa
-- contrato_semad(m.todos_grupos), que hoje volta vazio (o contrato do motorista
-- não está no texto cru) -> na prática grupo_id = hashtext(grupo || '|' || '').
-- Mantida a fórmula paralela por consistência; sem efeito enquanto houver 0 linhas.
-- CREATE OR REPLACE em todas (lista de colunas idêntica) -> sem DROP, sem lock.
-- ============================================================================

-- 1) DIMENSÃO — 1 linha por grupo×contrato
CREATE OR REPLACE VIEW vw_semad_grupos AS
 WITH combos AS (
         SELECT arrumar_grupos_semad(tb_cadastro.todos_grupos) AS grupo,
            contrato_semad(tb_cadastro.todos_grupos_expandido) AS contrato
           FROM tb_cadastro
          WHERE tb_cadastro.todos_grupos_expandido IS NOT NULL
            AND grupo_semad(tb_cadastro.todos_grupos_expandido)
        )
 SELECT hashtext(grupo || '|' || COALESCE(contrato, ''::text)) AS grupo_id,
    grupo,
    contrato
   FROM combos
  WHERE grupo IS NOT NULL
  GROUP BY grupo, contrato;

-- 2) CADASTRO — grupo_id composto (define a chave usada pela maioria dos fatos)
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
    hashtext(arrumar_grupos_semad(todos_grupos) || '|' || COALESCE(contrato_semad(todos_grupos_expandido), ''::text)) AS grupo_id,
    ativo,
    atualizado_em,
    marca_padrao(marca, modelo) AS marca_padrao,
    modelo_padrao(marca, modelo) AS modelo_padrao,
    contrato_semad(todos_grupos_expandido) AS contrato
   FROM tb_cadastro c
  WHERE grupo_semad(todos_grupos_expandido);

-- 3) MOTORISTAS (diária) — grupo_id composto (fórmula paralela; 0 linhas hoje)
CREATE OR REPLACE VIEW vw_semad_motoristas AS
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
             JOIN vw_semad_cadastro c ON c.id = v.device_id
          WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
          GROUP BY v.motorista_id, (v.data_partida::date)
        ), eventos_dia AS (
         SELECT cm.motorista_id,
            cm.dia,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'excesso_velocidade'::text), 0::bigint) AS excessos_velocidade,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracoes_bruscas,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagens_bruscas,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'curva_drastica'::text), 0::bigint) AS curvas_drasticas,
            COALESCE(sum(cm.qtd), 0::bigint) AS total_eventos
           FROM tb_comportamento_motorista cm
             JOIN vw_semad_cadastro c ON c.id = cm.device_id
          GROUP BY cm.motorista_id, cm.dia
        )
 SELECT m.nome AS motorista_nome,
    m.nome_completo AS motorista_nome_completo,
    m.matricula AS motorista_matricula,
    arrumar_grupos_semad(m.todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos_semad(m.todos_grupos) || '|' || COALESCE(contrato_semad(m.todos_grupos), ''::text)) AS grupo_id,
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
     LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id);

-- 4) MOTORISTAS (anual) — grupo_id composto (fórmula paralela; 0 linhas hoje)
CREATE OR REPLACE VIEW vw_semad_motoristas_anual AS
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
             JOIN vw_semad_cadastro c ON c.id = v.device_id
          WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
          GROUP BY v.motorista_id
        ), eventos_mot AS (
         SELECT cm.motorista_id,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracao_brusca,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagem_brusca,
            COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'curva_drastica'::text), 0::bigint) AS curva_drastica,
            COALESCE(sum(cm.qtd), 0::bigint) AS total_eventos
           FROM tb_comportamento_motorista cm
             JOIN vw_semad_cadastro c ON c.id = cm.device_id
          GROUP BY cm.motorista_id
        )
 SELECT vm.motorista_nome,
    m.nome_completo AS motorista_nome_completo,
    vm.motorista_matricula,
    arrumar_grupos_semad(m.todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos_semad(m.todos_grupos) || '|' || COALESCE(contrato_semad(m.todos_grupos), ''::text)) AS grupo_id,
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
     LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id;
