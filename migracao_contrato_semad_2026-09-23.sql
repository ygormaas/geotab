-- Recria tb_contrato_semad, que sumiu do banco local (e nunca existiu na nuvem).
-- Sintoma: Power BI acusava 42P01 "relacao tb_contrato_semad nao existe" na
-- vw_semad_status. A view sobrevivia sem a tabela porque quem a referencia e a
-- funcao contrato_semad() -- o Postgres nao registra dependencia atraves de
-- funcoes, entao o erro so aparece na execucao.
--
-- TOKENS: os do desenho VIGENTE (migracao_semad_hierarquia_2026-09-14.sql) =
-- nomes reais dos grupos-PAI, SEM o prefixo OPE_. O seed original de
-- migracao_semad_2026-08-27.sql ('OPE_SEMAD - 035/2026') esta OBSOLETO: era de
-- quando o contrato vinha no grupo-folha. Usar o antigo devolve 0 linhas nas
-- views do SEMAD, em silencio.
--
-- Conferencia esperada (documentada no script de 2026-09-14):
--   91 veiculos no total -- 035/2026 = 90, 031/2026 = 1.
--
-- Sem prefixo de schema: quem decide o destino e o search_path da sessao.

CREATE TABLE IF NOT EXISTS tb_contrato_semad (
    token      text PRIMARY KEY,
    observacao text
);

INSERT INTO tb_contrato_semad (token, observacao) VALUES
    ('SEMAD - 035/2026', 'Grupo-pai do contrato 035/2026 (desenho de 2026-09-14)'),
    ('SEMAD - 031/2026', 'Grupo-pai do contrato 031/2026 (desenho de 2026-09-14)')
ON CONFLICT (token) DO NOTHING;
