# Manual do Projeto — Geotab → Postgres Local → BI/CSV

> Documentação operacional do projeto. Voltada para **pessoas** (você e a equipe):
> o que o projeto faz, como ele funciona e como operá-lo no dia a dia.
> Para o estado técnico resumido entre sessões de desenvolvimento, ver `.claude/context.md`.
>
> **Última atualização:** 2026-09-22

---

## 1. Visão geral

Este projeto sincroniza dados da telemetria da frota (plataforma **Geotab**) para um
**banco PostgreSQL local**, alimentando dois consumidores:

1. **Power BI** — conectado ao banco local via On-premises Data Gateway (relatórios internos).
2. **Download CSV externo** — snapshot diário de cada relatório publicado no **Supabase Storage**,
   com links públicos estáveis para clientes que não têm acesso ao banco.

Fluxo de dados:

```
  API Geotab (JSON-RPC)
        │  (sync diária, dias úteis, no logon)
        ▼
  PostgreSQL LOCAL  (C:\Users\ygor.kouzak\pgdata, porta 5432, banco "geotab")
        │                                   │
        ▼                                   ▼
  Power BI (Gateway)              CSVs → Supabase Storage (links públicos)
```

### Por que rodar local?
O projeto já rodou no **Render** (nuvem), mas o IP de saída do Render é **bloqueado pelo WAF
da Geotab** (erro 403 na autenticação). Além disso, o banco era Supabase free (500 MB) e estourava.
Rodar na máquina do usuário resolve os três problemas (IP limpo, sem custo, sem limite de disco)
— ao custo de depender do notebook estar ligado em dia útil.

---

## 2. Stack e requisitos

- **Linguagem:** Python 3 (ver `requirements.txt`).
- **Libs principais:** `requests` (API Geotab), `pandas`, `SQLAlchemy`/`psycopg2` (Postgres),
  `python-dotenv` (carrega o `.env`).
- **Banco:** PostgreSQL 18.4 **portátil** (sem instalação/admin), binários em
  `C:\Users\ygor.kouzak\pgsql\pgsql\bin`, dados em `C:\Users\ygor.kouzak\pgdata`, porta 5432.
- **Storage externo:** Supabase (projeto `geotab-export`, ref `ldhelbygqrjqchistrgp`), só Storage.
- **SO:** Windows 11 (máquina corporativa — **sem admin**, GPO restritivo: por isso nada vira
  serviço do Windows nem roda sem janela de console).

---

## 3. Estrutura de arquivos

| Arquivo | Função |
|---|---|
| `geotab_supabase.py` | **Núcleo.** Extrai da API Geotab e grava no Postgres. Cria/migra tabelas, faz throttle de quota, geocodifica endereços. |
| `atualizar_local.py` | **Orquestrador.** Roda os 4 modos do sync em sequência (dias úteis, 1×/dia), garante o Postgres no ar e, no fim, dispara o export CSV. |
| `exportar_csv.py` | Exporta cada view para CSV e sobe no Supabase Storage (links externos). |
| `iniciar_postgres.bat` | Sobe o Postgres local. Roda no logon (pasta Inicializar). |
| `backup_geotab.bat` | `pg_dump` diário para `C:\Users\ygor.kouzak\backups` (mantém 14 dias). Roda no logon. |
| `psql_geotab.bat` | Abre o cliente `psql` já conectado ao banco local (duplo-clique; saída com `\q`). |
| `views.sql` | Definição das views (DDL). `views_backup.sql` é o backup. |
| `.env` | Credenciais e configuração (**não versionado**). |
| `.claude/context.md` | Estado técnico resumido para retomada de sessões de dev. |
| `MANUAL.md` | Este manual. |

Gerados em runtime (ignorados pelo git): `atualizacao_local.log`, `.ultima_atualizacao`, `exports/`, `__pycache__/`.

---

## 4. Operação no dia a dia

### Modelo de funcionamento
> **Liga o PC num dia útil → tudo roda sozinho no logon.** Não há servidor ligado 24/7.
> A máquina corporativa não acorda sozinha do desligado (GPO trava wake timers), então
> a sync depende de o computador ser ligado em algum momento do dia útil.

O que acontece automaticamente ao fazer **logon**:
1. `iniciar_postgres.bat` sobe o Postgres.
2. `backup_geotab.bat` faz o dump do dia.
3. A Tarefa Agendada **`GeotabSyncLocal`** dispara `atualizar_local.py`, que:
   - confere se é dia útil e se ainda não rodou hoje (marcador `.ultima_atualizacao`);
   - garante o Postgres no ar (auto-cura — ver §8);
   - roda os 5 modos: **cadastro → status → comportamento → viagens → abastecimento**;
   - se os 5 derem OK, grava o marcador do dia e **publica os CSVs** no Supabase Storage.

### Rodar a sync manualmente
```powershell
# orquestrador completo (5 modos + export):
python atualizar_local.py

# um modo isolado:
python geotab_supabase.py cadastro      # snapshot da frota + motoristas
python geotab_supabase.py status        # snapshot tempo real
python geotab_supabase.py comportamento # eventos + odômetro/dia (incremental)
python geotab_supabase.py viagens       # viagens + geocode (incremental)
python geotab_supabase.py abastecimento # abastecimentos FuelUpEvent (incremental)
```
> `viagens` NÃO entra no modo `all` (é o trecho mais pesado). O orquestrador roda os 5 explicitamente.

### Publicar os CSVs manualmente
```powershell
python exportar_csv.py
```
Gera os CSVs em `exports/` e sobe no bucket. Link do índice para o cliente:
`https://ldhelbygqrjqchistrgp.supabase.co/storage/v1/object/public/geotab-csv/index.html`

### Inspecionar o banco
- `psql_geotab.bat` (duplo-clique) ou DBeaver (`localhost:5432` / banco `geotab` / usuário `postgres`).
- Subir o Postgres na mão, se preciso:
  `pg_ctl -D C:\Users\ygor.kouzak\pgdata start`

### Onde olhar quando algo falha
- Log da sync: `atualizacao_local.log` (na raiz do projeto).
- Log do servidor Postgres: `C:\Users\ygor.kouzak\pgdata\server.log`.

---

## 5. Banco de dados — tabelas

> **Piso temporal:** nenhuma tabela guarda dados anteriores a **01/jan do ano corrente**
> (`ANO_CORTE`, default 2026, em `geotab_supabase.py`). Para virar o ano, ajustar `ANO_CORTE`.

| Tabela | Conteúdo | Janela |
|---|---|---|
| `tb_cadastro` | Snapshot atual da frota (full refresh). | atual |
| `tb_status` | Snapshot tempo real; motorista vem das viagens das últimas 24h. | atual |
| `tb_motoristas` | Dimensão de motoristas (entidade User): login/e-mail, nome próprio, matrícula, lotação/regional/superintendência. | atual |
| `tb_comportamento_eventos` | Buckets diários device/dia/tipo de evento (excesso, aceleração, frenagem, curva). | ano corrente |
| `tb_comportamento_motorista` | Mesmos eventos, por motorista (só eventos com motorista identificado, ~40-57%). | ano corrente |
| `tb_viagens` | Uma linha por viagem (enxuta — placa/veículo/grupo vêm de `tb_cadastro` por JOIN). | ano corrente (incremental) |
| `tb_enderecos` | Cache de geocode: coordenada arredondada → endereço. | acumulado |
| `tb_odometro_dia` | Odômetro por device/dia (físico + GPS, último valor do dia). | **abr/2025 →** (janela própria, ver 6-E) |
| `tb_odometro_mensal` | Hodômetro por veículo × mês (frota inteira, 35.784 linhas). Derivada de `tb_odometro_dia` — ver 6-E. | **abr/2025 →** |
| `tb_resumo_mensal` | Agregado km/tempo/dias/viagens por device/mês. | ano corrente |
| `tb_abastecimento` | Uma linha por abastecimento detectado (litros, km desde o anterior, odômetro, local, motorista). | ano corrente (incremental) |

**Notas de operação:**
- **Viagens é incremental** (`VIAGENS_INCREMENTAL=1`): a janela começa em `max(data_partida) − 3 dias`,
  evitando re-buscar o ano inteiro todo dia. Upsert por id não duplica.
- **Geocode é por lookup e incremental:** só geocodifica coordenadas novas; endereços ficam em
  `tb_enderecos`, não em `tb_viagens`. O `round(lat/lon, 3)` da view tem que casar com `GEOCODE_CASAS=3`.
- **Abastecimento é incremental** (`max(data_hora) − 3 dias`, env `ABASTECIMENTO_MARGEM_DIAS`) e
  barato: o `Get` da Geotab é por **janela** (uma chamada cobre a frota toda), fatiado em blocos
  de 31 dias (`ABASTECIMENTO_LOTE_DIAS`). Ano inteiro leva ~40 s; o incremental diário, ~2 s.

### 5-B. Abastecimento (`tb_abastecimento`) — 2026-08-31

Origem: entidade **`FuelUpEvent`** da Geotab. **É telemetria, não contabilidade** — a Geotab
*deduz* cada abastecimento pela subida do nível do tanque combinada com a parada da viagem.

> **Não há dado financeiro.** A entidade `FuelTransaction` (que traria R$, preço/litro, posto e
> nota fiscal) está **vazia** nesta base — não existe integração de cartão de combustível. Para
> ter custo, alguém precisa importar o extrato da administradora do cartão.

| Coluna | Conteúdo | Cobertura medida (ano 2026) |
|---|---|---|
| `device_id` + `data_hora` | **chave primária** (a API não devolve um `id` para o evento) | 100% |
| `litros` | litros abastecidos (`volume`) | **80,5%** > 0 |
| `litros_derivado` | recálculo da própria Geotab (`derivedVolume`) — **melhor fallback** | **95,8%** > 0 |
| `litros_motor` | litros consumidos pelo motor desde o abastecimento anterior | preenchido |
| `distancia_km` | km rodados desde o abastecimento anterior → **dá km/L** | preenchido |
| `odometro_km` | odômetro no momento (a API entrega em metros; convertido aqui) | ~100% |
| `latitude` / `longitude` | onde abasteceu (ainda **sem geocode** — nenhuma view consome) | 100% |
| `motorista_id` | casa com `tb_motoristas.id` | **56,5%** |
| `tanque_litros` | capacidade do tanque — **ESTIMADA** pela Geotab, não é dado de fábrica | preenchido |
| `tipo_combustivel` | `productType` — hoje **100% "Unknown"** (inútil) | — |
| `confianca` | qualidade da detecção — 98% na melhor faixa (`FuelLevel, TripStop`) | — |

**Estado da carga inicial (2026-08-31):** 53.237 eventos / 1.852 veículos / **12 MB** /
01-jan a 31-ago. **0 órfãos** contra `tb_cadastro`. Por cliente: **SANEAGO 1.058 veículos**,
SEMAD 58. Consumo mediano: **7,3 km/L na SANEAGO**, 5,8 no SEMAD.

**Ao montar a view (ainda não feita), atenção a:**
- Usar `coalesce(nullif(litros,0), litros_derivado)` — 1 em cada 5 eventos vem com `litros = 0`.
- **23 `motorista_id` não existem em `tb_motoristas`** (motoristas apagados ou fora do escopo da
  API) → o JOIN precisa ser `LEFT JOIN`, nunca `JOIN`.
- km/L extremo existe (p10 = 2,2 / p90 = 11,3 na frota toda): filtrar `litros > 5` e
  `distancia_km > 1` antes de calcular médias, ou o indicador fica distorcido.
- `tanque_litros` é estimativa — não usar como verdade absoluta em "% do tanque".

Levantamento completo do que a API oferece (e do que não oferece) sobre combustível:
`C:\Users\ygor.kouzak\Downloads\geotab_abastecimento_levantamento.md`.

---

## 6. Banco de dados — views (o que cada relatório serve)

Regra: **uma view por tema.** Todas filtram grupos OPE_*/terceiros e usam `security_invoker = on`.

> **Filtro de grupos centralizado (2026-08-24).** A lista de grupos excluídos vive numa
> função única, `grupo_visivel(todos_grupos)` — retorna FALSO se o veículo pertencer a
> qualquer grupo vetado (COMURG, SEINFRA, PEDREIRA, CS_BRASIL, AGETUL, SMT, SEPLANH, AMMA,
> SEMAD, SECULT, "SECRET. DA ECONOMIA", ADMINISTRATIVO, "ASSISTÊNCIA SOCIAL", "RECOLHIMENTO
> DE ANIMAIS", "DIRETORIA/GERÊNCIA", "SERVIÇOS EM CAMPO", "ATERRO SANITÁRIO", REDEMOB,
> P-CSB). **OPE_SANEAGO é mantido** (contrato principal). `vw_cadastro` também exclui as
> placas TFA2G98/TFN3B44/TFR4E14. As demais views herdam o filtro via JOIN em `vw_cadastro`
> (status/comportamento/resumo/indicadores) ou aplicam `grupo_visivel` direto
> (motoristas/grupos). **Para incluir ou tirar um grupo, edite só a função** — nenhuma view
> nem o Power BI precisa mudar. Antes disso o filtro estava replicado em cada consulta M do
> painel SANEAGO; foi movido para o SQL. Códigos M enxutos: `saneago_codigo_M_novo.md`.

> **Renomeadas para `vw_saneago_*` em 2026-08-24.** Os arquivos CSV públicos mantêm o nome
> antigo (o `exportar_csv.py` desacopla nome-da-view de nome-do-arquivo), então os links dos
> clientes não quebram.

| View | Granularidade | Uso |
|---|---|---|
| `vw_saneago_cadastro` | 1 linha/veículo | Snapshot atual da frota. |
| `vw_saneago_status` | 1 linha/veículo | Tempo real (último contato). |
| `vw_saneago_grupos` | por grupo | Dimensão de grupos. |
| `vw_saneago_comportamento` | device × dia | Eventos do dia + odômetro. ~6 meses. |
| `vw_saneago_relatorio_viagens` | 1 linha/viagem | Viagens com endereços, tempos de parada/ocioso. |
| `vw_saneago_motoristas` | motorista × dia | Espelha `vw_saneago_comportamento` por motorista; BI agrega no período. |
| `vw_saneago_motoristas_anual` | 1 linha/motorista | Versão **agregada no ano** (nomes legados `km_total`/`score_seguranca`), para o Power BI antigo. **+ score do motorista** (§6-D). |
| `vw_saneago_veiculos_anual` | 1 linha/veículo | **Score do veículo** no ano, com as 4 notas por regra (§6-D). |
| `vw_saneago_resumo_frota_mensal` | veículo × mês | Consumo e utilização por veículo: km, dias, taxa de utilização **e abastecimento** (litros e km/L — ver §6-C). |
| `vw_saneago_indicadores_mensal` | grupo × mês | Indicadores mensais por grupo. |
| `vw_saneago_abastecimento` | 1 linha/abastecimento | Detalhe de cada abastecimento (posto, motorista). **Fora do painel** por decisão do usuário — ver §6-C. |

> **Colunas padronizadas (2026-08-25).** Atendendo aos apontamentos da SANEAGO, as views
> ganharam três colunas **novas** — as originais foram preservadas, então nada no Power BI
> quebra; é só trocar o campo quando quiser:
>
> | Coluna nova | Substitui | O que faz |
> |---|---|---|
> | `modelo_padrao` / `marca_padrao` | `modelo` / `marca` | Unifica as 15 grafias em 3 modelos (SAVEIRO ROBUST, ARGO 1.0, POLO CL). Editável em `tb_modelo_canonico`. |
> | `sup_oficial` | `sup` | Corrige vínculo errado de regional→superintendência (caso Palmeiras). Editável em `tb_hierarquia_grupo`. |

> **Grupos (2026-08-25).** Todas as views expõem `todos_grupos` **tratado** — sem os rótulos
> que não são grupo (`Vehicle`, `Ethanol`, `Diesel`, `Compressed Natural Gas`,
> `Manually Classified Powertrain`…). É a **chave** para a dimensão de grupos, e é a **única**
> coluna de grupo que elas têm.
>
> A quebra por nível existe **só em `vw_saneago_grupos`**: `todos_grupos_original` (texto cru),
> `todos_grupos` (tratado/chave) e, por nível, código / nome / código + nome —
> `sup_codigo`, `sup_nome`, `sup_cod_nome` (idem `reg_*` e `ulot_*`), ex.:
> `G0111 - Ger.Regional Serv. Itumbiara`. Essa dimensão é a **união** das combinações de
> veículos e de motoristas (sem os motoristas, 81% deles ficariam órfãos): **793 chaves únicas**
> (eram 1.733 até 02/09/2026 — ver "Hierarquia de grupos" logo abaixo).
>
> **Hierarquia de grupos — como o nível é decidido (revisto em 02/09/2026).**
>
> No cadastro da Geotab, cada veículo/motorista carrega uma lista de grupos separados por `|`,
> com prefixos `SUP_`, `REG_`, `ULOT_`, `OPE_`. Dois problemas vinham daí:
>
> 1. **A ordem dos grupos variava.** A mesma unidade chegava como
>    `SUP_S0072 | REG_G0032 | ULOT_G0032` ou `ULOT_G0032 | SUP_S0072 | REG_G0032`, e como a chave
>    era o texto, isso virava **grupos diferentes** na dimensão. Uma única hierarquia chegou a
>    aparecer em 6 linhas, com os veículos repartidos entre elas — no Power BI, escolher um item
>    do filtro mostrava só uma fatia da frota.
> 2. **O prefixo não é confiável.** A mesma gerência aparecia como `REG_` em um veículo e `ULOT_`
>    em outro, então o mesmo código caía ora em "regional", ora em "lotação" (21 códigos assim).
>
> **Como funciona agora:**
>
> - A lista de grupos é **ordenada de forma canônica** (operação → superintendência → regional →
>   lotação → outros, depois alfabética) antes de virar chave. A mesma hierarquia produz sempre
>   o mesmo `todos_grupos` e o mesmo `grupo_id`.
> - O nível vem da **letra do código**, não do prefixo:
>
>   | letra do código | nível |
>   |---|---|
>   | `S` / `D` | superintendência / diretoria |
>   | `G` | gerência → **regional** |
>   | `V`, `T`, `C`, `USE` | supervisão, distrito, coordenação, unidade → **lotação** |
>   | `OPE_` (sem código) | operação / contrato |
>
>   Códigos fora dessa convenção (outros clientes, como o SEMAD) continuam usando o prefixo.
>   Exceções nomeadas ficam em `tb_grupo_nivel_excecao` (hoje: `T8000` → regional,
>   `G8100` → lotação).
> - Quando um veículo tem **dois grupos do mesmo nível** (ex. duas gerências), a coluna mostra
>   um só — o de prefixo concordante, depois o primeiro em ordem alfabética. Antes a escolha era
>   aleatória. A lista completa continua em `todos_grupos` e `todos_grupos_original`.
>
> **Padrão de preenchimento das colunas.** A regra é: **se `todos_grupos` mostra a informação de
> um nível, a coluna daquele nível tem que exibi-la.** A coluna só fica vazia quando não existe
> nenhum grupo daquele nível no cadastro. Na prática são duas tentativas, nessa ordem:
>
> 1. o grupo cujo **código** pertence ao nível — é o que faz `ULOT_G0087 - GERÊNCIA DE
>    FATURAMENTO` aparecer corretamente na coluna de **regional**, e não na de lotação;
> 2. se não houver nenhum, o grupo cujo **prefixo** declara o nível.
>
> Exemplo: um veículo cadastrado como `REG_G0084 - GERENCIA DE ARRECADAÇÃO |
> ULOT_G0084 - GERENCIA DE ARRECADAÇÃO` (o mesmo código nos dois campos) exibe
> "G0084 - Gerencia De Arrecadação" **tanto em regional quanto em lotação** — as duas
> informações estão no cadastro, então as duas colunas as mostram.
>
> **Nomes repetidos entre colunas são normais.** Quando a Geotab cadastra a mesma unidade nos
> três campos (`REG_S0021 | ULOT_S0021 | SUP_S0021`), as três colunas exibem S0021 — e a coluna
> de regional passa a mostrar o nome de uma superintendência. São 34 grupos assim na coluna
> regional e 29 na de lotação. **Isso não é defeito**: o cadastro de origem realmente diz isso, e
> a regra manda exibir. Uma versão anterior deste manual (26/08/2026) tratava a repetição como
> erro e zerava a coluna de baixo; essa regra foi **revogada** — zerar escondia informação que
> existe no cadastro.
>
> **Efeito da mudança:** a dimensão caiu de 1.733 para 793 linhas, sem perder ninguém
> (0 veículo ou motorista órfão). Colunas em branco caíram de 55 para 54 (superintendência),
> de 96 para 58 (regional) e de 186 para 26 (lotação) — 160 grupos, com 210 veículos, passaram
> a exibir a lotação que antes ficava vazia. Detalhamento item a item em `VALIDACAO_GRUPOS_2026-09-02.md`.
>
> ⚠️ **No Power BI:** os valores de `todos_grupos` e `grupo_id` mudaram. Os relacionamentos
> continuam válidos (fato e dimensão mudaram juntos), mas **filtros e bookmarks salvos que
> guardavam o texto antigo precisam ser refeitos**. Dê um refresh completo.

> As views de fato não têm **nenhuma** outra coluna de grupo — `grupo`/`uo_lotacao` foram
> removidos em 25/08. A lotação vem da dimensão (`ulot_nome`, `ulot_cod_nome`).
>
> No Power BI: relacione cada tabela de fato a `vw_grupos` por `todos_grupos`
> (muitos-para-um) e use os campos da dimensão nas segmentações e nas linhas dos visuais.
>
> Os endereços (`end_partida`/`end_chegada`) já saem limpos — sem Plus Code do Google nem
> número de imóvel solto no início.

> Para display de nome de motorista no BI, usar `motorista_nome_completo` (nome próprio);
> `motorista_nome` é o login/e-mail. Matrícula = `employeeNo` (~98% de cobertura).

> **Sempre conferir a definição real com `pg_get_viewdef` antes de assumir o que o `views.sql` diz** —
> o arquivo já ficou dessincronizado do banco no passado.

### 6-B. Cliente SEMAD — views `vw_semad_*` (2026-08-27)

Conjunto **espelho** das 9 views da SANEAGO, com as mesmas colunas, servindo o painel do
cliente SEMAD. Migração: `migracao_semad_2026-08-27.sql`.

**O filtro é por INCLUSÃO de contrato** (o oposto da SANEAGO, que é lista de exclusão):

| Objeto | Papel |
|---|---|
| `tb_contrato_semad(token)` | Contrato(s) do cliente, no formato exato em que aparecem em `todos_grupos`. |
| `grupo_semad(todos_grupos)` | TRUE se algum grupo do registro casar exatamente com um token da tabela. |
| `arrumar_grupos_semad(todos_grupos)` | Limpa os rótulos que não são grupo **e** remove contratos de outros clientes. |

**Para trocar o contrato, edite só a tabela** — nenhuma view precisa ser recriada:

```bash
psql -h localhost -U postgres -d geotab -c "UPDATE tb_contrato_semad SET token='OPE_SEMAD - 006/2026';"
```

**Estado (27/08/2026):** o contrato `035/2026` passou a chegar pela API depois que o escopo de
dados do usuário foi corrigido na Geotab. São **90 veículos** — frota diferente da de
`006/2026`, que tinha 15. Cadastro e status com 90 linhas, 2.523 viagens, 33 dias de
comportamento, sem órfãos de grupo e sem vazamento de outros contratos.

> ℹ️ **Hierarquia e 2º contrato (a partir de 09/2026).** O que em 27/08 era "1 token único, sem
> hierarquia" evoluiu: o Geotab passou a ter subgrupos por secretaria (SET, SEMASDH, SMS,
> SECULT…) e um segundo contrato, **031/2026**. Hoje `tb_contrato_semad` guarda **035/2026 e
> 031/2026** e a dimensão de grupos tem **22 linhas**.

> ⚠️ **Coluna de contratos = 1 linha por grupo × contrato (15/09/2026).**
> Migração `migracao_semad_grupos_contrato_2026-09-15.sql`. Um grupo pode ter veículos em mais de
> um contrato — o **SET** tem um em cada (`TGG0G28`→031/2026, `TFD2H94`→035/2026). Antes a view
> juntava os contratos numa linha só (`SET | "031/2026, 035/2026"`); agora `vw_semad_grupos`
> agrupa por **(grupo, contrato)** e o SET aparece em **duas linhas**, uma por contrato. Para isso
> o **`grupo_id` passou a ser composto** (`grupo + contrato`) na dimensão e nas três views que o
> definem (`vw_semad_cadastro`, `vw_semad_motoristas`, `vw_semad_motoristas_anual`); as demais o
> herdam por JOIN. O relacionamento *muitos-para-um* continua válido.
> **No Power BI:** os **valores** de `grupo_id` mudaram → refaça filtros/bookmarks salvos e dê
> refresh. Só o SET se dividiu (22 linhas / 22 ids únicos, 0 órfão).

> ⚠️ **`resumo_frota_mensal` e `indicadores_mensal` podem aparecer vazias** logo depois de uma
> frota nova entrar. Elas leem `tb_resumo_mensal`, que é preenchida no **fim** da sync de
> viagens: se a frota entrou no cadastro *depois* dessa etapa, os devices novos ficam de fora
> até a próxima sync. Foi o que aconteceu em 27/08 (resumo às 10:21, frota às 11:14).
> **Correção:** rodar a sync de viagens de novo — `python geotab_supabase.py viagens`.

**Diferenças em relação à SANEAGO** (deliberadas):

1. `vw_semad_motoristas` e `vw_semad_motoristas_anual` escopam pela **frota do contrato**,
   não pelos grupos do motorista. Os usuários com o grupo SEMAD são administrativos da MAAS
   e pertencem a **todos** os contratos; usar a lógica da SANEAGO colocaria 29 viagens de
   veículos da **SANEAGO** dentro do painel do SEMAD.
2. Sem a exclusão das placas TFA2G98/TFN3B44/TFR4E14 (correção específica da frota SANEAGO).

**Lacunas de cadastro no Geotab** (não são falha do pipeline — só se resolvem na origem):

- **Nenhuma viagem do SEMAD tem motorista identificado** — todas vêm com `UnknownDriverId` /
  "Nenhum", e não há eventos de comportamento por motorista. Sem chave de condutor nos
  veículos (NFC, teclado ou vínculo fixo), as duas views de motorista ficam vazias mesmo com
  o contrato correto.
- 1 veículo está **sem placa** (`licensePlate` vazio); a placa só existe dentro do texto do
  campo `veiculo`.
- Não existem subgrupos por unidade/base (ver aviso sobre hierarquia acima).

**Score Geotab no SEMAD (15/09/2026)** — migração `migracao_semad_score_geotab_2026-09-15.sql`.
O SEMAD passou a ter o mesmo score 0–100 da SANEAGO (método oficial *Event Count*, ver
seção 8). Foram criadas `vw_semad_veiculos_anual` e `vw_semad_veiculos_mensal` (espelho das
SANEAGO, com a coluna `contrato` para fatiar 031 × 035) e o `vw_semad_motoristas_anual` ganhou
`score_geotab` + `faixa_risco_geotab`.

> ⚠️ **O score do SEMAD é por VEÍCULO.** Como nenhuma viagem tem condutor identificado, as
> views de motorista ficam vazias — o `score_geotab` lá existe só por paridade. Use
> `vw_semad_veiculos_anual` / `_mensal`.

> ℹ️ **A coluna `score_risco` (nas views diárias) não é um score 0–100** — é uma *contagem
> ponderada de eventos* (`excesso×3 + acel×2 + fren×2 + curva×1`), sem teto, em que **maior é
> pior**. Passar de 100 é o comportamento normal dela. O score 0–100 (maior = melhor) é o
> `score_geotab`. No painel, rotule `score_risco` como **"Eventos Ponderados"** e use o
> `score_geotab` como o score. Vale para os dois clientes.

**Códigos M para o Power BI:** as 9 consultas prontas estão em `Downloads/semad_codigo_M.md`
(fonte Postgres local via Gateway, mesma rota do painel SANEAGO). Ainda **não** têm M escrito:
`vw_semad_abastecimento` e as novas views de score por veículo.

---

### 6-C. ABASTECIMENTO no resumo mensal (2026-08-31)

O abastecimento vive **dentro da view de consumo/utilização** —
`vw_saneago_resumo_frota_mensal` e `vw_semad_resumo_frota_mensal` (veículo × mês), ao lado de
`km_rodado`, `dias_utilizados` e `taxa_utilizacao_pct`. Não há view separada de abastecimento
no painel. Migração: `migracao_abastecimento_no_resumo_2026-08-31.sql`.

**3 colunas, nas posições 20 a 22 (fim da view):**

| Coluna | Conteúdo |
|---|---|
| `abastecimentos` | Quantas vezes o veículo abasteceu no mês. |
| `litros_abastecidos` | **Quanto consumiu:** litros no mês. |
| `km_por_litro` | **Consumo:** `km_rodado` / `litros_abastecidos`. |

*Quanto andou* já era o `km_rodado`, que existia antes.

> **`km_por_litro` fica em branco quando o resultado não é plausível** (fora da faixa de 1 a
> 20 km/L). Motivo: `km_rodado` e `litros_abastecidos` são ambos "o que aconteceu dentro do
> mês", mas não são o mesmo combustível — o que foi abastecido dia 31 é queimado no mês
> seguinte. Em veículo-mês isolado isso gerava absurdo: das 7.846 linhas com valor, 537 davam
> menos de 1 km/L e 413 mais de 20, com p99 em **606 km/L**. Melhor branco que número errado.
> A guarda **não afeta o total**: `km_rodado` e `litros_abastecidos` seguem íntegros em todas as
> linhas, então a medida agregada do painel usa tudo.

> **No BI, nunca faça média de média.** O consumo do período é
> `DIVIDE(SUM([km_rodado]), SUM([litros_abastecidos]))`. As duas colunas já existem na view.

**Estado (31/08/2026):**

| | SANEAGO | SEMAD |
|---|---|---|
| Linhas (veículo × mês) | 8.355 | 85 |
| Com abastecimento | 7.908 | 60 |
| Com `km_por_litro` preenchido | 6.896 (87% dos que têm abastecimento) | 58 (97%) |
| Litros no ano | 1.212.380 | 5.304 |

**Uma versão anterior tinha 6 colunas** (com uma segunda métrica de consumo calculada tanque a
tanque: `km_por_litro_evento`, `km_base_consumo`, `litros_base_consumo`). Foi **simplificada a
pedido** — duas métricas de consumo na mesma view confundiam quem monta o visual. Se algum dia
precisar da versão tanque a tanque, a fórmula é `DIVIDE(SUM(km_base), SUM(litros_base))` sobre
`tb_abastecimento`, filtrando `litros > 5 AND distancia_km > 1`.

**O que ficou de fora, e por quê:**

- **`litros_motor` não entrou.** Medido em 31/08: só 57,7% dos eventos têm o valor e, quando
  têm, ele é **exatamente igual** ao litro abastecido em 91% dos casos (razão p10–p90 = 1,00) —
  não é medição independente da ECM. **Detecção de desvio de combustível não é possível com
  este dado**; exigiria o extrato do cartão.
- `tipo_combustivel` vem **100% "Unknown"** na origem.
- **Detalhe por evento** (posto, motorista, litros de cada abastecimento) não cabe num agregado
  mensal. Está na tabela `tb_abastecimento` (§5-B) e em duas views de detalhe
  (`vw_*_abastecimento`) que seguem no banco mas **fora do escopo do painel** — definições em
  `migracao_abastecimento_2026-08-31.sql`.

> ⚠️ **É telemetria, não contabilidade.** A Geotab *deduz* cada abastecimento pela subida do
> nível do tanque combinada com a parada da viagem. **Não existe nenhuma coluna financeira** —
> a entidade `FuelTransaction` (R$, preço/litro, posto, nota fiscal) está **vazia** nesta base.
> Os litros não batem litro a litro com a nota do posto.

> 🔴 **PENDÊNCIA QUE AFETA O km/L — `tb_resumo_mensal` está defasada.** Descoberto em 31/08 ao
> validar o consumo: o `km_rodado` da view vem de `tb_resumo_mensal`, que está **11% a 14%
> abaixo** do km real de `tb_viagens` em todos os meses de 2026 (ex.: agosto 2.553.221 km na
> resumo contra 2.874.471 nas viagens; janeiro 1.280.124 contra 1.485.994). No SEMAD a defasagem
> é de **40%** (18.191 contra 30.192 km) porque a frota entrou no cadastro depois de a agregação
> do mês ter rodado. Efeito: **o `km_por_litro` sai subestimado na mesma proporção.** Causa
> provável: meses passados foram preenchidos uma vez por `backfill_resumo_mensal` (fonte Geotab)
> e nunca recalculados, enquanto `tb_viagens` seguiu crescendo com a sync incremental — e
> `atualizar_resumo_mes_corrente` só toca o mês corrente. **Correção = recalcular
> `tb_resumo_mensal` a partir de `tb_viagens` (SQL puro, sem chamada à Geotab). NÃO aplicado:
> muda `km_rodado`, `dias_utilizados`, `viagens` e `taxa_utilizacao_pct` de todos os meses no
> painel que o cliente já vê — decisão do usuário.**

---

### 6-D. SCORE DE COMPORTAMENTO (padrão Geotab) — 2026-09-09

Nota de **0 a 100** por motorista e por veículo, seguindo a metodologia oficial
**Geotab Driver Safety Scorecard**. Quanto **maior, melhor**.

Documento de apoio para usuários (explica o cálculo passo a passo, com caso real):
<https://claude.ai/code/artifact/dd0345c0-3344-475c-925e-6f3b9c86685f>

#### Como é calculado

Método oficial **Event Count**, aplicado a cada regra:

```
taxa = eventos × 1.000 ÷ km rodados
nota = 100 − taxa                     (mínimo 0)
score = Σ (nota × peso)
```

A nota **zera com 100 eventos por 1.000 km** — equivale à calibragem oficial da Geotab
(nota 0 com 10 eventos em 100 unidades de distância).

| Regra | Identificador na Geotab | Coluna | Peso oficial | Peso aplicado |
|---|---|---|---:|---:|
| Speeding | `RulePostedSpeedingId` | `excesso_velocidade` | 20% | **40%** |
| Hard Acceleration | `RuleJackrabbitStartsId` | `aceleracao_brusca` | 10% | **20%** |
| Harsh Braking | `RuleHarshBrakingId` | `frenagem_brusca` | 10% | **20%** |
| Harsh Cornering | `RuleHarshCorneringId` | `curva_drastica` | 10% | **20%** |

As quatro regras somam 50% no default oficial da Geotab; como o Scorecard exige que os
pesos fechem em 100%, cada peso foi dividido por 0,50. A Geotab define o peso como
parâmetro do cliente, então a renormalização é o uso previsto.

Faixas de risco (limiares default da Geotab, com as bordas fechadas):
**Baixo** ≥ 90 · **Leve** 75–90 · **Médio** 60–75 · **Alto** < 60.

#### Funções no banco

| Função | O que faz |
|---|---|
| `nota_regra_geotab(qtd, km)` | Nota 0–100 de uma regra (Event Count, piso em 0). |
| `score_geotab(km, exc, acel, fren, curva, piso_km=200)` | Score ponderado. **NULL** abaixo do piso de rodagem. |
| `faixa_risco_geotab(score)` | Texto da faixa; `NULL` → "Sem base (rodagem insuficiente)". |

#### Colunas por view

| Escopo | View | Colunas |
|---|---|---|
| Motorista (ano) | `vw_saneago_motoristas_anual` | `score_geotab`, `faixa_risco_geotab` |
| Veículo (ano) | `vw_saneago_veiculos_anual` | `km_ano`, contadores, `nota_velocidade`, `nota_aceleracao`, `nota_frenagem`, `nota_curva`, `score_geotab`, `faixa_risco_geotab` |
| **Veículo (mês)** | **`vw_saneago_veiculos_mensal`** | `ano`, `mes`, `ano_mes`, `km_mes`, contadores, 4 `nota_*`, `score_geotab`, `faixa_risco_geotab` |
| **Motorista (mês)** | **`vw_saneago_motoristas_mensal`** | `ano`, `mes`, `ano_mes`, `km_mes`, horas, contadores, 4 `nota_*`, `score_geotab`, `faixa_risco_geotab` |
| Período filtrado no painel | — | medidas DAX (`score_geotab_DAX.md`) |

**As views diárias (`vw_saneago_motoristas` e `vw_saneago_comportamento`) NÃO têm
score.** Ele viveu nelas por algumas horas em 09/09 e foi removido — ver *Custo no
banco* abaixo. O grão do painel é **mês/ano** (views `_mensal`), não diário.

> **Por que o score vive em views mensais/anuais, nunca diárias.** Ele só fecha depois
> de somar um período com rodagem suficiente: por dia o km é baixo e a projeção por
> 1.000 km vira ruído (1 evento em 8 km já zera a regra). O **mês** já é volume
> suficiente — por isso o painel usa as views `_mensal` (uma por veículo, uma por
> motorista, grão `ano, mes`), com a versão `_anual` para o fechamento do ano. Para o
> score de um período **filtrado arbitrário**, use as medidas DAX de
> `score_geotab_DAX.md`, que recalculam sobre a seleção (nunca média de médias).

> **A `vw_saneago_veiculos_anual` cobre a frota inteira** (1.063 veículos), porque
> parte de `vw_saneago_cadastro`. Veículo sem nenhum evento aparece com nota 100 nas
> quatro regras, em vez de ficar de fora.

> **Rodagem mínima de 200 km.** Abaixo disso o score é `NULL` e a faixa vira
> "Sem base", **nunca nota zero**. 583 dos 2.817 motoristas ficam sem score no ano.

> **O km do veículo NÃO vem do odômetro.** A coluna `odometro` da
> `vw_saneago_comportamento` é a **leitura acumulada** do dia — somá-la dá número
> absurdo. O `km_ano` vem de `tb_viagens` agregado por `device_id`.

#### Não confundir com os scores antigos

| Coluna | O que é | Direção |
|---|---|---|
| `score_risco` | Soma ponderada de eventos (exc×3 + acel×2 + fren×2 + curva×1). | Maior = **pior**, sem teto. |
| `score_seguranca` | Média **simples** das quatro notas, sem pesos. | Maior = melhor, 0–100. |
| `score_geotab` | Metodologia oficial, com pesos e piso de rodagem. | Maior = melhor, 0–100. |

As duas antigas foram **mantidas** para não quebrar o Power BI existente.

#### Estado atual (01 jan – 09 set 2026)

| Faixa | Motoristas | Veículos |
|---|---:|---:|
| Baixo risco | 59 | 33 |
| Risco leve | 205 | 82 |
| Risco médio | 370 | 175 |
| **Alto risco** | **1.600** | **750** |
| Sem base | 583 | 23 |

Score agregado da frota: **37,0** (notas por regra: velocidade 14,5 · aceleração 43,9 ·
frenagem 95,9 · curva 16,2). A frota registra um excesso de velocidade a cada 11,7 km.

> **Ressalva para leitura do número.** A frota gerou **758.007 curvas bruscas** contra
> **37.247 frenagens** — 20× mais. Apenas 1 motorista em 2.234 zerou a nota de frenagem,
> contra 764 que zeraram a de velocidade. Manobras de severidade equivalente com
> frequência tão distinta indicam **limiares de disparo desalinhados no MyGeotab**.
> Enquanto não forem equalizados, o score reflete também a configuração das regras, e não
> apenas a condução. Equalizar os limiares na origem é o próximo passo para o número ser
> defensável em contrato.

#### Custo no banco — e a regressão que houve no caminho

A primeira versão colocou o score também nas duas views **diárias**, calculado com
CTEs que agregam `tb_comportamento_eventos` e `tb_viagens` inteiras. Isso destruiu o
uso interativo: o `SELECT * … LIMIT 200` que o DBeaver (e qualquer exploração) faz
passou de **0,1 s para 21,9 s** na `vw_saneago_comportamento`. Agregação de hash
consome toda a entrada antes de emitir a primeira linha, então o `LIMIT` deixa de
cortar trabalho.

A medição que havia sido feita usou `count(*)`, que é varredura completa — o pior caso
e o menos representativo. Ali o impacto parecia de 5%, e por isso a regressão passou.

**Correção** (`migracao_score_correcao_2026-09-09.sql`): o score saiu das diárias e
passou a viver em views anuais, que é o grão onde ele faz sentido. Depois da correção:

| View | `SELECT * LIMIT 200` |
|---|---:|
| `vw_saneago_comportamento` | 0,1 s |
| `vw_saneago_motoristas` | 35 s (custo original, sem score) |
| `vw_saneago_veiculos_anual` | 17,8 s |
| `vw_saneago_motoristas_anual` | ~22 s |

> **Ao medir custo de view, meça `LIMIT 200`, não `count(*)`.** É o que as
> ferramentas fazem ao abrir a view, e é o caso onde CTE de agregação machuca.

Migrações: `migracao_score_geotab_2026-09-09.sql` (funções + motoristas_anual) e
`migracao_score_correcao_2026-09-09.sql` (restaura as diárias + cria a view de
veículos). **Não aplicado nas views `vw_semad_*`** — as funções são globais, bastaria
repetir o padrão.

---

---

### 6-E. HODÔMETRO POR VEÍCULO × MÊS — `tb_odometro_mensal` (2026-09-22)

**Tabela física** (não view) com o hodômetro de cada veículo no grão **ano-mês**,
cobrindo a **frota inteira** e o período **abr/2025 → set/2026** — 1.988 veículos × 18 meses =
**35.784 linhas**.

> A primeira entrega foram duas *views* separadas por cliente
> (`vw_saneago_odometro_mensal` / `vw_semad_odometro_mensal`). O usuário pediu uma
> **tabela única com todos os veículos**; as views foram dropadas.

**Fonte:** `tb_odometro_dia` + `tb_cadastro` **cru** (sem filtro de cliente — inclui
SANEAGO, SEMAD, COMURG, ECONOMIA). Só o odômetro **físico**; `odometro_gps` é `0,0` em
100% das linhas (coluna morta na origem).

#### Colunas

| Coluna | O que é |
|---|---|
| `device_id` | = `tb_cadastro.id` (PK junto de `ano`, `mes`) |
| `serial`, `placa`, `veiculo` | Identificação (`veiculo` = `PLACA \| MARCA \| MODELO` padronizado) |
| `todos_grupos` | Hierarquia **folha** |
| **`todos_grupos_expandido`** | Folha **+ ancestrais** — use esta para filtrar por cliente |
| `grupo_id` | Hash da hierarquia |
| `ano`, `mes`, `ano_mes`, `mes_ini`, `mes_fim` | Grão do período |
| **`odometro_inicio`** | Hodômetro na **abertura** do mês (km) |
| **`odometro_fim`** | Hodômetro no **fechamento** do mês (km) |
| `km_periodo` | `odometro_fim − odometro_inicio` |
| `dia_inicio`, `dia_fim` | Datas das leituras usadas |
| `dias_com_leitura` | Quantos dias do mês tiveram leitura |
| `origem_inicio` | `fechamento do mes anterior` / `primeira leitura do veiculo` / `sem leitura` |
| **`origem_dado`** | `carga corrigida` / `legado (unidade suspeita)` / `sem leitura` — **filtre por esta coluna** |
| `atualizado_em` | Quando a linha foi recalculada |

#### Como se mantém atualizada

`recarregar_odometro_mensal(engine)` roda **no fim do modo `comportamento`**, logo após
`sincronizar_odometro_dia` — de onde a tabela deriva. É `TRUNCATE` + `INSERT` da tabela
inteira: **3,6 s** para as 17.892 linhas, então não há lógica incremental. Um veículo
novo no cadastro ou uma leitura corrigida entram sozinhos. **Nenhuma chamada à Geotab.**

#### Filtrar por cliente: use `todos_grupos_expandido`

Depois do restructuring de grupos de 2026-09-14, o token `OPE_<cliente>` passou a viver
só no grupo **ancestral** — a folha não o tem. Medido nesta tabela:

| Filtro | Veículos |
|---|---|
| `todos_grupos LIKE '%OPE_SANEAGO%'` | **0** |
| `todos_grupos_expandido LIKE '%OPE_SANEAGO%'` | **1.395** |

#### Três decisões de desenho

1. **Todo veículo aparece em todo mês** (`cadastro CROSS JOIN meses`). Sem isso o
   veículo parado sumiria do filtro.
2. **A abertura é o fechamento do mês anterior** (carry-forward), não a primeira
   leitura do mês. Só existe leitura em dia que o veículo rodou — usar a primeira
   leitura do mês perderia o km do primeiro dia e os meses não emendariam. Resultado:
   o fim de um mês é exatamente o início do seguinte (**0 desencontros em 13.187
   pares**). No primeiro mês do veículo cai na primeira leitura, sinalizado em
   `origem_inicio`.
3. **Mês sem leitura carrega a última conhecida** → `inicio = fim` e `km_periodo = 0`
   (veículo parado), em vez de linha vazia.

#### Sujeiras do dado bruto

| Sujeira | Tamanho | Situação |
|---|---|---|
| `odometro_gps` sempre zero | 324.016 de 324.016 linhas | Coluna não entra na tabela |
| Sentinela de overflow INT32 (`2^31/10` = 214.749.636,49 km) | 16 dias, device `b12B` / placa SGZ8B71 (faixa real 5.169 → 11.413 km) | Contida pela guarda `odometro < 3000000` |
| **Odômetro gravado em METROS** em veículos de baixa quilometragem | ~57–69 veículos | **EM ABERTO** — ver abaixo |

> ##### Bug de unidade do odômetro — corrigido em 22/09/2026
>
> `_inferir_km` decidia a unidade **por leitura** (`raw > 1.000.000 → ÷1000`, senão
> mantém). O diagnóstico em uso manda metros sempre, então todo veículo **abaixo de
> 1.000 km** ficava gravado em metros, como se fosse km.
>
> Duas medições confirmaram:
> - Contra `tb_viagens` em set/2026: **57 devices com razão odômetro ÷ km_viagens ≈ 1000**
>   (todos com odômetro entre 154.000 e 995.700, isto é, sob o limiar), contra 1.656 com
>   razão ≈ 1.
> - **69 devices com uma queda de exatamente ~1000×** na série, sempre com o valor logo
>   antes da queda entre 908.000 e 1.000.000 — o dia em que cruzaram o limiar.
>
> Era **a causa raiz** das 439 leituras "não monotônicas" e dos `km_periodo` negativos.
>
> **A correção saiu em dois passos.** O primeiro foi um `÷1000` fixo — certo para o dado
> atual, mas frágil: `_selecionar_diag_fisico` escolhe o diagnóstico **em tempo de
> execução**, e o primeiro candidato da fila se chama `DiagnosticOdometerInKilometersId`,
> que já entrega km. Se ele passasse a responder, o `÷1000` fixo deixaria todo o hodômetro
> 1000× **menor**. Trocado por **`DIVISOR_ODO_KM`, um divisor por diagnóstico**.
>
> Sondagem de 22/09 (set/2026, 20 devices):
>
> | Diagnóstico | Leituras | Faixa | Unidade |
> |---|---|---|---|
> | `DiagnosticOdometerInKilometersId` | 0 | — | (vazio nesta base) |
> | `DiagnosticOdometerAdjustmentId` | 219 | 9.456.000 a 190.527.798 | **metros** |
> | `DiagnosticOdometer` | 0 | — | — |

#### Linhas legadas em 2026 — use `origem_dado`

O re-sync de 2026 (18 min, 250.383 linhas) corrigiu **2.068 linhas em 218 devices** e
levou os devices errados na prova de campo de **57 para 25**. Mas o upsert **não
reescreveu 76.756 linhas**: em 362 devices a API não devolve mais nada (são inativos —
zero viagens em set/2026 e os três diagnósticos vazios) e em 1.549 devices alguns dias
vieram e outros não.

**Decisão do usuário: manter essas linhas.** Apagá-las custaria 1.984 veículo-mês de
cobertura em 2026 (−13%). Em vez disso elas ficam **marcadas** na coluna `origem_dado`:

| `origem_dado` | Linhas | km negativo | Maior hodômetro |
|---|---|---|---|
| `carga corrigida` | 15.962 | **1** | **245.168 km** (plausível) |
| `legado (unidade suspeita)` | 9.197 | 129 | 975.000 km (impossível) |
| `sem leitura` | 10.625 | 0 | — |

> Todas as linhas `legado` estão em **2026**. O período de 2025 saiu limpo, porque foi
> carregado inteiro já com a conversão corrigida.

**No painel, filtre `origem_dado = 'carga corrigida'`** para trabalhar só com o dado
confiável. A flag marca como suspeito o mês em que **qualquer das duas pontas** (abertura
ou fechamento) veio da carga legada — olhar só o fechamento deixava 68 km negativos
vazarem para o lado limpo.

#### Dados de 2025 — janela própria do odômetro

O `ANO_CORTE`/`DATA_CORTE` é piso **global** do projeto. Baixá-lo para 2025 arrastaria
comportamento, viagens e resumo mensal junto — `tb_viagens` tem 204 MB só de 2026, o
banco quase dobraria e o enxugamento de junho seria desfeito.

Por isso o odômetro ganhou uma **janela independente**: a env **`ODO_DATA_INICIO`**
(no `.env`, valendo `2025-04-15`), lida em `ODO_DATA_CORTE`. Só `tb_odometro_dia` e
`tb_odometro_mensal` a enxergam; `DATA_CORTE` segue mandando em todo o resto. Sem a env,
`ODO_DATA_CORTE == DATA_CORTE` e nada muda.

> **Cuidado:** a poda de `sincronizar_odometro_dia` passou a usar `ODO_DATA_CORTE`. Se
> ficasse no piso global, o sync das 08:00 **apagaria 2025 inteiro** no dia seguinte.

**O limite real é da origem, não nosso.** Sondando mês a mês com 8 devices:

| Mês pedido | Leituras |
|---|---|
| jan, fev, mar/2025 | **0** |
| **15/abr/2025** | primeira leitura que existe |
| jun/2025 em diante | volume estável |

A Geotab retém ~17 meses; pedir antes de 15/04/2025 devolve vazio.

#### No Power BI

- Km do período filtrado: `SUM(km_periodo)`.
- Hodômetro de abertura/fechamento de um **intervalo** de meses: medidas DAX no rodapé
  de `migracao_odometro_mensal_2026-09-22.sql`.

## 7. Configuração (`.env`)

O `.env` (não versionado) guarda credenciais e parâmetros. Principais chaves:

| Chave | Para quê |
|---|---|
| `GEOTAB_SERVIDOR` / `GEOTAB_DATABASE` / `GEOTAB_USERNAME` / `GEOTAB_PASSWORD` | Acesso à API Geotab. |
| `SUPABASE_HOST` / `_PORTA` / `_BANCO` / `_USUARIO` / `_SENHA` | Conexão Postgres **local** (nomes herdados da era Supabase; hoje apontam p/ localhost). |
| `SUPABASE_SSLMODE` | `disable` no local (era `require` na nuvem). |
| **`SUPABASE_SCHEMA`** | Schema alvo. Vazio/ausente = `search_path` padrao (local: `public`). No Cloud SQL vale `geotab` — ver secao 14. |
| `VIAGENS_DIAS` | `0` = ano inteiro (local); `>0` = janela móvel em dias (e ativa a poda). |
| `ABASTECIMENTO_MARGEM_DIAS` | Dias já gravados que o incremental re-busca (default `3`) — a Geotab revisa eventos recentes. |
| `ABASTECIMENTO_LOTE_DIAS` | Tamanho do bloco de dias por chamada (default `31`). |
| **`ODO_DATA_INICIO`** | Piso **só do odômetro** (`AAAA-MM-DD`). Vale `2025-04-15`. Independente de `ANO_CORTE` — ver 6-E. **Remover esta chave faz o sync apagar 2025.** |
| `SUPABASE_STORAGE_URL` / `SUPABASE_SERVICE_KEY` / `SUPABASE_BUCKET` | Upload dos CSVs no Storage externo. |

> **Importante:** o orquestrador `atualizar_local.py` carrega o `.env` via `load_dotenv`. Sem isso,
> o export CSV era pulado todo dia (bug corrigido em 2026-06-23).

---

## 8. Robustez do Postgres (auto-cura)

O Postgres local **morre se fecharem a janela/terminal que o hospeda** (exceção `0xC000013A`,
`STATUS_CONTROL_C_EXIT`). Isso já derrubou a sync no meio.

- **Não pode virar serviço** (precisa de admin/GPO) nem rodar sem console (WSH e janela-oculta
  bloqueados na máquina). Por isso a defesa é no código, não no launcher.
- **Auto-cura:** `atualizar_local.py` checa o socket e dá `pg_ctl start` **antes** da sync e
  **de novo** se uma fase falhar (repetindo a fase 1×). Caminhos configuráveis por env
  (`PG_CTL`/`PGDATA`/`PG_HOST`/`PG_PORT`).
- **Regra de ouro para o usuário:** nunca suba o banco por um terminal que vai fechar. Deixe o
  `iniciar_postgres.bat` do logon cuidar disso. Se fechar e o banco morrer, a próxima sync religa.
- **Janela rotulada (2026-07-01):** o `iniciar_postgres.bat` agora abre uma janela com título
  claro (`BANCO GEOTAB — NAO FECHE...`) e um banner explicando o que ela faz e quando pode ser
  fechada (só depois de terminar o Power BI e a sync do dia; volta no próximo logon). Um loop
  `timeout` mantém a janela aberta — deixe-a **minimizada**, não fechada.

---

## 9. Download CSV externo (Supabase Storage)

- **Objetivo:** clientes externos baixam cada relatório por link público estável, **sem depender
  do notebook ligado** (snapshot diário, não ao vivo).
- **Como:** após a sync, `exportar_csv.py` usa `psql \copy` (não carrega na RAM) para gerar 1 arquivo
  de **nome fixo** por view e sobe no Storage com `x-upsert` (o link nunca muda). Gera um `index.html`
  com todos os links — **esse é o link que se manda ao cliente.**
- **Viagens é grande** (~1,6 GB no ano): dividida por mês + gzip, e particionada por tamanho
  (`_YYYY-MM.csv.gz` ou `_p1`/`_p2`) para respeitar o **limite do free tier: 50 MB por arquivo**.
- **Refresh:** o bucket é limpo antes de cada publicação (evita arquivos órfãos).
- **Encoding:** `PGCLIENTENCODING=UTF8` é obrigatório no `\copy` (senão o psql aborta no 1º acento).
- **Caveat free tier:** o projeto Supabase pausa após ~7 dias sem atividade — o upload diário o mantém acordado.

Link do índice: `https://ldhelbygqrjqchistrgp.supabase.co/storage/v1/object/public/geotab-csv/index.html`

---

## 10. Atualização agendada no Power BI (banco local via Gateway)

O Power BI Service lê o banco **local** através do **On-premises Data Gateway** instalado nesta
máquina. Para a atualização rodar sozinha, é preciso configurar uma vez a fonte de dados no
gateway e o agendamento no dataset.

### Pré-requisitos
- **Gateway padrão** (standard, não "personal") instalado e online, rodando como **serviço do
  Windows** e logado com a **mesma conta da organização** dona do dataset.
- Driver **Npgsql** (PostgreSQL) instalado na máquina do gateway.
- **Postgres local no ar** no momento do refresh (ver gotcha abaixo).

### Passo a passo (uma vez)
1. Power BI Service → ⚙ → **Gerenciar conexões e gateways** → **Nova conexão / fonte de dados**:
   - **Cluster:** selecionar o gateway desta máquina (dropdown).
   - **Nome da conexão:** `geotab-localhost` (rótulo livre).
   - **Tipo:** PostgreSQL · **Servidor:** `localhost:5432` · **Banco:** `geotab`.
   - **Autenticação:** Basic — usuário `postgres`, senha do banco (ver `psql_geotab.bat` / `.env`).
   - **Nível de privacidade:** Organizational.
   > O **Servidor** aqui tem que ser idêntico ao que está no Power Query do `.pbix` (`localhost`
   > vs `127.0.0.1` importa) — senão dá "não foi possível encontrar a fonte no gateway".
2. Dataset → **⋯ → Configurações → Conexão de gateway:** ativar e mapear para a fonte criada.
3. Mesma tela → **Atualização agendada:** ligar, fuso **UTC-3 (Brasília)**, horário **10:00**,
   e ativar notificação de falha por e-mail.

### Por que 10:00
A sync diária roda no logon e termina cedo (~08:20). 10:00 dá folga para banco + gateway
estarem no ar. Limite do Pro: até 8 horários/dia.

### Gotcha — o refresh falha se o banco estiver fora do ar
A atualização agendada dispara num horário fixo e exige, naquele instante: **PC ligado e
acordado**, **Postgres no ar** e **serviço do gateway rodando**.
- Erro típico: `No connection could be made because the target machine actively refused it`
  (status 400) = **o Postgres não estava no ar** na hora (porta 5432 sem listener).
- A **auto-cura só roda durante a sync diária** — ela NÃO fica vigiando o banco o resto do dia.
  Se o banco cair (janela fechada — gotcha `0xC000013A`, §8) e o Power BI tentar atualizar, falha
  e nada religa o banco para o Power BI.
- **Defesa:** não fechar a janela do Postgres; deixar o `iniciar_postgres.bat` do logon subir o
  banco; manter o PC ligado/acordado às 10:00. Religar na mão se preciso:
  `pg_ctl -D C:\Users\ygor.kouzak\pgdata start` e reexecutar o refresh.
- Nos dias em que o PC fica desligado às 10:00, o refresh falha (limitação do banco ser local
  nesta máquina) — não há solução sem mudar a fonte para um host sempre no ar.

---

## 10-B. Power BI SEM gateway — via CSV público (alternativa; 2026-07-01)

Quando **não é possível criar o gateway**, o Power BI Service pode atualizar lendo os CSVs
que o `exportar_csv.py` já publica no Supabase Storage (fonte **Web / Anônimo** refresca no
Service sem gateway).

- **Vantagem:** o refresh **independe do PC ligado / Postgres no ar** — lê o último snapshot
  diário publicado na nuvem. Não usa o usuário/senha do Postgres.
- **Custo:** exige refazer as consultas do `.pbix` para ler os CSVs em vez da conexão Postgres
  (modelo/DAX seguem iguais, pois são as mesmas views).
- **Frescura:** a do último export diário (`exportar_csv.py` no fim da sync). Se um dia não
  exporta, o Service reapresenta o snapshot anterior (sem erro de conexão).
- **Como fazer (consultas M prontas + passo a passo):** ver a pasta `powerbi_queries/`
  (1 arquivo `.m` por view + `README.md`). Inclui as 8 views dashboard e a
  `vw_relatorio_viagens` combinando todos os meses (lê o `index.html` p/ descobrir os
  arquivos, aguenta partições `_p1`/`_p2`). Usa o padrão `Web.Contents(base, [RelativePath=...])`
  p/ o Service aceitar as URLs dinâmicas. Cada script é autossuficiente (não depende de
  funções auxiliares).

---

## 11. Problemas conhecidos (troubleshooting)

| Sintoma | Causa / Solução |
|---|---|
| Sync não rodou / dados parados | PC não foi ligado em dia útil, ou Postgres caiu. Conferir `atualizacao_local.log` e `server.log`. Religar: `pg_ctl -D C:\...\pgdata start`. |
| `connection refused localhost:5432` | Postgres caiu (janela fechada — `0xC000013A`). A auto-cura religa na próxima fase/sync; ou religar na mão. |
| Power BI: `target machine actively refused it` (400) | Postgres fora do ar na hora do refresh. Religar (`pg_ctl ... start`) e reexecutar. A auto-cura só roda na sync, não p/ o Power BI (ver §10). |
| Export CSV pulado | Faltava `SUPABASE_SERVICE_KEY` no ambiente do orquestrador (corrigido com `load_dotenv` em 2026-06-23). Conferir a chave no `.env`. |
| `403` não-JSON na auth Geotab | Bloqueio de WAF por IP (era o caso do Render). Local tem IP limpo. |
| HTTP 400 ao subir CSV | Arquivo > 50 MB (free tier). O particionamento já cuida; conferir `ALVO_CSV`/`LIMITE_ARQUIVO`. |
| Taxa de utilização > 100% no BI | Mês futuro em `tb_resumo_mensal`. Corrigido em código + views; dar **refresh** no Power BI p/ limpar cache. |
| Quota Geotab estourada | Throttle proativo em 4500 sub-chamadas/min (limite real 5000). |
| Views dão erro `relação "tb_..." não existe` | Alguma das **6 tabelas de configuração** foi apagada (ver aviso abaixo). Restaurar do backup do dia. |

> ⚠️ **Não apague estas 6 tabelas — elas quebram TODAS as 18 views.**
>
> | Tabela | Quem lê | Linhas |
> |---|---|---|
> | `tb_grupo_token_ignorado` | `arrumar_grupos()` | 8 |
> | `tb_grupo_nome_excecao` | `grupo_nome()` | 3 |
> | `tb_grupo_nivel_excecao` | `nivel_grupo()` | 2 |
> | `tb_hierarquia_grupo` | `sup_oficial()` | 1 |
> | `tb_veiculo_correcao` | `marca_padrao()` / `modelo_padrao()` | 15 |
> | `tb_contrato_semad` | `grupo_semad()` | 1 |
>
> São minúsculas e parecem descartáveis, mas as **funções** que as views chamam dependem
> delas. Como a dependência é via função (e não direta), o Postgres **não avisa nem bloqueia**
> o `DROP TABLE`: as views continuam existindo e só quebram na hora da leitura — ou seja, no
> refresh do Power BI. Aconteceu em 28/08/2026.
>
> **Cuidado ao conferir:** `SELECT count(*) FROM a_view` **passa mesmo com a view quebrada**
> (o Postgres descarta as colunas que não usa e nem avalia as funções). Teste sempre com
> `SELECT * FROM a_view LIMIT 1`.

### Restaurar as tabelas de configuração (sem mexer no resto do banco)

Os backups diários ficam em `C:\Users\ygor.kouzak\backups` (formato custom, 14 dias).
Restaure **só as tabelas perdidas** — um restore completo sobrescreveria os dados do dia:

```bash
pg_restore -h localhost -U postgres -d geotab --no-owner --no-acl -t tb_grupo_token_ignorado -t tb_grupo_nome_excecao -t tb_grupo_nivel_excecao -t tb_hierarquia_grupo -t tb_veiculo_correcao -t tb_contrato_semad "C:\Users\ygor.kouzak\backups\geotab_AAAAMMDD.dump"
```

> ⚠️ O `pg_restore -t` traz a tabela e os dados, mas **não traz as chaves primárias**. Sem
> elas o `ON CONFLICT` da sync quebra. Reaplique depois:

```bash
psql -h localhost -U postgres -d geotab -c "ALTER TABLE public.tb_contrato_semad ADD CONSTRAINT tb_contrato_semad_pkey PRIMARY KEY (token); ALTER TABLE public.tb_grupo_nome_excecao ADD CONSTRAINT tb_grupo_nome_excecao_pkey PRIMARY KEY (codigo); ALTER TABLE public.tb_grupo_nivel_excecao ADD CONSTRAINT tb_grupo_nivel_excecao_pkey PRIMARY KEY (codigo); ALTER TABLE public.tb_grupo_token_ignorado ADD CONSTRAINT tb_grupo_token_ignorado_pkey PRIMARY KEY (token); ALTER TABLE public.tb_hierarquia_grupo ADD CONSTRAINT tb_hierarquia_grupo_pkey PRIMARY KEY (reg); ALTER TABLE public.tb_veiculo_correcao ADD CONSTRAINT tb_veiculo_correcao_pkey PRIMARY KEY (marca_raw, modelo_raw);"
```

---

### Power BI: `42P01 relação "tb_contrato_semad" não existe` (resolvido em 2026-09-23)

Erro nas views do SEMAD (`vw_semad_status` e as demais). A tabela `tb_contrato_semad` havia
sumido do banco. Recriada por `migracao_contrato_semad_2026-09-23.sql`, aplicada no banco local
e no Cloud SQL.

Duas coisas valem ser entendidas aqui:

**Por que a view existia sem a tabela.** Quem referencia `tb_contrato_semad` é a função
`contrato_semad()`, e o PostgreSQL **não registra dependência através de funções**. Por isso a
tabela pôde desaparecer sem derrubar a view na hora — o erro só aparece quando alguém executa a
consulta. Sempre que um `42P01` surgir numa view que "sempre funcionou", suspeite de uma tabela
lida por função.

**Cuidado ao repovoar: o seed antigo devolve zero, em silêncio.** O
`migracao_semad_2026-08-27.sql` semeia `'OPE_SEMAD - 035/2026'`, formato **obsoleto**. O desenho
vigente é o de `migracao_semad_hierarquia_2026-09-14.sql`: os tokens são os nomes dos grupos-PAI,
**sem prefixo** — `'SEMAD - 035/2026'` e `'SEMAD - 031/2026'`. Com o token errado as views do
SEMAD não dão erro: retornam 0 linhas. Conferência após aplicar: o contrato 035 deve trazer
**90 veículos**. Se vier 0, o token está errado.

> As views `vw_semad_motoristas` e `vw_semad_motoristas_anual` retornam 0 linhas, e isso é
> **esperado** — `tb_motoristas` não tem a coluna `todos_grupos_expandido`. Ressalva já
> registrada em `migracao_semad_grupos_contrato_2026-09-15.sql`, não é regressão.

---

### Nunca inicie o Postgres por fora do `iniciar_postgres.bat` (2026-09-23)

O banco local **morre junto com o processo que o iniciou**. Isso já estava documentado no
próprio `iniciar_postgres.bat` (*"a janela hospeda o banco: fechá-la = derruba o Postgres,
gotcha 0xC000013A"*), mas vale repetir aqui porque a armadilha tem uma forma menos óbvia:

Subir o servidor por um terminal, script ou tarefa em segundo plano amarra o Postgres àquele
processo. Quando ele termina — ou é interrompido — o banco cai, e **não há janela rotulada para
alertar ninguém**. O sintoma no `server.log` é sempre o mesmo:

```
client backend (PID nnnnn) foi terminado pela exceção 0xC000013A
terminando quaisquer outros processos servidor ativos
```

`0xC000013A` é `STATUS_CONTROL_C_EXIT`: encerramento por evento de console, **não** falta de
memória nem corrupção. Se o log mostrar isso, alguém fechou o hospedeiro do banco.

**Para subir o banco, use sempre o `iniciar_postgres.bat`** (duplo clique). Ele é idempotente —
se o banco já estiver no ar, não faz nada — e deixa a janela rotulada no desktop.

**Se o servidor travar e não parar** (`pg_ctl stop` dizendo *"servidor não desligou"*), encerre
os processos `postgres.exe`, apague o `postmaster.pid` órfão do `pgdata` e rode o `.bat`. Os
dados estão protegidos pelo WAL: o Postgres faz a recuperação sozinho no próximo start. Em
2026-09-23 esse ciclo completo foi executado e as 12 tabelas, 25 views e 22 funções vieram
íntegras.

> **Dois erros conhecidos do Postgres no Windows, ambos transitórios**, que aparecem no
> `server.log` deste projeto desde agosto e **não indicam perda de dados**:
> `could not reserve shared memory region ... error code 487` (conflito de endereçamento ao
> criar processos filhos) e `0xC0000142` (falha de inicialização de DLL num filho). O Postgres
> reinicia sozinho; se travar, siga o parágrafo acima.

> **Melhoria pendente:** o `server.log` está **dentro** do `pgdata`. Durante a recuperação, o
> Postgres varre o diretório de dados e tenta abrir o próprio log, que está travado pelo
> redirecionador — daí o aviso *"não foi possível abrir o arquivo ./server.log: violação de
> compartilhamento"*. Ele tenta por 30s e segue, então é inofensivo, mas mover o log para fora
> do `pgdata` elimina o ruído. A correção definitiva para tudo isto é rodar o Postgres como
> **serviço do Windows** — aí nenhuma janela pode derrubá-lo. Deixa de importar após a migração
> para o Cloud SQL.

---

### Campo `combustivel` na view de abastecimento (2026-09-23)

**O que ele é — e o que ele NÃO é.** Ele diz o **combustível com que o veículo está
classificado na Geotab**, não o produto que entrou no tanque naquele abastecimento. Essa
distinção importa: a Geotab **deduz** o abastecimento pela subida do nível do tanque combinada
com a parada da viagem. É telemetria, não extrato de cartão — ela não sabe o que foi abastecido.
O campo `tipo_combustivel`, que vem do `FuelUpEvent.productType`, traz **`Unknown` em 100% dos
59.508 eventos**; foi mantido na view por compatibilidade, mas não serve para nada.

**De onde sai o dado.** Da própria hierarquia de grupos da Geotab, sob
`Powertrain and Fuel Type` → `Internal Combustion Engine` → `Diesel` / `Ethanol` /
`Gasoline or Petrol`. Esses tokens já estavam na `tb_grupo_token_ignorado` — o projeto os
descartava de propósito para não poluírem a coluna de grupos.

A função `combustivel_veiculo(p_todos)` lê a coluna **crua** `tb_cadastro.todos_grupos`. Isso não
é detalhe: o `todos_grupos` das views já passou por `arrumar_grupos()` e **perdeu** o token. O
cru cobre 1.914 dos 1.988 veículos; o expandido cobre menos (1.872). Etanol + Gasolina no mesmo
veículo vira `Flex`.

O campo foi acrescentado à **`vw_saneago_cadastro`** (é atributo do veículo, então toda view que
use a cadastro o herda) e exposto na **`vw_saneago_abastecimento`**.

| Combustível | Abastecimentos (SANEAGO) |
|---|---:|
| Etanol | 35.779 (93,7%) |
| Gasolina | 2.327 (6,1%) |
| Diesel | 37 (0,1%) |
| sem classificação | 30 (0,1%) |

> **Cuidado ao analisar: a divisão Etanol × Gasolina é artefato de cadastro, não realidade.**
> O mesmo modelo aparece dos dois lados — 578 Saveiros como `Etanol` e 80 como `Gasolina`, sendo
> que todos são flex. A Geotab registra o que foi marcado veículo a veículo, e isso foi
> preenchido de forma inconsistente. Para somar litros por combustível, trate `Etanol` e
> `Gasolina` como um grupo só; para separar leve de pesado, `Diesel` é confiável.

> **Por que quase não há Diesel aqui:** a `vw_saneago_abastecimento` filtra pelos veículos
> visíveis da SANEAGO, que são quase todos carros leves. Os caminhões a diesel estão nos outros
> contratos. Na frota inteira a proporção é bem outra: 13.891 abastecimentos a diesel.

**No SEMAD o campo também existe** (`vw_semad_cadastro` e `vw_semad_abastecimento`), e a
proporção confirma o ponto acima — lá o diesel é 24,0% contra 0,1% na SANEAGO:

| Combustível | Abastecimentos (SEMAD) |
|---|---:|
| Etanol | 303 (72,7%) |
| Diesel | 100 (24,0%) |
| sem classificação | 14 (3,4%) |

> **Ordem dentro dos arquivos .sql não é detalhe estético.** Duas vezes na mesma tarefa isso
> quebrou: a função `combustivel_veiculo()` ficou depois das views que a usam (o banco local
> passou, porque a função já existia de um teste, e só o Cloud SQL acusou); e o
> `migracao_gcp_views_semad_*.sql`, gerado em ordem alfabética, criava
> `vw_semad_abastecimento` antes de `vw_semad_cadastro` — que é de onde vem a coluna nova. Os
> arquivos são executados na ordem em que estão escritos. **Regra: funções antes das views, e
> a view de cadastro antes das que fazem JOIN com ela.**

---

### Veículo aparece no resumo de frota mas não no abastecimento (2026-09-23)

**Não é defeito das views.** Toda placa da `vw_saneago_abastecimento` está no
`vw_saneago_resumo_frota_mensal`; o contrário é que falha — e falha porque **a Geotab nunca
gerou evento de abastecimento** para aquele veículo, não porque a view o esconda.

A causa é o **sensor de nível do tanque**. A Geotab deduz o abastecimento pela subida do nível
combinada com a parada da viagem; sem leitura de nível, não há evento. Conferido na API
(`StatusData` / `DiagnosticFuelLevelId`, janela de 14 dias):

| Placa | Situação | Leituras de nível |
|---|---|---:|
| SGZ8J09, SGZ5H99 | sem abastecimento | **0** |
| SGZ9E21, SGZ5I15 | sem abastecimento | 1 |
| SGZ8I53, SGZ9E71 | com abastecimento | 446 / 536 |

E **não é falta de uso**: os quatro rodam o ano inteiro, com 2.862 a 5.979 viagens e até
19.837 km — acima da mediana da frota (2.467 viagens / 8.051 km).

**Na frota inteira são 43 veículos ativos** com 50+ viagens e zero abastecimento, e eles se
dividem em dois problemas distintos:

- **Sistemático — classes inteiras de modelo, 24 veículos:** ATEGO 2426 (11 de 11),
  DELIVERY 9.180 (9 de 9), ATEGO 1419 (2 de 2), ATEGO 1719 (2 de 2). Cem por cento do modelo não
  reporta. Isso é compatibilidade ou configuração do rastreador com o barramento do caminhão,
  não defeito individual — é pauta para o fornecedor da telemetria.
- **Isolado — ~19 veículos** de modelos que funcionam bem (Saveiro 2 de 657, Argo 2 de 393,
  Ducato 2 de 48). Aí sim é falha unitária: sensor, conexão ou configuração daquele veículo.

Lista completa em `veiculos_sem_nivel_tanque_2026-09-23.csv`.

> **Consequência para os relatórios:** km/L e litros consumidos **não existem** para esses 43
> veículos, e nenhum ajuste de SQL resolve — o dado não é coletado. Ao comparar consumo entre
> grupos, verifique se a diferença não vem daí.

**Atenção: há DUAS causas diferentes, e elas se confundem.** No SEMAD, 23 das 103 placas do
resumo não aparecem no abastecimento — e o motivo não é sensor, é **falta de uso**: são veículos
que entraram na frota entre 24/08 e 16/09/2026, com 2 a 67 viagens e **zero quilômetro em 18
dos 23**. Sem rodar não se gasta combustível, sem gastar não há queda de nível, sem queda não há
o que detectar. Esses aparecem sozinhos quando começarem a operar.

**Como distinguir, antes de acionar alguém:** olhe os km rodados.

| Sintoma | Causa | Ação |
|---|---|---|
| Muitas viagens e muitos km, zero abastecimento | sensor de nível mudo | acionar o fornecedor da telemetria |
| Poucas viagens e ~zero km, veículo recente | ainda não rodou | nenhuma; aguardar |

Confirme pela API antes de abrir chamado: `StatusData` com `DiagnosticFuelLevelId` numa janela
de 14 dias. Veículo saudável devolve centenas de leituras variando de ~13% a 100%; veículo com
sensor mudo devolve 0 ou 1.

---

### Placas com espaço em branco — corrigido (2026-09-24)

A Geotab devolve `licensePlate` (e `name`) com espaço nas bordas em parte da frota: **207 de
1.988 placas**, uma delas com dois espaços. O sync copiava como vinha.

**Os JOINs do projeto nunca sofreram** — são todos por `device_id`. Quem sofria era o **Power BI**:
`ABC1D23` e `ABC1D23 ` são valores distintos, aparecem duas vezes num filtro, quebram
relacionamento por placa e fazem um veículo "sumir" de um visual mesmo estando no banco.

| Onde estava | Valores |
|---|---:|
| `tb_cadastro.placa` | 207 |
| `tb_cadastro.veiculo` | 13 |
| `tb_status.placa` | 207 |
| `tb_odometro_mensal.placa` | 3.726 |
| `tb_odometro_mensal.veiculo` | 450 |

Varredura nas 73 colunas de texto das tabelas: **nenhuma coluna de chave** (`id`, `device_id`)
foi afetada.

**A correção tem três camadas, e as três são necessárias:**
1. **Origem** — `.strip()` nos três pontos de escrita do `geotab_supabase.py` (nome do veículo e
   placa no cadastro, `placa_map` do status) e `btrim(c.placa)` no SQL de `tb_odometro_mensal`.
   Sem isto, o sync do dia seguinte sujaria tudo de novo.
2. **Passivo** — `migracao_placas_btrim_2026-09-24.sql`, idempotente.
3. **Views** — `btrim` na placa das duas views de cadastro, como cinto de segurança.

> **Depois de corrigir dados, lembre da materialized view.** A `vw_saneago_comportamento` é
> materializada: ela continuou devolvendo as placas sujas mesmo com as tabelas já limpas, porque
> `CREATE MATERIALIZED VIEW IF NOT EXISTS` não reconstrói o conteúdo. Foi preciso um
> `REFRESH MATERIALIZED VIEW CONCURRENTLY`. **Toda correção de dado exige o refresh.**

### Placas duplicadas e placas vazias (achado de 2026-09-24, NÃO corrigido)

A limpeza expôs um problema que já existia e que o espaço vinha mascarando:

- **8 pares de placa duplicada** — mesma placa, dois `device_id`. São trocas de rastreador: o
  registro antigo ficou com o histórico e o novo continua rodando. Ex.: `RCG5B89` tem 5.767
  viagens até 05/06 num dispositivo e 6.646 até 23/09 noutro. Quatro desses pares
  (`C422102`, `RBO7D02`, `SCF8D32`, `SGZ6E17`) **já estavam duplicados sem espaço nenhum**.
- **25 veículos com placa VAZIA**, vários deles caminhões ativos com milhares de viagens.

**Placas duplicadas — resolvido na view `vw_placa_resolvida` (2026-09-24).** A regra, definida
pelo usuário:

| Situação | Tratamento |
|---|---|
| **Troca de rastreador** (os dois `device_id` têm viagem) | o device **atual** mantém a placa limpa; o **antigo** recebe o sufixo **` -OFF`** |
| **Linha fantasma** (o outro lado tem zero viagem) | a linha é **descartada** da view — a placa volta a ter uma linha só |

Exemplo: `RCG5B89` (device atual, 6.646 viagens) e `RCG5B89 -OFF` (o que saiu, 5.767 viagens).
Assim o histórico do rastreador antigo continua disponível e visivelmente marcado como
desativado, sem competir com o veículo em operação num filtro do Power BI. Se algum dia houver
três ou mais devices na mesma placa, o terceiro em diante vira ` -OFF 2`, ` -OFF 3` — só para
não voltar a duplicar; hoje são todos pares.

A ordenação é `tem_viagem DESC, ultimo_contato DESC`, conferida nos 8 pares. O `EXISTS` sobre
`tb_viagens` só roda para as placas duplicadas (16 linhas), via `ix_viagens_device` — a view
inteira custa 0,01s. Nenhum fato se perde: os descartados têm zero viagem e zero abastecimento.

**A tabela também é corrigida (2026-09-24).** O sufixo ` -OFF` é gravado em `tb_cadastro` e
`tb_status` pela função `resolver_placas_duplicadas()`, chamada **logo depois de cada upsert**
no `geotab_supabase.py`. Isso é obrigatório e não opcional: o upsert traz a placa crua da API e
desfaz o sufixo, então sem o passo seguinte a tabela voltaria a ter duplicadas todo dia — com as
views certas e a tabela errada.

A função **não duplica a lógica**: ela lê a `vw_placa_resolvida` e aplica o resultado. A regra
mora num lugar só.

> **A view precisa ser imune ao próprio sufixo.** Como a tabela agora pode conter
> `RCG5B89 -OFF`, a `vw_placa_resolvida` deixaria de enxergar o par como duplicado e **pararia de
> ocultar as linhas fantasma**. Por isso ela normaliza o valor antes de agrupar
> (`regexp_replace(..., '\s*-OFF( \d+)?$', '')`). Efeito colateral bom: a view dá o mesmo
> resultado com a tabela crua ou já resolvida, e o `UPDATE` é idempotente — a segunda passada
> altera zero linhas.

**Diferença entre a tabela e as views:** na tabela as 4 linhas fantasma ficam **visíveis e
marcadas** com ` -OFF` (não dá para "sumir" com um registro de dispositivo sem apagá-lo); nas
views elas continuam **ocultas**, unificando a placa numa linha só. A única duplicidade que
resta na tabela é a **placa vazia** (25 linhas), que se resolve preenchendo o `licensePlate` no
Geotab.

> **Ao mudar a regra da placa, dois lugares escapam — confira os dois.**
> **(1)** A `vw_saneago_comportamento` é materializada e continua servindo o valor antigo até o
> `REFRESH`. O sync diário já refresca ao fim do modo `comportamento`, mas uma mudança feita
> fora do ciclo exige o refresh manual.
> **(2)** `vw_saneago_status` e `vw_semad_status` liam `s.placa` direto da `tb_status`, e não
> `c.placa` da view de cadastro — ficavam de fora da regra. Corrigido em 2026-09-24. **Qualquer
> view nova que exponha placa deve tirá-la da view de cadastro**, nunca da tabela.
>
> Para conferir de uma vez: varra `information_schema.columns` por views com coluna `placa` e
> teste se alguma ainda mostra a placa sem sufixo para os pares conhecidos.

**Placas vazias — lista para corrigir no Geotab.** São 25 veículos, e a boa notícia é que a
placa **existe, no campo errado**: está no *nome* do veículo (`TGE7H14 | VOLKSWAGEN | 26.260`),
enquanto o `licensePlate` ficou em branco. A lista com a placa já extraída está em
`veiculos_sem_placa_2026-09-24.csv` — 23 com placa clara, 1 a revisar (`TGG 4A94`, com espaço no
meio) e 1 sem placa alguma no nome. A correção é preencher o `licensePlate` no Geotab; o sync
passa a trazer sozinho.

---

### Onde ficam os arquivos gerados (2026-09-24)

| Pasta | Conteúdo | Versionada? |
|---|---|---|
| `exports/` | CSVs publicados para clientes externos, gerados pelo `exportar_csv.py` | não |
| `diagnosticos/` | CSVs de levantamento pontual (validações, listas para correção de cadastro) | não |

> **Nunca guarde nada em `exports/` que você queira conservar.** O `exportar_csv.py` **esvazia a
> pasta inteira** no início de cada execução (`for f in OUT.glob("*"): f.unlink()`), e ela roda
> todo dia útil. Pior: uma **subpasta** ali dentro faz o export **quebrar**, porque `unlink()`
> falha em diretório. Foi por isso que os CSVs de diagnóstico ganharam pasta própria em vez de
> irem para dentro da `exports/`.

---

## 12. Decisões importantes (resumo)

- **Local em vez de nuvem:** resolve IP bloqueado (WAF Geotab), limite de disco e custo.
- **Timestamps sem timezone, em horário de Brasília** (Brasil sem horário de verão desde 2019).
- **Uma tabela/view por tema** — rodar tudo junto estoura a RAM e mistura janelas temporais.
- **User-Agent de navegador** nas chamadas Geotab (evita bloqueio Cloudflare).
- **Piso temporal no ano corrente** — banco não guarda histórico anterior a 01/jan.
- **`tb_viagens` enxuta** — texto repetido (placa/grupo) vem por JOIN de `tb_cadastro`.

Para o histórico detalhado por sessão e decisões com data, ver `.claude/context.md`.

---

## 14. Migração para o Google Cloud SQL (EM ANDAMENTO — 2026-09-22)

Projeto de mover o banco da máquina local para o **Cloud SQL** da empresa.

**Onde fica:** projeto `gcp-db-sian-citizen-dev` → instância `sian-citizen-postgres-dev`
(Postgres **16**, região `southamerica-east1`, `db-custom-1-3840`, disco 30 GB).
Connection name: `gcp-db-sian-citizen-dev:southamerica-east1:sian-citizen-postgres-dev`.

**Desenho escolhido:** as tabelas do Geotab NÃO ganham um banco próprio — elas vivem no
schema **`geotab`** dentro do banco **`maas_man`** (o banco do sistema de manutenção da MAAS,
que já existia na instância). Motivo: a conta `ygor.kouzak@maasservicos.com.br` tem apenas
leitura no IAM do projeto (não pode criar banco), mas é **dona do schema `geotab`** — e criar
schema/tabela é SQL puro, fora do alcance do IAM.

**Como o código endereça o schema:** `SUPABASE_SCHEMA=geotab` no `.env`. O `criar_engine()`
traduz isso em `options=-c search_path=geotab` na conexão, então todo `CREATE TABLE`,
`CREATE VIEW` e `to_sql` sem qualificação cai no schema certo. **Nenhuma linha de SQL do
projeto precisou de prefixo** — nem o `geotab_supabase.py`, nem as 13 views do `views.sql`.
Com a chave vazia, o comportamento local (schema `public`) fica intacto.

**Conexão validada (2026-09-22):** a T.I. liberou o IP de saída da máquina
(`200.195.234.205/32`, entrada "Maas") nas redes autorizadas da instância, e a conexão do PC
foi testada de ponta a ponta com `testar_cloudsql.py` — TCP, autenticação e sessão, todos OK.
Servidor real: **PostgreSQL 16.14**. O usuário `ygor.kouzak` é `BUILT_IN` (senha nativa do
Postgres, não é login por conta Google). A senha fica no `.env` em `GCP_SENHA`, num bloco
`GCP_*` separado das chaves `SUPABASE_*` — assim o teste do Cloud SQL nunca interfere no
sync local em produção.

> **Diagnóstico de conexão:** `python testar_cloudsql.py`. Ele separa os três estágios
> (TCP → autenticação → sessão), o que distingue bloqueio de rede de erro de credencial.
> Um *timeout* na autenticação significa IP fora da whitelist; um `password authentication
> failed` significa que a rede está OK e só a senha está errada.

**O que o `geotab_supabase.py` NÃO cria (descoberto no ensaio de 2026-09-22):** montar o
schema do zero revelou que o script cria apenas as **11 tabelas** de dados. Tudo o mais nasceu
em scripts de migração avulsos ao longo dos meses e precisa ser aplicado à parte:

| Objeto | Quantidade | Arquivo | Quem depende |
|---|---|---|---|
| Tabelas auxiliares (exceções/de-para) | 5 | `migracao_gcp_tabelas_auxiliares_2026-09-22.sql` | as 13 views e as funções |
| Funções SQL customizadas | 22 | `migracao_gcp_funcoes_2026-09-22.sql` | o SQL do sync e as 13 views |

> **Armadilha do `pg_get_functiondef()`:** ele devolve o corpo da função com o schema de
> origem embutido (`public.tb_grupo_token_ignorado`). Copiado assim para o Cloud SQL, isso
> faria as funções lerem o schema `public` do `maas_man` — o do sistema de manutenção — em vez
> do `geotab`. No melhor caso quebra; no pior, lê a tabela errada em silêncio. O arquivo gerado
> **remove o prefixo `public.`** de todas as 38 ocorrências, deixando a resolução por conta do
> `search_path`. As 27 referências distintas foram conferidas uma a uma: todas são objetos do
> próprio projeto.

**Ordem de montagem do schema do zero:** (1) `python geotab_supabase.py cadastro` cria as 11
tabelas; (2) `migracao_gcp_tabelas_auxiliares_...sql`; (3) `migracao_gcp_funcoes_...sql`;
(4) os demais modos do sync; (5) `views.sql`. O passo 3 antes do 4 não é opcional — o SQL que
monta `tb_odometro_mensal` chama `marca_padrao()`, `modelo_padrao()` e `arrumar_grupos()`.

**Carga dos dados: `copiar_para_cloudsql.py`.** O DDL já existe na nuvem, então falta só
dado — e dado em CSV não tem acoplamento de versão, o que contorna o Postgres 18 local vs 16
do Cloud SQL sem `pg_dump`. O script faz `COPY ... TO STDOUT` da origem alimentar direto o
`COPY ... FROM STDIN` do destino através de um `os.pipe()`, com memória constante (necessário
para os 6 milhões de linhas da `tb_viagens`). É idempotente: tabela cuja contagem já bate dos
dois lados é pulada, então uma queda no meio não obriga a refazer tudo.

> ⚠️ **A armadilha mais perigosa da migração — ordem das colunas.** Sem lista explícita de
> colunas, o `COPY` casa origem e destino **por posição**. As tabelas do local evoluíram por
> `ALTER TABLE ADD COLUMN` (coluna nova vai para o fim); as da nuvem nasceram na ordem atual
> do DDL. Resultado: em `tb_viagens`, a posição 8 alinhava `hodometro_final` (local) com
> `distancia_km` (nuvem) — **mesmos tipos, nenhum erro, dado errado gravado em silêncio**.
> Três tabelas tinham esse desalinhamento: `tb_viagens`, `tb_motoristas` e `tb_odometro_mensal`.
> O script hoje monta a lista de colunas comuns explicitamente e avisa sobre as que só existem
> de um lado. **Nunca copiar entre estes dois bancos sem lista de colunas.**

**Defeito pré-existente corrigido (2026-09-22): `tb_status.viagem_fim`.** A coluna foi criada
por um script de migração avulso e nunca entrou no `criar_tabelas()`. Como o `views.sql` a usa
(`vw_saneago_status`), qualquer instalação nova do projeto quebrava na criação das views —
defeito que existia antes desta migração e só apareceu ao montar um schema do zero. O
`criar_tabelas()` agora cria a coluna e roda um `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
idempotente para instalações existentes.

**Estado do ensaio (2026-09-22):** schema `geotab` com **16 tabelas, 22 funções e 13 views**,
carregado por completo. A `tb_viagens` levou 4min32s para 6.058.858 linhas. A integridade foi
provada comparando o `md5` de todos os ids nos dois bancos (com `ORDER BY id COLLATE "C"`).
**12 das 13 views devolvem contagem idêntica** à do banco local.

> **Collation diferente, e não dá para ajustar.** O banco local usa `Portuguese_Brazil.1252` e
> o `maas_man` usa `en_US.UTF8` — e como não podemos criar banco próprio, isso fica como está.
> O efeito prático é `ORDER BY` em texto ordenando diferente. O impacto é baixo porque o
> `views.sql` quase não usa `ORDER BY` (decisão de performance já tomada no projeto).

> **`views.sql` agora é agnóstico de schema.** Ele criava 19 funções explicitamente como
> `public.xxx`. Aplicado na nuvem, isso as criaria no `public` do `maas_man` — poluindo o schema
> do sistema de manutenção e deixando as views do Geotab apontando para lá. As 35 ocorrências de
> `public.` foram removidas; o `search_path` passa a decidir, e o arquivo serve aos dois
> destinos sem alteração (no local ele resolve para `public` como sempre).

> **Depois de qualquer `COPY` em massa, rodar `ANALYZE`.** Sem estatísticas o planejador escolhe
> planos ruins e as views ficam lentas sem motivo aparente.

**⛔ Item em aberto — `vw_saneago_comportamento` não roda no Cloud SQL.** Passa de 300s na nuvem
contra 103s no local. O gargalo são as funções `arrumar_grupos()` e `nivel_grupo()` chamadas por
linha, e a instância tem **1 vCPU** (`db-custom-1-3840`) contra a máquina local. Detalhe
revelador: no local, um `LIMIT 200` leva os **mesmos 103s** do `count(*)` — há agregação
bloqueante, então a view é calculada inteira antes de devolver a primeira linha. Caminhos:
(a) pedir um tier maior à T.I.; (b) otimizar a view e as funções; (c) transformá-la em
`MATERIALIZED VIEW` refrescada pelo sync — este último ajudaria também o banco local, onde 103s
já é um tempo ruim para o Power BI.

**As 12 views do SEMAD no Cloud SQL (2026-09-23) — `migracao_gcp_views_semad_2026-09-23.sql`.**
Elas não estão no `views.sql`: vivem nos arquivos `migracao_semad_*.sql`. O arquivo novo foi
gerado extraindo o **estado atual** das views do banco local (`pg_get_viewdef`), e não
replicando a cadeia histórica de migrações — porque o script de 2026-08-27 contém o `INSERT` do
token obsoleto `'OPE_SEMAD - 035/2026'` em `tb_contrato_semad`, que entraria ao lado dos dois
corretos. É a mesma técnica usada para trazer as 22 funções. O schema `geotab` tem agora
**25 views**, o mesmo total do banco local.

> **Comparar local × nuvem: separe dimensão de fato.** Na validação, as 9 views de dimensão
> (cadastro, status, grupos) bateram exato, e as 3 de fato (viagens, abastecimento,
> comportamento) divergiram — porque o sync local roda todo dia útil às 08:00 e a nuvem é um
> retrato do dia da carga. Diferença nas views de fato com dimensões iguais é **defasagem de
> snapshot, não erro**. Para comparar de verdade, carregue os dois no mesmo dia ou compare
> filtrando até uma data de corte comum.

**Conferir local × nuvem: `validar_local_x_cloud.py`.** Compara em três camadas — estrutura
(tabelas, colunas, tipos, funções, views), contagem por tabela e conteúdo linha a linha. Quando
o conteúdo difere, ele disseca e informa **quais colunas** divergem, que é o que separa "dado
atualizado depois da carga" de "cópia corrompida".

> **Duas armadilhas que produzem falso positivo** (o script já as evita, mas se você comparar à
> mão, atenção): **(1)** `md5(linha::text)` serializa na **ordem das colunas**, e quatro tabelas
> têm ordem diferente nos dois bancos — isso acusou 800 de 800 linhas divergentes na
> `tb_viagens` com dado perfeitamente idêntico. Monte a linha com `ROW()` sobre as colunas em
> ordem alfabética. **(2)** `ORDER BY` sem `COLLATE "C"` muda o md5 agregado por causa das
> collations diferentes, sem que o dado tenha mudado.

**Como ler o resultado.** Divergência de **estrutura** é sempre defeito. Divergência de
**conteúdo** precisa ser lida por coluna:

| Sintoma | Significado |
|---|---|
| Só `atualizado_em` difere | Nenhum dado de negócio mudou; o sync recarimba toda linha a cada execução. |
| `tb_status` difere em latitude, velocidade, ignição... | Normal — é tabela de tempo real. Se **não** mudasse, aí sim seria suspeito. |
| Tabela de fato com mais linhas no local | Defasagem de snapshot; o sync roda todo dia útil às 08:00. |
| Linha na nuvem **ausente** no local | Aí sim é problema — investigar. |

### `vw_saneago_comportamento` materializada (2026-09-23)

A view custava **103s no banco local** e **não rodava no Cloud SQL** (passava de 300s numa
instância de 1 vCPU). O gargalo são `arrumar_grupos()` e `nivel_grupo()` chamadas por linha, e
há agregação bloqueante — um `LIMIT 200` custava os mesmos 103s, porque a view é calculada
inteira antes de devolver a primeira linha. Como ela está na lista do `exportar_csv.py`, depois
da virada para a nuvem seria um relatório que simplesmente não sai.

**Desenho:** a lógica pesada virou a `mv_saneago_comportamento`; a view `vw_saneago_comportamento`
virou uma casca (`SELECT * FROM mv_...`). **Nada a jusante mudou de nome** — Power BI,
`exportar_csv.py` e consultas manuais continuam chamando a view de sempre.

**A causa raiz não era volume — era o planejador.** A `vw_saneago_cadastro` tem apenas 1.061
linhas e é lida em 0,0s. Mas, inlineada dentro do `JOIN`, ela fazia o PostgreSQL reavaliar
`arrumar_grupos()`, `nivel_grupo()` e `marca_padrao()` **uma vez por linha de saída** — 139 mil
vezes em vez de 1.061. A correção é envolver a cadastro num `WITH cad AS MATERIALIZED (...)`,
que força o cálculo uma única vez. As linhas de saída são idênticas.

| | Antes | Depois |
|---|---|---|
| Corpo da consulta (local) | 121,1s | **4,4s** |
| `REFRESH` (local) | 135s | **7,0s** |
| `REFRESH` (Cloud SQL) | 720s | **8,9s** |
| Reconstrução da MV (Cloud SQL) | 383s | **5,2s** |
| Leitura da view | 103s / não rodava | **0,04s / 0,05s** |

> **Se uma consulta que junta com `vw_saneago_cadastro` estiver lenta, suspeite disto primeiro.**
> As views `vw_saneago_motoristas` (12-13s) e `vw_semad_motoristas` (5-15s) fazem o mesmo JOIN e
> não foram investigadas — provavelmente têm o mesmo problema e a mesma correção.

O `REFRESH MATERIALIZED VIEW CONCURRENTLY` roda ao final do modo `comportamento` do sync.
**Concurrently não bloqueia leitores**: durante o refresh, um leitor aberto respondeu em 0,009s,
lendo o retrato anterior. Isso exige o índice único em `(id, data)`, verificado: 139.694 linhas,
139.694 pares distintos.

> **Armadilha que isso revelou — funções e MATERIALIZED VIEW.** O PostgreSQL executa **tanto o
> `CREATE` quanto o `REFRESH`** de uma materialized view com **`search_path` restrito**
> (`pg_catalog, pg_temp`), por segurança. As funções do projeto são agnósticas de schema e
> resolvem as tabelas pelo `search_path`, então **quebram nos dois** — sintoma:
> `relação "tb_veiculo_correcao" não existe`, dentro de `marca_padrao`. A correção é um bloco
> `DO` no `views.sql` que roda `ALTER FUNCTION ... SET search_path = current_schema(), pg_temp`
> em todas as funções do schema; como usa `current_schema()`, o arquivo continua servindo ao
> `public` local e ao `geotab` da nuvem. **O mesmo vale para índices com expressão.**
>
> **A posição desse bloco no arquivo importa.** Ele fica depois das funções e **antes** da MV,
> porque `CREATE OR REPLACE FUNCTION` **descarta as cláusulas `SET`** — ou seja, toda reexecução
> do `views.sql` desfixa as 22 funções e precisa refixá-las antes de chegar na MV. Com o bloco no
> fim do arquivo, a criação da MV falhava em toda reexecução.

> **Ao alterar a lógica da view:** `CREATE MATERIALIZED VIEW IF NOT EXISTS` **não** substitui o
> corpo de uma MV existente. É preciso `DROP MATERIALIZED VIEW mv_saneago_comportamento CASCADE;`
> e rodar o `views.sql` de novo. Sem isso, a alteração passa despercebida.

### Varredura de performance das views (2026-09-23)

Depois de descobrir a causa raiz na `vw_saneago_comportamento`, as outras 24 views foram
medidas pelo mesmo critério. **Oito** tinham o mesmo problema e foram corrigidas; o resultado
de todas é idêntico ao anterior, conferido por contagem e por hash do conteúdo.

| View | Antes | Depois | Ganho |
|---|---:|---:|---:|
| `vw_saneago_relatorio_viagens` | 100,5s | 9,9s | 10x |
| `vw_saneago_motoristas` | 43,0s | 9,7s | 4,5x |
| `vw_semad_relatorio_viagens` | 28,4s | 2,1s | 13,5x |
| `vw_saneago_abastecimento` | 10,4s | 1,1s | 9,5x |
| `vw_saneago_veiculos_anual` | 4,8s | 1,5s | 3,1x |
| `vw_saneago_indicadores_mensal` | 2,0s | 0,3s | 6,0x |
| `vw_saneago_resumo_frota_mensal` | 2,0s | 0,3s | 5,8x |
| `vw_semad_comportamento` | 1,4s | 0,1s | 13,0x |

**Duas formas do mesmo problema.** Na maioria, a view de cadastro (1.061 linhas) era inlineada
no `JOIN` e as funções de grupo eram reavaliadas por linha de saída; a correção é envolvê-la num
`WITH cad AS MATERIALIZED (...)`. Na `vw_saneago_motoristas` não há JOIN com cadastro — as
funções são aplicadas direto na `tb_motoristas` (5.713 linhas) dentro de um JOIN que devolve
182 mil; ali a correção é pré-calcular `arrumar_grupos()` e `grupo_visivel()` numa CTE
`mot AS MATERIALIZED`.

> **Medir por `count(*)` engana — e enganou aqui.** Na `vw_saneago_relatorio_viagens`, o
> `count(*)` era **0,9s antes e 1,6s depois**: pela métrica errada, a correção "piorava" a view.
> Só medindo como o sistema realmente lê — um mês, todas as colunas, que é o que o
> `exportar_csv.py` faz — apareceu o quadro real: **100,5s → 9,9s**. O `count(*)` não precisa das
> colunas da cadastro, então o planejador as descarta e a medição não representa nada.

> **Nem toda view ganha.** `vw_saneago_motoristas_mensal` (1,2x), `vw_saneago_motoristas_anual`
> (0,9x), `vw_semad_motoristas` (1,1x) e `vw_semad_motoristas_anual` (0,7x) foram testadas e
> **não foram alteradas** — em duas delas a CTE deixaria a consulta mais lenta. Medir antes de
> aplicar vale também para não aplicar.

**Onde cada view mora** (não é tudo no `views.sql`): as 13 `vw_saneago_*` estão no `views.sql`;
as 12 `vw_semad_*` estão em `migracao_gcp_views_semad_2026-09-23.sql`.

**Pendência com a T.I.:** um **usuário de aplicação** para o sync diário — rodar com conta
pessoal é frágil (no dia em que a conta for desativada, a carga para). A convenção da
instância é `db_maas_man_user`, `db_sian_gg_user`, `urbi_gipe_user`, `maas_backend`; o pedido
coerente é um `db_geotab_user` com owner do schema `geotab`.

**Carga inicial:** NÃO usar `pg_dump`/`pg_restore` — o banco local é Postgres **18.4** e a
instância é **16**; dump de versão maior para servidor menor não é suportado. O caminho é
repopular pela própria API Geotab (`python geotab_supabase.py <modo>`), já que o piso de
dados é 2026. As views entram rodando o `views.sql` com o `search_path` no schema `geotab`.

---

## 13. Manutenção deste manual

Sempre que houver uma alteração relevante no projeto (novo arquivo, mudança de fluxo,
nova tabela/view, mudança de operação, novo gotcha), **atualize a seção correspondente
deste manual e a data de "Última atualização" no topo** — edição incremental, não
regeneração. Esta regra também está registrada em `claude.md`.
