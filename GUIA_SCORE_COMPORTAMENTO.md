# Guia do Score de Comportamento — SANEAGO / MAAS

> Adaptação do *Driver Safety Scorecard* da Geotab à base que realmente temos.
> Mesma lógica do guia oficial (0–100, eventos normalizados por distância, notas
> ponderadas, faixas de risco) — com os ajustes que os nossos dados exigem.
>
> Última atualização: 2026-09-09 · Janela dos números: **2026-01-01 → 2026-09-09**
> Fonte: `vw_saneago_motoristas_anual` (2.817 motoristas, 9.081.890 km)

---

## 1. Por que não dá para usar a fórmula do guia direto

O guia da Geotab assume `Nota = 100 − (eventos × 1.000 / km)`, ou seja: **cada
evento a mais por 1.000 km custa 1 ponto**. Isso pressupõe uma frota que gera
poucos eventos por 1.000 km.

A nossa não gera. Taxas reais da frota inteira:

| Regra | Eventos / 1.000 km | Nota pela fórmula crua |
|---|---:|---:|
| Excesso de Velocidade | **85,4** | 14,6 |
| Curva Brusca | **84,0** | 16,0 |
| Aceleração Brusca | **56,3** | 43,7 |
| Frenagem Brusca | **4,1** | 95,9 |

Aplicando a fórmula crua nos 2.234 motoristas com ≥ 200 km:

| Faixa | Motoristas | % |
|---|---:|---:|
| Baixo risco (≥90) | 74 | 3% |
| Risco leve (75–90) | 228 | 10% |
| Risco médio (60–75) | 315 | 14% |
| **Alto risco (<60)** | **1.617** | **72%** |

Mediana: **39,4**. Um score em que 72% da frota é vermelho não separa ninguém de
ninguém — não serve para gestão. O problema não é a lógica da Geotab, é a
**escala**: ela foi calibrada para outra ordem de grandeza de evento.

> **Achado importante:** a Frenagem Brusca é **20× mais rara** que a Curva Brusca
> (37.466 vs 762.528 eventos). Regras de severidade parecida não deveriam ter
> essa distância. Indica **limiares desalinhados entre as regras no MyGeotab** —
> ver seção 9.

---

## 2. O que a nossa base entrega: 4 das 6 regras

| Regra do guia | Peso original | Temos? | Observação |
|---|---:|---|---|
| Aceleração Brusca | 10% | ✅ | `aceleracao_brusca` |
| Frenagem Brusca | 10% | ✅ | `frenagem_brusca` |
| Curva Brusca | 10% | ✅ | `curva_drastica` |
| Excesso de Velocidade | 20% | ⚠️ | temos **contagem**, o guia usa **distância** em excesso |
| Velocidade Grave | 30% | ⚠️ | cai no **mesmo bucket** de excesso — sem regra separada |
| Cinto de Segurança | 20% | ❌ | nenhuma regra/sensor capturado |

Origem: `geotab_supabase.py:1094-1135` — `_identificar_regras()` resolve 4 tipos.
As regras de velocidade (`RuleSpeedingId`, `RulePostedSpeedingId` e qualquer
regra com "excesso velocidade" no nome) são somadas em **um** bucket.

---

## 3. Regras e pesos NOSSOS

Sem o cinto, os 100% do guia precisam ser redistribuídos. Como o nosso excesso
de velocidade é uma **contagem** (proxy fraco, e altíssima — 1 evento a cada
12 km), dar a ele os 50% do guia faria o score virar só um índice de velocidade.
Pesos adotados:

| Regra | Peso | Racional |
|---|---:|---|
| Excesso de Velocidade | **40%** | 20% do guia renormalizado sobre as 4 regras (20/50) |
| Aceleração Brusca | **20%** | 10/50 |
| Frenagem Brusca | **20%** | 10/50 |
| Curva Brusca | **20%** | 10/50 |

*(Alternativa: se considerarmos que a Velocidade Grave já está dentro do nosso
bucket de excesso, os pesos ficam 62,5 / 12,5 / 12,5 / 12,5. Testado — piora a
separação: 62% em alto risco em vez de 51%.)*

---

## 4. A matemática

### 4.1 Meta por regra (a mudança central)

Em vez do "−1 ponto por evento/1.000 km" implícito, cada regra tem uma **meta
explícita**: a taxa por 1.000 km na qual a nota chega a zero. Definida como
**≈ 2× a média atual da frota**, arredondada:

| Regra | Média da frota /1.000 km | **Meta (nota 0)** |
|---|---:|---:|
| Excesso de Velocidade | 85,4 | **170** |
| Aceleração Brusca | 56,3 | **115** |
| Frenagem Brusca | 4,1 | **8** |
| Curva Brusca | 84,0 | **170** |

Leitura: *quem roda na média da frota tira ~50 na regra; quem faz o dobro da
média tira 0; quem não tem evento tira 100.*

### 4.2 Nota de cada regra

```
taxa       = eventos × 1.000 / km_do_periodo
nota_regra = 100 − 100 × (taxa / meta_da_regra)      [piso 0, teto 100]
```

O **piso em zero é obrigatório** — sem ele, um motorista com 3× a meta puxa a
nota para −200 e zera o score inteiro (o guia não menciona isso).

### 4.3 Score final

```
score = nota_excesso    × 0,40
      + nota_aceleracao × 0,20
      + nota_frenagem   × 0,20
      + nota_curva      × 0,20
```

### 4.4 Piso de quilometragem: 200 km

Abaixo disso o score é **NULL / "sem base"**, não zero. Motivo: normalizar por
1.000 km com pouca rodagem amplifica o ruído — 1 evento em 50 km projeta 20
eventos/1.000 km. Impacto: dos 2.817 motoristas, **2.234 (79%) têm base**; 583
ficam sem score no ano.

Distribuição de rodagem no ano: mediana 1.409 km · média 3.224 km ·
≥ 500 km: 1.918 · ≥ 1.000 km: 1.575.

---

## 5. Classificação de risco

Faixas do guia, com as bordas fechadas (o original sobrepõe 90, 75 e 60):

| Faixa | Score | Cor |
|---|---|---|
| Baixo risco | ≥ 90 | `#2E7D32` |
| Risco leve | 75 – 89,9 | `#FBC02D` |
| Risco médio | 60 – 74,9 | `#EF6C00` |
| Alto risco | < 60 | `#C62828` |
| Sem base | km < 200 | `#9E9E9E` |

---

## 6. Exemplo prático (motorista real da frota)

Motorista **M162183**, ano de 2026, **1.014 km** rodados — quase os mesmos
1.000 km do exemplo do guia, o que deixa a comparação direta.

**Passo 1 — dados brutos**

| | Eventos | Taxa /1.000 km |
|---|---:|---:|
| Excesso de Velocidade | 124 | 122,3 |
| Aceleração Brusca | 25 | 24,7 |
| Frenagem Brusca | 2 | 2,0 |
| Curva Brusca | 51 | 50,3 |

**Passo 2 — nota de cada regra**

| Regra | Cálculo | Nota |
|---|---|---:|
| Excesso | 100 − 100 × (122,3 / 170) | **28,0** |
| Aceleração | 100 − 100 × (24,7 / 115) | **78,6** |
| Frenagem | 100 − 100 × (2,0 / 8) | **75,3** |
| Curva | 100 − 100 × (50,3 / 170) | **70,4** |

**Passo 3 — pesos**

| Regra | Nota | Peso | Pontos |
|---|---:|---:|---:|
| Excesso de Velocidade | 28,0 | 40% | 11,20 |
| Aceleração Brusca | 78,6 | 20% | 15,72 |
| Frenagem Brusca | 75,3 | 20% | 15,06 |
| Curva Brusca | 70,4 | 20% | 14,08 |
| **SCORE TOTAL** | | | **56,1** |

**Veredito:** 56,1 → **Alto risco**. Diferente do "Carlos" do guia, aqui o
diagnóstico é cirúrgico: aceleração, frenagem e curva estão em faixa aceitável
(70–79); o score foi derrubado **só pela velocidade** (nota 28, com 40% do peso).
A conversa com esse motorista é sobre velocidade, não sobre direção agressiva.

Esse é o ganho real do score ponderado sobre o `score_risco` antigo: ele diz
**onde** perdeu ponto, não só que perdeu.

---

## 7. A realidade da frota com este score

2.234 motoristas com base (≥ 200 km):

| Faixa | Motoristas | % |
|---|---:|---:|
| Baixo risco | 96 | 4% |
| Risco leve | 333 | 15% |
| Risco médio | 655 | 29% |
| **Alto risco** | **1.150** | **51%** |

Mediana: **59,5** — a frota inteira está na fronteira Médio/Alto.

Melhora muito em relação aos 72% da fórmula crua, mas **metade da frota segue em
alto risco**. Isso não é defeito do score: é o retrato de 85 excessos de
velocidade por 1.000 km. Duas leituras possíveis, e as duas precisam ser
checadas antes de o número ir para um contrato ou uma avaliação de pessoas:

1. **A frota realmente dirige assim** (trânsito urbano, agenda apertada) → o
   score está certo e é a linha de base de um programa de melhoria.
2. **As regras estão sensíveis demais no MyGeotab** (ex.: excesso disparando a
   +1 km/h da via) → o número está inflado e as metas precisam ser refeitas
   depois de corrigir o limiar. A discrepância de 20× entre frenagem e curva
   (seção 1) é evidência forte disso.

---

## 8. Onde o score fica implementado

### 8.1 Banco (recorte anual fixo)

Funções em `public` + 2 colunas em `vw_saneago_motoristas_anual`:

```sql
-- nota 0-100 de uma regra, normalizada por 1.000 km contra a meta
CREATE OR REPLACE FUNCTION public.nota_regra_geotab(
    p_qtd bigint, p_km numeric, p_meta numeric
) RETURNS numeric AS $func$
    SELECT LEAST(100::numeric, GREATEST(0::numeric,
        100::numeric - 100::numeric * (COALESCE(p_qtd,0)::numeric * 1000.0
                                       / NULLIF(p_km,0)) / p_meta))
$func$ LANGUAGE sql IMMUTABLE;

-- score ponderado 0-100; NULL abaixo do piso de km
CREATE OR REPLACE FUNCTION public.score_geotab(
    p_km numeric, p_excesso bigint, p_acel bigint, p_fren bigint, p_curva bigint,
    p_piso_km numeric DEFAULT 200
) RETURNS numeric AS $func$
    SELECT CASE WHEN COALESCE(p_km,0) >= p_piso_km THEN round(
          nota_regra_geotab(p_excesso, p_km, 170) * 0.40
        + nota_regra_geotab(p_acel,    p_km, 115) * 0.20
        + nota_regra_geotab(p_fren,    p_km,   8) * 0.20
        + nota_regra_geotab(p_curva,   p_km, 170) * 0.20
    , 1) END
$func$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.faixa_risco_geotab(p_score numeric)
RETURNS text AS $func$
    SELECT CASE
        WHEN p_score IS NULL THEN 'Sem base (km insuficiente)'
        WHEN p_score >= 90   THEN 'Baixo risco'
        WHEN p_score >= 75   THEN 'Risco leve'
        WHEN p_score >= 60   THEN 'Risco medio'
        ELSE                      'Alto risco'
    END
$func$ LANGUAGE sql IMMUTABLE;
```

Migração: `migracao_score_geotab_2026-09-09.sql` — apende `score_geotab` e
`faixa_risco_geotab` via `CREATE OR REPLACE VIEW`, **sem `DROP CASCADE`** (que já
derrubou uma view dependente uma vez).

### 8.2 Power BI (qualquer período filtrado)

O score **tem que** ser calculado depois de agregar o período — por dia o km é
baixo e a normalização por 1.000 km vira ruído. Por isso é **medida**, nunca
coluna calculada. DAX completo em `score_geotab_DAX.md`, sobre
`vw_saneago_motoristas` (diária).

### 8.3 Não confundir com os scores que já existem

| Coluna | O que é | Direção |
|---|---|---|
| `score_risco` | soma ponderada de eventos (exc×3 + acel×2 + fren×2 + curva×1) | maior = **pior**, sem teto |
| `score_seguranca` | média **simples** das 4 notas por 1.000 km (fórmula crua) | maior = melhor, sem pesos |
| **`score_geotab`** | **este documento** — meta por regra + pesos + piso de km | maior = melhor, 0–100 |

---

## 9. Limitações e caminho para o padrão pleno

| Lacuna | Efeito | Como fechar |
|---|---|---|
| Sem Cinto de Segurança (20% do guia) | 1/5 do score oficial ausente | depende de sensor/regra de cinto na Geotab — verificar se a frota tem |
| Excesso por contagem, não por distância | não distingue "5 km a 5 km/h acima" de "50 km a 40 acima" | `ExceptionEvent` traz `activeFrom`/`activeTo`; hoje só usamos `activeFrom` (`geotab_supabase.py:1301`). Capturar a duração permite estimar a distância em excesso |
| Velocidade Grave junto com o excesso comum | perde a distinção 20% vs 30% do guia | conferir no log do sync quais regras de velocidade a base devolve; se houver uma separada, criar 5º bucket em `_identificar_regras()` |
| Limiares das regras desalinhados | infla as taxas e joga a frota para vermelho | revisar as regras no MyGeotab (frenagem 20× mais rara que curva) |
| Metas fixas em literais | não acompanham a frota | revisar anualmente; recalcular como 2× a média e rearredondar |
| Só 40–57% dos eventos têm motorista identificado | o score por motorista cobre parte da operação | identificação de condutor (NFC/chave) na frota |

**Ordem de prioridade:** revisar os limiares no MyGeotab **antes** de publicar o
score em painel de cliente. Enquanto os limiares estiverem desalinhados, o score
mede tanto a configuração quanto a direção.
