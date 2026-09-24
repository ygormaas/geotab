# Score de Comportamento — como o cálculo funciona

Padrão Geotab (*Driver Safety Scorecard*) · nota **0 a 100**, quanto maior melhor
Frota SANEAGO · 2026-01-01 a 2026-09-09 · 2.817 motoristas · 9.081.890 km

---

## A conta, em 3 passos

```
1.  taxa   =  eventos × 1.000 ÷ km rodados
2.  nota   =  100 − taxa                      (mínimo 0)
3.  score  =  soma de (nota × peso) de cada regra
```

Nota **zero** quando a regra atinge **100 eventos por 1.000 km**. É a calibragem da Geotab.

## Por que dividir pelos km

| Motorista | Excessos | Km | Taxa /1.000 km | Nota |
|---|---:|---:|---:|---:|
| A | 30 | 1.000 | 30 | **70** |
| B | 120 | 4.000 | 30 | **70** |

O B cometeu 4× mais infrações e rodou 4× mais. Mesma nota. Quem roda mais não é punido por isso.

## As regras e os pesos

| Regra | Peso Geotab | Temos? | Peso nosso |
|---|---:|:---:|---:|
| Excesso de Velocidade | 20% | ✅ | **40%** |
| Aceleração Brusca | 10% | ✅ | **20%** |
| Frenagem Brusca | 10% | ✅ | **20%** |
| Curva Brusca | 10% | ✅ | **20%** |
| Velocidade Grave | 30% | ⚠️ vem junto com o excesso | — |
| Cinto de Segurança | 20% | ❌ sem regra/sensor | — |

Sem o cinto, os 100% foram redistribuídos entre as 4 regras que temos, na proporção original.

## As faixas

| 🟢 Baixo | 🟡 Leve | 🟠 Médio | 🔴 Alto |
|---|---|---|---|
| ≥ 90 | 75 – 90 | 60 – 75 | < 60 |

---

## O cálculo de um motorista real

**M162183** · 1.014 km em 2026

| Regra | Eventos | Taxa /1.000 km | Nota | Peso | Pontos |
|---|---:|---:|---:|---:|---:|
| Excesso de Velocidade | 124 | 122,3 | **0,0** | 40% | 0,00 |
| Aceleração Brusca | 25 | 24,7 | 75,3 | 20% | 15,06 |
| Frenagem Brusca | 2 | 2,0 | 98,0 | 20% | 19,60 |
| Curva Brusca | 51 | 50,3 | 49,7 | 20% | 9,94 |
| | | | | | **44,6** 🔴 |

Frenagem quase perfeita, aceleração aceitável, **velocidade zerada**. A conversa com esse motorista é sobre velocidade — não sobre direção agressiva.

É isso que o score ponderado entrega e o contador de eventos não: **onde** perdeu ponto.

---

## A frota hoje

**2.234 motoristas** com pelo menos 200 km no ano *(583 ficam sem base — ver Miúdos)*

| 🟢 Baixo | 🟡 Leve | 🟠 Médio | 🔴 Alto |
|---:|---:|---:|---:|
| 59 · 2,6% | 205 · 9,2% | 370 · 16,6% | **1.600 · 71,6%** |

Mediana **52,3**

**Score agregado da frota: 37,0**

| Regra | Taxa /1.000 km | Nota | Peso | Pontos |
|---|---:|---:|---:|---:|
| Excesso de Velocidade | 85,4 | 14,5 | 40% | 5,80 |
| Aceleração Brusca | 56,3 | 43,9 | 20% | 8,78 |
| Frenagem Brusca | 4,1 | 95,9 | 20% | 19,18 |
| Curva Brusca | 84,0 | 16,2 | 20% | 3,24 |
| | | | | **37,0** |

Um excesso de velocidade a cada **12 km** rodados. Uma curva brusca a cada 12 km.

---

## ⚠️ As regras não estão na mesma escala

Quantos dos 2.234 motoristas **zeraram** a nota de cada regra:

| Regra | Zeraram |
|---|---:|
| Excesso de Velocidade | **764** |
| Curva Brusca | 649 |
| Aceleração Brusca | 355 |
| **Frenagem Brusca** | **1** |

No ano: **762.528** curvas bruscas contra **37.466** frenagens — a curva é 20× mais frequente.

Frear forte e fazer curva rápido têm severidade parecida. Frequência 20× diferente não vem da direção, vem do **limiar de disparo** configurado no MyGeotab.

**Hoje o score mede duas coisas ao mesmo tempo: como a frota dirige e como as regras foram configuradas.**

---

## Decidir

### 1. Revisar os limiares no MyGeotab — pré-requisito
A que km/h acima da via o excesso dispara? Em que força G disparam frenagem e curva? Igualar. Sem isso, qualquer número publicado é contestável.

### 2. Qual escala usar enquanto isso

| | **A. Padrão Geotab** | **B. Calibrada na frota** |
|---|---|---|
| Nota 0 em | 100 eventos/1.000 km | ~2× a média da frota |
| Alto risco | 72% | 51% |
| Vai para cliente | ✅ padrão, auditável | ❌ métrica nossa |
| Prioriza ação | ⚠️ quase todos vermelhos | ✅ separa bem |

**Recomendação:** **A** em painel de cliente. **B** só como ranking interno, com nome próprio. Nos dois casos, exibir **as 4 notas por regra ao lado do score** — é ali que está o acionável.

### 3. Fechar lacunas de dado

| Lacuna | Ganho |
|---|---|
| Cinto de segurança | recupera 20% do score oficial |
| Duração dos eventos de velocidade | mede *quanto* acima, não só quantas vezes |
| Identificação de condutor | só 40–57% dos eventos têm motorista hoje |

---

## Miúdos

**Piso de 200 km** — abaixo disso o motorista fica "sem base", não com nota zero: 1 evento em 50 km projeta 20 eventos/1.000 km e derruba 20 pontos injustamente. Cobre 2.234 de 2.817 (79%).

**Não bate com a tela do MyGeotab** — faltam 2 das 6 regras e os pesos foram renormalizados. Se alguém abrir o relatório da Geotab ao vivo, os dois números estão certos medindo coisas diferentes.

**Não confundir com `score_risco`**, que já está nos painéis: é soma de eventos, quanto **maior pior**, sem teto. Não se comparam.

**Pesos são default editável** — a Geotab exporta o relatório em planilha e a tabela de pesos é alterada lá. Customizar é o uso previsto, não desvio do padrão.

**Onde está implementado** — banco: `migracao_score_geotab_2026-09-09.sql`. Power BI: `score_geotab_DAX.md` (medida, não coluna — o score só fecha depois de somar o período).

**Fonte** — [Driver Safety Scorecard, Geotab Support Center](https://support.geotab.com/help/mygeotab/reports/safety-reports/driver-safety-scorecard). A variante "excesso e cinto medidos por distância em infração" aparece em material de terceiros e **não** na documentação oficial — não citar como padrão.
