# Solicitação — hospedar o sincronizador Geotab na infraestrutura oficial

**Solicitante:** Ygor Kouzak — ygor.kouzak@maasservicos.com.br
**Data:** 24/09/2026

---

## 1. O pedido, em uma frase

Tirar de uma estação de trabalho um processo Python que alimenta diariamente a base de
telemetria da frota (Geotab) e acomodá-lo na infraestrutura oficial da empresa — **no padrão
que vocês julgarem adequado**.

Não estamos pedindo uma tecnologia específica: descrevemos abaixo o que o processo faz e do
que ele precisa, para que vocês indiquem onde isso melhor se encaixa.

---

## 2. Como funciona hoje

O sincronizador é um **script Python único**, sem interface web e sem estado em disco entre
execuções. Ele roda numa **estação de trabalho Windows**, disparado pelo Agendador de Tarefas
do Windows, de segunda a sexta às 08:00.

O ciclo é sempre o mesmo:

1. Autentica na API da Geotab (HTTPS, JSON-RPC).
2. Extrai cinco blocos de dados — cadastro de veículos, status, comportamento de condução,
   viagens e abastecimentos.
3. Grava tudo num banco PostgreSQL.
4. No fim, gera arquivos CSV de relatórios.

Cada bloco roda em subprocesso isolado: se um falha, os outros continuam, e o dia é marcado
como pendente para nova tentativa. O volume atual é de cerca de **3,4 GB**, sendo a maior
tabela a de viagens, com **6 milhões de registros**.

**O banco já está na infraestrutura de vocês.** Foi migrado para o Cloud SQL
(`sian-citizen-postgres-dev`, banco `maas_man`, schema `geotab`): 17 tabelas, 23 funções e
26 views. A migração foi validada comparando estrutura e conteúdo entre a base antiga e a
nova, registro a registro, por hash MD5.

Falta mover apenas o **processo de extração**.

---

## 3. Por que queremos sair da estação de trabalho

Não é uma limitação técnica do processo — ele funciona. É uma questão de onde ele mora:

- **Depende de a máquina estar ligada** e de o usuário ter feito logon. Máquina desligada
  ou em viagem significa relatório desatualizado.
- **É frágil por construção:** o banco local roda numa janela de terminal, e fechá-la derruba
  a sincronização. Já aconteceu.
- **Exige manter um IP externo liberado** na whitelist do Cloud SQL, e esse IP muda quando a
  rede de saída muda.
- **Não há alerta de falha** nem redundância: se o processo quebra de madrugada, só se
  descobre quando alguém abre o relatório.
- **Está fora de qualquer inventário de vocês** — sem backup padronizado, sem monitoramento,
  sem registro formal.

Queremos que esse processo passe a ser um ativo gerenciado, dentro das regras e das
ferramentas que a empresa já usa.

---

## 4. O que o processo precisa

| Necessidade | Detalhe |
|---|---|
| Ambiente de execução | Python 3.12+, processo único, sem paralelismo |
| Agendamento | seg–sex, 08:00 (America/Sao_Paulo) |
| Duração | ~14 min por execução (medição abaixo) |
| CPU / memória | estimamos 1 vCPU e 2 GB — a confirmar na primeira execução |
| Saída para a internet | HTTPS (443) para `my.geotab.com` |
| Acesso ao banco | Cloud SQL `sian-citizen-postgres-dev`, `southamerica-east1` |
| Segredos | credenciais da API Geotab e do banco |
| Persistência | nenhuma — não guarda arquivo entre execuções |

**Um ganho de segurança que vale destacar:** se o processo rodar dentro da mesma rede do
banco, ele passa a acessá-lo pelo **IP privado** e **deixa de ser necessário manter IPs
externos liberados** na whitelist da instância — hoje há uma entrada aberta apenas para dar
acesso a essa estação de trabalho.

**Sobre segredos:** hoje ficam num arquivo local de configuração. Pedimos orientação sobre o
mecanismo padrão de vocês (cofre de segredos, variáveis gerenciadas etc.) para nos adequarmos.

---

## 5. Perfil de execução (medido em 24/09/2026)

| Fase | Duração |
|---|---|
| cadastro | 9 s |
| status | 41 s |
| comportamento | 3 min 33 s |
| viagens | 8 min 19 s |
| abastecimento | 4 s |
| **Total** | **~14 min** |

Há uma etapa final de exportação de CSVs (~9 min) que publica relatórios para clientes
externos. Ela pode ficar fora desta migração, se preferirem tratá-la à parte.

**Validação já feita:** confirmamos que a API da Geotab responde e autentica normalmente a
partir de um ambiente do Google Cloud. Ressalva honesta — o teste cobre autenticação e
chamadas simples; uma execução completa faz milhares de sub-chamadas (com limitador próprio
de 4.500 a cada 60 s). Sugerimos tratar a primeira semana como período de observação.

---

## 6. O repositório

| | |
|---|---|
| **URL** | `https://github.com/centraldeinteligenciamaas/geotab` |
| **Organização** | `centraldeinteligenciamaas` (GitHub, privado) |
| **Branch principal** | `main` — 76 commits |
| **Linguagem** | Python (hoje rodando em 3.14; compatível com 3.12+) |
| **Tamanho** | ~11.700 linhas entre Python e SQL, 37 arquivos versionados |
| **Dependências** | `requirements.txt` fixado por versão |

**Arquivos que importam para a execução:**

| Arquivo | Papel |
|---|---|
| `atualizar_local.py` | **Ponto de entrada.** Orquestra os cinco blocos em subprocessos isolados e controla a trava de execução diária |
| `geotab_supabase.py` | Núcleo: extração da API Geotab, criação/migração de tabelas e gravação no Postgres |
| `exportar_csv.py` | Etapa final opcional — gera os CSVs de relatório |
| `views.sql` | Definição das views e funções do banco (idempotente) |
| `requirements.txt` | Dependências fixadas |
| `MANUAL.md` | Documentação operacional, incluindo diagnóstico de falhas |
| `.env` | Configuração e segredos — **não versionado** (está no `.gitignore`) |

**Dependências de terceiros** (todas com versão fixada; nenhuma exige compilação):

```
pandas 3.0.2 · SQLAlchemy 2.0.49 · psycopg2-binary 2.9.12
requests 2.33.1 · python-dotenv 1.2.2 · numpy 2.4.4
```

**Pontos de atenção para o empacotamento:**

- **Não há `Dockerfile` hoje.** O projeto nunca foi containerizado; podemos criar um assim que
  soubermos o padrão de vocês (imagem base, registro de imagens, pipeline).
- **Toda a configuração vem do arquivo `.env`**, lido em tempo de execução. Ele não está no
  repositório. Adaptamos para o mecanismo de segredos que vocês indicarem.
- **Há três arquivos `.bat`** (`iniciar_postgres.bat`, `backup_geotab.bat`, `psql_geotab.bat`)
  que só fazem sentido no ambiente Windows atual e não vão para a hospedagem.
- **O código não tem dependência de Windows.** Usa apenas biblioteca padrão e os pacotes acima;
  roda em Linux sem alteração.
- **Acesso ao repositório:** podemos conceder leitura à conta ou ao grupo que vocês indicarem,
  ou transferir o repositório para a organização de vocês, se for o padrão.

---

## 7. Pedido adicional: usuário de aplicação no banco

Hoje a sincronização autentica no Cloud SQL com a **conta pessoal** `ygor.kouzak`. Se essa
conta for desativada ou tiver a senha rotacionada, a carga diária para em silêncio, de
madrugada.

Solicitamos a criação de um usuário de aplicação, seguindo a convenção que a instância já
adota (`db_maas_man_user`, `db_sian_gg_user`, `urbi_gipe_user`, `maas_backend`):

- **Usuário:** `db_geotab_user`
- **Permissões:** owner do schema `geotab` do banco `maas_man` — o processo cria e altera
  tabelas, funções e views **apenas dentro desse schema**
- **Sem acesso** ao schema `public` nem aos demais bancos da instância

---

## 8. Pontos que gostaríamos de alinhar

Nenhum destes bloqueia a solicitação; levantamos porque afetam o serviço no médio prazo.

**a) A instância é de desenvolvimento.** `sian-citizen-postgres-dev` é `ZONAL` (sem alta
disponibilidade) e está no canal de manutenção `canary`, com reinícios às segundas ~01:00.
Como esses dados alimentam relatórios entregues a clientes, faz sentido avaliar uma instância
de produção.

**b) *Point-in-time recovery* está desligado.** A recuperação possível hoje é o backup diário
das 02:00 — uma perda de dados às 14:00 significa voltar 12 horas.

**c) Backups em outra região.** Estão configurados em `us`, enquanto a instância está em
`southamerica-east1`. Gostaríamos de confirmar se é intencional.

**d) Carga na instância compartilhada.** A instância tem 1 vCPU e hospeda 6 bancos de outros
sistemas. Nossa carga diária é modesta — a etapa mais pesada consome cerca de 9 s de CPU no
banco —, mas achamos correto declarar isso antecipadamente.

---

## 9. O que entregamos

- Acesso ao repositório (seção 6) e empacotamento no formato que vocês indicarem.
- Documentação operacional completa (`MANUAL.md`), incluindo diagnóstico de falhas.
- Acompanhamento da primeira semana de execução.

Ficamos à disposição para adequar o desenho ao padrão de vocês — inclusive para refazê-lo em
outra tecnologia, se a infraestrutura oficial for outra.
