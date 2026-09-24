# Validação — migração de grupos SANEAGO (2026-09-02)

Tudo abaixo foi medido rodando a migração dentro de `BEGIN … ROLLBACK`.
**Nada foi alterado no banco.** Script: `migracao_grupos_nivel_por_codigo_2026-09-02.sql`.

## Resumo

| | valor |
|---|---|
| combos de grupo existentes (cadastro ∪ motoristas) | 2.115 |
| combos com mudança de **conteúdo** (sup/regional/lotação/outros) | **44** |
| combos com mudança de **texto da chave** (`todos_grupos` / `grupo_id`) | 1.303 |
| linhas em `vw_saneago_grupos` | 1.733 → **793** |
| hierarquias que absorvem duplicatas | 489 (1.429 linhas antigas viram 489) |
| veículos / motoristas nessas hierarquias | 967 / 3.140 |
| colisões de `grupo_id` | 0 |
| veículos ou motoristas órfãos da dimensão | 0 |
| códigos em mais de um nível | 21 → **0** |
| views do SEMAD | inalteradas (90 veículos, 1 grupo) |

Arquivos de apoio:
- `validacao_grupos_niveis_2026-09-02.csv` — toda mudança de conteúdo, com contagem de veículos/motoristas.
- `validacao_grupos_consolidacao_2026-09-02.csv` — os 793 grupos finais e quantas linhas antigas cada um absorve.

---

## 1. Ganhos — nível que passa a aparecer (era vazio)

### Regional recuperada (20 casos)

| código / nome | veíc. | motor. |
|---|---|---|
| G0180 - Ger.Reg.De Negocios-Sumeg | 1 | 0 |
| G8310 - Gerencia De Apoio Administrativo | 1 | 0 |
| G0155 - Ger.Reg.Serv.Palmeiras Goias | 1 | 0 |
| G0087 - Gerencia De Faturamento | 1 | 0 |
| G0301 - Ger. Sistemas De Esgoto | 0 | 2 |
| G8313 - Gerência De Gestão E Fiscalização De Contratos II | 0 | 2 |
| G0079 - Ger. De Apoio À Conservação De Mananciais | 0 | 2 |
| G0161 - Ger.A. Tec Des. Operacional | 0 | 2 |
| G8314 - Gerência De Gestão E Fiscalização De Contratos III | 0 | 1 |
| G0106 - Ger. De Atendimento Ao Cliente | 0 | 1 |
| G8312 - Gerência De Gestão E Fiscalização De Contratos I | 0 | 1 |
| G0184 - Gerencia De Negocios-Norte | 0 | 1 |
| G0390 - Ger. De Planejamento Estratégico E Monitoramento | 0 | 1 |
| G0069 - Ger.Suporte Trat.Esgotos | 0 | 1 |
| G8315 - Gerência De Apoio Técnico | 0 | 1 |
| G0077 - Gerência De Licenciamento Ambiental | 0 | 1 |
| G8327 - Ger. De Gestao, Fisc. E Mon. De Contr. Da Operacao | 0 | 1 |
| G0182 - Gerencia De Negocios-Leste | 0 | 1 |
| G0392 - Ger. De Proj. Estrat. E Parcerias Público-Privadas | 0 | 1 |
| G0376 - Gerencia De Controladoria Juridica | 0 | 1 |

### Superintendência recuperada (4 casos)

| código / nome | veíc. | motor. | por quê |
|---|---|---|---|
| D2000 - Presidência | 1 | 3 | token `PRE _ D2000` estava em "outros" |
| S0090 - Super. De Atend. Ao Cliente | 0 | 1 | vinha só como `ULOT_S0090` (a ressalva documentada em 2026-08-26) |
| S0086 - Superintendencia De Meio Ambiente E Recursos Hidr. | 0 | 1 | idem `ULOT_S0086` |
| S0060 - Super. Reg. Oper. Entorno Df | 0 | 1 | preenchida via `tb_hierarquia_grupo` a partir da regional |

### Lotação recuperada (6 casos)

| código / nome | veíc. | motor. |
|---|---|---|
| V3175 - Supervisao De Apoio Na Administracao De Recursos | 1 | 7 |
| USE26 - Un. De Serv. Esp. Corp. - Grs S.L.M.Belos | 1 | 0 |
| V2047 - Sup. De Gestao Eletrom. Do Df. | 0 | 6 |
| V2030 - Super Prog Cont Trafego Viagem | 0 | 1 |
| T0269 - Distrito-Bonfinopolis | 0 | 1 |
| USE17 - Un. De Serv. Esp. De Expansão - Grs Formosa | 0 | 1 |

---

## 2. Perdas reais — código que some de todas as colunas

Total: **3 veículos e 7 motoristas**. Em todos os casos o combo tem **dois ou mais
tokens do mesmo nível** e só um cabe na coluna — isso já acontecia antes, só que a
escolha era não-determinística (`LIMIT 1` sem `ORDER BY`); agora ela é fixa. O texto
cru continua em `todos_grupos` e `todos_grupos_original`.

| some | veíc. | motor. | motivo |
|---|---|---|---|
| PRE _ D2000 - PRESIDENCIA (como "outros") | 2 | 2 | virou superintendência em 2 dos 3 combos; no 3º perde para `SUP_S0062` |
| G0301 - Ger. Sistemas De Esgoto | 1 | 0 | combo tem `REG_G0301` **e** `REG_G0300`; fica G0300 |
| D6000 - Diretoria De Producao. | 0 | 1 | combo tem `SUP_S0085` **e** `REG_D6000` (ambos nível superintendência); fica S0085 |
| G8327 - Ger. De Gestao, Fisc. E Mon. De Contr. Da Operacao | 0 | 1 | combo com 4 tokens `REG_`; fica G0124 |
| V0137 - Supervisao De Macromedicao E Pitometria | 0 | 1 | combo com 9 tokens `ULOT_`; fica V0129 |
| V2047 - Sup. De Gestão Eletrom. Do Df. | 0 | 1 | vira lotação; a regional passa a ser G0301 |
| V0129 - Supervisao De Oficina Eletrica E Eletronica | 0 | 1 | combo com 4 tokens `ULOT_`; fica V0126 |
| RESERVA \| ULOT \| REG \| SUP (como "outros") | 0 | 1 | só reordenação do campo "outros"; nada sumiu |

Se algum desses desempates estiver errado, dá para fixar caso a caso em
`tb_grupo_nivel_excecao` sem mexer na lógica.

## 3. Trocas de rótulo (mesmo nível, outro token)

| nível | antes | depois | veíc. | motor. |
|---|---|---|---|---|
| regional | G0301 - Ger. Sistemas De Esgoto | G0300 - Ger. Sistemas De Agua | 1 | 0 |
| regional | V2047 - Sup. De Gestão Eletrom. Do Df. | G0301 - Ger. Sistemas De Esgoto | 0 | 1 |
| regional | G8327 - Ger. De Gestao, Fisc. E Mon. | G0124 - Gerencia De Oficina De Eletromecanica | 0 | 1 |
| lotação | V0137 - Supervisao De Macromedicao E Pitometria | V0129 - Supervisao De Oficina Eletrica E Eletronica | 0 | 1 |
| lotação | V0129 - Supervisao De Oficina Eletrica E Eletronica | V0126 - Supervisão De Fibra De Vidro | 0 | 1 |

## 4. Exceções de nível cadastradas (`tb_grupo_nivel_excecao`)

| código | nível forçado | motivo |
|---|---|---|
| T8000 | reg | "Ger. Neg. Desev. M. Operac. Sist. Aguas Lindas" — código T (distrito) mas é gerência; fica acima de G8100/V810x sob a SUP S0060 |
| G8100 | ulot | "Gerencia Tecnica Do SAA - Sist. Aguas Lindas" — código G mas sempre aparece como lotação |

---

## 5. Consolidação (a mudança de maior impacto)

Distribuição dos 793 grupos finais por quantas linhas antigas cada um absorve:

| linhas antes | grupos finais |
|---|---|
| 1 (nada mudou) | 304 |
| 2 | 200 |
| 3 | 165 |
| 4 | 87 |
| 5 | 36 |
| 6 | 1 |

Exemplos (lista completa no CSV de consolidação):

| grupo unificado | linhas antes | veíc. | motor. |
|---|---|---|---|
| SUP_S0069 \| REG_G0140 \| ULOT_V0231 (GYN*) | 6 | 0 | 50 |
| SUP_S0020 \| REG_G8310 \| ULOT_G8310 | 5 | 35 | 5 |
| SUP_S0072 \| REG_G0032 \| ULOT_G0032 | 5 | 23 | 15 |
| SUP_S0069 \| REG_G0140 \| ULOT_V0231 | 5 | 22 | 1 |
| SUP_S0069 \| REG_G0182 \| ULOT_V0180 | 5 | 18 | 0 |
| SUP_S0069 \| REG_G0184 \| ULOT_V0005 | 5 | 16 | 0 |
| SUP_S0071 \| REG_G0153 \| ULOT_V0140 | 5 | 16 | 40 |
| SUP_S0062 \| REG_G0333 \| ULOT_V2030 | 5 | 14 | 6 |
| SUP_S0060 \| REG_G0149 \| ULOT_T0113 | 5 | 11 | 5 |

---

## 6. O que muda para o Power BI

- `todos_grupos` e `grupo_id` mudam de valor em 1.303 dos 2.115 combos (mesma unidade,
  texto/hash novo). **Fato e dimensão mudam juntos**, então os relacionamentos seguem
  válidos — mas filtros/bookmarks salvos que citam o texto antigo precisam ser refeitos.
- Filtro/slicer de grupo passa de 1.733 para 793 itens, sem repetição.
- `DISTINCTCOUNT` de grupo deixa de ser inflado (~2,2×).
- O `index.html` / CSVs públicos mudam no próximo export.
- Nenhuma coluna é adicionada ou removida em nenhuma das 10 views.
