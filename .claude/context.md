# Contexto — geotab (sync Geotab → Supabase)

## Stack
- Python (Flask + APScheduler + SQLAlchemy/psycopg2 + pandas + requests)
- Banco: **PostgreSQL LOCAL 18.4** (portátil em `C:\Users\ygor.kouzak\pgsql\pgsql\bin`, dados em `C:\Users\ygor.kouzak\pgdata`, porta 5432, sslmode=disable). Migrado do Supabase em 2026-06-17.
- Deploy: **LOCAL** (Render aposentado — IP era bloqueado pelo WAF da Geotab). Sync via `atualizar_local.py` no logon.
- Config via .env (credenciais Geotab + conexão local nas mesmas chaves SUPABASE_*)

## Como rodar (LOCAL — não há mais servidor web)
- Postgres local sobe no logon via `iniciar_postgres.bat` (pasta Inicializar). Manual: `pg_ctl -D C:\Users\ygor.kouzak\pgdata start`.
- Sync: `python geotab_supabase.py <modo>` (cadastro | status | comportamento | viagens). O orquestrador é `atualizar_local.py` (roda os 4 em sequência, seg-sex, 1x/dia).
- Agendamento: Tarefa `GeotabSyncLocal` — gatilho no logon + seg-sex 08:00 com `WakeToRun` (acorda do sleep/hibernate; wake timers habilitados no plano de energia). NÃO acorda do desligado.
- app.py/Flask/APScheduler/endpoints /run /status: REMOVIDOS (2026-06-17). Status agora = SQL direto (DBeaver/psql).

## Arquitetura (mapa de arquivos)
- `geotab_supabase.py` — extração da API Geotab (JSON-RPC) e gravação no Postgres; cria/migra tabelas; throttle de quota (4500 sub-chamadas/60s). Conexão lê `SUPABASE_*` do .env (agora apontam p/ localhost) + `SUPABASE_SSLMODE`.
- `atualizar_local.py` — orquestrador local: roda os 4 modos em subprocesso, seg-sex, 1x/dia (marcador `.ultima_atualizacao`). Disparado pela Tarefa `GeotabSyncLocal`. No fim, se todos OK, chama `_exportar_csv` (não-fatal).
- `exportar_csv.py` (2026-06-22) — exporta cada view p/ CSV e sobe no Supabase Storage (links de download p/ clientes externos). Ver seção "Download CSV externo".
- `powerbi_queries/*.m` (2026-07-01) — os 8 scripts M REAIS do usuário já adaptados p/ CSV público (fonte Web/Anônimo) = atualização agendada no Service SEM gateway, alternativa quando não dá p/ criar gateway (1 por view: cadastro/status/grupos/comportamento/motoristas/indicadores_mensal/resumo_frota_mensal/relatorio_viagens) + README. Cada script é AUTOSSUFICIENTE (sem funções auxiliares). Padrão `Web.Contents(base,[RelativePath=...])` p/ o Service aceitar URLs dinâmicas; viagens combinam todos os meses via index.html (aguenta `_p1`/`_p2`). Tipagem dobrada no passo `public_vw_*` (tipos de information_schema, cultura en-US); booleanos `t`/`f`→logical via `each _="t"`; `duracao_hhmm` fica texto (usuário converte p/ duration). Transformações originais (filtros OPE_*, Proper, etc.) intactas. (O guia `POWERBI_WEB_QUERIES.md` foi apagado pelo usuário 2026-07-01 — redundante, pois os scripts são autossuficientes.)
- `iniciar_postgres.bat` — sobe o Postgres local (pasta Inicializar/logon). Desde 2026-07-01: seta title da janela + banner explicando que a janela hospeda o banco (não fechar durante Power BI/sync; fechar = derruba o PG) + loop `timeout` p/ manter a janela aberta.
- `backup_geotab.bat` — pg_dump diário p/ `C:\Users\ygor.kouzak\backups` (mantém 14 dias; pasta Inicializar/logon).
- `views.sql` / `views_backup.sql` — definição/backup das views.
- (REMOVIDOS 2026-06-17: `app.py`, `render.yaml`, gunicorn/Flask/APScheduler.)

## Tabelas e períodos
- `tb_cadastro` — snapshot atual da frota (full refresh; `atualizado_em`)
- `tb_status` — snapshot tempo real (`snapshot_em`); motorista vem das trips das últimas 24h
- `tb_comportamento` — janela móvel de 6 meses (contadores `*_6m`); incremental via buckets
- `tb_comportamento_eventos` — buckets diários device/dia/tipo; janela = ANO CORRENTE (DATA_CORTE), ALINHADA com tb_viagens (antes era 6 meses móveis; alinhado 2026-06-18 p/ o km do score não descasar dos eventos). Limpeza apaga < DATA_CORTE.
- `tb_comportamento_motorista` (2026-06-18) — MESMOS eventos, mas por motorista/device/dia/tipo (captura `ev["driver"]` no `processar()`, antes descartado). device_id é a CHAVE de ligação com tb_comportamento_eventos. Só eventos com motorista identificado (~40-57%). Janela = ano corrente (DATA_CORTE, igual aos eventos/viagens). Base da vw_motoristas. Backfill via env `COMPORTAMENTO_BACKFILL=1` (one-shot; força backfill mesmo com buckets existentes — re-upsert idempotente dos device buckets + preenche os por motorista).
- `tb_viagens` — JANELA MÓVEL DE 30 DIAS (`VIAGENS_DIAS=30`, fixado no free tier). `sincronizar_viagens` PODA (`DELETE data_partida < data_inicio`) quando `VIAGENS_DIAS>0` — sem isso o upsert nunca apaga e reenche o disco.
- VIAGENS INCREMENTAL (2026-06-18): no modo ano-corrente (`VIAGENS_DIAS=0`, atual no local) a sync NÃO rebaixa mais a janela p/ 1º/jan todo dia (re-buscava o ano inteiro, ~70 lotes/~1h30). `VIAGENS_INCREMENTAL=1` (default) + `_ultima_partida_gravada()` começam a janela em `max(data_partida) − VIAGENS_MARGEM_DIAS` (default 3d, cobre viagens em curso/revisadas; upsert por id não duplica). Vazio → cai p/ 1º/jan (primeira carga). Log mostra `[incremental ...]` / `[ano corrente]`. Nº de lotes (71) NÃO muda (é por device, 25/lote); o que cai é o volume/geocode por lote. Poda segue só com VIAGENS_DIAS>0 (incremental mantém o ano todo).
- GEOCODE por LOOKUP (2026-06-15): endereços ficam em `tb_enderecos` (coord arredondada→endereço), NÃO em tb_viagens. `vw_relatorio_viagens` traz `end_partida`/`end_chegada` por JOIN em `round(lat/lon, 3)`. `geocodificar_enderecos()` (chamada no fim de sincronizar_viagens se VIAGENS_GEOCODE on) é incremental: só geocodifica coords novas. `GEOCODE_CASAS=3` (~110m) dedup ~1,4M→83k coords (geocode trip-a-trip era inviável, dias). IMPORTANTE: o `round(...,3)` da view tem que casar com GEOCODE_CASAS.
- COLUNAS DE PARADA (2026-06-18): `tempo_ocioso_segundos` (Trip.idlingDuration = parado c/ motor ligado) e `duracao_parada_segundos` (Trip.stopDuration = tempo parado no destino) em tb_viagens, capturadas em `_montar_viagem_row`, migração ADD COLUMN em `migrar_colunas`. Expostas em `vw_relatorio_viagens` (+ `*_hhmm` via H:MM manual que suporta >24h). SÓ preenchem em viagens (re)sincronizadas — linhas antigas ficam NULL até um backfill total (VIAGENS_INCREMENTAL=0). Em 2026-06-18 só os ~3 dias recentes (~101k linhas) têm valor; resto NULL.
- tb_viagens ENXUTA (2026-06-15): removidas serial/placa/veiculo/grupo/todos_grupos/regional/superintendencia (~190 MB de texto repetido). placa/veiculo/grupo/todos_grupos agora vêm de tb_cadastro via JOIN (por device_id) nas views *_viagens; regional/superintendencia eram peso morto (nenhuma view usava). Resultado: banco 484→259 MB, tb_viagens 429→204 MB, ~241 MB de folga. 0 viagens órfãs (todo device casa com tb_cadastro). 709.767 viagens / 30 dias.

## Piso temporal: SOMENTE 2026 (2026-06-16)
- `DATA_CORTE`/`ANO_CORTE` (env `ANO_CORTE`, default 2026) em geotab_supabase.py. Nenhuma tabela guarda dados < 2026-01-01. Aplicado como floor nas janelas: comportamento (`janela_ini=max(6m, corte)`), viagens (`data_inicio>=corte`), odômetro (clamp + DELETE <corte), resumo mensal (skip `ts.year<corte`). Limpeza única feita: removidos 2025-12 de comportamento_eventos/odometro_dia/resumo_mensal. Para virar o ano, bump ANO_CORTE.

## Views e períodos (UMA por tema; header de views.sql) — reorg 2026-06-16
- `vw_cadastro` — snapshot atual (`atualizado_em`)
- `vw_status` — tempo real (`snapshot_em`, `ultimo_contato`)
- `vw_comportamento` — POR DIA (device×dia), ~6 meses (`data`, `ano`, `mes`); eventos dos buckets + `odometro`/`odometro_gps` do dia (JOIN tb_odometro_dia). 129k linhas. **SEM score** — as colunas de score foram add e REMOVIDAS em 2026-09-09 (regressão de perf, ver seção SCORE GEOTAB). Score do veículo mora em `vw_saneago_veiculos_anual`.
- `vw_relatorio_viagens` — últimos 30 dias, por viagem (`data_partida`, `data_chegada`)
- `tb_motoristas` (2026-06-18) — dimensão de motoristas (entidade User). `nome` = login/e-mail (User.name); `nome_completo` (2026-06-19) = nome próprio (User.firstName, 100% preenchido; lastName é lixo numérico, ignorado); `matricula` = User.employeeNo (~98%); `lotacao` (grupo ULOT_), `regional` (REG_), `superintendencia` (SUP_), `todos_grupos`. Populada no modo `cadastro` (`extrair_motoristas`, mesma fonte de Group do cadastro). 3.630 motoristas; companyGroups vem 100% preenchido.
- `vw_motoristas` (2026-06-18) — POR DIA (motorista × `data`), espelha vw_comportamento; BI agrega no período. Cols: motorista_nome/matricula, `lotacao`/`regional`/`superintendencia` (JOIN tb_motoristas), data/ano/mes, qtd_veiculos, `veiculos` (string_agg placas), viagens, km, horas movimento/ocioso/parado, contadores de eventos e `score_risco` (ponderado: excesso×3+acel×2+fren×2+curva×1, igual vw_comportamento). FULL JOIN viagens_dia × eventos_dia (não perde dia). Janelas alinhadas (ambas ano/DATA_CORTE). O score 0-100 estilo Geotab (Event Count: `100 - SUM(total_eventos)*1000/SUM(km)`, piso de km a gosto) vira MEDIDA no BI sobre o período — por dia não faz sentido (km baixo). Era anual c/ score_seguranca 0-100 até virar diária em 2026-06-18. **SEM score** (add e removido em 2026-09-09, ver seção SCORE GEOTAB). A ressalva acima segue válida: score por DIA não faz sentido; o fechado mora nas views anuais e o de período filtrado é medida DAX.
- `vw_resumo_frota_mensal` — por veículo×mês, ano 2026 (`ano`, `mes`, `ano_mes`). Cols `marca`+`modelo` (de tb_cadastro via JOIN) add 2026-06-19, logo após `placa`. Recriada com DROP+CREATE (CREATE OR REPLACE não aceita coluna no meio da lista). NOTA: a view NÃO expõe device_id (PK real = tb_cadastro.id); 152 equipamentos sem placa ficam indistinguíveis no BI.
- `vw_motoristas_anual` (2026-06-19) — versão AGREGADA NO ANO da vw_motoristas (1 linha/motorista). Restaurada do git (commit 4ce68c4) p/ o Power BI legado, que foi feito no formato antigo ANTES de a vw_motoristas virar diária (2026-06-18). Mantém os nomes antigos: `km_total` (não `km`), `excesso_velocidade`/`aceleracao_brusca`/`frenagem_brusca`/`curva_drastica` (singular, não plural) e `score_seguranca` 0-100 Event Count (não `score_risco` ponderado). 2.639 motoristas. A vw_motoristas (diária) segue intacta p/ análise por período. **+ `score_geotab`/`faixa_risco_geotab` (2026-09-09)** — ver seção SCORE GEOTAB. `score_seguranca` (média simples, sem pesos) foi MANTIDA p/ não quebrar o BI legado.
- `vw_saneago_veiculos_anual` (2026-09-09) — 1 linha/VEÍCULO, espelha motoristas_anual. Cols: id/serial/placa/veiculo/todos_grupos/grupo_id, viagens, `km_ano` (de tb_viagens), horas_movimento, os 4 contadores, total_eventos, as 4 `nota_*` por regra, `score_geotab`, `faixa_risco_geotab`. Parte de `vw_saneago_cadastro` (herda grupo_visivel) → cobre a frota INTEIRA (1.063), inclusive veículo sem evento (nota 100). Criada na correção de perf — é o lugar certo do score do veículo, que eu havia pendurado na diária só porque não existia view anual de veículo.
- COL `todos_grupos` add às DUAS views de motoristas (vw_motoristas e vw_motoristas_anual) em 2026-06-19, após `superintendencia` (vem de m.todos_grupos / tb_motoristas, que já tinha a coluna). DROP+CREATE nas duas.
- COL `motorista_nome_completo` (= m.nome_completo / User.firstName) add às DUAS views em 2026-06-19, logo após `motorista_nome` (que segue sendo o e-mail/login). Resolve a queixa de "nome" — agora há o nome próprio. No BI, usar `motorista_nome_completo` como display.
- MATRÍCULA (investigado 2026-06-19): NÃO há "metade sem matrícula" — cobertura real ~98% em todas as fontes (tb_motoristas 83/3630=2,3% vazias; vw_motoristas 0,4%; vw_motoristas_anual 0,6%). O campo `nome` guarda o LOGIN/e-mail (`User.name`, ex. fabiosm@saneago.com.br), NÃO o nome próprio; a matrícula é `employeeNo` (ex. M140040). Os poucos sem matrícula são contas genéricas/reserva sem employeeNo na Geotab. Se o Power BI mostra ~metade, o problema é no modelo do BI (relacionamento/fan-out/cache), não no banco.
- `vw_indicadores_mensal` — por grupo×mês, ano 2026 (`ano`, `mes`, `ano_mes`)
- REMOVIDAS (2026-06-16): views `vw_comportamento_mensal`/`vw_resumo_frota`/`vw_indicadores_produtividade` (1 view por tema) e a TABELA `tb_comportamento` (dropada). vw_comportamento usa os buckets; odômetro migrou p/ tb_odometro_dia.
- `tb_odometro_dia` — odômetro POR DIA (device×dia, último valor do dia, físico+GPS). Preenchido por `sincronizar_odometro_dia` (chamado no fim de sincronizar_comportamento; incremental = dias novos). Substitui o odômetro que vivia em tb_comportamento. Funções antigas buscar_odo_gps/fisico/_com_fallback_ano/_reconstruir/_ler_odo_anterior TODAS removidas (limpeza 2026-06-17).
- `tb_odometro_mensal` (2026-09-22) — **TABELA (não view): hodômetro por VEÍCULO × MÊS**, frota INTEIRA, **abr/2025 → set/2026** (1.988 veículos × 18 meses = 35.784 linhas). Cols: device_id, `ano`/`mes`/`ano_mes`/`mes_ini`/`mes_fim`, serial/placa/veiculo/todos_grupos/**todos_grupos_expandido**/grupo_id, `odometro_inicio`, `odometro_fim`, `km_periodo`, `dia_inicio`/`dia_fim`, `dias_com_leitura`, `origem_inicio`, **`origem_dado`**, atualizado_em. Derivada de tb_odometro_dia + tb_cadastro **cru** (SEM filtro de cliente). Recalculada por inteiro (TRUNCATE+INSERT, **9 s**) por `recarregar_odometro_mensal(engine)` no fim do modo `comportamento`; nenhuma chamada à Geotab. `odometro_inicio` = última leitura ANTES do mês (carry-forward) → os meses EMENDAM. **Para recortar por cliente no BI use `todos_grupos_expandido`, NUNCA `todos_grupos`** (o token `OPE_<cliente>` só existe no ancestral; pela folha dá ZERO veículos). **`origem_dado` separa o dado confiável do legado**: `carga corrigida` 15.962 linhas (1 km negativo, maior hodômetro 245.168 km) × `legado (unidade suspeita)` 9.197 (129 km negativos, maior hodômetro 975.000 km, TODAS em 2026) × `sem leitura` 10.625. A flag marca suspeito se QUALQUER das duas pontas do mês (abertura ou fechamento) vier da carga legada — olhar só o fechamento deixava 68 km negativos vazarem p/ o lado limpo.
- `tb_resumo_mensal` — agregado km/tempo/dias/viagens por device×mês (~21k linhas/ano). Mês corrente: atualizado no sync de viagens via `atualizar_resumo_mes_corrente` (SQL de tb_viagens, sem Geotab). Meses passados: `backfill_resumo_mensal` (Geotab, uma vez). placa/grupo via JOIN tb_cadastro nas views.
- NOTA: as views VIVAS já estavam em 30 dias; o `views.sql` estava DESATUALIZADO (dizia "ano corrente"). Arquivo sincronizado com o banco em 2026-06-15. Sempre conferir com `pg_get_viewdef` antes de assumir o que o arquivo diz.

## Taxa de utilização > 100% / dias_utilizados > dias_no_periodo (corrigido 2026-06-18)
- CAUSA: `dias_no_periodo` é calculado AO VIVO na view (`LEAST(fim_mes, CURRENT_DATE) - ini_mes + 1`). Linha de tb_resumo_mensal p/ um MÊS FUTURO (relativo a hoje) → dias_no_periodo ≤ 0 com dias_utilizados ≥ 1 → taxa > 100. Mês futuro surgia porque `atualizar_resumo_mes_corrente` só tinha limite INFERIOR (`data_partida >= ini do mês`); viagem com data vazada p/ o mês seguinte criava a linha. Intermitente (some quando os dados são reescritos).
- FIX: (1) código — `atualizar_resumo_mes_corrente` ganhou limite SUPERIOR (`AND data_partida < ini_mes + 1 mês`), confinando ao mês corrente. (2) views `vw_resumo_frota_mensal` e `vw_indicadores_mensal` — `WHERE make_date(ano,mes,1) <= CURRENT_DATE` (ignora meses não iniciados) + taxa com `LEAST(dias_utilizados, dias_no_periodo)` (nunca passa de 100). Power BI: dar refresh p/ limpar valores cacheados.

## Download CSV externo (exportar_csv.py → Supabase Storage) (2026-06-22)
- OBJETIVO: clientes externos baixam cada view via link público estável, SEM depender do notebook ligado (snapshot diário, não ao vivo — a máquina dorme/sem admin/GPO).
- DESENHO: após a sync, `exportar_csv.py` (via `psql \copy`, NÃO carrega na RAM) gera 1 arquivo de NOME FIXO por view e sobe no Storage com `x-upsert` (link nunca muda). Gera um `index.html` com todos os links = O link que se manda ao cliente. Pasta `exports/` (gitignored, recriada a cada run).
- 8 views "dashboard" → `.csv` inteiro (maior: vw_motoristas 39 MB). `vw_relatorio_viagens` (1,6 GB / 3,58M linhas, ano inteiro) → DIVIDIDA POR MÊS + gzip, PARTICIONADA POR TAMANHO (`_gzip_particionado`): cada parte tem CSV cru <= ALVO_CSV (180 MB) → gzip ~35 MB. Mês pequeno = `_YYYY-MM.csv.gz`; mês grande = `_YYYY-MM_p1/_p2.csv.gz`. ORDER BY data_partida piora a compressão vs arquivo único (gz por mês ~46-63 MB se inteiro, por isso o split).
- LIMITE FREE TIER: Supabase Storage = **50 MB POR ARQUIVO** no plano grátis (não-negociável). Mês inteiro gzipado passava de 50 MB e dava HTTP 400 → daí o particionamento (LIMITE_ARQUIVO/ALVO_CSV em exportar_csv.py). Storage total free = 1 GB (snapshot ~369 MB cabe).
- REFRESH: `limpar_bucket()` apaga TODOS os objetos antes de subir o snapshot do dia (evita órfãos quando um mês muda de nº de partes). Upload com `x-upsert`.
- ENCODING: `PGCLIENTENCODING=UTF8` é OBRIGATÓRIO no \copy — sem isso o psql assume WIN1252 do console e aborta no 1º acento.
- SUPABASE: o projeto antigo (dyqrxszogdcsjnhodmrv) foi DELETADO (DNS não resolve) após a migração p/ local. Criado projeto NOVO `geotab-export` (ref `ldhelbygqrjqchistrgp`, org ygormaas's/gsfnitfhyiwxoefcmojk, free, sa-east-1) só p/ Storage. URL + service_role key JÁ no .env; pipeline VALIDADO ao vivo 2026-06-22 (21 arquivos no ar, downloads públicos HTTP 200). Caveat free tier: projeto pausa após ~7d sem atividade (upload diário mantém acordado).
- LINK P/ O CLIENTE (índice de todos): `https://ldhelbygqrjqchistrgp.supabase.co/storage/v1/object/public/geotab-csv/index.html`. Arquivo direto: `{STORAGE_URL}/storage/v1/object/public/geotab-csv/<arquivo>`.
- BUG CORRIGIDO (2026-06-23): no fluxo automático o export era PULADO todo dia (`export CSV pulado (sem SUPABASE_SERVICE_KEY no .env)`). Causa: `atualizar_local.py` checava a chave via `os.environ` mas NÃO carregava o `.env` (só os modos/`exportar_csv.py` faziam `load_dotenv` por conta própria). Fix: `load_dotenv(BASE/".env")` no topo do orquestrador. Por isso só funcionava quando se rodava o `exportar_csv.py` na mão.

## Views renomeadas p/ vw_saneago_* (2026-08-24)
- As 9 views ganharam prefixo `vw_saneago_` (`rename_saneago_2026-08-24.sql`; ALTER VIEW RENAME — deps entre views por OID, não quebram). Nomes: vw_saneago_cadastro/status/comportamento/relatorio_viagens/resumo_frota_mensal/indicadores_mensal/motoristas/motoristas_anual/grupos.
- CSV público: `exportar_csv.py` foi DESACOPLADO (VIEWS agora é lista de tuplas `(view_no_banco, nome_arquivo)`; VIEW_MENSAL idem). Query usa o nome novo, ARQUIVO mantém o antigo (vw_cadastro.csv etc.) → links dos clientes NÃO quebram. `exportar_view`/`exportar_view_mensal` ganharam param `arquivo`. Testado: lê vw_saneago_cadastro, grava vw_cadastro.csv (1062 linhas).
- `geotab_supabase.py` só cita os nomes em COMENTÁRIOS (não usa view no código da sync) → não precisou mudar. `powerbi_queries/*.m` leem CSV por nome de arquivo (preservado) → não mudaram. M do painel atualizado em `Downloads/saneago_codigo_M_novo.md` (Item + variável renomeados).

## CLIENTE SEMAD — 9 views `vw_semad_*` (2026-08-27) — `migracao_semad_2026-08-27.sql`
- Espelho das 9 views da SANEAGO (mesmas colunas), filtrando SOMENTE o contrato do SEMAD.
- **FILTRO POR INCLUSÃO**: `tb_contrato_semad(token)` + função `grupo_semad(todos_grupos)` (STABLE, match EXATO do token). Trocar/adicionar contrato = UPDATE/INSERT na tabela, **nenhuma view é recriada**. É o inverso do `grupo_visivel()` da SANEAGO (que é lista de EXCLUSÃO).
- `arrumar_grupos_semad()` = `arrumar_grupos()` + remove tokens de contrato de OUTROS clientes (regex `[0-9]+/[0-9]{4}$` fora da tb_contrato_semad). Necessário porque os usuários MAAS carregam os 6 contratos no mesmo `todos_grupos`.
- **CONTRATO CADASTRADO: `OPE_SEMAD - 035/2026`** (decisão do usuário). **RESOLVIDO em 2026-08-27**: o escopo de dados do usuário da API foi corrigido na Geotab (ver causa-raiz abaixo) e o contrato passou a chegar — **90 veículos**, frota DIFERENTE da de `006/2026` (15). Primeira viagem 2026-08-24. As views populariam sozinhas, sem nenhuma alteração de SQL.
- **CAUSA-RAIZ do "035/2026 não vem pela API" (diag ao vivo 2026-08-27):** NÃO é sync/conexão (a API devolve 1.868 devices, 100% capturados). O grupo `OPE_SEMAD - 035/2026` **não existe** entre os 834 grupos que a API enxerga, e há **0 veículos SPIN** (o cliente disse que os carros do 035 são SPIN). MOTIVO: o **escopo de dados** (companyGroups) do usuário da API `abel.neto@maasservicos.com.br` só tem 6 grupos: `OPE_SEMAD - 006/2026`, `OPE_SECRET. DA ECONOMIA - 018/2025`, `OPE_SANEAGO - 30000070/2025`, `OPE_COMURG - 001/2026`, `OPE_COMURG - 003/2026`, `REDEMOB CONSÓRCIO - 008/2025`. `Get<Device>/<Group>` só retorna o que está no escopo do user autenticado → o 035 e os SPIN (visíveis a um admin no portal) ficam invisíveis à API. **AÇÃO NA GEOTAB (admin):** (1) confirmar que 035/SPIN estão na database `maasserviços` (a que a API usa); (2) adicionar `OPE_SEMAD - 035/2026` (ou o grupo-pai `OPE_SEMAD` inteiro) ao Acesso a Dados do abel.neto. Feito isso, a próxima sync traz sozinha; o filtro `tb_contrato_semad` já está em 035/2026 e passa a casar.
- ENSAIO na criação (transação revertida, com 006/2026): cadastro 14, status 14, comportamento 214, relatorio_viagens 6.846, resumo 16, indicadores 8, grupos 1, motoristas 0/0. **0 órfãos de grupo_id** nas 5 views de fato, **0 vazamento** de SANEAGO/COMURG/REDEMOB/ECONOMIA.
- ESTADO REAL com 035/2026 (2026-08-27, pós-sync): cadastro 90, status 90, relatorio_viagens 2.523, comportamento 33, grupos 1, resumo_frota_mensal 0, indicadores_mensal 0, motoristas 0/0.
- **DIMENSÃO DE GRUPOS = 1 LINHA, SEM HIERARQUIA** (estado de 2026-08-27, JÁ SUPERADO): a frota estava toda sob o token único `OPE_SEMAD - 035/2026`. Depois vieram os subgrupos por secretaria (SET, SEMASDH, SMS, SECULT…) e o 2º contrato 031/2026 — hoje a dimensão tem 22 linhas.
- **CONTRATO NA DIMENSÃO DE GRUPOS = 1 LINHA POR grupo×contrato (2026-09-15)** — `migracao_semad_grupos_contrato_2026-09-15.sql` (APLICADA). Pedido do usuário: no grupo **SET** (1 veículo em cada contrato — TGG0G28→031/2026, TFD2H94→035/2026) a coluna de contratos tem que dar UMA linha p/ 031 e UMA p/ 035. `vw_semad_grupos` passou de `GROUP BY grupo` + `string_agg(contrato)` (SET saía "031, 035" numa linha) p/ `GROUP BY grupo, contrato`. **`grupo_id` virou COMPOSTO** `hashtext(arrumar_grupos_semad(todos_grupos) || '|' || COALESCE(contrato,''))` na dimensão E nas 3 views que o DEFINEM (cadastro, motoristas, motoristas_anual); as demais herdam por JOIN. Relacionamento muitos-p/-um segue válido; SET é o único grupo que dividiu (22 linhas / 22 ids únicos, 0 órfão). **BI: valores de grupo_id MUDARAM → refazer filtros/bookmarks + refresh.** Ressalva motoristas: tb_motoristas não tem `todos_grupos_expandido` e as 2 views estão com 0 linhas — a chave usa `contrato_semad(m.todos_grupos)` (volta vazio hoje), fórmula paralela por consistência, sem efeito enquanto 0 linhas. **Config de contratos: tb_contrato_semad = 035/2026 + 031/2026** (subgrupos por secretaria, 2026-09-14).
- **resumo_frota_mensal / indicadores_mensal VAZIAS = ORDEM DE EXECUÇÃO, não bug de view**: `atualizar_resumo_mes_corrente` rodou às 10:21 (gravou 1.789 devices em ago/2026) e a frota SEMAD só entrou no cadastro às 11:14. tb_viagens já tem 1.865 devices em agosto (76 do SEMAD), mas tb_resumo_mensal só conhece 1.789. A função NÃO tem filtro de grupo — só rodou cedo demais. CORREÇÃO: rerodar `python geotab_supabase.py viagens` (chama a função no fim) ou o upsert idempotente do mês corrente na mão. NÃO executado nesta sessão (usuário pediu só o M).
- **DESVIO CONSCIENTE (motoristas)**: as 2 views de motoristas escopam pelo **VEÍCULO** (`JOIN vw_semad_cadastro`), não pelos grupos do motorista como na SANEAGO. Motivo: os 30 "motoristas" com SEMAD são **usuários administrativos da MAAS** (`@maasservicos.com.br`) que pertencem a TODOS os 6 contratos; filtrar por eles traria **29 viagens em veículos da SANEAGO** (S0062/S0069/S0071/Presidência) para dentro do painel do SEMAD. Medido em 2026-08-27.
- Removida a exclusão de placas TFA2G98/TFN3B44/TFR4E14 (correção específica da frota SANEAGO; nenhuma é do SEMAD).
- SEM ORDER BY em relatorio_viagens/motoristas/motoristas_anual (regra de PERF). Volume é pequeno (~6,8k viagens) — não há risco de estouro de stream.
- **PENDÊNCIAS NA ORIGEM (Geotab), não no pipeline**: (a) 10 dos 15 veículos estão **sem `placa`** (o campo licensePlate está vazio; a placa só existe dentro do texto de `tb_cadastro.veiculo`) → `veiculo` sai como " | VOLKSWAGEN | 14.190 CRM"; (b) **100% das 8.297 viagens do SEMAD têm `motorista_id='UnknownDriverId'`/nome "Nenhum"** e `tb_comportamento_motorista` tem 0 eventos para os 15 devices → sem chave/identificação de condutor nos veículos, as views de motorista ficam vazias mesmo com o contrato certo; (c) 1 veículo (RBP0F52) tem o token `OPE_SEMAD` **sem número de contrato** → fica de fora do match exato.
- views.sql NÃO foi regenerado (segue só com as 9 da SANEAGO) — a definição do SEMAD vive na própria migração.
- **CÓDIGOS M ENTREGUES (2026-08-27): `Downloads/semad_codigo_M.md`** — 9 consultas, fonte `PostgreSQL.Database("localhost:5432","geotab")` (mesmo caminho do Gateway da SANEAGO). Padrão enxuto (Fonte + Item), `Text.Proper` só no motorista_nome_completo, `CommandTimeout` 1h na viagens por precaução (frota 12x menor que SANEAGO, sem o problema de volume), SEM `Table.AddIndexColumn`. Inclui variante do M de grupos com as colunas legadas (sup/reg/ulot/SUP_/todos_grupos_arrumado/Outros.1) p/ o caso de CLONAREM o .pbix da SANEAGO — sem elas as colunas calculadas DAX herdadas falham e cancelam o carregamento das outras tabelas. Relacionamento sugerido: fato → `semad vw_grupos[grupo_id]`, muitos-p/-um.

## ABASTECIMENTO (2026-08-31) — tabela + 2 VIEWS IMPLEMENTADAS; M/CSV NÃO
- Doc do levantamento: `Downloads/geotab_abastecimento_levantamento.md`. Sondas em scratchpad (probe_abastecimento/probe2/probe3/probe4.py).
- IMPLEMENTADO: `tb_abastecimento` (PK **device_id+data_hora** — a API não devolve `id`), `sincronizar_abastecimento` + `_montar_abastecimento_row` + `_ultimo_abastecimento_gravado`, modo `abastecimento` (entra tb no `all`, é barato), 5º modo no `atualizar_local.py`. `gravar_tabela` generalizada p/ CHAVE COMPOSTA (`chave_upsert="device_id, data_hora"`).
- CARGA INICIAL VALIDADA: **53.237 eventos / 1.852 devices / 12 MB / 01-jan→31-ago em ~40 s** (8 blocos mensais). Re-run incremental: 2 s, 648 eventos re-upsertados, **contagem inalterada (idempotente)**. **0 órfãos** vs tb_cadastro. SANEAGO 1.058 devices, SEMAD 58. km/L mediana 7,3 (SANEAGO) / 5,8 (SEMAD).
- **`litros` (volume) vem 0 em 1 de cada 5 eventos (80,5% >0); `litros_derivado` cobre 95,8%** → na view usar `coalesce(nullif(litros,0), litros_derivado)`. `motorista_id` 56,5%, e **23 ids não existem em tb_motoristas** (LEFT JOIN obrigatório). lat/lon 100% mas **geocode NÃO rodado** (sem view p/ consumir).
- UNIDADES: `odometer` e `distance` da API vêm em **METROS** (verificado contra tb_odometro_dia, razão ~997) → convertidos p/ km na gravação.
- **JANELA PRÓPRIA DO ODÔMETRO `ODO_DATA_CORTE` (2026-09-22).** O usuário pediu hodômetro de 2025. `ANO_CORTE`/`DATA_CORTE` é piso GLOBAL — baixá-lo arrastaria comportamento/viagens/resumo junto (tb_viagens tem 204 MB só de 2026; quase dobraria o banco e desfaria o enxugamento de 2026-06-15). Então o odômetro ganhou piso independente: env **`ODO_DATA_INICIO=2025-04-15`** (já no .env), default = DATA_CORTE (sem a env nada muda). Só tb_odometro_dia/tb_odometro_mensal a enxergam. **A poda de `sincronizar_odometro_dia` passou a usar ODO_DATA_CORTE** — se ficasse no piso global, o sync das 08:00 APAGARIA 2025 inteiro no dia seguinte. **LIMITE REAL DA ORIGEM: 2025-04-15.** Sondado mês a mês com 8 devices: jan/fev/mar-25 = 0 leituras; 15/abr/25 = primeira que existe; jun/25 em diante volume estável. Geotab retém ~17 meses — pedir antes disso devolve vazio. Backfill feito em 3 blocos trimestrais (~20 min). **2025 saiu LIMPO** (0 km negativo, maior hodômetro 205.689 km em dez/25); a sujeira toda está em 2026, que é onde vivem as linhas legadas.
- **ODÔMETRO BRUTO TEM 3 SUJEIRAS (medidas em 2026-09-22 sobre 324.016 linhas / 1.961 devices):** (a) `odometro_gps` é **0,0 em 100% das linhas** — coluna MORTA na origem, não usar; (b) o device `b12B` (placa SGZ8B71) tem **16 dias com 214.749.636,49 km = 2^31/10**, sentinela de overflow INT32 da telemetria (faixa real dele: 5.169 → 11.413 km) → guarda `odometro > 0 AND odometro < 3000000` nas views; (c) o odômetro **NÃO é monotônico**: 439 leituras (363 devices, 0,14%) caem em relação ao dia anterior (troca/reset de equipamento) → abertura/fechamento têm de ser a leitura mais ANTIGA/RECENTE por DATA, **nunca `min()`/`max()`**. Consequência aceita: `km_periodo` sai NEGATIVO em 7 das 9.549 linhas.
- **BUG DE UNIDADE NO ODÔMETRO — CORRIGIDO 2026-09-22.** `_inferir_km` usava limiar POR LEITURA (`raw > 1.000.000 → ÷1000, senão mantém`), então todo veículo abaixo de **1.000 km** ficava gravado em METROS. Provas: 57 devices com razão odômetro÷km_viagens ≈ 1000 (todos sob o limiar) vs 1.656 com razão ≈ 1; e 69 devices com queda de ~1000× na série, sempre com o valor anterior entre 908.000 e 1.000.000 (o dia em que cruzaram o limiar). Era a causa raiz das 439 leituras 'não monotônicas' e dos km_periodo negativos. **FIX EM DOIS PASSOS, porque o 1º estava frágil:** (a) primeiro pus `÷1000` fixo — certo p/ o dado atual mas perigoso, porque `_selecionar_diag_fisico` escolhe o diagnóstico EM TEMPO DE EXECUÇÃO e o 1º candidato se chama `DiagnosticOdometerInKilometersId` (já vem em km) → um ÷1000 fixo deixaria tudo 1000× MENOR se ele passasse a responder; (b) trocado por **`DIVISOR_ODO_KM` por diagnóstico**. Sondagem 2026-09-22 (set/26, 20 devices): `OdometerInKilometers` **0 leituras (vazio nesta base)**, `OdometerAdjustment` 219 leituras de 9.456.000 a 190.527.798 (= metros), `Odometer` 0. **RE-SYNC de 2026 feito (18 min, 250.383 linhas): 2.068 linhas corrigidas ÷1000 em 218 devices; devices errados na prova de campo 57 → 25.** Sobraram **76.756 linhas que o upsert NÃO reescreveu** — em 362 devices a API não devolve mais nada (inativos: 0 viagens em set/26 e os 3 diagnósticos vazios) e em 1.549 alguns dias vieram e outros não. **O usuário decidiu MANTER essas linhas** (apagar custaria 1.984 veículo-mês, −13% de cobertura em 2026) → elas ficam marcadas em `tb_odometro_mensal.origem_dado = 'legado (unidade suspeita)'`. Backup pré-fix em `tb_odometro_dia_bkp_20260922` (324.016 linhas).
- km/L extremo existe (p10 2,2 / p90 11,3 na frota toda) → filtrar `litros>5 AND distancia_km>1` antes de média.
- **VIEWS (2026-08-31, parte 2) — `migracao_abastecimento_2026-08-31.sql`**: `vw_saneago_abastecimento` (também em views.sql, agora 10 views) e `vw_semad_abastecimento`. Escopo pelo VEÍCULO (JOIN vw_<cliente>_cadastro, herda grupo_visivel/grupo_semad), `todos_grupos`+`grupo_id`, placa/veiculo/marca_padrao/modelo_padrao do cadastro, `security_invoker=on`, **SEM ORDER BY**.
- VALIDADO: SANEAGO **34.640 linhas / 1.058 placas / 0 órfãos de grupo_id / 73 ms**; SEMAD 130 / 58 / 0 / 26 ms. Endereço do posto 99,1% (SANEAGO) SEM geocode novo — abastecimento acontece em parada de viagem, coord já no `tb_enderecos` (faltam só 329 coords distintas). Motorista 84,4% na SANEAGO (bem melhor que os 56,5% da tabela crua), **0% no SEMAD** (lacuna conhecida). km/L mensal 6,2-7,8, estável.
- DECISÕES DA VIEW: `litros` = coalesce(nullif(litros,0), litros_derivado) — é a coluna que se SOMA; `litros_medido`/`litros_derivado`/`origem_litros` (medido 27.087 / derivado 7.085 / indefinido 468) são auditoria. `km_por_litro` só com **litros_ok>5 AND distancia_km>1** (senão NULL) — a guarda usa o litro COALESCED via subconsulta `litros_ok` (usar o cru descartava 19% dos eventos; **erro que cometi e corrigi na 1ª versão**). Expostas `distancia_km_valida`/`litros_validos` porque **a média do período NÃO é AVERAGE(km_por_litro)** e sim SUM/SUM. Breakdown do descarte na SANEAGO: 7.131 rodaram ≤1 km desde o anterior (evento dividido), 2.582 com ≤5 L, 468 sem litro.
- `tipo_combustivel` mantido na view apesar de 100% "Unknown" (evita recriar se a Geotab passar a preencher).
- **`litros_motor` (totalFuelUsed) NÃO É medição independente — não serve p/ desvio de combustível** (medido 2026-08-31): só 57,7% preenchido e, quando vem, **razão litros_motor/litros = 1,00 de p10 a p90** (91% idênticos). 538 casos inflados até 534× fazem a soma do "motor" dar 2.573.648 L contra 1.208.840 L abastecidos. Eu havia proposto essa medida no doc de levantamento E no 1º rascunho do M — **RETIRADA dos dois** após medir. Conciliação de desvio exige o extrato do cartão.
- **"VAZAMENTO DA SANEAGO NA VIEW DO SEMAD" (reportado 2026-08-31) = FALSO ALARME NO BANCO, é o modelo do BI.** AUDITORIA EXAUSTIVA: `todos_grupos` tem **1 único valor distinto** (`OPE_SEMAD - 035/2026`) nas 8 views do SEMAD com dados (cadastro 90, status 90, comportamento 70, viagens 3.269, resumo 78, indicadores 1, abastecimento 130, grupos 1); 0 placas da SANEAGO; 0 logins @saneago; nenhuma das 10 definições cita saneago; tb_contrato_semad = 1 linha. Na SANEAGO o abastecimento tem 619 grupos (vs 622 no cadastro/viagens — os 3 sem abastecimento), 0 vazamento de SEMAD/COMURG/REDEMOB/ECONOMIA, 0 órfãos. CAUSA PROVÁVEL: **eu entreguei os 2 blocos de M no mesmo arquivo**, então o bloco da SANEAGO pode ter sido colado na consulta do SEMAD (sintoma exato: todos_grupos com texto da SANEAGO, sem erro nenhum). Checagem p/ o usuário: linha `Item=` de cada consulta. **AÇÃO TOMADA: M separado em 1 ARQUIVO POR CLIENTE** (`Downloads/abastecimento_M_SANEAGO.md` e `abastecimento_M_SEMAD.md`, cada um com aviso + números esperados p/ conferência); o combinado virou REFERÊNCIA de colunas. **LIÇÃO: nunca entregar M de 2 clientes no mesmo documento.**
- **CÓDIGOS M ENTREGUES: `Downloads/abastecimento_codigo_M.md`** (agora só referência) — 2 consultas (Fonte+Item+`Text.Proper` só no motorista_nome_completo), SEM CommandTimeout (73 ms/26 ms), SEM AddIndexColumn. Medidas DAX com separador **vírgula** (igual aos docs anteriores do usuário): Litros, Abastecimentos, **Km por litro = DIVIDE(SUM(distancia_km_valida), SUM(litros_validos))**, % litros medidos, % com consumo calculável. Relacionamentos: fato→vw_grupos[grupo_id] e fato[data]→calendário (NÃO data_hora).
- PENDENTE: entrada no `exportar_csv.py` (é publicação externa — NÃO fazer sem o usuário pedir), geocode das 329 coords faltantes.
- **NADA de combustível existia no pipeline antes disso.**
- **`FuelUpEvent` = A FONTE.** Abastecimento deduzido pela subida do nível do tanque + parada de viagem. Medido: 8.284 eventos / 1.742 devices / 406.703 L em 30d (23.083 em 90d). SANEAGO **1.012 de 1.062 veículos (95%)**, 4.773 ev, 171.366 L; SEMAD 58/90 (64%), 133 ev, 5.006 L. Sanidade OK: litros/evento mediana 41,5, máx 68, tanque estimado 55 L, **0 absurdos >100 L**.
- Campos úteis: `volume` (litros, 89% >0), `derivedVolume` (fallback, 90% >0), `totalFuelUsed` (litros do motor desde o abast. anterior — dá para achar desvio), `distance` (metros desde o anterior → **km/L direto**), `odometer`, `location` (lat/lon do posto → geocode reaproveita `tb_enderecos`), `driver` (**54%**), `tankCapacity` (ESTIMADO, não é de fábrica), `confidence` (98% "FuelLevel, TripStop"). **NÃO tem `id`** → PK teria de ser device+data_hora.
- **`FuelTransaction` = 0 REGISTROS** em qualquer janela → sem integração de cartão de combustível. **NÃO HÁ R$, preço/litro, posto, cartão nem NF.** Só entra se importarem o extrato da administradora. `productType` 100% "Unknown" (sem gasolina/etanol/diesel).
- `StatusData` de tanque (`DiagnosticFuelLevelId`/`FuelUnitsId`/`DeviceTotalFuelId`) só em **~30-35 veículos** → inútil p/ painel (é a matéria-prima do FuelUpEvent). `FuelLevelInput`/`EngineFuelRate`/`FuelTemperature` = 0. `FuelTaxDetail` = imposto IFTA/US, só odômetro, **nenhum litro** — irrelevante.
- CUSTO DE API baixo: `Get FuelUpEvent` é **1 chamada por janela**, não por device (diferente das viagens). 90 dias volta em segundos. Volume no banco ~100k linhas/ano, poucos MB.
- Proposta (aguardando decisão do usuário): `tb_abastecimento` + modo `abastecimento` incremental por `max(data_hora)` + `vw_saneago_abastecimento`/`vw_semad_abastecimento` (padrão vigente: todos_grupos+grupo_id, sem ORDER BY) + M + exportar_csv.

## ABASTECIMENTO NO RESUMO MENSAL (2026-08-31, partes 3 e 4) — `migracao_abastecimento_no_resumo_2026-08-31.sql`
- **DECISÃO DO USUÁRIO (parte 3): NÃO quer view separada de abastecimento; quer a informação NA view de consumo/utilização** = `vw_<cliente>_resumo_frota_mensal` (veículo × mês).
- **DECISÃO DO USUÁRIO (parte 4): "confunde. quero somente a informação correta para a situação de frota, quanto cada veículo andou e consumiu, muito simples."** → das 6 colunas da parte 3 sobraram **3**.
- ESTADO FINAL — posições 20-22 das 2 views: `abastecimentos`, `litros_abastecidos` (quanto consumiu), `km_por_litro` (= km_rodado/litros_abastecidos). "Quanto andou" já era `km_rodado`.
- **REMOVIDAS na parte 4** (exigiu DROP+CREATE, pois CREATE OR REPLACE não apaga coluna): `km_por_litro_evento`, `km_base_consumo`, `litros_base_consumo` — era a 2ª métrica (tanque a tanque, pela distância que a Geotab mede ENTRE abastecimentos). Tecnicamente melhor emparelhada, mas 2 métricas de consumo na mesma view confundiam. Fórmula guardada no header da migração se precisar voltar.
- **GUARDA DE PLAUSIBILIDADE no km_por_litro (1 a 20 km/L; fora = NULL)**: km_rodado e litros_abastecidos são do mesmo mês-calendário mas NÃO do mesmo combustível (abasteceu dia 31, queima em setembro). Medido: de 7.846 linhas com valor, **537 davam <1 km/L e 413 >20, p99 = 606 km/L** (12% de lixo). A guarda NÃO afeta o total — km_rodado e litros seguem íntegros em todas as linhas.
- DROP sem CASCADE de propósito (0 dependentes verificados) + `SET LOCAL lock_timeout='15s'` p/ não pendurar atrás de refresh do BI.
- VALIDADO: SANEAGO 8.355 linhas, 7.908 com abastecimento, **6.896 com km_por_litro (87%)**, 1.212.380 L no ano. SEMAD 85 / 60 / 58 (97%) / 5.304 L.
- No BI: `DIVIDE(SUM(km_rodado), SUM(litros_abastecidos))`. NUNCA média de média. As colunas do numerador/denominador já existiam.
- views.sql: bloco do `vw_saneago_resumo_frota_mensal` substituído 2x nesta sessão (parte 3 e parte 4). Confere com o banco.
- **🔴 ACHADO GRAVE, NÃO CORRIGIDO — `tb_resumo_mensal` DEFASADA vs tb_viagens.** Descoberto ao validar o km/L. `km_rodado` (que vem de tb_resumo_mensal) está **11-14% ABAIXO** do km real de tb_viagens em TODOS os meses de 2026: ago 2.553.221 vs 2.874.471; jan 1.280.124 vs 1.485.994; jul 2.519.869 vs 2.612.160. **No SEMAD a defasagem é 40%** (18.191 vs 30.192 km — a frota entrou no cadastro depois da agregação; hoje é 01/09 então agosto já não é "mês corrente" e `atualizar_resumo_mes_corrente` não alcança mais). EFEITO: **km_por_litro sai SUBESTIMADO na mesma proporção** (frota daria ~8,4 em vez de 7,47). CAUSA PROVÁVEL: meses passados preenchidos uma vez por `backfill_resumo_mensal` (fonte Geotab) e nunca recalculados, enquanto tb_viagens cresceu com a sync incremental. CORREÇÃO = recalcular tb_resumo_mensal de tb_viagens (SQL puro, sem Geotab). **NÃO APLICADO: mudaria km_rodado/dias_utilizados/viagens/taxa_utilizacao_pct de TODOS os meses no painel que o cliente já vê — é decisão do usuário (regra de 2026-08-26).**
- AS 2 VIEWS DE DETALHE (`vw_*_abastecimento`) seguem no banco, fora do escopo do painel. Não dropadas (guardam posto/motorista/litros por evento). Perguntar antes de dropar.
- PENDENTE: M do resumo mensal (o antigo funciona — colunas aditivas no fim, só dar refresh); `vw_*_indicadores_mensal` (grupo × mês) NÃO recebeu litros; decidir sobre o recálculo da tb_resumo_mensal.

## NÍVEL DO GRUPO PELO CÓDIGO + ORDEM CANÔNICA (2026-09-02) — `migracao_grupos_nivel_por_codigo_2026-09-02.sql`
**SUBSTITUI a regra de "níveis repetidos" de 2026-08-26 (removida da view).** APLICADA no banco. Rollback: `rollback_grupos_2026-09-02.sql`. Diff completo: `VALIDACAO_GRUPOS_2026-09-02.md` + os 2 CSVs `validacao_grupos_*`.
- SINTOMA reportado: "códigos se repetem mesmo sendo grupos diferentes; informação sendo perdida".
- **CAUSA 1 (a maior) — FRAGMENTAÇÃO POR ORDEM.** `arrumar_grupos()` preservava a ordem dos tokens vinda da Geotab. O MESMO conjunto de grupos chegava em várias ordens → várias linhas em `vw_saneago_grupos` e vários `grupo_id`. Ex.: `SUP_S0072|REG_G0032|ULOT_G0032` existia em 5 ordens, com os veículos espalhados 3+4+9+6+1 — no BI o filtro trazia 9 de 23. Medido: **1.733 linhas p/ 793 hierarquias reais**; 967/1.063 veículos e 2.546/2.808 motoristas afetados.
- **CAUSA 2 — NÍVEL VINDO DO PREFIXO.** `split_grupo()` decidia o nível por `SUP_`/`REG_`/`ULOT_`, preenchidos de forma inconsistente na Geotab: **21 códigos apareciam ora como regional, ora como lotação**. A regra de níveis repetidos então zerava o de baixo, às vezes o único lugar onde a gerência estava (ex. `REG_S0088 | ULOT_G0087 | SUP_S0088` → G0087 sumia do filtro de regional).
- **FIX 1:** `arrumar_grupos()` ORDENA CANONICAMENTE (ope > sup > reg > ulot > outros, depois alfabética) e deduplica tokens. `todos_grupos`/`grupo_id` viram chave estável.
- **FIX 2:** nova `nivel_grupo(token)` decide pela **LETRA DO CÓDIGO** (convenção SANEAGO, confirmada na base: S/D=sup 1.660 usos, G=reg 1.582, V/T/C/USE=ulot 1.378). Fallback no prefixo do token p/ códigos fora da convenção → **SEMAD e futuros clientes intactos**. Exceções em `tb_grupo_nivel_excecao` (T8000→reg, G8100→ulot).
- **FIX 3:** `token_nivel(todos, nivel)` substitui `split_grupo()` nas views. Desempate quando 2 tokens caem no mesmo nível: ganha o de prefixo concordante (`nivel_prefixo`), depois alfabética. O `split_grupo()` antigo usava `LIMIT 1` SEM `ORDER BY` = não-determinístico. `split_grupo()` segue no banco por compat, sem uso nas views SANEAGO.
- **RESULTADO:** 1.733 → **793** linhas, 793 ids, 0 colisão, 0 órfão, **0 código em 2 níveis** (era 21). Recuperados: 20 regionais, 6 lotações, 4 superintendências (incl. as 2 "ressalvas" ULOT_S0086/ULOT_S0090, que agora vão certo p/ a coluna de sup). 489 hierarquias absorvem 1.429 linhas duplicadas.
- **PERDA RESIDUAL ACEITA:** 3 veículos / 7 motoristas em combos com 2+ tokens do mesmo nível (só um cabe na coluna) — G0301, D6000, G8327, V0137, V0129, V2047. Isso já acontecia, só que a escolha era aleatória. Texto cru intacto em `todos_grupos`/`todos_grupos_original`. Se algum desempate estiver errado, fixar em `tb_grupo_nivel_excecao`.
- **POWER BI:** `todos_grupos` e `grupo_id` MUDAM de valor em 1.303 dos 2.115 combos. Fato e dimensão mudam juntos → relacionamentos seguem válidos, mas **filtros/bookmarks salvos com o texto antigo precisam ser refeitos**. Slicer de grupo cai de 1.733 p/ 793 itens; DISTINCTCOUNT deixa de ser inflado ~2,2×. Nenhuma coluna add/removida em nenhuma das 10 views. CSV público muda no próximo export.
### PADRÃO DE PREENCHIMENTO DAS COLUNAS DE NÍVEL (regra do usuário, 2026-09-02) — `migracao_grupos_preenchimento_nivel_2026-09-02.sql` — APLICADA
- **REGRA, palavras do usuário:** "se em `todos_grupos` dá pra ver a informação daquele nível, a coluna daquele nível TEM que estar preenchida com a sua respectiva informação". Vale para sup, reg e ulot, **sempre**. Coluna só fica vazia quando NÃO EXISTE token daquele nível.
- CASO QUE GEROU: `REG_G0084 - GERENCIA DE ARRECADAÇÃO | ULOT_G0084 - GERENCIA DE ARRECADAÇÃO` saía com `reg`=G0084 e `ulot`=**vazio**. Motivo: `token_nivel()` escolhia pelo NÍVEL DO CÓDIGO; os dois tokens têm código G0084 (=gerência=reg), então nada sobrava p/ `ulot`. O usuário quer os DOIS preenchidos.
- **FIX:** `token_nivel()` virou COALESCE de duas buscas — (1) token cujo **código** pertence ao nível (preserva a promoção: `ULOT_G0087 - GERENCIA...` continua indo p/ a coluna REGIONAL); (2) se não houver, token cujo **prefixo** declara o nível.
- EFEITO: vazios caíram sup 55→54, reg 96→58, ulot 186→26. 160 grupos (210 veículos) ganharam lotação, 38 (23 veículos) ganharam regional. **Nenhuma coluna já preenchida mudou de valor; a chave `todos_grupos` não é tocada** (793 continua 793, 0 órfão). `sup_oficial()` segue envolvendo o resultado → caso Palmeiras (G0155→S0071) preservado.
- **✅ CONFIRMADO PELO USUÁRIO (2026-09-02):** 34 grupos exibem código de superintendência/diretoria na coluna REGIONAL e 29 na de LOTAÇÃO — os `REG_S0021 | ULOT_S0021 | SUP_S0021` (mesma unidade nos 3 campos da Geotab). **ISSO É O CORRETO, NÃO É DEFEITO.** Palavras dele: *"antes eu estava errado, os nomes se repetem, e às vezes a coluna de regional vai ter o nome da superintendência"*. **A regra de "níveis repetidos" de 2026-08-26 fica REVOGADA PELO PRÓPRIO USUÁRIO** — não é mais uma decisão dele a ser preservada. **NUNCA voltar a zerar coluna de nível por repetição de código ou de nome.**

- **PENDÊNCIAS ABERTAS (medidas, NÃO aplicadas — decisão do usuário):**
  - ~~**Dedup por CÓDIGO na chave**~~ — **DESCARTADA em 2026-09-02.** Colapsaria `REG_G0084 | ULOT_G0084` em um token só (793→771), mas apagaria justamente o token `ULOT_` que alimenta a coluna de lotação via fallback — **violaria a regra de preenchimento que o usuário acabou de estabelecer**. A repetição no rótulo é intencional. NÃO aplicar.
  - ~~**Deduzir a superintendência ausente da regional**~~ — **DESCARTADA em 2026-09-02 por decisão do usuário.** Ganho ínfimo (2 veículos, 15 motoristas) e risco de gravar a sup errada em 9 gerências ambíguas. Caminho escolhido: **corrigir no cadastro da Geotab**. Listas exportadas em `cadastro_sem_superintendencia_RESUMO_2026-09-02.csv` (54 grupos) e `_DETALHE_` (1.558 placas/motoristas), classificadas em 4 situações (A: sem nenhum grupo de estrutura; B: só lotação; C: falta sup, regional ambígua; D: falta sup, dedutível). **ACHADO GRANDE: 1.475 dos 4.949 motoristas (30%) e 25 veículos estão SÓ com o token de contrato `OPE_SANEAGO - 30000070/2025`, sem nenhum grupo de estrutura** — não é "falta a superintendência", é falta a hierarquia inteira. Mais 23 motoristas só com `RESERVA`. Enquanto a origem não for corrigida, esses ficam fora de qualquer quebra por unidade no painel.
  - (não aplicar) Deduzir a superintendência ausente da regional e injetar na chave → 771→762; recupera sup em 17 dos 55 grupos sem sup (os outros 39 não têm nem regional). Custo: `todos_grupos` deixa de ser literal e **9 das 106 regionais são ambíguas** (aparecem sob 2 sups: G0032, G0079, G0137, G0150, G0152, G0341, G0376, G0386, G8323) — usaria a mais frequente, podendo errar nessas 9.
  - Variação de escrita do mesmo código (`GERENCIA` vs `GERÊNCIA`) responde por 89 das duplicações residuais.

## (HISTÓRICO, SUPERADO) NÍVEIS REPETIDOS na hierarquia de grupos (2026-08-26) — `migracao_niveis_repetidos_2026-08-26.sql`
- SINTOMA reportado: "coluna de regional com informação de superintendência; a de lotação também tem sup e reg".
- CAUSA: dado de ORIGEM, não a função. No cadastro Geotab a mesma unidade aparece sob vários prefixos: `REG_S0021 - SUPERIN. DE ESTUDOS E PROJETOS | ULOT_S0021 - ... | SUP_S0021 - ...`. `split_grupo()` estava CERTO (pegava o token REG_/ULOT_); o token é que carrega conteúdo do nível de cima. Mesmo sintoma do Palmeiras (item 9).
- REGRA: nível que só REPETE o código do nível acima → NULL. reg→NULL se `reg_codigo=sup_codigo`; ulot→NULL se `ulot_codigo=sup_codigo OR =reg_codigo`.
- ANTES: 50 grupos c/ regional repetida (24 veículos), 335 c/ lotação repetida (208 veículos), de 1.721 grupos / 1.062 veículos. DEPOIS: 0/0/0. Hierarquias reais preservadas (S0021→G0123→V0123). reg_codigo começando com 'S' caiu de 37 → 0.
- Aplicado via CREATE OR REPLACE (lista de colunas idêntica) → sem DROP, sem lock exclusivo travando com refresh do BI.
- RESSALVA mantida: 2 grupos têm SÓ um token `ULOT_` com código de superintendência (ULOT_S0086, ULOT_S0090) e NADA acima — não é repetição. **0 veículos** nesses grupos (só motoristas). Zerar apagaria a única info de grupo; correção real é no cadastro Geotab.
- Auditoria: `todos_grupos_original` guarda o texto cru.
- **REVOGADO em 2026-09-02:** as CTEs `codigos`/`limpo` saíram da view; a repetição deixou de existir por construção (um código só ocupa um nível). Ver seção acima.

## REGRA DE TRABALHO (feedback do usuário, 2026-08-26)
- **NUNCA decidir algo que contrarie instrução que ele já deu.** Se uma otimização colidir com um pedido anterior, PARAR e propor explicitamente com o trade-off medido, esperando a decisão. Mencionar a mudança num documento de entrega NÃO é autorização.
- Caso que gerou a regra: ele pediu "todas as views devem ter a coluna todos_grupos"; ao otimizar a viagens (2,5 GB derrubando o refresh) eu removi a coluna de lá p/ economizar 635 MB e só avisei no doc. REVERTIDO — as 9 views voltaram a ter todos_grupos (+ grupo_id ao lado como chave leve opcional). Viagens voltou a 2.502 MB.

## MARCA/MODELO: corrigir só typos, NÃO colapsar (2026-08-26) — `migracao_modelo_so_typos_2026-08-26.sql`
- **ERRO MEU, corrigido a pedido do usuário**: `tb_modelo_canonico` casava por REGEX e colapsava todas as variantes em 3 nomes (ARGO/ARGO 1.0/ARGO DRIVE/ARGO DRIVE 1.0 → "ARGO 1.0"; 7 grafias de Saveiro → "SAVEIRO ROBUST"). Isso APAGAVA distinções reais de versão do veículo.
- AGORA: `tb_veiculo_correcao(marca_raw, modelo_raw → marca_ok, modelo_ok)`, 15 linhas (um par por combinação existente). Corrige APENAS: typo (FITA→FIAT, VOKSWAGEN→VOLKSWAGEN), caixa (Fiat, VW Saveiro), marca abreviada (VW SAVEIRO→VOLKSWAGEN) e modelo gravado no campo da marca (modelo vazio: "ARGO DRIVE 1.0", "SAVEIRO CS RB MF", "FIAT/ARGO DRIVE 1.0", "VW SAVEIRO"). Fallback sem linha na tabela = cru em maiúsculas.
- RESULTADO: **9 modelos distintos** preservados — SAVEIRO CS RB 656, ARGO DRIVE 1.0 391, SAVEIRO 7, POLO CL AB 3, e 1 cada de ARGO 1.0/SAVEIRO CS/ARGO DRIVE/ARGO/SAVEIRO CS RB MF. Total 1062, 0 sem classificação, 0 grafias erradas.
- Só as FUNÇÕES mudaram (marca_padrao/modelo_padrao) — views absorvem sem recriar.
- DIVERGÊNCIA CONSCIENTE do documento da SANEAGO: a pág. 4 dela pedia nomes canônicos ("SAVEIRO ROBUST", "ARGO 1.0"). O usuário decidiu preservar os modelos reais. **Rever o item 7 da triagem antes da devolutiva.**
- ~~PENDÊNCIA: `tb_modelo_canonico` obsoleta no banco~~ **RESOLVIDO em 2026-08-28**: foi apagada junto com as outras na exclusão acidental do usuário e **deliberadamente NÃO restaurada** (nada a usa; era exatamente a limpeza pendente). Não recriar.
- LIÇÃO: não incluir DROP TABLE na mesma transação de migrações de view — se travar no lock, perde tudo.

## `veiculo` + `motorista_nome_completo` (2026-08-26) — `migracao_veiculo_e_motorista_2026-08-26.sql`
- `veiculo` = `concat_ws(' | ', placa, marca_padrao, modelo_padrao)` → "SGZ5D49 | VOLKSWAGEN | SAVEIRO ROBUST". Montado das PADRONIZADAS, não do cru de tb_cadastro (que tem FITA/VOKSWAGEN/ARGO em 7 formas). Nas 5 views com placa: cadastro, status, comportamento, relatorio_viagens, resumo_frota_mensal. Em cadastro SUBSTITUIU o `veiculo` cru.
- `motorista_nome_completo` (3ª coluna de motorista) em relatorio_viagens e status. `tb_viagens.motorista_nome` guarda o LOGIN (ex. clesio@saneago.com.br) — 74.377 viagens em 7 dias. Nome vem de `tb_motoristas.nome_completo` via LEFT JOIN em `motorista_id`. **Cobertura 69.725/69.725 = 100%**. Em status o join é por `nome` (tb_status não tem motorista_id); hoje status é 100% "Nenhum".
- Volume viagens: 1.622 → 1.839 MB (+217 MB pelas 2 colunas). Tempo inalterado (3,3 s/1M — o JOIN em tb_motoristas não custou). Órfãos de grupo_id seguem 0.
- ATENÇÃO/ERRO COMETIDO: o `DROP ... CASCADE` em vw_saneago_cadastro derrubou tb `vw_saneago_indicadores_mensal`, que NÃO estava na migração — recriada em seguida. Ao mexer em cadastro, SEMPRE recriar as 5 dependentes: status, comportamento, relatorio_viagens, resumo_frota_mensal, indicadores_mensal.

## CHAVE `grupo_id` + volume da viagens (2026-08-26) — `migracao_grupo_id_2026-08-26.sql`
- Usuário optou por MANTER o ano inteiro nas viagens (5,3M linhas) — não limitar período.
- PROBLEMA: view de viagens = 2.484 MB num único stream → "Exception while reading from stream". `todos_grupos` (~126 bytes) repetido 5,3M vezes = **635 MB só de chave**.
- FIX: `grupo_id` = `hashtext(todos_grupos)` (4 bytes, 31x menor) em TODAS as 9 views. Verificado: 1.721 grupos → 1.721 ids, ZERO colisão, ZERO órfãos em todas as views. `todos_grupos` FICA nas views pequenas (exibição) e SAIU da viagens. Removido tb `veiculo` da viagens (redundante c/ placa+modelo_padrao). **2.484 MB → 1.622 MB.**
- ATENÇÃO: `hashtext` NÃO serve p/ endereço — 3 colisões em 125.622 distintos. Se um dia virar dimensão, usar a chave natural (lat,lon), que é única (156.038/156.038).
- REMOVIDAS da viagens neste passo (derivadas, se precisar é trivial devolver): `tempo_ocioso_hhmm`, `duracao_parada_hhmm`. `duracao_hhmm` MANTIDA (é a do item 3).
- No M: **remover `Table.AddIndexColumn`** (bufferiza a tabela toda em memória — principal suspeito da falha nesse volume) e definir `CommandTimeout=#duration(0,2,0,0)`. Se algum visual usar a coluna Índice, recriar via RANKX.
- Resta ~1,6 GB, dos quais 743 MB são end_partida/end_chegada. Se falhar de novo: virar dimensão de endereços (cai p/ ~80 MB) — CUSTO: PBI só permite 1 relacionamento ativo entre 2 tabelas, então partida+chegada exigiria USERELATIONSHIP ou 2 cópias da dimensão. Alternativa simples: limitar período (90 dias = ~500 MB).
- Server-side a viagens escala linear: 1M em 3,5 s → 5,3M em ~19 s.

## PERF: SEM ORDER BY nas views grandes (2026-08-25) — `migracao_perf_e_compat_2026-08-25.sql`
- **CAUSA RAIZ do "PostgreSQL: Exception while reading from stream" no Power BI**: `ORDER BY` em view obriga o PG a ordenar TODAS as linhas antes de devolver a 1ª. Em vw_saneago_relatorio_viagens (3,9M) eram **88 s p/ ler 200 mil linhas** → o BI estourava timeout. Achei 4 consultas do refresh presas há 17-22 min segurando lock (bloquearam até meu DROP VIEW; cancelei com pg_cancel_backend).
- FIX: ORDER BY removido de relatorio_viagens, motoristas e motoristas_anual. **88 s → 0,77 s (114x)**. O BI ordena no modelo. **NÃO reintroduzir.** Views pequenas mantêm ORDER BY (custo irrelevante, ajuda inspeção manual).
- motoristas segue ~20 s (scan de 3,9M viagens no CTE diário) — inerente, não é o ORDER BY. Medição de 40 s era cache frio.
- COMPAT: `operacao` (cru) voltou à dimensão — o Power BI usa nos rótulos legados.

## ERROS DE DAX após remover colunas (2026-08-25) — diagnóstico
- Os erros que o usuário reportou NÃO eram do M: eram COLUNAS CALCULADAS DAX no .pbix referenciando colunas que a reescrita da consulta de grupos deixou de produzir (`todos_grupos_arrumado`, `Outros.1`, e `SUP 2`/`REG 2`/`ULOT 2` que dependiam de `SUP_`/`REG_`/`ULOT_`). Sintoma do PBI: "Expressões que geram tipo de dados variável não podem ser usadas para definir colunas calculadas" + cascata "Um erro ao carregar uma tabela anterior cancelou o carregamento".
- FIX: o M de grupos voltou a produzir TODAS as colunas legadas, remontadas das novas: `todos_grupos_arrumado`=Text.Proper(todos_grupos); `sup`="SUP_"&sup_codigo; `SUP_`=sup_nome (idem reg/ulot); `gruposemnumero` e `Outros.1` via `Text.Combine(List.RemoveNulls({...}))` — sem nenhum ReplaceValue. Formato legado confere (sup era "SUP_S0062", SUP_ era o nome Proper).
- PENDENTE p/ o usuário: colunas calculadas DAX que citem `uo_lotacao`/`sup`/`reg`/`ulot`/`lotacao`/`regional`/`superintendencia` nas tabelas de FATO ainda vão falhar (essas colunas foram removidas a pedido). Trocar por RELATED('public vw_grupos'[ulot_nome]) etc. Oferecido devolver uo_lotacao se preferir.

## ORGANIZAÇÃO FINAL das colunas de grupo (2026-08-25) — `migracao_grupos_organizados_2026-08-25.sql`
- `vw_saneago_grupos` (DIMENSÃO, única com quebra por nível): `todos_grupos_original` (cru) + `todos_grupos` (tratado = CHAVE) + `sup_codigo/sup_nome/sup_cod_nome` + `reg_*` + `ulot_*` + `operacao` + `outros`.
- TODAS as outras views: SOMENTE `todos_grupos` (tratado). REMOVIDAS de lá: operacao/sup/reg/ulot/outros/sup_oficial (cadastro, resumo) e lotacao/regional/superintendencia/superintendencia_oficial (motoristas).
- `grupo`/`uo_lotacao` REMOVIDOS em 2026-08-25 a pedido (`migracao_remove_lotacao_2026-08-25.sql`). Agora NENHUMA view de fato tem coluna de grupo além de `todos_grupos`. A lotação vem da dimensão (`ulot_nome`/`ulot_cod_nome`) via relacionamento. IMPORTANTE: em vw_saneago_indicadores_mensal o uo_lotacao saiu do SELECT **e do GROUP BY** (senão as linhas ficariam divididas por coluna invisível) → 5.539→4.866 linhas; VALIDADO que totais não mudaram (8.336 veic-mês, km bate). Quebra por lotação agora se faz no BI com `ulot_nome` na linha do visual.
- CHAVE ÚNICA: 2.116 textos originais colapsam em 1.721 chaves (diferem só nos rótulos ignorados ou na ORDEM deles). A view AGRUPA por todos_grupos e mostra `min(original)` como representativo — o Power BI exige chave única p/ relacionamento muitos-p/-um. Os níveis são idênticos entre os originais de um grupo (só dependem dos tokens que sobrevivem à limpeza). VALIDADO: 1721 linhas = 1721 chaves, 0 órfãos em todas as views.
- Dimensão COMPLETADA (2026-08-25): + `ope_codigo/ope_nome/ope_cod_nome` (4º nível) e `outros_nome`. Sem eles o M de grupos ainda precisaria dos ReplaceValue. `operacao` cru saiu (virou ope_*). As exceções já cadastradas valem aqui: SANEAGO→"CT. 30000070/2025", D2000→"Presidência", RESERVA→"Reserva" (via fallback initcap). Sobra 1 combo feio ("SUP | REG | ULOT | ..." — grupos literalmente chamados SUP/REG/ULOT), raro.
- **ARMADILHA CRÍTICA p/ o BI**: NUNCA aplicar `Text.Proper` (ou qualquer transformação) em `todos_grupos` nas tabelas de FATO. É a chave do relacionamento; transformar no fato e não na dimensão faz o join parar de casar e os visuais ficam vazios. Os M ANTIGOS faziam isso — todos foram reescritos.
- M REESCRITOS (2026-08-25) em `Downloads/saneago_codigo_M_novo.md`: os antigos quebrariam por falta de uo_lotacao/sup/reg/ulot/lotacao/regional/superintendencia/todos_grupos_arrumado/lot3. A maioria virou 3 linhas (Fonte + Item). No M de grupos, `gruposemnumero` = `Text.Combine(List.RemoveNulls({ope_nome, outros_nome, sup_nome, reg_nome, ulot_nome}), " | ")` — dispensa TODOS os ReplaceValue (níveis vazios não entram, em vez de virar barras soltas). Validado que toda coluna citada nos M/DAX existe.
- No M de `vw_motoristas cadastro` REMOVI o dedup por `motorista_matricula`: com 1.391 motoristas sem matrícula, o Table.Distinct manteria só 1 e descartaria ~1.390 da dimensão. Dedup por motorista_nome (login, único) basta.
- Guia: `Downloads/saneago_colunas_grupos_tratados.md`.

## Desenho anterior de grupos (2026-08-25) — `migracao_todos_grupos_limpo_2026-08-25.sql` (base do atual)
- REGRA (definida pelo usuário): **TODAS as views expõem `todos_grupos` LIMPO** (= `arrumar_grupos()`, sem Vehicle/Ethanol/Diesel/Compressed Natural Gas/Manually Classified Powertrain/etc.) — é a CHAVE p/ a dimensão. **SÓ `vw_saneago_grupos`** tem a quebra por nível com e sem código (sup_codigo/sup_nome/sup_cod_nome, reg_*, ulot_*). As colunas separadas foram REMOVIDAS de cadastro/resumo/indicadores/motoristas.
- `tb_grupo_token_ignorado` (tabela) substituiu a lista fixa dentro de `arrumar_grupos` (que virou STABLE). ACHADO: **`Compressed Natural Gas` NÃO estava na lista antiga e vazava p/ o painel** (1 veículo). Combustível novo = 1 INSERT.
- `vw_saneago_grupos` = UNION das combinações de tb_cadastro + tb_motoristas. CRÍTICO: só 263 das 1.348 combinações de motorista existem entre os veículos (19%) — sem a união, 81% dos motoristas ficariam órfãos ao relacionar por todos_grupos. Resultado: 1.707 combos, **0 órfãos** dos dois lados.
- Views DERRUBADAS e recriadas (CREATE OR REPLACE não remove coluna); ordem de criação respeita dependências. `sup`/`reg`/`ulot`/`operacao`/`outros` MANTIDOS em vw_saneago_cadastro porque o M atual ainda usa — remover depois que o BI puxar da dimensão.
- EFEITO COLATERAL ESPERADO: `vw_saneago_indicadores_mensal` 5.878→5.539 linhas (agrupa por todos_grupos; combos que só diferiam por combustível se fundiram). VALIDADO que nada se perdeu: 8.336 veículos-mês idêntico à fonte, km total bate (dif. 71 em 8,86M = arredondamento por grupo, pré-existente).
- No BI: relacionar cada fato → `vw_grupos[todos_grupos]` (muitos-p/-um) e usar os campos da dimensão nas segmentações.

## Grupos tratados: sup/reg/ulot de todos_grupos (2026-08-25) — HISTÓRICO (superado pelo desenho acima)
- `todos_grupos` é a coluna que dita os 3 níveis. Migração `migracao_grupos_tratados_2026-08-25.sql` + tabela de exceções.
- Funções: `grupo_codigo(p)` (IMMUTABLE, regex `^[A-Za-z]+_([^-\s]+)`), `grupo_nome(p)` (STABLE — consulta exceções; senão `initcap` do que vem após o 1º hífen), `grupo_cod_nome(p)` (concat_ws ' - ').
- Colunas novas por nível em vw_saneago_cadastro/_grupos/_resumo_frota_mensal/_indicadores_mensal: `sup_codigo/sup_nome/sup_cod_nome`, `reg_*`, `ulot_*`. Ex.: "G0111 - Ger.Regional Serv. Itumbiara". Originais (sup/reg/ulot) preservados.
- sup_* deriva de `sup_oficial()` → a correção do Palmeiras já vem embutida.
- FORMATOS: padrão é `PREFIXO_CODIGO - NOME`, mas 36 linhas usam hífen SEM espaços (`REG_G0162-GERENCIA...`, `ULOT_T0171-DISTRITO-FLORES DE GOIAS`) — o regex cobre os dois e corta só no 1º hífen, preservando nome com hífen. Dispensa os ReplaceValue manuais de G0162/T0171 no M. Cobertura: 0 falhas. 16 sup / 68 reg / 346 ulot.
- `tb_grupo_nome_excecao(codigo → nome_exibicao)`: initcap rebaixa siglas (SUMEG→Sumeg); G0162 já carregado. **É por aqui que entra o de-para do item 16** (abreviações Superv./Super./Sup.). INSERT resolve, sem recriar view.
- ACHADO: "S0098 - SUBPROCURADORIA JURÍDICA JUDICIA" do PDF NÃO está truncado no dado — o cru é `...JUDICIAL` completo. Era corte de LARGURA DE COLUNA no visual do BI. Item 16 reclassificado (parte é ajuste de relatório).
- MOTORISTAS (migracao_grupos_motoristas_2026-08-25.sql): mesmas colunas em vw_saneago_motoristas/_anual como `lotacao_*`, `regional_*`, `superintendencia_*` (+ `superintendencia_oficial`). Substituem `lot3` e TODOS os ReplaceValue do M.
  - `tb_motoristas.lotacao` tem FALLBACK (extrair_motoristas usa o 1º grupo útil se não há ULOT_) → 2.994/159.792 linhas (1,9%) trazem REG_/SUP_/PRE_. Por isso `grupo_nome` ganhou 3º nível de COALESCE: exceção → nome após 1º hífen → texto cru capitalizado (nunca NULL). Era o que o lot3 fazia.
  - Regex de `grupo_codigo`/`grupo_nome` relaxado p/ aceitar espaço ao redor do "_" (caso `PRE _ D2000`).
  - Exceções carregadas: G0162 (SUMEG), D2000→"Presidência", SANEAGO→"CT. 30000070/2025".
  - PERF: vw_saneago_motoristas leva ~20s, mas JÁ LEVAVA antes das colunas novas (elas somam ~1,2s / 6%). Custo é o scan de tb_viagens (3,9M) no CTE viagens_dia, não as funções. Cadastro 448ms, resumo 458ms.
- Guia p/ o usuário: `Downloads/saneago_colunas_grupos_tratados.md`.

## Apontamentos SANEAGO — itens 7-9 implementados (2026-08-25)
- Origem: PDF "BI - MAAS - CORREÇÕES E SUGESTÕES" (12/08/2026, 9 slides). Triagem completa dos 18 apontamentos em `Downloads/triagem_apontamentos_saneago.md` (2 já resolvidos, 4 BI, 5 banco, 6 cliente, 1 improcedente).
- Migração: `migracao_saneago_itens_7a9_2026-08-25.sql`. REGRA: colunas novas são ADITIVAS (marca/modelo/sup ORIGINAIS preservados) p/ não quebrar relacionamentos/medidas do BI. Exceção: endereço limpo NO LUGAR (é texto de exibição).
- **Item 7 — modelo canônico**: `tb_modelo_canonico` (padrao regex → marca_padrao/modelo_padrao, por prioridade) + funções `modelo_padrao(marca,modelo)`/`marca_padrao(...)` (STABLE, leem tabela). Colunas `marca_padrao`/`modelo_padrao` em vw_saneago_cadastro, _relatorio_viagens, _resumo_frota_mensal. 15 grafias → 3 modelos (SAVEIRO ROBUST 665 / ARGO 1.0 394 / POLO CL 3), 0 sem classificação. VIRTUS e COMMANDER pré-cadastrados (prio 20) p/ caso a Q2 libere. Add modelo = INSERT, sem recriar view.
- **Item 8 — endereço**: `limpar_endereco()` (IMMUTABLE) tira do INÍCIO: Plus Code do Google (`^[0-9A-Z]{4,}\+[0-9A-Z]+`, separador OPCIONAL — havia casos só com espaço) e nº/CEP solto (`^[0-9]+(-[0-9]+)*\s*[-,]`— o grupo composto evita picar CEP inicial ao meio, bug que a 1ª versão tinha). Aplicada em end_partida/end_chegada. Plus codes 3.296→0; nº solto 1.121→9 (malformados na origem, ex. `6 - 1 - Parque`, coord crua; não insisti p/ não apagar km de rodovia `46,7, BR-040`). 0 endereços normais alterados.
- **Item 9 — hierarquia**: `tb_hierarquia_grupo(reg → sup_oficial)` + `sup_oficial(reg,sup)` (COALESCE: sem linha na tabela, devolve o original). Coluna `sup_oficial` em vw_saneago_cadastro, _resumo_frota_mensal, _grupos. Palmeiras (REG_G0155) agora 100% S0071 (1 veículo vinha errado sob S0062). PENDENTE de propósito: REG_G0341 sob S0071(2)/S0060(1) — cliente não citou, maioria fraca, NÃO adivinhar; corrigir = INSERT na tabela.
- Itens 10 (campo "Outros") e 11 (texto do método de utilização): NÃO são mudança de banco. `outros` FICA no banco (o M do vw_grupos usa p/ montar gruposemnumero/Outros.1) — remover é decisão de visual. Texto do método já redigido na triagem; aplicar só depois do item 6 (agregação de % no BI).
- Itens 3-6 (Power BI): guia escrito em `Downloads/saneago_ajustes_powerbi_itens_3a6.md` — falta o usuário APLICAR no .pbix. (3) duração: view já entrega `duracao_hhmm` texto HH:MM, o M converte p/ minutos com `Duration.Minutes` — remover; não virar tipo duration (exibe 0.14:02:00); somar só `duracao_segundos`. Máx 15h, 0 viagens ≥24h. (4) trocar campo da segmentação p/ `motorista_nome_completo` (100% preenchido); `motorista_nome` fica como chave técnica. (5) prefixo ULOT_: coluna `ulot` já vem limpa (só nome) e `Ulot_` tem o código com prefixo — opção (b) do doc junta `Text.AfterDelimiter([Ulot_],"_") & " - " & [ulot]` = "G0155 - Nome", que RESOLVE A CONTRADIÇÃO DA Q1 (Multas elogia código+nome, Frota pede tirar ULOT_). (6) taxa >100%: BI soma percentual; virou 2 medidas DAX (SUMX com MIN por linha / DIVIDE no fim) — remover tb as colunas `dia x hora liq` e `tx utilizaçao hr liq` do M.
- CORREÇÃO no texto do método (item 11): `dias_no_periodo` são dias CORRIDOS (inclui fim de semana), não dias úteis — frota seg-sex tem teto prático ~70%.

## MATRÍCULA = employeeNo (confirmado com usuário 2026-08-24)
- A matrícula da SANEAGO é o `User.employeeNo` (formato `M######`), que o sync JÁ lê em `extrair_motoristas` (`geotab_supabase.py:755`). View e sync estão corretos.
- Cobertura real no Geotab: só **70%** (3533/4985 motoristas isDriver). **1.391 motoristas de grupos visíveis estão SEM employeeNo** no Geotab → matrícula vazia no painel. NÃO é bug do pipeline; é lacuna de cadastro na ORIGEM. Só preenchendo o employeeNo no Geotab chega a 100% (o próximo sync traz sozinho).
- Há um 2º número em `User.lastName` (10 dígitos, ex. 3065279919; 99% preenchido, mas 117 registros têm sobrenome de texto). NÃO é a matrícula — usuário confirmou que é o employeeNo. lastName segue ignorado.
- Lista dos sem-matrícula exportada em `Downloads/saneago_motoristas_sem_matricula.csv` (login, nome_completo, lastName como pista, lotação) p/ correção no Geotab.
- No BI: LOOKUPVALUE motorista↔viagens deve casar por `motorista_nome` (login, 100%) quando precisar cobrir todos; matrícula só cobre ~49% das linhas de viagens.

## Filtro de grupos centralizado (REFACTOR Power BI SANEAGO, 2026-08-24)
- Função `grupo_visivel(todos_grupos)` (IMMUTABLE) = FALSE se qualquer token do veículo casar por PREFIXO com a lista de exclusão (OPE_COMURG/SEINFRA/PEDREIRA/CS_BRASIL/P-CSB/AGETUL/SMT/SEPLANH/AMMA/SEMAD/SECULT/"SECRET. DA ECONOMIA"/"SERVIÇOS EM CAMPO"/ADMINISTRATIVO/"ASSISTÊNCIA SOCIAL"/"RECOLHIMENTO DE ANIMAIS"/"DIRETORIA/GERÊNCIA"/"ATERRO SANITÁRIO"/REDEMOB). **OPE_SANEAGO NÃO entra** (contrato principal). Para mudar a regra: editar SÓ a função.
- Todas as views passaram a filtrar por ela: vw_cadastro (WHERE grupo_visivel + exclui placas TFA2G98/TFN3B44/TFR4E14 — o M tinha bug `or` que não excluía nada); vw_status/comportamento/resumo/indicadores herdam via JOIN vw_cadastro; vw_motoristas/vw_motoristas_anual/vw_grupos ganharam WHERE grupo_visivel próprio.
- FUROS QUE EXISTIAM: vw_relatorio_viagens fazia `LEFT JOIN tb_cadastro` (cru, sem filtro) → virou `JOIN vw_cadastro`. vw_motoristas não tinha filtro nenhum. vw_cadastro viva estava SEM filtro (todo o filtro vivia no Power BI).
- Colunas NOVAS aditivas movidas do M p/ SQL: vw_relatorio_viagens `velocidade_media_2` (>150→0) e `velo_max_2` (>200→0); vw_resumo_frota_mensal `modelo2` (modelo vazio→marca).
- FICOU no Power BI (não mexer no SQL p/ não quebrar relacionamentos/medidas): Text.Proper, normalização do veiculo (FITA→FIAT, "/"→espaço, Upper), duração, renomeações amigáveis (gruposemnumero/lot3), índice, medidas dia*8 e tx utilização.
- Efeito medido: vw_cadastro 1869→1062, vw_status 1210→1062. Códigos M novos entregues em `Downloads/saneago_codigo_M_novo.md`. Migração aplicada: `migracao_powerbi_2026-08-24.sql`; rollback: `views_backup_2026-08-24.sql`. views.sql regenerado do banco.

## Decisões importantes
- TIMESTAMP sem timezone, valores em BRT (Brasil sem horário de verão desde 2019)
- NullPool + pooler transaction mode → evita "max clients reached"
- Uma tabela por job/horário — rodar tudo junto estoura RAM do free tier
- UA de navegador nas chamadas Geotab → evita bloqueio WAF/Cloudflare (403)
- Views filtram grupos OPE_*/terceiros via `todos_grupos NOT LIKE`

## Gotchas / armadilhas
- **AS 5 TABELAS DE CONFIGURAÇÃO SÃO CRÍTICAS — apagá-las QUEBRA AS 18 VIEWS** (2026-08-28, aconteceu). São pequenas (1-15 linhas) e parecem descartáveis, mas as FUNÇÕES que as views chamam leem delas: `tb_grupo_token_ignorado`←`arrumar_grupos()`, `tb_grupo_nome_excecao`←`grupo_nome()`, `tb_hierarquia_grupo`←`sup_oficial()`, `tb_veiculo_correcao`←`marca_padrao()`/`modelo_padrao()`, `tb_contrato_semad`←`grupo_semad()`/`arrumar_grupos_semad()`. As views CONTINUAM EXISTINDO (o DROP TABLE não as derruba, pois a dependência é via função, não direta) e só falham na LEITURA.
- **`count(*)` NÃO detecta view quebrada**: o planejador do PG descarta colunas não usadas, então as funções nem são avaliadas e o count passa. Testar SEMPRE com `SELECT * FROM <view> LIMIT 1`.
- **`pg_restore -t` NÃO restaura PRIMARY KEY/constraints** (só CREATE TABLE + dados). Depois de um restore seletivo, extrair os `ADD CONSTRAINT` do dump (`pg_restore -s -f - dump.dump | grep "ALTER TABLE ONLY public.<tab>" -A2`) e aplicá-los na mão. Sem PK, o `ON CONFLICT` das migrações/sync quebra.
- POSTGRES CAI com 0xC000013A se FECHAREM A JANELA que o hospeda (2026-06-18; recorrente). Causa = STATUS_CONTROL_C_EXIT: fechar o terminal/console manda CTRL_CLOSE ao postmaster (que está pendurado nesse console) → "desligamento rápido". Derrubou a sync no meio (viagens → "connection refused localhost:5432"). Diagnóstico em `C:\Users\ygor.kouzak\pgdata\server.log`. Religar manual: `pg_ctl -D C:\Users\ygor.kouzak\pgdata -l ...\server.log start`.
- NÃO dá pra rodar o PG sem console nesta máquina: WSH/wscript BLOQUEADO (testado, .vbs não dispara) e `Start-Process -WindowStyle Hidden` BLOQUEADO ("operação cancelada"); serviço do Windows exige admin (GPO). Por isso a defesa é na SYNC, não no launcher.
- MITIGAÇÃO (2026-06-18): `atualizar_local.py` agora AUTO-CURA — `garantir_postgres()` (socket check 127.0.0.1:5432 + `pg_ctl start` + espera) roda ANTES da sync e DE NOVO se uma fase falhar, repetindo a fase 1×. Caminhos por env: `PG_CTL`/`PGDATA`/`PG_HOST`/`PG_PORT`. Validado ao vivo (porta fechada→religou). Regra p/ o usuário: nunca subir o banco por um terminal que vai fechar; deixar o logon (iniciar_postgres.bat no Startup) cuidar. Mesmo que feche e o PG morra, a próxima sync religa.
- 403 não-JSON na autenticação Geotab = bloqueio WAF (IP do Render), não credencial
- Quota Geotab: 5000 sub-chamadas/min — throttle proativo em 4500
- Fuso na busca de eventos: BRT rotulado como UTC "vaza" ~3h p/ dia anterior (floor_dia descarta)
- `_lock` é POR PROCESSO e cobre TODOS os modos: enquanto um modo roda (ex.: comportamento, que é longo), `/run/<outro>` é descartado. Antes respondia "iniciado" falso; agora responde 409 "ocupado". Se um modo trava (banco lento), starva os demais → tabelas congelam todas juntas.
- `GEOTAB_PROXY` (env): alterna o IP de saída das chamadas Geotab. Vazio = direto (local, IP limpo). Preenchido (`http://user:senha@host:porta`) = via proxy (Render, p/ furar o bloqueio de WAF). Só afeta requests da Geotab, não o Supabase (psycopg2). Modo ativo aparece em `/status` e `/health` no campo `saida_geotab` (credenciais mascaradas).

## Próximos passos
- [x] Banco Supabase estrangulado de IO (2026-06-12): RESOLVIDO — banco suspenso no fim de semana + reiniciado em 2026-06-15, voltou ao normal
- [ ] **CAUSA REAL da defasagem desde 04/jun = bloqueio de WAF (Cloudflare) da Geotab no IP de saída do Render (403 na auth).** Revelado pelo /status após a correção (antes ficava ultimo_erro=null por causa do sys.exit). Banco saudável NÃO resolve — auth falha antes. Soluções: (a) allowlist dos IPs de saída estáticos do Render no Geotab (pegar IPs no painel Render → Connect/Outbound; pedir liberação ao suporte/admin Geotab); (b) rotear chamadas Geotab por proxy com IP confiável; (c) rodar a sync de outro host cujo IP não esteja flagado (GitHub Action, VPS, máquina local agendada). UA de navegador já está no código e não basta — bloqueio é por IP.
- [ ] Confirmar RLS das tabelas após recuperação (views já corrigidas: security_invoker=on confirmado nas 7)
- [ ] Rerun linter no Advisors após recuperação (painel congelado — linter não roda com banco lento)
- [ ] Definir VIAGENS_DIAS=7 no Render antes de religar (sync diário regrava ano inteiro = provável causa do dreno de IO)
- [x] Exportar definição de vw_grupos para views.sql (FEITO 2026-08-24 — views.sql regenerado do banco com as 9 views + funções)
- [ ] Considerar WITH (security_invoker = on) nas views do views.sql (CREATE OR REPLACE sem a opção pode resetar)

## Gotchas / armadilhas (sessão 2026-06-12)
- Projeto Supabase do geotab (ref dyqrxszogdcsjnhodmrv) está em OUTRA conta — integração MCP só vê "automultas"
- (check_lints.py / est_volume.py: REMOVIDOS 2026-06-17 — eram diagnósticos da era Supabase/free-tier, sem sentido no local.)
- Lints corrigidos com: ALTER VIEW ... SET (security_invoker = on) + ALTER TABLE ... ENABLE ROW LEVEL SECURITY (sem policies — consumo é só conexão direta como owner)

## LIMITE DE DISCO ESTOURADO (2026-06-15) — banco em READ-ONLY
- Supabase free tier = 500 MB. Carga de viagens do ANO inteiro (geocode off) levou o banco a 890 MB e o Supabase forçou `default_transaction_read_only=on` (bloqueia INSERT/DELETE/TRUNCATE/DROP).
- Culpado: `tb_viagens` = 1.295.267 linhas / 834 MB (carga parou no lote 26/70; ano completo seria ~3,4M). As outras tabelas são pequenas (~1 MB cada; eventos = 42 MB) e foram atualizadas OK ANTES de encher.
- tb_viagens ano-corrente é INCOMPATÍVEL com o free tier. Caminhos: (a) no painel Supabase desativar read-only temporariamente → trim/TRUNCATE tb_viagens → usar VIAGENS_DIAS curto (ex.: 30-90d) p/ nunca reencher; (b) upgrade Pro (8 GB) se precisa do ano todo. Decisão pendente do usuário (custo x retenção) + ação no painel (só o dono faz).

## Bug corrigido (2026-06-15)
- `_limpar_buckets_antigos` e `_reconstruir_comportamento` usavam bind colado no cast PG (`:lim::date`, `:ini::date`). SQLAlchemy 2.0/psycopg2 não substitui o bind nesse formato → "syntax error at or near :". Corrigido p/ `CAST(:param AS date)`. (A contagem + upsert de buckets já tinha rodado; o erro era só na limpeza/reconstrução.)

## MIGRAÇÃO Supabase → Postgres LOCAL (2026-06-17)
- MOTIVO: Supabase free 500 MB estourado (banco a 671 MB) + RAM 512 MB do Render + IP do Render bloqueado pelo WAF da Geotab. Local resolve os 3 de graça.
- FEITO: PG 18.4 portátil (sem admin, zip já extraído). `initdb` em `C:\Users\ygor.kouzak\pgdata`, senha postgres no `.env` (SUPABASE_SENHA). Banco `geotab` criado. Dump do Supabase (session pooler porta 5432, `-n public --no-owner --no-acl`) → restore local. 7 tabelas + 7 views migradas; tb_enderecos (83k, cache geocode) e tb_viagens (2,1M) preservados.
- CÓDIGO: `criar_engine()` agora lê `SUPABASE_SSLMODE` de env (default require p/ nuvem; local=disable). Única mudança.
- .env repontado p/ localhost:5432/geotab; `VIAGENS_DIAS=0` (ano inteiro, sem limite de disco). Supabase antigo comentado p/ rollback.
- AUTOMAÇÃO (sem admin — criar tarefa no Agendador dá "Acesso negado" por GPO): `iniciar_postgres.bat` + `backup_geotab.bat` na pasta Inicializar (`shell:startup`) → rodam no logon. Sync continua na task `GeotabSyncLocal` (já existia). Backup diário (1/dia por data, mantém 14d) em `C:\Users\ygor.kouzak\backups`.
- LIGAR SOZINHO: inviável (notebook corporativo, sem admin/BIOS, GPO trava wake timers). Modelo é "liga o PC num dia útil → sync roda no logon".
- FEITO (usuário, 2026-06-17): On-premises Data Gateway configurado + dataset Power BI repontado p/ localhost; serviço do Render deletado. Inspeção via DBeaver (localhost:5432/geotab/postgres).

## SCORE GEOTAB (2026-09-09) — `migracao_score_geotab_2026-09-09.sql` — APLICADO
- Metodologia oficial **Geotab Driver Safety Scorecard**, método **Event Count**. Fórmula oficial: `100 - (Event Rule Event Count x 1000) / Total Driving Distance`; calibrada p/ nota 0 com 10 eventos em 100 unidades de distância → em km, **zera com 100 eventos/1.000 km**. Faixas default: Low ≥90, Mild ≥75, Medium ≥60, High <60 (bordas fechadas por nós; a doc oficial as sobrepõe).
- **Regras REAIS desta base** (confirmado no log do sync, não suposto): velocidade = **1 só regra, `RulePostedSpeedingId`** (= Speeding oficial, 20%); aceleração = **`RuleJackrabbitStartsId`**, NÃO `RuleHarshAccelerationId` (proxy de Hard Acceleration, 10%); `RuleHarshBrakingId` (10%); `RuleHarshCorneringId` (10%). **Excessive Speeding (30%) e Seatbelt (20%) NÃO existem aqui** → peso oficial disponível = 50%.
- **Pesos = default oficial ÷ 0,50** → velocidade **0.40**, acel/fren/curva **0.20** cada. A Geotab define peso como parâmetro do cliente (total 100%), o que autoriza a renormalização. Variante 62,5/12,5 foi testada e DESCARTADA (mediana cai de 52,3 p/ 39,4).
- 3 funções: `nota_regra_geotab(qtd, km)` (Event Count, piso 0), `score_geotab(km, exc, acel, fren, curva, piso_km=200)` (NULL abaixo do piso), `faixa_risco_geotab(score)`.
- **Piso de 200 km** (parâmetro nosso, sem equivalente oficial): 1 evento em 50 km projeta 20 eventos/1.000 km. Cobertura 2.234 de 2.817 motoristas (79%); 583 ficam "Sem base", NUNCA nota 0.
- Colunas: `vw_saneago_motoristas_anual` → `score_geotab`+`faixa_risco_geotab`; `vw_saneago_motoristas` e `vw_saneago_comportamento` (diárias) → `km_ano`+`score_geotab_ano`+`faixa_risco_ano`. **Sufixo `_ano` é deliberado**: nas diárias o valor é da ENTIDADE NO ANO, repetido; sem o sufixo alguém lê "score do dia".
- **PERF — armadilha que eu caí**: a 1ª versão agregava o próprio CTE `base` p/ obter os totais por entidade → estourou 2 min (obriga a reavaliar o FULL JOIN + string_agg das placas 2×). Corrigido: totais saem DIRETO de `tb_viagens`/`tb_comportamento_motorista`/`tb_comportamento_eventos`. Válido porque `grupo_visivel` exclui a entidade INTEIRA, nunca dias isolados.
- Custo medido (varredura completa, antes × depois): comportamento 90,6→95,2 s (**+4,6 s**), motoristas_anual 20,3→22,3 s (+2,1 s), motoristas 38,5→24,7 s (ruído de passada única). **Os ~90 s da vw_saneago_comportamento são PRÉ-EXISTENTES**, não do score.
- Estado real: motoristas 59 baixo / 205 leve / 370 médio / **1.600 alto** / 583 sem base (mediana 52,3). Veículos 23/82/175/**750**/7. Score agregado da frota **37,0** (notas: veloc 14,5 · acel 43,9 · fren 95,9 · curva 16,2). Caso de referência do doc: **M162183, 1.013,7 km → 44,6** (bate na diária e na anual).
- **ACHADO NÃO RESOLVIDO**: 758.007 curvas bruscas vs 37.247 frenagens (**20×**) e só 1 motorista em 2.234 zerou frenagem, contra 764 que zeraram velocidade. Severidade parecida com frequência 20× diferente = **limiares de disparo desalinhados no MyGeotab**. Enquanto não equalizar, o score mede também a configuração. Retirado do documento oficial por pedido do usuário (guia de uso, não de lacunas), mas segue verdadeiro.
- **REGRESSÃO DE PERF QUE EU CAUSEI E O USUÁRIO PEGOU (2026-09-09)** — `migracao_score_correcao_2026-09-09.sql`: pôr o score nas 2 views DIÁRIAS com CTEs que agregam `tb_comportamento_eventos`/`tb_viagens` INTEIRAS matou o uso interativo. `SELECT * LIMIT 200` na vw_saneago_comportamento foi de **0,1 s → 21,9 s (219×)**; motoristas 29,2 → 45,8 s; carregar filtro de 1 coluna no DBeaver = 106 s. Hash aggregate consome TODA a entrada antes da 1ª linha, então o LIMIT para de cortar trabalho. **Sintoma que o usuário viu**: DBeaver com "Recuperar dados de tabela - 1m3s" + barra `Load 'score_geotab_ano' values: (0%)` + erro 57014 (que é só o Cancel dele, não erro de SQL).
- **LIÇÃO DE MEDIÇÃO (a causa de eu não ter pego)**: medi com `count(*)`, que é varredura completa — ali o impacto parecia +4,6 s (5%) e eu reportei isso como "o custo". **Para custo de view, medir `SELECT * LIMIT 200`**, que é o que DBeaver/exploração fazem, e é exatamente o caso que CTE de agregação destrói.
- **CORREÇÃO**: score REMOVIDO das 2 diárias (restauradas ao original, comportamento voltou a 0,1 s) e criada `vw_saneago_veiculos_anual`. Score agora só em grão anual: motorista → motoristas_anual, veículo → veiculos_anual, período filtrado → DAX. Veículos: 33 baixo / 82 leve / 175 médio / 750 alto / 23 sem base (1.063 = frota inteira; antes 1.037 pois só entravam devices COM evento).
- Documento oficial (artifact, v1.0): https://claude.ai/code/artifact/dd0345c0-3344-475c-925e-6f3b9c86685f · DAX em `score_geotab_DAX.md`.
- ~~NÃO aplicado nas views do SEMAD~~ **APLICADO no SEMAD em 2026-09-15** (seção "SCORE GEOTAB NO SEMAD").
- **"TEVE GENTE COM SCORE 102" (2026-09-09) = era a `score_risco`, NÃO o score novo.** Auditado: 0 linhas > 100 nas 3 views (máx exato 100,0 / 99,8) e 0 km negativo (`min(distancia_km)=0`). A `score_risco` (pré-existente, ILIMITADA, maior=pior) tem **182 linhas exatamente em 102**, 10.483 acima de 100 e **máximo 613** na vw_saneago_motoristas. Linha comprovada: M143642 08/09, 30×3+5×2+0×2+2×1 = 102, com score_geotab_ano 49,6 na MESMA linha. **CAUSA: eu deixei 3 colunas chamadas "score" lado a lado** (score_risco ilimitada/invertida, score_seguranca 0-100 sem pesos, score_geotab 0-100 oficial). Rótulos sugeridos no `score_geotab_DAX.md`: score_geotab → "Score de Segurança (0-100)", score_risco → "Eventos Ponderados". NÃO renomeei a coluna (remover/renomear coluna já quebrou DAX em 25/08 — ver seção própria).
- **Teto de 100 restaurado na `nota_regra_geotab` (2026-09-09)**: ao trocar da escala calibrada p/ o Event Count eu removi o `LEAST(100, ...)` raciocinando que `100 - positivo` nunca passa de 100 — verdade só se o km for positivo. Com km negativo (correção de odômetro na origem) a divisão inverte e a nota estoura. Não era a causa do 102 (não há km negativo hoje), é blindagem: a função garante a escala 0..100 sozinha. Mesmo teto add nas 4 medidas DAX (`MIN(100, MAX(0, ...))`). Caso de referência inalterado (M162183 = 44,6).

## SCORE GEOTAB POR MÊS/ANO (2026-09-14) — `migracao_score_mensal_2026-09-14.sql` — APLICADO
- **Motivo: grão ANUAL não serve p/ o painel; o usuário quer o score no grão MÊS/ANO** (decisão explícita). Criadas 2 views NOVAS espelhando as anuais, grão `(entidade × ano,mes)`:
  - `vw_saneago_veiculos_mensal` — veículo × mês (espelha `vw_saneago_veiculos_anual`). Cols: id/serial/placa/veiculo/todos_grupos/grupo_id, `ano`,`mes`,`ano_mes` (YYYY-MM), viagens, `km_mes`, horas_movimento, 4 contadores, total_eventos, 4 `nota_*`, `score_geotab`, `faixa_risco_geotab`. Driven por FULL JOIN km(device×mês, de tb_viagens) × eventos(device×mês, de tb_comportamento_eventos) → JOIN vw_saneago_cadastro (herda grupo_visivel).
  - `vw_saneago_motoristas_mensal` — motorista × mês (espelha `vw_saneago_motoristas_anual`). Mesmas colunas de contexto do motorista + `ano`,`mes`,`ano_mes`, `km_mes`, horas, 4 contadores, 4 `nota_*`, `score_geotab`, `faixa_risco_geotab`.
- **km de tb_viagens (NÃO tb_resumo_mensal, defasada 11-14%)** — mesma fonte/metodologia das anuais. Piso **200 km/mês** (default de `score_geotab`, escolha do usuário): mês com <200 km → score NULL "Sem base", nunca nota 0.
- **PERF medida com `LIMIT 200` (a lição de 09/09)**: veiculos_mensal **20,5 s**, motoristas_mensal **27,1 s** — MESMA faixa das anuais aceitas (veiculos_anual 9,4 s / motoristas_anual 21,5 s). NÃO é a regressão de 219× (aquela era view diária de 0,1 s → 21,9 s). São views agregadas por natureza; no Power BI import é carga única no refresh.
- **VALIDAÇÃO** (ensaio BEGIN/ROLLBACK antes de aplicar): score 0..100, 0 fora de faixa, 0 km negativo. Soma do ANO no mensal reproduz a anual — eventos batem EXATO (veíc 2.850.172; mot 2.129.938), km com Δ de 34/68 km em ~10 M (arredondamento por grão). Ref. M162183: mensal soma 1013,8 km/202 ev vs anual 1013,7/202. Contagens: veiculos_mensal 11.632 linhas/1.422 veíc/10 meses; motoristas_mensal 17.252/2.788/10.
- **PODER BI**: relacionar `grupo_id` à dimensão e `ano_mes`/`ano,mes` ao calendário. Score de período filtrado continua sendo MEDIDA DAX (`score_geotab_DAX.md`); as views mensais dão o valor pré-calculado por mês. A `km_ano` das diárias que quebrou o BI NÃO voltou — o cliente deve apontar as tabelas de score p/ estas views mensais (ou anuais).
- ~~NÃO replicado no SEMAD~~ **REPLICADO no SEMAD em 2026-09-15** (ver seção abaixo). views.sql atualizado (1103 linhas, agora 12 views SANEAGO).

## SCORE GEOTAB NO SEMAD (2026-09-15) — `migracao_semad_score_geotab_2026-09-15.sql` — APLICADO
- **Pedido: trazer o "formato SANEAGO" (score_geotab 0-100) p/ o SEMAD, que só tinha soma.** O >100 que o usuário viu = a `score_risco` (soma ponderada `exc×3+acel×2+fren×2+curva×1`, ILIMITADA, maior=pior) — é CONTAGEM de eventos, não score 0-100; passar de 100 é natural. **Decisão: score_risco FICA como está** (não mexer no SQL das diárias — não quebra DAX); no painel renomear p/ "Eventos Ponderados". O 0-100 oficial passa a ser o `score_geotab`, igual à SANEAGO.
- **3 views novas/alteradas** (as 3 funções são globais; só se usam): `vw_semad_veiculos_anual` (NOVA) e `vw_semad_veiculos_mensal` (NOVA) = espelho EXATO das SANEAGO trocando `vw_saneago_cadastro`→`vw_semad_cadastro` + coluna `contrato` exposta; `vw_semad_motoristas_anual` ganhou `score_geotab`+`faixa_risco_geotab` no fim (score_seguranca preservada), CREATE OR REPLACE só adiciona coluna.
- **GRÃO: por VEÍCULO tem dado real** (motoristas SEMAD = 0 linhas, viagens sem condutor; score_geotab lá é só paridade, fica vazio). `grupo_id` COMPOSTO (grupo|contrato) herdado do cadastro; expõe `contrato` p/ fatiar 031 vs 035.
- **VALIDADO** (BEGIN/ROLLBACK + spot checks pós-aplicação): veiculos_anual 91 linhas / 72 com score / **0 fora de 0-100** / min 18,9 máx 92,9 média 65,1 (faixas: 28 alto, 22 médio, 21 leve, 1 baixo, 19 sem base). veiculos_mensal 178 linhas / 90 veíc / 2 meses / 0 fora / máx 96,1. **Soma do mês reproduz o ano: 0 veículos divergentes.** 0 órfão de grupo_id. SET: TFD2H94/035 → 55,5 Alto (253 km, 58 ev); TGG0G28/031 → Sem base (0,8 km < piso 200).
- **BI**: relacionar `grupo_id`→dimensão e `ano_mes`/`ano,mes`→calendário; apontar as tabelas de score p/ vw_semad_veiculos_anual/_mensal. Score de período filtrado = mesma MEDIDA DAX da SANEAGO (`score_geotab_DAX.md`). views.sql NÃO regenerado (SEMAD vive nas migrações).

## RESTRUCTURING DE GRUPOS NO GEOTAB → HIERARQUIA CONTRATO→SECRETARIA (2026-09-14) — `migracao_semad_hierarquia_2026-09-14.sql` + `migracao_saneago_visivel_2026-09-14.sql` — APLICADO
- **O que mudou na ORIGEM (Geotab, feito pelo usuário):** os contratos do SEMAD/COMURG/ECONOMIA deixaram de ser um token plano `OPE_<cliente> - NNN/AAAA` e viraram **grupo-PAI** (ex.: `SEMAD - 035/2026`) com **subgrupos por secretaria** (SMS, SEMASDH, SET, AMMA, PGM...). O veículo agora fica no subgrupo folha; a folha NÃO carrega mais o número do contrato.
- **COLUNA NOVA `tb_cadastro.todos_grupos_expandido`** (folha + TODOS os ancestrais), preenchida no sync: `extrair_cadastro` agora busca a árvore de grupos (`_indice_grupos`/`_grupos_com_ancestrais` — invertem `children[]` p/ achar pais e sobem a hierarquia). SEPARADA de propósito — **NÃO toca `todos_grupos`/`grupo_id` (compartilhados com a SANEAGO)**. Migração ADD COLUMN no bloco `migrar_colunas`.
- **SEMAD — inclusão por hierarquia:** `tb_contrato_semad` = `SEMAD - 035/2026` + `SEMAD - 031/2026` (os `OPE_SEMAD - ...` que cheguei a inserir estavam ERRADOS — o nome do grupo-pai é `SEMAD - NNN/2026`, sem `OPE_`). Só `vw_semad_cadastro` e `vw_semad_grupos` filtram direto → passaram a usar `grupo_semad(todos_grupos_expandido)` (as outras 8 herdam via JOIN vw_semad_cadastro). Display/grupo_id seguem na FOLHA (quebra limpa por secretaria). **RESULTADO: 91 veículos (035=90, 031=1)**, exatamente o que o usuário disse. status 91, viagens 12.769, abastecimento 284, grupos 22 (secretarias).
- **COLUNA `contrato` (2026-09-14, parte 2)** — `contrato_semad(expandido)` (STABLE) retorna o(s) token(s) de `tb_contrato_semad` que casam no expandido → identifica **035 vs 031** no grão veículo. Adicionada como ÚLTIMA coluna de `vw_semad_cadastro` (CREATE OR REPLACE só adiciona no fim; inserir no meio dá "não é possível alterar nome da coluna"). 90 em 035, 1 em 031. As 7 views de fato herdam via JOIN (podem expor `c.contrato` se quiserem fatiar por contrato).
- **`vw_semad_grupos` ENXUTA (2026-09-14, parte 3)** — a pedido do usuário, reduzida a **`grupo_id`, `grupo`, `contrato`** (DROP+CREATE; 0 dependentes). As colunas de hierarquia SUP_/REG_/ULOT_/OPE_ eram TODAS vazias no SEMAD (grupos são só secretarias). 21 linhas (1 por secretaria). Há **2 grupos distintos de nome "SET"** (um filho de cada contrato) → a linha SET mostra os 2 contratos concatenados (os 2 veículos vão certo p/ 035 e 031 no cadastro). `grupo_id`=hashtext(grupo) casa com o grupo_id de vw_semad_cadastro (relação do BI preservada).
- **SANEAGO — vazamento causado pelo restructuring, CORRIGIDO.** Com os outros clientes sem `OPE_<cliente>` na folha, `grupo_visivel()` (exclusão por prefixo na folha) parou de reconhecê-los → COMURG/ECONOMIA/SEMAD **vazaram p/ o painel SANEAGO** (1062 → 1425). **Viria na sync diária de qualquer forma** (não foi bug do meu código — só ADICIONEI coluna; o re-sync antecipou). FIX: nova função `saneago_visivel(expandido)` = **tem `OPE_SANEAGO` E nenhum marcador de outro cliente**, trocada SÓ nos 2 sites de VEÍCULO (`vw_saneago_cadastro` WHERE + ramo tb_cadastro de `vw_saneago_grupos`). **Motoristas intactos** (seguem `grupo_visivel(m.todos_grupos)`; companyGroups não reestruturados). **grupo_id NÃO muda** (só o WHERE; SELECT segue lendo a folha SUP_/REG_/ULOT_). RESULTADO: cadastro **1061** (=1062 clean − 1 placa da exclusão pré-existente), 0 vazamento, grupos 788, veiculos_anual 1061; SEMAD segue 91.
- **DIAGNÓSTICO-CHAVE (bucket por marcador no expandido):** OPE_SANEAGO & sem-outro = **1062** (frota conhecida, casa exato); outro-cliente & sem-SANEAGO = 526; **DUPLO-MARCADOS (OPE_SANEAGO + outro) = 333** — reorg inacabada, ficam de fora até o usuário limpar no Geotab (vão para 1 cliente só). Usuário NÃO sabe ainda o que são os 333 (pendência de investigação; posso exportar a lista).
- views.sql: função `saneago_visivel` add ao lado de `grupo_visivel`; predicados das 2 views SANEAGO trocados. Views SEMAD seguem fora do views.sql (definição vive na migração). Backup de hoje (08:08) veio **0 bytes** (falhou; só o de 02/09 tem conteúdo — investigar o backup_geotab.bat).
- **PENDÊNCIAS:** (a) investigar/limpar os 333 duplo-marcados na origem; ~~(b) SEMAD por CONTRATO~~ RESOLVIDO (coluna `contrato`); ~~(c) replicar score mês/ano no SEMAD~~ RESOLVIDO 2026-09-15 (por VEÍCULO anual+mensal); (d) backup diário falhando.

## MIGRAÇÃO GOOGLE CLOUD SQL (2026-09-22) — EM ANDAMENTO, BLOQUEADA NA REDE
- Destino: projeto `gcp-db-sian-citizen-dev` → instância `sian-citizen-postgres-dev` (POSTGRES_16,
  southamerica-east1, db-custom-1-3840, disco 30 GB). IP público 34.39.208.223, privado 172.25.12.3.
  connectionName: `gcp-db-sian-citizen-dev:southamerica-east1:sian-citizen-postgres-dev`.
- IAM do usuário: SÓ LEITURA. Tem instances.get/list/connect, databases.list, users.list.
  NÃO tem databases.create, instances.update, instances.login, users.create. → não cria banco.
- CONTORNO: não usa banco próprio. Tabelas vão no schema **`geotab`** dentro do banco **`maas_man`**
  (schema criado como `"Geotab"`, renomeado p/ minúsculo; usuário `ygor.kouzak` é o DONO → CREATE ok).
  Criar schema/tabela é SQL, o IAM não alcança. Testado: CREATE/INSERT/SELECT OK no Studio.
- `search_path` do usuário no banco: `ALTER ROLE "ygor.kouzak" IN DATABASE maas_man SET search_path = geotab, public;`
- Código: nova chave `SUPABASE_SCHEMA` (.env, comentada). `criar_engine()` vira
  `options=-c search_path=<schema>` quando preenchida. Vazia = comportamento local (public) intacto.
  ZERO mudança de SQL — nem no script, nem nas 13 views do views.sql. Testado contra o local.
- REDE LIBERADA (2026-09-22): T.I. adicionou `200.195.234.205/32` (name "Maas") nas
  authorizedNetworks. CONEXÃO DO PC VALIDADA de ponta a ponta — ver `testar_cloudsql.py`.
  Servidor real: PostgreSQL 16.14. Schema `geotab` ainda vazio (0 tabelas).
- Usuário `ygor.kouzak` é **BUILT_IN** (senha nativa, NÃO é IAM) — confirmado por
  `gcloud sql users list`. Senha no .env em `GCP_SENHA` (bloco GCP_* separado do SUPABASE_*).
- PENDENTE (T.I.): usuário de aplicação. Convenção da casa na instância: `db_maas_man_user`,
  `db_sian_gg_user`, `db_sian_gtsi_user`, `urbi_gipe_user`, `maas_backend` → pedir `db_geotab_user`.
  Rodar o sync diário com conta pessoal é frágil (conta desativada = carga para).
- SELETOR DE DESTINO (aplicado): `GEOTAB_DESTINO=local|cloud` (default local). `cloud` lê as
  chaves `GCP_*`; `local` lê `SUPABASE_*`. Banner no início do main mostra o destino. A tarefa
  agendada não define a var → produção intocada. `testar_cloudsql.py` diagnostica a conexão.
- ENSAIO 2026-09-22: schema `geotab` com 16 tabelas + 22 funções. Carregados cadastro (1.606),
  motoristas (5.689), status (1.606). Contagens NÃO batem com o local (cadastro local=1.988)
  porque a nuvem é extração nova da API e o local tem histórico acumulado — esperado.
- ⚠️ O `geotab_supabase.py` só cria as 11 tabelas de dados. Faltavam no schema novo:
  5 tabelas auxiliares (`migracao_gcp_tabelas_auxiliares_2026-09-22.sql`) e 22 funções SQL
  (`migracao_gcp_funcoes_2026-09-22.sql`). O modo `comportamento` QUEBRA sem as funções
  (`marca_padrao`/`modelo_padrao`/`arrumar_grupos` no SQL de `tb_odometro_mensal`).
- ⚠️ ARMADILHA: `pg_get_functiondef()` embute `public.` no corpo (38 ocorrências). Copiado cru
  p/ a nuvem, as funções leriam o `public` do `maas_man` (sistema de manutenção). O arquivo
  gerado remove o prefixo — resolução fica com o `search_path`.
- CARGA: `copiar_para_cloudsql.py` (COPY TO STDOUT -> COPY FROM STDIN via os.pipe, memoria
  constante, idempotente por contagem). CSV nao tem acoplamento de versao → contorna 18 vs 16.
- ⚠️⚠️ ARMADILHA GRAVE: COPY sem lista de colunas casa por POSICAO. Local evoluiu por ALTER ADD
  COLUMN (coluna nova no fim), nuvem nasceu na ordem do DDL. `tb_viagens` pos.8: hodometro_final
  (local) ↔ distancia_km (nuvem), MESMOS TIPOS = grava errado SEM ERRO. Tambem desalinhadas:
  tb_motoristas, tb_odometro_mensal. O script usa lista explicita. NUNCA copiar sem ela.
- DEFEITO PRE-EXISTENTE CORRIGIDO: `tb_status.viagem_fim` nao era criada pelo `criar_tabelas()`
  (veio de migracao avulsa), mas o views.sql a usa → instalacao nova quebrava nas views.
  Adicionada ao CREATE + `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` idempotente.
- CORRECAO DE DIAGNOSTICO: `pg_stat_user_tables.n_live_tup` estava DESATUALIZADO (stats zeradas
  por shutdown sujo). tb_viagens tem 6.058.858 linhas REAIS, nao 31.995 — os 3 GB sao dado
  legitimo, NAO inchaco. Nao ha VACUUM FULL a fazer. Usar count(*) para numeros que importam.
- Disco da instancia: 1,75 GB usados de 30 GB (maior banco: sian_gg 1,37 GB). Cabe com folga.
- Ordem p/ montar o schema do zero: cadastro → aux → funções → demais modos → views.sql.
- Carga inicial: NÃO usar pg_dump/pg_restore (local é PG 18.4, destino PG 16 — downgrade não
  suportado). Repopular pela API Geotab + rodar views.sql com search_path=geotab.
- CARGA COMPLETA OK (2026-09-22): 16 tabelas + 22 funcoes + 13 views no schema geotab.
  tb_viagens: 6.058.858 linhas em 4min32s (22.289 linhas/s). Integridade PROVADA: md5 de todos
  os ids com `ORDER BY id COLLATE "C"` bate nos dois bancos.
- COLLATION DIFERENTE (nao ajustavel): local `Portuguese_Brazil.1252` x nuvem `en_US.UTF8`
  (o maas_man ja nasceu assim e nao podemos criar banco). Efeito: ORDER BY em texto ordena
  diferente. Impacto baixo — o views.sql quase nao usa ORDER BY (decisao de performance).
  md5 de ids so divergia por isso; com COLLATE "C" bate.
- Soma de `double precision` diverge no ultimo digito (305 bilhoes → 0,1). Ponto flutuante nao
  e associativo; a ordem de agregacao muda. NAO e erro de dados.
- ⚠️ views.sql CRIAVA 19 funcoes como `public.xxx` — rodado na nuvem, poluiria o public do
  maas_man (sistema de manutencao) e deixaria as views apontando p/ la. As 35 ocorrencias de
  `public.` foram REMOVIDAS do views.sql: agora e agnostico de schema e serve aos dois destinos
  (no local o search_path resolve p/ public). Verificado: 0 objetos nossos no public do maas_man.
- Pos-COPY e obrigatorio ANALYZE (planejador sem estatisticas). Feito nas 16 tabelas.
- VALIDACAO DAS VIEWS: 12/13 com contagem IDENTICA local x nuvem.
- ⛔ ABERTO: `vw_saneago_comportamento` NAO roda na nuvem (>300s; no local 103s). O gargalo e
  `arrumar_grupos`/`nivel_grupo` chamadas por linha. `LIMIT 200` leva os MESMOS 103s no local →
  ha agregacao bloqueante, o LIMIT nao ajuda. Instancia e 1 vCPU (db-custom-1-3840) contra a
  maquina local. Opcoes: (a) pedir tier maior a T.I.; (b) otimizar a view/funcoes;
  (c) MATERIALIZED VIEW refrescada pelo sync — ajudaria o local tambem, onde 103s ja e ruim.
- sslMode da instância = ENCRYPTED_ONLY → `SUPABASE_SSLMODE=require` quando migrar.

## tb_contrato_semad RECRIADA (2026-09-23) — `migracao_contrato_semad_2026-09-23.sql`
- Sintoma: Power BI dava 42P01 "tb_contrato_semad nao existe" na `vw_semad_status`. A tabela
  NAO existia no local nem na nuvem. A view sobrevivia sem ela porque quem a referencia e a
  funcao `contrato_semad()` — Postgres NAO registra dependencia atraves de funcoes, entao o
  erro so aparece na execucao. Problema anterior a migracao p/ o GCP.
- ⚠️ SEED: usar os tokens do desenho VIGENTE (2026-09-14) = nomes dos grupos-PAI SEM prefixo:
  'SEMAD - 035/2026' e 'SEMAD - 031/2026'. O seed de `migracao_semad_2026-08-27.sql`
  ('OPE_SEMAD - 035/2026') esta OBSOLETO e devolve 0 linhas EM SILENCIO.
- Aplicada no LOCAL e na NUVEM. Conferencia: 035=90 veiculos (bate exato com o documentado em
  14/09 → token correto); 031=14 (era 1 em 14/09 — a frota cresceu nos 9 dias). Total 104.
- As 12 views `vw_semad_*` voltaram a rodar no local (vw_semad_status = 104 linhas).
  `vw_semad_motoristas` e `_anual` em 0 linhas = ressalva JA documentada (tb_motoristas nao
  tem todos_grupos_expandido), nao e regressao.
- RESOLVIDO (2026-09-23): as 12 `vw_semad_*` foram aplicadas na nuvem —
  `migracao_gcp_views_semad_2026-09-23.sql`. Nuvem agora tem 25 views (13 saneago + 12 semad),
  mesmo total do local. Verificado: 0 objetos nossos vazados p/ o public do maas_man.
- ⚠️ NAO replicar os `migracao_semad_*.sql` na nuvem: o de 2026-08-27 traz o INSERT do token
  OBSOLETO 'OPE_SEMAD - 035/2026' em tb_contrato_semad. O arquivo novo foi gerado do ESTADO
  ATUAL do local via `pg_get_viewdef` — mesma tecnica usada para as 22 funcoes.
- VALIDACAO SEMAD: 9/12 views com contagem identica. As 3 divergentes (abastecimento,
  comportamento, relatorio_viagens) sao views de FATO e a causa e defasagem de snapshot: o sync
  local rodou em 2026-09-23 08:40 e somou 32.022 viagens; a nuvem e o retrato de 2026-09-22.
  As 9 de DIMENSAO batem exato. Nao e erro.

## VALIDACAO LOCAL x CLOUD (2026-09-23) — `validar_local_x_cloud.py`
- Script de 3 camadas: ESTRUTURA (tabelas/colunas/tipos/funcoes/views), CONTAGEM por tabela,
  CONTEUDO (checksum total se a contagem bate; senao amostra da nuvem conferida pela PK no
  local, dissecando QUAIS COLUNAS divergem).
- ⚠️ DOIS ERROS DE METODO QUE INVALIDAM A COMPARACAO (ambos ja evitados no script):
  (a) `md5(linha::text)` serializa na ORDEM das colunas → deu 800/800 divergentes em tb_viagens
      com dado IDENTICO. Usar `ROW(col_a, col_b, ...)` em ordem ALFABETICA.
  (b) `ORDER BY` sem `COLLATE "C"` → collations diferentes mudam o md5 agregado sem o dado mudar.
- RESULTADO: estrutura IDENTICA (17 tabelas, 141 colunas, 22 funcoes, 25 views). NENHUMA linha
  orfa — toda linha amostrada da nuvem existe no local. tb_viagens: 800/800 identicas.
- Divergencias 100% explicadas: (1) tb_cadastro/tb_motoristas/tb_odometro_mensal diferem SO em
  `atualizado_em` (o sync recarimba toda linha); (2) tb_status e tabela de TEMPO REAL — muda
  inteira a cada run (se NAO mudasse e que seria suspeito); (3) 7 tabelas de fato com mais
  linhas no local = o sync de hoje 08:40.
- ORDEM DAS COLUNAS difere em tb_viagens, tb_motoristas, tb_odometro_mensal, tb_status. Benigno
  (copia usa lista explicita; Power BI le por views com colunas nomeadas). A NUVEM e que esta na
  ordem canonica do criar_tabelas(); o LOCAL e que derivou por ALTER TABLE ADD COLUMN.

## APOSENTAR A MAQUINA LOCAL? (2026-09-23) — TESTE PARCIAL, PROMISSOR
- Contexto: o Render foi aposentado porque o WAF da Geotab bloqueava o IP. Dai a duvida se um
  IP do GCP (datacenter, mesma categoria) seria bloqueado tambem.
- TESTE 1 (feito, Cloud Shell): `GetVersion` (NAO autenticado) → **HTTP 200**. Nao ha bloqueio
  de faixa de IP na entrada. NAO prova autenticacao nem tolerancia ao volume do sync.
- TESTE 2 (pendente): chamada `Authenticate` a partir do Cloud Shell. Se voltar "credentials",
  o caminho esta aberto; se voltar "error", o WAF barra na autenticacao.
- RESTRICAO: mesmo com os 2 testes OK, criar Cloud Run Job / Scheduler / VM exige IAM que o
  usuario NAO tem (somente leitura no projeto). Nivel 2 = projeto da T.I., nao configuracao.
- DOIS NIVEIS DE "DESATIVAR O LOCAL":
  1. Aposentar o POSTGRES local → `GEOTAB_DESTINO=cloud` no .env. A maquina vira so o agente
     que puxa da Geotab e grava no Cloud SQL. Fazivel hoje.
  2. Aposentar a MAQUINA → depende dos testes acima + provisionamento pela T.I.
- ⚠️ FURO NA VIRADA: `exportar_csv.py` NAO passa pelo `criar_engine()` — chama o psql.exe direto
  e le `SUPABASE_*` por conta propria (linhas 38-42). Com GEOTAB_DESTINO=cloud, o sync gravaria
  na nuvem e o export continuaria lendo o LOCAL congelado, publicando CSV velho para clientes
  externos SEM ERRO. Precisa do mesmo seletor ANTES da virada.
- ⛔ BLOQUEADOR DA VIRADA: `vw_saneago_comportamento` nao roda na nuvem (>300s) E esta na lista
  de views exportadas p/ CSV. Hoje e relatorio lento; depois da virada, relatorio que nao sai.
  Resolver ANTES (MATERIALIZED VIEW resolve nos dois bancos).
- SEQUENCIA RECOMENDADA: (1) materializar a view; (2) seletor no exportar_csv.py; (3) pedir
  `db_geotab_user` a T.I.; (4) conferir backups automaticos do Cloud SQL; (5) virar p/ cloud e
  observar 1 dia; (6) repontar Power BI; (7) so entao desligar o Postgres local, mantendo-o
  instalado algumas semanas como rede de seguranca.

## MV DE COMPORTAMENTO + SELETOR NO EXPORT (2026-09-23) — APLICADO NOS DOIS BANCOS
- `vw_saneago_comportamento` virou casca sobre `mv_saneago_comportamento`
  (`migracao_mv_comportamento_2026-09-23.sql`, ja incorporado ao views.sql).
  Local: 103s → 0,02s. Nuvem: NAO RODAVA (>300s) → 0,19s. Construcao inicial na nuvem: 383s.
- REFRESH: `atualizar_mv_comportamento()` no geotab_supabase.py, ao fim do modo `comportamento`.
  CONCURRENTLY (135s no local); leitor concorrente respondeu em 0,009s durante o refresh.
  Exige o indice unico `ux_mv_saneago_comportamento (id, data)` — conferido 139.694/139.694.
  NAO-FATAL: banco novo ainda sem MV nao derruba o sync.
- ⚠️⚠️ ARMADILHA: **CREATE e REFRESH de MATERIALIZED VIEW rodam com search_path RESTRITO**
  (pg_catalog, pg_temp). Como as funcoes ficaram agnosticas de schema, elas quebram nos DOIS
  ("relacao tb_veiculo_correcao nao existe", dentro de marca_padrao). Vale o mesmo p/ indices
  com expressao. FIX: bloco DO no views.sql com
  `ALTER FUNCTION ... SET search_path = current_schema(), pg_temp` nas 22 funcoes.
- ⚠️ A ORDEM DESSE BLOCO IMPORTA: ele fica DEPOIS das funcoes e ANTES da MV, porque
  `CREATE OR REPLACE FUNCTION` **DESCARTA as clausulas SET** — toda reexecucao do views.sql
  desfixa as 22 funcoes e precisa refixa-las antes de chegar na MV. Com o bloco no fim do
  arquivo, a criacao da MV falhava em TODA reexecucao.
- ⭐ CAUSA RAIZ DA LENTIDAO (2026-09-23): NAO era volume. O planejador inlineava a
  `vw_saneago_cadastro` dentro do JOIN e reavaliava arrumar_grupos()/nivel_grupo()/marca_padrao()
  UMA VEZ POR LINHA DE SAIDA (139 mil) em vez das 1.061 linhas de cadastro. FIX: envolver a
  cadastro num `WITH cad AS MATERIALIZED (...)` no corpo da MV. Linhas de saida IDENTICAS.
- NUMEROS (antes -> depois do CTE MATERIALIZED):
    corpo da consulta, local .... 121,1s -> 4,4s   (27,6x)
    REFRESH CONCURRENTLY, local .. 135s  -> 7,0s
    REFRESH CONCURRENTLY, nuvem .. 720s  -> 8,9s   (81x)
    reconstrucao da MV, nuvem .... 383s  -> 5,2s
  Leitura segue instantanea (0,04s local / 0,05s nuvem).
- TABELA INCREMENTAL: DESCARTADA, virou desnecessaria. Recalcular o ano inteiro custa 9s.
- A preocupacao com CPU saturada na instancia compartilhada (6 bancos, 1 vCPU) caiu junto:
  de 12 min/dia para ~9s.
- VARREDURA FEITA (2026-09-23): 8 views corrigidas com CTE MATERIALIZED, todas com resultado
  IDENTICO (contagem + hash). relatorio_viagens 100,5s->9,9s | motoristas 43,0s->9,7s |
  semad_relatorio_viagens 28,4s->2,1s | abastecimento 10,4s->1,1s | veiculos_anual 4,8s->1,5s |
  indicadores_mensal 2,0s->0,3s | resumo_frota_mensal 2,0s->0,3s | semad_comportamento 1,4s->0,1s.
- DUAS FORMAS DO MESMO BUG: (a) view de cadastro inlineada no JOIN -> `WITH cad AS MATERIALIZED`;
  (b) vw_saneago_motoristas NAO usa cadastro — funcoes aplicadas direto em tb_motoristas (5.713)
  dentro de JOIN de 182 mil linhas -> CTE `mot AS MATERIALIZED` pre-calculando _grupos/_visivel.
- ⚠️ MEDIR POR count(*) ENGANA: em relatorio_viagens o count(*) dava 0,9s ANTES e 1,6s DEPOIS
  (parecia piora!), porque o planejador descarta as colunas da cadastro. Medindo o caminho REAL
  (1 mes, todas as colunas, como o exportar_csv.py le): 100,5s -> 9,9s.
- NAO ALTERADAS por nao ganharem (testadas): motoristas_mensal 1,2x, motoristas_anual 0,9x,
  semad_motoristas 1,1x, semad_motoristas_anual 0,7x — duas PIORAVAM.
- ONDE CADA VIEW MORA: 13 vw_saneago_* no views.sql; 12 vw_semad_* em
  migracao_gcp_views_semad_2026-09-23.sql. `vw_saneago_abastecimento` tem
  `WITH (security_invoker = on)` entre o nome e o AS — preservado.
- `CREATE MATERIALIZED VIEW IF NOT EXISTS` NAO troca o corpo de MV existente. Mudar a logica
  exige `DROP MATERIALIZED VIEW ... CASCADE` + rodar views.sql.
- views.sql reexecutavel: 0,0s local / 0,2s nuvem, MV intacta, 25 views.
- `exportar_csv.py` agora respeita `GEOTAB_DESTINO` (antes lia SUPABASE_* direto via psql.exe e
  publicaria CSV do banco local congelado apos a virada). Testado nos 2 destinos via psql real.
  Passa PGSSLMODE e PGOPTIONS=-c search_path=<schema>.

## POSTGRES LOCAL: COMO (NAO) INICIAR (2026-09-23)
- ⚠️ O banco MORRE junto com o processo que o iniciou. Subir por terminal/tarefa em segundo
  plano amarra o postmaster aquele grupo de processos — encerrar a tarefa DERRUBA o banco, sem
  janela rotulada para avisar. Assinatura no server.log: `0xC000013A` (STATUS_CONTROL_C_EXIT),
  NAO e falta de memoria. Ja documentado no proprio iniciar_postgres.bat.
- SEMPRE subir com `iniciar_postgres.bat` (idempotente, usa `-l` e deixa a janela rotulada).
  Via ferramenta: `Start-Process -FilePath iniciar_postgres.bat` desacopla; rodar `pg_ctl start`
  direto NAO desacopla.
- Se travar e `pg_ctl stop` falhar: matar os postgres.exe, apagar `postmaster.pid` orfao do
  pgdata, rodar o .bat. WAL protege os dados (redo levou 0,00s no caso real de 2026-09-23;
  12 tabelas, 25 views e 22 funcoes vieram intactas).
- Erros conhecidos e TRANSITORIOS no Windows (no log desde agosto, sem perda de dados):
  `could not reserve shared memory region ... error code 487` e `0xC0000142`.
- MELHORIA PENDENTE: `server.log` esta DENTRO do pgdata → na recuperacao o Postgres tenta abrir
  o proprio log travado pelo redirecionador ("violacao de compartilhamento", tenta 30s e segue).
  Mover o log p/ fora do pgdata. Correcao de fundo: Postgres como SERVICO do Windows.
  Some com a migracao p/ Cloud SQL.

## CAMPO combustivel NA VIEW DE ABASTECIMENTO (2026-09-23) — no views.sql
- ⚠️ NAO e o produto abastecido: e a CLASSIFICACAO DO VEICULO na Geotab. Ela DEDUZ o
  abastecimento pela subida do nivel do tanque (telemetria, nao extrato de cartao) e nao sabe o
  que entrou. `FuelUpEvent.productType` = 'Unknown' em 100% dos 59.508 eventos; a coluna
  `tipo_combustivel` foi mantida so por compatibilidade.
- FONTE: hierarquia de grupos da Geotab — `Powertrain and Fuel Type` > `Internal Combustion
  Engine` > Diesel / Ethanol / Gasoline or Petrol. Ideia do usuario ("na coluna todos_grupos tem
  informacoes uteis") — estava certo. Os tokens ja estavam em tb_grupo_token_ignorado.
- ⚠️ A funcao `combustivel_veiculo()` le a coluna CRUA `tb_cadastro.todos_grupos`. O
  todos_grupos das VIEWS ja passou por arrumar_grupos() e PERDEU o token. Cru = 1.914/1.988
  veiculos; expandido = 1.872 (pior).
- Campo adicionado na `vw_saneago_cadastro` (atributo do veiculo → toda view que usa a cadastro
  herda) e exposto na `vw_saneago_abastecimento`. Etanol+Gasolina no mesmo veiculo = 'Flex'.
- ⚠️ ORDEM NO views.sql: a funcao precisa vir ANTES das views. Colocada depois, o local passou
  (a funcao ja existia do teste) e a NUVEM quebrou — `combustivel_veiculo(text) does not exist`.
  Testado derrubando a funcao de proposito e reaplicando o arquivo: se basta.
- ⚠️ ANALISE: a divisao Etanol x Gasolina e ARTEFATO DE CADASTRO. 578 Saveiros como Etanol e 80
  como Gasolina — todos flex. Somar litros por combustivel: tratar Etanol+Gasolina como um grupo.
  Diesel e confiavel. Na view SANEAGO quase nao ha diesel (filtro de veiculos visiveis, quase
  todos leves); na frota inteira sao 13.891 abastecimentos a diesel.
- REPLICADO NO SEMAD (2026-09-23): campo tambem em `vw_semad_cadastro` e
  `vw_semad_abastecimento`. 4 views carregam a coluna. SEMAD: Etanol 72,7% | Diesel 24,0% |
  sem classificacao 3,4% (proporcao bem diferente da SANEAGO — la o diesel e 0,1%).
- ⚠️ ORDEM DENTRO DO migracao_gcp_views_semad_*.sql: o arquivo nasceu em ordem ALFABETICA, entao
  `vw_semad_abastecimento` vinha ANTES de `vw_semad_cadastro` e quebrava ao precisar da coluna
  nova ("coluna c.combustivel nao existe"). Arquivo REORDENADO: cadastro primeiro, pois todas as
  outras fazem JOIN com ela.

## VEICULO NO RESUMO MAS NAO NO ABASTECIMENTO (2026-09-23) — NAO E BUG
- Toda placa do abastecimento esta no resumo; o inverso falha em 4 de 1.062 (SANEAGO).
- CAUSA: a Geotab deduz o abastecimento pela subida do NIVEL DO TANQUE. Sem leitura de nivel,
  nao ha FuelUpEvent. Confirmado na API (StatusData/DiagnosticFuelLevelId, 14 dias):
  os 4 ausentes tiveram 0 ou 1 leitura; controles com abastecimento tiveram 446 e 536.
- NAO e falta de uso: os 4 rodam o ano todo, 2.862-5.979 viagens, ate 19.837 km — ACIMA da
  mediana da frota (2.467 viagens / 8.051 km).
- FROTA INTEIRA: 43 veiculos ativos com >=50 viagens e ZERO abastecimento. Dois problemas:
  (a) SISTEMATICO, classes inteiras: ATEGO 2426 (11/11), DELIVERY 9.180 (9/9), ATEGO 1419 (2/2),
      ATEGO 1719 (2/2) = 24 veiculos, 100% do modelo → compatibilidade do rastreador com o
      barramento do caminhao; pauta p/ o fornecedor da telemetria.
  (b) ISOLADO, ~19 veiculos de modelos que funcionam (Saveiro 2/657, Argo 2/393, Ducato 2/48).
- ⚠️ DUAS CAUSAS DIFERENTES p/ "esta no resumo mas nao no abastecimento":
  (1) SENSOR MUDO — muitas viagens E muitos km, zero abastecimento (caso SANEAGO, 4 placas).
  (2) NAO RODOU — veiculo recente, poucas viagens e ~ZERO km (caso SEMAD, 23 das 103 placas:
      entraram entre 24/08 e 16/09/2026, 2-67 viagens, 18 das 23 com ZERO km). Aparecem sozinhos.
  DISTINGUIR PELOS KM antes de acionar fornecedor. Confirmar na API: StatusData +
  DiagnosticFuelLevelId, 14 dias — saudavel devolve centenas de leituras (13%-100%), mudo 0 ou 1.
- PLACAS COM ESPACO: CORRIGIDO em 2026-09-24, nos dois bancos. Eram 4.603 valores
  (tb_cadastro.placa 207 + veiculo 13, tb_status.placa 207, tb_odometro_mensal.placa 3.726 +
  veiculo 450). Nenhuma coluna de CHAVE afetada (JOINs sao por device_id).
  TRES CAMADAS: (1) origem — .strip() nos 3 pontos de escrita do geotab_supabase.py + btrim no
  SQL de tb_odometro_mensal (sem isso o sync sujava de novo no dia seguinte);
  (2) passivo — `migracao_placas_btrim_2026-09-24.sql`, idempotente;
  (3) views — btrim na placa das 2 views de cadastro, como cinto de seguranca.
- ⚠️ A MV NAO SE ATUALIZA SOZINHA: apos limpar as tabelas, `vw_saneago_comportamento` continuou
  devolvendo placa suja (1.055 valores) — `CREATE MATERIALIZED VIEW IF NOT EXISTS` nao reconstroi
  conteudo. Exigiu REFRESH. TODA correcao de dado exige refresh da MV.
- ⚠️ ACHADO NAO CORRIGIDO: 8 PARES DE PLACA DUPLICADA (mesma placa, 2 device_id) = trocas de
  rastreador; o registro antigo ficou com o historico. Ex.: RCG5B89 com 5.767 viagens ate 05/06
  num device e 6.646 ate 23/09 noutro. 4 desses pares (C422102, RBO7D02, SCF8D32, SGZ6E17) JA
  estavam duplicados SEM espaco — o btrim nao criou o problema, so revelou mais 4.
- PLACAS DUPLICADAS: RESOLVIDO (2026-09-24) pela view `vw_placa_resolvida`, no views.sql ANTES
  das views de cadastro. Regra do usuario (ajustada em 2026-09-24): troca de device (ambos com
  viagem) -> o device ATUAL mantem a placa LIMPA e o ANTIGO ganha o sufixo " -OFF"
  (ex.: "RCG5B89" e "RCG5B89 -OFF"); 3+ devices na mesma placa -> " -OFF 2", " -OFF 3" so p/ nao
  reduplicar. Linha FANTASMA (zero viagem) -> `ocultar`=true e as
  views de cadastro a descartam (unifica). Ordenacao: tem_viagem DESC, ultimo_contato DESC.
  EXISTS sobre tb_viagens so p/ as duplicadas (16 linhas) via ix_viagens_device -> 0,01s.
  Resultado: 0 placas duplicadas nas views; contagens inalteradas (1063 / 104).
- ⚠️ 2 LUGARES ESCAPAM DA REGRA DA PLACA (corrigido 2026-09-24): (1) a MV
  mv_saneago_comportamento serve o valor antigo ate o REFRESH — o sync diario ja refresca, mas
  mudanca fora do ciclo exige manual; (2) vw_saneago_status e vw_semad_status liam `s.placa` da
  tb_status em vez de `c.placa` da view de cadastro. VIEW NOVA COM PLACA: sempre tirar da view
  de CADASTRO, nunca da tabela. Conferir varrendo information_schema por views com coluna placa.
- TABELA TAMBEM CORRIGIDA (2026-09-24): `resolver_placas_duplicadas(engine, tabela)` grava o
  sufixo em tb_cadastro e tb_status, chamada LOGO APOS cada upsert no geotab_supabase.py.
  OBRIGATORIO: o upsert traz a placa crua da API e desfaz o sufixo -- sem o passo seguinte a
  tabela reduplica todo dia. A funcao LE a vw_placa_resolvida e aplica (logica num lugar so).
- ⚠️ A VIEW PRECISA SER IMUNE AO PROPRIO SUFIXO: com a tabela contendo 'RCG5B89 -OFF', a
  vw_placa_resolvida deixaria de ver o par como duplicado e PARARIA de ocultar as fantasmas.
  Ela normaliza antes de agrupar: regexp_replace(btrim(placa), '\s*-OFF( \d+)?$', '').
  Resultado: view idempotente e UPDATE idempotente (2a passada = 0 linhas).
- TABELA x VIEW: na tabela as 4 fantasmas ficam VISIVEIS e marcadas com -OFF (nao da p/ sumir com
  o registro do dispositivo sem apagar); nas views continuam OCULTAS. Unica duplicidade restante
  na tabela: a placa VAZIA (25 linhas) -> corrigir o licensePlate no Geotab.
- 25 PLACAS VAZIAS: a placa EXISTE, no campo errado — esta no NOME do veiculo
  ("TGE7H14 | VOLKSWAGEN | 26.260"), com licensePlate em branco. Lista com a placa ja extraida:
  `veiculos_sem_placa_2026-09-24.csv` (23 claras, 1 a revisar com espaco no meio 'TGG 4A94',
  1 sem placa no nome). Corrigir no Geotab; o sync passa a trazer sozinho.
- ⚠️ CUIDADO AO QUALIFICAR COLUNAS: ao adicionar o JOIN com vw_placa_resolvida, um regex meu
  qualificou tambem o ALIAS ('AS c.todos_grupos') e quebrou o SQL. Conferir sempre o bloco final.
- Lista: `veiculos_sem_nivel_tanque_2026-09-23.csv`. km/L e litros NAO existem p/ esses 43 —
  nenhum ajuste de SQL resolve, o dado nao e coletado.

## SENHA DO POSTGRES LOCAL ROTACIONADA (2026-09-24)
- Motivo: estava em texto claro em psql_geotab.bat e backup_geotab.bat (VERSIONADOS) -> foi p/ o
  historico do repo, que agora vive em github.com/ygormaas/geotab.
- Feito: (1) os .bat passaram a ler SUPABASE_SENHA do .env; (2) senha rotacionada (28 chars
  alfanumericos + _ -; sem % ^ & | < > p/ nao quebrar batch). Valor so no .env.
- Verificado: senha ANTIGA recusada ("autenticacao do tipo senha falhou"); NOVA funciona em
  criar_engine (sync), exportar_csv (psql) e nos .bat.
- Historico do git NAO foi reescrito: custo alto (muda todos os hashes, exige push --force) e
  desnecessario apos a rotacao. O banco local so escuta em localhost (listen_addresses=localhost),
  nunca esteve acessivel de fora.
- ⚠️ NAO leem do .env e precisam de atualizacao MANUAL: conexoes salvas do POWER BI e do DBEAVER.

## Última sessão
- Data: 2026-09-22
- Resumo: **HODÔMETRO POR VEÍCULO × MÊS** — pedido do usuário: ver o hodômetro de cada veículo no período filtrado, com TODOS os veículos da telemetria, id, placa/veículo, hodômetro inicial e final. 1ª entrega foram 2 VIEWS por cliente; o usuário pediu **"apague essas views, eu quero que seja uma tabela com todos os veículos"** → views DROPADAS e criada a TABELA única `tb_odometro_mensal` (`migracao_odometro_mensal_2026-09-22.sql`, APLICADA) sobre `tb_odometro_dia` + `tb_cadastro` cru. Três decisões de desenho: GRADE COMPLETA (cadastro CROSS JOIN meses, p/ o veículo parado não sumir do filtro); abertura por CARRY-FORWARD (última leitura ANTES do mês, não a 1ª do mês — só há leitura em dia rodado, então a 1ª do mês perderia km e os meses não emendariam); e mês sem leitura carrega a última conhecida (início=fim, km=0). O perfil do dado bruto revelou 3 sujeiras que viraram gotcha próprio (`odometro_gps` 100% zero, sentinela 2^31/10 no device b12B, odômetro não-monotônico em 363 devices). Perf medida com `LIMIT 200` ANTES (lição de 09/09): **0,07 s**. Ensaio em BEGIN/ROLLBACK; validações: meses emendam (0 desencontros/8.477 pares), km do odômetro 949.432 vs km de viagens 901.562 em set/26 (+5,3%, coerente — odômetro pega movimento fora de viagem). views.sql voltou ao original (1121 linhas). `geotab_supabase.py`: DDL da tabela + `recarregar_odometro_mensal` + chamada no fim do modo comportamento (testada de verdade: 3,6 s / 17.892 linhas). **Abrir p/ a frota inteira revelou 2 coisas que o filtro SANEAGO escondia**: (1) `todos_grupos` não tem o token `OPE_<cliente>` (zero veículos no LIKE) → tabela ganhou `todos_grupos_expandido`; (2) o **bug de unidade do odômetro** (gotcha próprio acima) — corrigido em 2 passos (÷1000 fixo → `DIVISOR_ODO_KM` por diagnóstico, porque o diag é escolhido em runtime e o 1º candidato já vem em km) + re-sync de 2026. **DEPOIS o usuário pediu 2025**: criado piso próprio `ODO_DATA_CORTE`/`ODO_DATA_INICIO` (gotcha próprio) e feito backfill de 15/abr→31/dez/2025 — tabela foi de 9 p/ **18 meses, 17.892 → 35.784 linhas**. Sobraram 76.756 linhas legadas em 2026 que a API não devolve mais; **o usuário optou por MANTER** (apagar custaria −13% de cobertura em 2026) → marcadas em `origem_dado`. Filtrando `origem_dado='carga corrigida'` restam 15.962 linhas com 1 km negativo e hodômetro máximo plausível (245.168 km). Pendente: apontar o Power BI p/ `tb_odometro_mensal`. NÃO commitado.
- Data: 2026-09-14
- Resumo: **SCORE GEOTAB POR MÊS/ANO** (seção própria acima). Partiu de um erro no Power BI `42703: coluna km_ano não existe` — mesmo tipo do `km_total` de 19/06: o painel referenciava `km_ano` numa view DIÁRIA de onde a coluna foi removida na correção de perf de 09/09 (score migrou p/ grão anual). O usuário rejeitou o grão anual: **"deve ser mês/ano"**. Criadas 2 views novas (`vw_saneago_veiculos_mensal`, `vw_saneago_motoristas_mensal`) espelhando as anuais no grão mês, km de tb_viagens, piso 200 km. Medi perf com `LIMIT 200` ANTES (lição de 09/09): 20-27 s, mesma faixa das anuais aceitas — não repeti a regressão de 219×. Ensaio em BEGIN/ROLLBACK; totais do mensal batem com a anual (eventos exatos). APLICADO. views.sql +2 views. Pendente: entregar os 2 códigos M ao usuário e ele repontar as tabelas de score do painel p/ as views mensais. NÃO commitado.
- Resumo (parte 2, mesma data): **RESTRUCTURING DE GRUPOS + FIX SEMAD/SANEAGO** (seção própria acima). Pedido: "adicione os contratos SEMAD 035/26 e 031/26 nas views". Investigação ao vivo na API revelou que o usuário reestruturou os grupos no Geotab: contratos viraram grupo-PAI com subgrupos por secretaria; a folha perdeu o número do contrato. Implementada Opção A (hierarquia no sync) de forma ISOLADA da SANEAGO: coluna nova `todos_grupos_expandido` (folha+ancestrais) no `extrair_cadastro`, usada só pelo filtro SEMAD → **91 veículos** (035=90, 031=1, casou com o "91" que o usuário afirmou). AO RE-SINCRONIZAR, descobri que o mesmo restructuring **quebrou a `grupo_visivel` da SANEAGO** (outros clientes vazaram, 1062→1425); o usuário pediu p/ manter a SANEAGO como antes. Corrigido com `saneago_visivel(expandido)` (tem OPE_SANEAGO E sem outro cliente) só no lado veículo → **1061** (=frota de antes), 0 vazamento, motoristas e grupo_id intactos. Lição: re-sync durante restructuring do usuário antecipa vazamentos que a sync diária traria; os 333 duplo-marcados = reorg inacabada. 3 migrações (`migracao_semad_hierarquia`, `migracao_saneago_visivel`, tokens em tb_contrato_semad) + `geotab_supabase.py` (coluna+helpers) + views.sql. NÃO commitado.
- Data: 2026-09-09
- Resumo: **SCORE DE COMPORTAMENTO ESTILO GEOTAB** (seção própria acima) — migração APLICADA (COMMIT) nas 3 views. Partiu de um PDF que o usuário mandou como referência; o PDF acertava pesos e faixas, mas eu tratei sua "matemática" como oficial antes de checar. Ao buscar a fonte real (white paper + Support Center) apareceram os **3 métodos oficiais** (Event Count / Violation Percentage / Hybrid) e a confirmação de que peso é parâmetro do cliente. Duas correções minhas no caminho: (a) Excessive Speeding NÃO vem junto no nosso bucket de velocidade — está ausente, o que fez o peso 40/20/20/20 virar derivação oficial em vez de escolha empírica; (b) a aceleração vem de Jackrabbit Starts. Descobri as duas lendo `atualizacao_local.log`, não supondo. Entreguei tb. o **documento oficial** (artifact) após 4 iterações: o usuário reprovou markdown longo/redundante, depois "visualmente feio", depois pediu foco no cálculo com fonte oficial e sem menção a reunião, e por fim que só constasse **o que está em uso** (removidos Violation Percentage/Hybrid, Seatbelt/Excessive Speeding e a seção de limites). Ensaio em BEGIN…ROLLBACK antes de aplicar; contagens de linha inalteradas. **DEPOIS o usuário abriu o DBeaver e a view travou**: eu havia introduzido regressão de 219× no `LIMIT 200` ao pendurar o score nas views diárias — corrigido com `migracao_score_correcao_2026-09-09.sql` (score só em grão anual + nova `vw_saneago_veiculos_anual`). Duas lições registradas na seção própria: medir view com `LIMIT 200` e não `count(*)`; e não forçar dado em grão errado por falta de view no grão certo. Pendente: 2 markdowns de rascunho (`GUIA_SCORE_COMPORTAMENTO.md`, `SCORE_COMPORTAMENTO.md`) aguardando descarte. NÃO commitado.
- Data: 2026-09-02
- Resumo (parte 2, mesma data): **PADRÃO DE PREENCHIMENTO DAS COLUNAS DE NÍVEL** (seção própria acima). Ao revisar o resultado, o usuário mostrou o grupo `REG_G0084 | ULOT_G0084` com a coluna de lotação vazia e estabeleceu a regra: se o dado bruto mostra a informação daquele nível, a coluna tem que exibi-la — e pediu que o padrão valha para casos análogos (salvo na memória). `token_nivel()` ganhou fallback por prefixo. Vazios: ulot 186→26, reg 96→58, sup 55→54; chave e contagem de grupos intocadas. Avisado o efeito colateral: 34 grupos passam a exibir superintendência na coluna regional (o sintoma de 26/08), que pela regra nova é o esperado. Deixadas 3 pendências medidas e não aplicadas (dedup por código 793→771; sup deduzida 771→762; variação de escrita).
- Resumo (parte 1): **GRUPOS DA SANEAGO — nível pelo código + ordem canônica** (seção própria acima). Queixa do usuário: "códigos se repetem mesmo sendo grupos diferentes, informação sendo perdida". Diagnóstico achou DUAS causas, e a maior não era a apontada: `arrumar_grupos()` preservava a ORDEM dos tokens da Geotab, então a mesma hierarquia virava até 6 linhas/`grupo_id` distintos (1.733 linhas p/ 793 reais; 91% dos veículos e motoristas afetados) — no BI o filtro trazia só uma fatia. A 2ª causa era o nível vir do prefixo do token (21 códigos em 2 níveis) somada à regra de "níveis repetidos" de 26/08, que zerava justamente onde a gerência estava. Migração aplicada: ordem canônica + `nivel_grupo()` pela letra do código + `token_nivel()` determinística; regra de níveis repetidos removida. Antes de aplicar, rodei tudo em `BEGIN…ROLLBACK` e gerei o diff antes×depois combo a combo — o próprio diff revelou uma regressão no desempate alfabético (`SUP_S0062` perdia p/ `PRE _ D2000`), corrigida com `nivel_prefixo()`. Usuário validou a lista e autorizou. Resultado: 793 linhas, 0 colisão, 0 órfão, 0 código em 2 níveis, +30 níveis recuperados, perda residual de 3 veículos/7 motoristas. SEMAD intacto. `views.sql` atualizado e validado em transação; rollback pronto. NÃO commitado.
- Data: 2026-08-31
- Resumo: Levantamento ao vivo do ABASTECIMENTO na API + **implementada a tabela** (ver seção própria). Achado central: `FuelUpEvent` cobre 95% da frota SANEAGO com dados coerentes, mas `FuelTransaction` está **vazia** → **sem nenhum dado financeiro** (R$/posto/NF); só entra se importarem o extrato do cartão. Doc do levantamento em `Downloads/geotab_abastecimento_levantamento.md`. Criadas `tb_abastecimento` + modo `abastecimento` (5º no orquestrador) + chave composta no `gravar_tabela`; carga do ano inteiro validada (53.237 eventos, 12 MB, 40 s, 0 órfãos) e incremental idempotente. Em seguida (mesma sessão, a pedido) as **2 views**: `vw_saneago_abastecimento` (34.640 linhas, 1.058 placas, 73 ms) e `vw_semad_abastecimento` (130, 58, 26 ms), 0 órfãos de grupo_id nas duas. E os **códigos M**. DEPOIS o usuário esclareceu que **não quer view separada de abastecimento** — quer a informação na view de consumo/utilização: 6 colunas adicionadas a `vw_<cliente>_resumo_frota_mensal` (ver seção própria); as 2 views de detalhe seguem no banco, fora do painel. Achado ao validar as medidas: **`litros_motor` não presta p/ detectar desvio** (é o mesmo número do litro abastecido em 91% dos casos) — a medida que eu havia proposto foi RETIRADA do M e do doc de levantamento. **CSV público e geocode das 329 coords NÃO feitos.** MANUAL §5-B e §6-C atualizados; views.sql com a 10ª view. NÃO commitado.
- Data: 2026-08-28
- Resumo: **RESTAURAÇÃO** — o usuário apagou tabelas e quebrou as 18 views (9 SANEAGO + 9 SEMAD). Diagnóstico: as views não tinham sido derrubadas, faltavam as **5 tabelas de configuração** que as funções leem (ver novo gotcha). Restauradas cirurgicamente do backup `geotab_20260828.dump` (08:28) com `pg_restore -t` das 5 tabelas — **NÃO** restore total, que sobrescreveria os dados do dia. As PKs não vieram no `-t`; extraídas do dump e reaplicadas. `tb_modelo_canonico` deliberadamente NÃO restaurada (era a limpeza pendente). VALIDADO: 18/18 views leem colunas reais; saneago_cadastro 1062, status 1062, semad_cadastro 90, semad_grupos 1; os 9 modelos padronizados com as contagens documentadas (SAVEIRO CS RB 656, ARGO DRIVE 1.0 391...); 8 tokens ignorados incl. Compressed Natural Gas; **0 órfãos** de grupo_id em todas as views de fato dos 2 clientes. (vw_saneago_grupos 1721→1749 = crescimento normal de cadastro, não efeito do restore.)
- Data: 2026-08-27 (parte 3 — códigos M)
- Resumo: Contrato `035/2026` chegou pela API (escopo do usuário corrigido na Geotab): **90 veículos**, views populadas (cadastro/status 90, viagens 2.523, comportamento 33). Entregues os **9 códigos M** em `Downloads/semad_codigo_M.md` (ver seção do SEMAD). Dois achados: (a) a dimensão de grupos tem **1 linha e nenhuma hierarquia** — sem SUP_/REG_/ULOT_ no contrato, o painel não tem quebra por unidade e os indicadores mensais colapsam em 1 linha/mês; (b) `resumo_frota_mensal`/`indicadores_mensal` seguem vazias por **ordem de execução** — a função do resumo mensal rodou às 10:21 e a frota entrou às 11:14, então faltam os 76 devices do SEMAD em tb_resumo_mensal. Comando de correção entregue ao usuário, NÃO executado (fora do escopo pedido). Motoristas seguem vazios (0% de identificação de condutor). NÃO commitado.
- Data: 2026-08-27
- Resumo: Criadas as 9 views do cliente **SEMAD** (`vw_semad_*`, ver seção própria) espelhando a SANEAGO, com filtro por INCLUSÃO de contrato (`tb_contrato_semad` + `grupo_semad()`). Contrato cadastrado = `OPE_SEMAD - 035/2026` por decisão do usuário; **o Geotab só tem `006/2026`, então as views estão em 0 linhas** até a origem mudar (avisado). Ensaio com 006/2026 (transação revertida) provou o encanamento: 14 veículos / 6.846 viagens / 0 órfãos / 0 vazamento. Descoberto e barrado um vazamento entre clientes: os 30 "motoristas" do SEMAD são usuários MAAS presentes em todos os contratos, e a lógica da SANEAGO traria 29 viagens da SANEAGO — as views de motorista passaram a escopar pelo veículo. Levantadas 3 lacunas de cadastro na origem (10 veículos sem placa; 0% de identificação de motorista nas viagens; 1 veículo com token sem nº de contrato). NÃO commitado.
- Data: 2026-08-25
- Resumo: Avaliado o PDF de apontamentos da SANEAGO (12/08) — triagem dos 18 itens validada por consulta ao banco, em `Downloads/triagem_apontamentos_saneago.md`. Confirmado com o usuário que a frota correta é 1.062 (item 14 virou IMPROCEDENTE: os 1.036 da tela são veículos com viagem no período, não a frota; e a lista da SANEAGO soma 1.033, não os 1.040 declarados) — exportada `saneago_frota_1062_placas.csv` como comprovação. Implementados os itens 7-9 (ver seção própria): modelo canônico, limpeza de endereço e hierarquia regional→superintendência. views.sql regenerado. NÃO commitado.
- Data: 2026-08-24
- Resumo: REFACTOR das views p/ o painel Power BI SANEAGO (ver seção "Filtro de grupos centralizado"). Criada função `grupo_visivel()` com a lista de exclusão única; filtros de grupo/palavra/Aterro/placas e limpezas aditivas (cap velocidade, modelo2) movidos do M p/ o SQL. Plugados 2 furos (vw_relatorio_viagens sem filtro; vw_motoristas sem filtro). Corrigido bug do filtro de placas (M usava `or`, nunca excluía). Migração aplicada e validada ao vivo (SANEAGO mantido, Aterro/placas/COMURG/SEMAD zerados, 0 vazamento). Entregues códigos M enxutos em `Downloads/saneago_codigo_M_novo.md`. views.sql regenerado do banco. DEPOIS: renomeadas as 9 views p/ vw_saneago_* (ver seção própria); exportar_csv.py desacoplado p/ preservar nomes de CSV; M e docs atualizados. NÃO commitado.
- Data: 2026-06-24
- Resumo: Sync diária de 24/jun OK (rodou 08:22, 4 fases, 93.220 viagens, marcador gravado). O export CSV automático rodou (load_dotenv do dia 23 funcionou — não foi mais "pulado") mas FALHOU não-fatal na etapa da vw_relatorio_viagens (1ª query psql, exit 0xC000013A = gotcha do PG/console). Rodado `exportar_csv.py` na mão logo depois: exit 0, snapshot público atualizado p/ 24/jun (8 views + viagens 2025-12..2026-06 em 2 partes/mês + index.html). Falha do automático considerada TRANSITÓRIA (mesmo script passou limpo na mão). Se recorrer no automático: blindar com retry na query do export ou respiro entre sync e export. Não commitado (sem mudança de código).
- Data: 2026-06-23
- Resumo: Sync diária de 23/jun OK (rodou às 08:23, 90.707 viagens, marcador gravado). Descoberto que o export CSV automático vinha sendo PULADO todo dia desde a criação (guard sem `load_dotenv` no orquestrador — ver BUG CORRIGIDO na seção Download CSV). Corrigido com `load_dotenv(BASE/".env")` em `atualizar_local.py`; guard validado (passa True). Rodado `exportar_csv.py` na mão p/ atualizar o snapshot público (estava de 22/jun): 21 arquivos no ar, snapshot de 23/jun. Commitado o pipeline CSV + o fix (era trabalho não-commitado de 22/jun).
- Data: 2026-06-22
- Resumo: Sync diária de 22/jun OK (marcador gravado). Criado pipeline de DOWNLOAD CSV EXTERNO (ver seção própria): `exportar_csv.py` + integração não-fatal no `atualizar_local.py` + template no .env + `exports/` no .gitignore. Medidos os tamanhos reais das 9 views (viagens = 1,6 GB, resto leve). Descoberto que o projeto Supabase do geotab foi deletado; criado projeto novo `geotab-export` via MCP (ACTIVE_HEALTHY, domínio responde 401=ok). Usuário colou a service_role key; pipeline LIGADO e VALIDADO ao vivo: bucket público `geotab-csv` criado, 21 arquivos no ar (8 views + viagens por mês particionada <50MB + index.html), downloads públicos HTTP 200. Descoberto/contornado o limite de 50 MB/arquivo do free tier (particionamento por tamanho) + limpeza do bucket por refresh. NÃO commitado.
- Data: 2026-06-19
- Resumo: Sync diária de 19/jun rodou OK (4 fases, 135.656 viagens, marcador gravado). Adicionadas `marca`+`modelo` à `vw_resumo_frota_mensal` (só nessa view, a pedido) — em views.sql e no banco local (DROP+CREATE p/ inserir após `placa`). vw_indicadores_mensal não mexida. Criada `vw_motoristas_anual` (formato antigo, `km_total`/nomes legados) p/ destravar o Power BI que quebrava com `42703: coluna km_total não existe` (modelo feito na vw_motoristas anual, que virou diária em 18/jun). Add `todos_grupos` às duas views de motoristas. Investigada a queixa de "metade sem matrícula": é falso — cobertura real ~98% (ver seção views); `nome`=login/e-mail, matrícula=employeeNo. Add coluna `nome_completo` (User.firstName, 100% preenchido) em tb_motoristas + extrair_motoristas + migração; exposta como `motorista_nome_completo` nas duas views. PG caiu no meio (gotcha 0xC000013A) e foi religado. NÃO commitado.
- Data: 2026-06-18
- Resumo: Implementado modo INCREMENTAL nas viagens (`VIAGENS_INCREMENTAL`/`VIAGENS_MARGEM_DIAS` + `_ultima_partida_gravada`) — ver seção tb_viagens. VALIDADO ao vivo: janela caiu p/ 3 dias, 100k viagens (vs ~700k) e geocode 226 coords; fase viagens ~7min (vs ~1h30). A sync das 08h FALHOU (Postgres caiu às 08:21, ver gotcha abaixo) — religuei o banco e re-rodei o orquestrador OK (marcador 2026-06-18 gravado).
- Tratada a fragilidade do Postgres a fechamento de janela (0xC000013A): auto-cura no orquestrador (ver gotcha). WSH e janela-oculta confirmados bloqueados pelo ambiente; serviço exige admin. Startup voltou ao iniciar_postgres.bat.
- Data: 2026-06-17 (migração concluída; antes: 2026-06-15)
- Resumo: Banco recuperado (suspenso no fim de semana + reiniciado hoje). Diagnosticado o "rodei /run/cadastro e não atualizou": no momento da chamada o comportamento segurava o `_lock`, a thread do cadastro foi descartada, mas `/run` respondia "iniciado" falso (sem registrar erro). Correções aplicadas:
  - `app.py`: `executar_sync` → `_disparar` (adquire lock e passa p/ thread) + `_executar_com_lock` (captura BaseException). `/run/<modo>` agora responde 409 "ocupado" quando o lock está tomado.
  - `geotab_supabase.py`: `autenticar()` levanta `GeotabAuthError` em vez de `sys.exit(1)` (SystemExit escapava do except do worker); `extrair_cadastro` aborta com erro se a Geotab retorna 0 devices (não grava vazio em silêncio).
