-- Tabelas auxiliares (de apoio/excecao) que o geotab_supabase.py NAO cria.
-- Elas nasceram em scripts de migracao avulsos, mas as 13 views do views.sql
-- dependem das 5 -- sem elas o views.sql quebra.
-- Nomes sem prefixo de schema: quem decide o destino e o search_path da sessao.
-- DDL extraido do Postgres local em 2026-09-22 (pg_dump --schema-only).

CREATE TABLE IF NOT EXISTS tb_grupo_nivel_excecao (
    codigo text NOT NULL,
    nivel  text NOT NULL,
    obs    text,
    CONSTRAINT tb_grupo_nivel_excecao_pkey PRIMARY KEY (codigo),
    CONSTRAINT tb_grupo_nivel_excecao_nivel_check
        CHECK (nivel = ANY (ARRAY['ope'::text, 'sup'::text, 'reg'::text, 'ulot'::text, 'outros'::text]))
);

CREATE TABLE IF NOT EXISTS tb_grupo_nome_excecao (
    codigo        text NOT NULL,
    nome_exibicao text NOT NULL,
    obs           text,
    CONSTRAINT tb_grupo_nome_excecao_pkey PRIMARY KEY (codigo)
);

CREATE TABLE IF NOT EXISTS tb_grupo_token_ignorado (
    token text NOT NULL,
    obs   text,
    CONSTRAINT tb_grupo_token_ignorado_pkey PRIMARY KEY (token)
);

CREATE TABLE IF NOT EXISTS tb_hierarquia_grupo (
    reg         text NOT NULL,
    sup_oficial text NOT NULL,
    obs         text,
    CONSTRAINT tb_hierarquia_grupo_pkey PRIMARY KEY (reg)
);

CREATE TABLE IF NOT EXISTS tb_veiculo_correcao (
    marca_raw  text NOT NULL,
    modelo_raw text NOT NULL,
    marca_ok   text NOT NULL,
    modelo_ok  text NOT NULL,
    obs        text,
    CONSTRAINT tb_veiculo_correcao_pkey PRIMARY KEY (marca_raw, modelo_raw)
);
