-- 12 views vw_semad_* extraidas do banco LOCAL em 2026-09-23 (pg_get_viewdef).
-- Aplicadas no schema geotab do Cloud SQL.
--
-- POR QUE NAO REPLICAR OS migracao_semad_*.sql: o script de 2026-08-27 contem o
-- INSERT do token OBSOLETO 'OPE_SEMAD - 035/2026' em tb_contrato_semad. Replicar
-- a cadeia historica inseriria esse token ao lado dos dois corretos. Extrair o
-- estado ATUAL do local evita isso e garante paridade com o que o Power BI ja usa.
--
-- Sem prefixo de schema: quem decide o destino e o search_path da sessao.
-- Ordem de criacao resolvida por tentativa e repeticao (7 das 12 fazem JOIN com
-- vw_semad_cadastro).

-- ORDEM IMPORTA: vw_semad_cadastro vem PRIMEIRO. As demais fazem JOIN com ela,
-- e o arquivo e executado na ordem em que esta escrito -- uma coluna nova na
-- cadastro so existe para as outras se ela for criada antes (2026-09-23).

CREATE OR REPLACE VIEW vw_semad_cadastro AS
 -- btrim na placa: mesmo cinto de seguranca da vw_saneago_cadastro (2026-09-24).
 -- placa resolvida (duplicadas por troca de rastreador ganham " (2)"; linhas
 -- fantasma sao descartadas) -- ver vw_placa_resolvida no views.sql.
 SELECT c.id,
    c.serial,
    pr.placa,
    concat_ws(' | '::text, pr.placa, marca_padrao(marca, modelo), modelo_padrao(marca, modelo)) AS veiculo,
    marca,
    modelo,
    ano,
    tipo_veiculo,
    arrumar_grupos_semad(todos_grupos) AS todos_grupos,
    hashtext((arrumar_grupos_semad(todos_grupos) || '|'::text) || COALESCE(contrato_semad(todos_grupos_expandido), ''::text)) AS grupo_id,
    ativo,
    atualizado_em,
    marca_padrao(marca, modelo) AS marca_padrao,
    modelo_padrao(marca, modelo) AS modelo_padrao,
    contrato_semad(todos_grupos_expandido) AS contrato,
    -- combustivel do VEICULO (classificacao da Geotab, nao o produto abastecido).
    -- Le a coluna CRUA: o todos_grupos acima ja passou por arrumar_grupos_semad()
    -- e perdeu o token. Mesma funcao usada na vw_saneago_cadastro.
    combustivel_veiculo(c.todos_grupos) AS combustivel
   FROM tb_cadastro c
   JOIN vw_placa_resolvida pr ON pr.id = c.id
  WHERE NOT pr.ocultar
    AND grupo_semad(todos_grupos_expandido);

CREATE OR REPLACE VIEW vw_semad_abastecimento AS
 SELECT c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    a.data_hora,
    a.data_hora::date AS data,
    date_part('year'::text, a.data_hora)::integer AS ano,
    date_part('month'::text, a.data_hora)::integer AS mes,
    to_char(a.data_hora, 'YYYY-MM'::text) AS ano_mes,
    COALESCE(NULLIF(a.litros, 0::double precision), a.litros_derivado) AS litros,
    a.litros AS litros_medido,
    a.litros_derivado,
        CASE
            WHEN a.litros > 0::double precision THEN 'medido'::text
            WHEN a.litros_derivado > 0::double precision THEN 'derivado'::text
            ELSE 'indefinido'::text
        END AS origem_litros,
    a.litros_motor,
    a.distancia_km,
    a.odometro_km,
    a.tanque_litros,
        CASE
            WHEN a.litros > 5::double precision AND a.distancia_km > 1::double precision THEN round((a.distancia_km / a.litros)::numeric, 2)
            ELSE NULL::numeric
        END AS km_por_litro,
        CASE
            WHEN a.litros > 5::double precision AND a.distancia_km > 1::double precision THEN a.distancia_km
            ELSE NULL::double precision
        END AS distancia_km_valida,
        CASE
            WHEN a.litros > 5::double precision AND a.distancia_km > 1::double precision THEN a.litros
            ELSE NULL::double precision
        END AS litros_validos,
    limpar_endereco(e.endereco) AS end_abastecimento,
    a.latitude,
    a.longitude,
    mo.nome AS motorista_nome,
    mo.nome_completo AS motorista_nome_completo,
    mo.matricula AS motorista_matricula,
    -- tipo_combustivel vem do FuelUpEvent e e SEMPRE 'Unknown'. Use `combustivel`.
    a.tipo_combustivel,
    a.confianca,
    c.marca_padrao,
    c.modelo_padrao,
    c.combustivel
   FROM ( SELECT ab.device_id,
            ab.data_hora,
            ab.litros,
            ab.litros_derivado,
            ab.litros_motor,
            ab.distancia_km,
            ab.odometro_km,
            ab.tanque_litros,
            ab.latitude,
            ab.longitude,
            ab.motorista_id,
            ab.tipo_combustivel,
            ab.confianca,
            ab.atualizado_em,
            COALESCE(NULLIF(ab.litros, 0::double precision), ab.litros_derivado) AS litros_ok
           FROM tb_abastecimento ab) a
     JOIN vw_semad_cadastro c ON c.id = a.device_id
     LEFT JOIN tb_motoristas mo ON mo.id = a.motorista_id
     LEFT JOIN tb_enderecos e ON e.lat = round(a.latitude::numeric, 3) AND e.lon = round(a.longitude::numeric, 3);

CREATE OR REPLACE VIEW vw_semad_comportamento AS
-- CTE MATERIALIZED (2026-09-23): sem isso o planejador inlineia a vw_semad_cadastro e
-- reavalia as funcoes de grupo POR LINHA DE SAIDA. Medido no local: 1,4s -> 0,1s (13,0x).
WITH cad AS MATERIALIZED (SELECT * FROM vw_semad_cadastro)
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
CREATE OR REPLACE VIEW vw_semad_grupos AS
 WITH combos AS (
         SELECT arrumar_grupos_semad(tb_cadastro.todos_grupos) AS grupo,
            contrato_semad(tb_cadastro.todos_grupos_expandido) AS contrato
           FROM tb_cadastro
          WHERE tb_cadastro.todos_grupos_expandido IS NOT NULL AND grupo_semad(tb_cadastro.todos_grupos_expandido)
        )
 SELECT hashtext((grupo || '|'::text) || COALESCE(contrato, ''::text)) AS grupo_id,
    grupo,
    contrato
   FROM combos
  WHERE grupo IS NOT NULL
  GROUP BY grupo, contrato;

CREATE OR REPLACE VIEW vw_semad_indicadores_mensal AS
 WITH base AS (
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
             JOIN vw_semad_cadastro c ON c.id = r.device_id
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
  ORDER BY todos_grupos, ano, mes;

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
    hashtext((arrumar_grupos_semad(m.todos_grupos) || '|'::text) || COALESCE(contrato_semad(m.todos_grupos), ''::text)) AS grupo_id,
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

CREATE OR REPLACE VIEW vw_semad_motoristas_anual AS
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
   FROM ( SELECT b.motorista_nome,
            b.motorista_nome_completo,
            b.motorista_matricula,
            b.todos_grupos,
            b.grupo_id,
            b.qtd_veiculos,
            b.veiculos,
            b.viagens,
            b.km_total,
            b.horas_movimento,
            b.horas_ocioso,
            b.horas_parado,
            b.excesso_velocidade,
            b.aceleracao_brusca,
            b.frenagem_brusca,
            b.curva_drastica,
            b.total_eventos,
            b.score_seguranca,
            score_geotab(b.km_total, b.excesso_velocidade, b.aceleracao_brusca, b.frenagem_brusca, b.curva_drastica) AS score_geotab
           FROM ( WITH viagens_mot AS (
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
                    hashtext((arrumar_grupos_semad(m.todos_grupos) || '|'::text) || COALESCE(contrato_semad(m.todos_grupos), ''::text)) AS grupo_id,
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
                     LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id) b) x;

CREATE OR REPLACE VIEW vw_semad_relatorio_viagens AS
-- CTE MATERIALIZED (2026-09-23): sem isso o planejador inlineia a vw_semad_cadastro e
-- reavalia as funcoes de grupo POR LINHA DE SAIDA. Medido no local: 28,4s -> 2,1s (13,5x).
WITH cad AS MATERIALIZED (SELECT * FROM vw_semad_cadastro)
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
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3);
CREATE OR REPLACE VIEW vw_semad_resumo_frota_mensal AS
 WITH base AS (
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
             JOIN vw_semad_cadastro c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        ), abast AS (
         SELECT a.device_id,
            date_part('year'::text, a.data_hora)::integer AS ano,
            date_part('month'::text, a.data_hora)::integer AS mes,
            count(*) AS abastecimentos,
            sum(COALESCE(NULLIF(a.litros, 0::double precision), a.litros_derivado)) AS litros
           FROM tb_abastecimento a
          GROUP BY a.device_id, (date_part('year'::text, a.data_hora)::integer), (date_part('month'::text, a.data_hora)::integer)
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
    ab.abastecimentos,
    round(ab.litros::numeric, 1) AS litros_abastecidos,
        CASE
            WHEN round((base.km / NULLIF(ab.litros, 0::double precision))::numeric, 2) >= 1::numeric AND round((base.km / NULLIF(ab.litros, 0::double precision))::numeric, 2) <= 20::numeric THEN round((base.km / NULLIF(ab.litros, 0::double precision))::numeric, 2)
            ELSE NULL::numeric
        END AS km_por_litro
   FROM base
     LEFT JOIN abast ab ON ab.device_id = base.device_id AND ab.ano = base.ano AND ab.mes = base.mes
  ORDER BY base.placa, base.ano, base.mes;

CREATE OR REPLACE VIEW vw_semad_status AS
 -- placa vem da CADASTRO (c.placa), nao da tb_status -- ver vw_saneago_status.
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
     JOIN vw_semad_cadastro c ON c.id = s.id
     LEFT JOIN tb_motoristas mo ON mo.nome = s.motorista_nome;

CREATE OR REPLACE VIEW vw_semad_veiculos_anual AS
 WITH km_dev AS (
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
    contrato,
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
            c.contrato,
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
           FROM vw_semad_cadastro c
             LEFT JOIN km_dev k ON k.device_id = c.id
             LEFT JOIN ev_dev e ON e.device_id = c.id) x;

CREATE OR REPLACE VIEW vw_semad_veiculos_mensal AS
 SELECT id,
    serial,
    placa,
    veiculo,
    todos_grupos,
    grupo_id,
    contrato,
    ano,
    mes,
    ano_mes,
    viagens,
    km_mes,
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
   FROM ( WITH km_dev AS (
                 SELECT tb_viagens.device_id,
                    EXTRACT(year FROM tb_viagens.data_partida)::integer AS ano,
                    EXTRACT(month FROM tb_viagens.data_partida)::integer AS mes,
                    count(*) AS viagens,
                    round(sum(tb_viagens.distancia_km)::numeric, 1) AS km_mes,
                    round(sum(tb_viagens.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento
                   FROM tb_viagens
                  GROUP BY tb_viagens.device_id, (EXTRACT(year FROM tb_viagens.data_partida)), (EXTRACT(month FROM tb_viagens.data_partida))
                ), ev_dev AS (
                 SELECT tb_comportamento_eventos.device_id,
                    EXTRACT(year FROM tb_comportamento_eventos.dia)::integer AS ano,
                    EXTRACT(month FROM tb_comportamento_eventos.dia)::integer AS mes,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracao_brusca,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagem_brusca,
                    COALESCE(sum(tb_comportamento_eventos.qtd) FILTER (WHERE tb_comportamento_eventos.tipo = 'curva_drastica'::text), 0::bigint) AS curva_drastica,
                    COALESCE(sum(tb_comportamento_eventos.qtd), 0::bigint) AS total_eventos
                   FROM tb_comportamento_eventos
                  GROUP BY tb_comportamento_eventos.device_id, (EXTRACT(year FROM tb_comportamento_eventos.dia)), (EXTRACT(month FROM tb_comportamento_eventos.dia))
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
         SELECT c.id,
            c.serial,
            c.placa,
            c.veiculo,
            c.todos_grupos,
            c.grupo_id,
            c.contrato,
            g.ano,
            g.mes,
            to_char(make_date(g.ano, g.mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
            g.viagens,
            g.km_mes,
            g.horas_movimento,
            g.excesso_velocidade,
            g.aceleracao_brusca,
            g.frenagem_brusca,
            g.curva_drastica,
            g.total_eventos,
            round(nota_regra_geotab(g.excesso_velocidade, g.km_mes), 1) AS nota_velocidade,
            round(nota_regra_geotab(g.aceleracao_brusca, g.km_mes), 1) AS nota_aceleracao,
            round(nota_regra_geotab(g.frenagem_brusca, g.km_mes), 1) AS nota_frenagem,
            round(nota_regra_geotab(g.curva_drastica, g.km_mes), 1) AS nota_curva,
            score_geotab(g.km_mes, g.excesso_velocidade, g.aceleracao_brusca, g.frenagem_brusca, g.curva_drastica) AS score_geotab
           FROM grade g
             JOIN vw_semad_cadastro c ON c.id = g.device_id) x;
