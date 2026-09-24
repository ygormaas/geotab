# Score de Comportamento — medidas DAX (Power BI)

Metodologia: **Geotab Driver Safety Scorecard**, método **Event Count**.
Documentação: guia técnico v1.0 · Implementação no banco: `migracao_score_geotab_2026-09-09.sql`

Fonte: `vw_saneago_motoristas` (diária).

**É medida, não coluna calculada.** O score só fecha depois de somar o período:
eventos e km são agregados primeiro, e só então a fórmula é aplicada. Calculado
por dia, o km é baixo demais e a projeção por 1.000 km vira ruído.

Fórmula oficial (Geotab, white paper): `100 − (Event Rule Event Count × 1000) / Total Driving Distance`

Pesos = default oficial renormalizado sobre os 50% disponíveis (faltam Seatbelt 20% e Excessive Speeding 30%):

| Regra | Peso oficial | Peso aplicado |
|---|---:|---:|
| Excesso de Velocidade *(Speeding)* | 20% | **40%** |
| Aceleração Brusca *(Hard Acceleration)* | 10% | **20%** |
| Frenagem Brusca *(Harsh Braking)* | 10% | **20%** |
| Curva Brusca *(Harsh Cornering)* | 10% | **20%** |

## Parâmetro

```dax
Piso Km Score = 200
```

## Notas por regra

Publique as quatro no relatório ao lado do score — é nelas que está o acionável.

```dax
Nota Velocidade =
MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas[excessos_velocidade] ) * 1000, SUM ( vw_saneago_motoristas[km] ) ) ) )
```

```dax
Nota Aceleracao =
MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas[aceleracoes_bruscas] ) * 1000, SUM ( vw_saneago_motoristas[km] ) ) ) )
```

```dax
Nota Frenagem =
MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas[frenagens_bruscas] ) * 1000, SUM ( vw_saneago_motoristas[km] ) ) ) )
```

```dax
Nota Curva =
MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas[curvas_drasticas] ) * 1000, SUM ( vw_saneago_motoristas[km] ) ) ) )
```

## Score e faixa de risco

```dax
Score Geotab =
VAR KmPeriodo = SUM ( vw_saneago_motoristas[km] )
RETURN
    IF (
        KmPeriodo >= [Piso Km Score],
        ROUND (
              [Nota Velocidade] * 0.40
            + [Nota Aceleracao] * 0.20
            + [Nota Frenagem]   * 0.20
            + [Nota Curva]      * 0.20,
            1
        )
    )
```

```dax
Faixa de Risco Geotab =
VAR S = [Score Geotab]
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( S ), "Sem base (rodagem insuficiente)",
        S >= 90,       "Baixo risco",
        S >= 75,       "Risco leve",
        S >= 60,       "Risco médio",
                       "Alto risco"
    )
```

Cores da faixa: Baixo `#2F7D4F` · Leve `#BF9A1C` · Médio `#C44E14` · Alto `#8F2130` ·
Sem base `#7D8A97`. Não use formatação condicional "por regra": use as medidas de cor
abaixo (**Estilo de formato: Valor do campo**), que seguem exatamente os mesmos cortes
do `Score Geotab` e não precisam ser refeitas se a faixa mudar.

## Formatação condicional — fundo e fonte

```dax
Cor Fundo Score =
VAR S = [Score Geotab]
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( S ), "#7D8A97",   -- sem base (rodagem insuficiente)
        S >= 90,       "#2F7D4F",   -- verde
        S >= 75,       "#BF9A1C",   -- amarelo
        S >= 60,       "#C44E14",   -- laranja
                       "#8F2130"    -- vermelho
    )
```

```dax
Cor Fonte Score =
VAR S = [Score Geotab]
RETURN
    IF ( S >= 75 && S < 90, "#1F1A00", "#FFFFFF" )
```

Os quatro fundos são escuros o bastante para texto branco; só o amarelo (`#BF9A1C`)
exige fonte escura para manter contraste legível. O branco também cobre o "sem base"
(cinza) e o caso `S` em branco, porque a comparação com BLANK devolve falso.

### Como aplicar na coluna

No visual de tabela/matriz: **Formatar visual → Células → Aplicar configurações a: `<a coluna desejada>`**.

| Propriedade | Estilo de formato | Campo |
|---|---|---|
| Cor do plano de fundo | Valor do campo | `Cor Fundo Score` |
| Cor da fonte | Valor do campo | `Cor Fonte Score` |

A medida é avaliada por linha do visual, então o score é recalculado no grão da
linha (motorista, veículo, contrato). Colorir uma linha de **total** não faz sentido
aqui: o total agrega km e eventos antes de dividir e cai quase sempre em "alto risco".

### Quando o score já é coluna da view

A formatação "Valor do campo" só aceita **medida**, nunca coluna — mas a medida não
precisa recalcular nada: basta ler a coluna no contexto da linha. Troque a primeira
linha das duas medidas de cor por:

```dax
VAR S = SELECTEDVALUE ( vw_saneago_veiculos_anual[score_geotab] )
```

A coluna `score_geotab` existe nas views anuais e mensais; nas diárias ela se chama
`score_geotab_ano`.

- Na linha de **total** o `SELECTEDVALUE` devolve BLANK (há vários valores) e a célula
  sai cinza — comportamento correto, porque score de total não é média de linhas.
- Se o grão do visual repetir o mesmo veículo/motorista em várias linhas, o valor
  também não é único e vem BLANK: use `MAX ( ...[score_geotab] )` no lugar.

Sem DAX dá para usar **Estilo de formato: Regras** com campo base `score_geotab`
(resumo **Máximo**) e as 4 faixas na mão — mas as regras se repetem em cada visual e
em cada propriedade (fundo e fonte), e é por isso que a medida compensa.

### Grão mensal

Views: `vw_saneago_motoristas_mensal` e `vw_saneago_veiculos_mensal` — ambas já trazem
`score_geotab` e `faixa_risco_geotab`, com os mesmos nomes de coluna.

Para o `SELECTEDVALUE` funcionar, **cada célula precisa resolver um mês só**: `ano_mes`
no visual, ou segmentação de mês em seleção única. Com vários meses no mesmo grão vem
BLANK (célula cinza).

Para **período de vários meses** a coluna não serve — `MAX` ou média de meses dá número
errado, porque o score soma km e eventos antes de dividir. Use a medida sobre a view
mensal (nomes de coluna diferentes dos da view diária: `km_mes`, `excesso_velocidade`,
`aceleracao_brusca`, `frenagem_brusca`, `curva_drastica`):

```dax
Score Geotab Mensal =
VAR Km = SUM ( vw_saneago_motoristas_mensal[km_mes] )
VAR Vel = MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas_mensal[excesso_velocidade] ) * 1000, Km ) ) )
VAR Ace = MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas_mensal[aceleracao_brusca]  ) * 1000, Km ) ) )
VAR Fre = MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas_mensal[frenagem_brusca]    ) * 1000, Km ) ) )
VAR Cur = MIN ( 100, MAX ( 0, 100 - DIVIDE ( SUM ( vw_saneago_motoristas_mensal[curva_drastica]     ) * 1000, Km ) ) )
RETURN
    IF ( Km >= [Piso Km Score], ROUND ( Vel * 0.40 + Ace * 0.20 + Fre * 0.20 + Cur * 0.20, 1 ) )
```

As medidas de cor passam a usar `VAR S = [Score Geotab Mensal]` e deixam de depender
do grão do visual.

## Conferência

Filtrando 2026 e o motorista **M162183** (1.014 km), o painel deve mostrar:

| Medida | Valor |
|---|---:|
| Nota Velocidade | 0,0 |
| Nota Aceleracao | 75,3 |
| Nota Frenagem | 98,0 |
| Nota Curva | 49,7 |
| **Score Geotab** | **44,6** |
| Faixa de Risco Geotab | Alto risco |

Sem filtro de motorista, no ano de 2026: **Score Geotab = 37,0** (score agregado
da frota). Esse valor **não** é a média dos scores individuais — a medida soma km
e eventos da frota antes de calcular, que é o comportamento correto para um KPI.
A contagem por faixa da view é: Baixo 59 · Leve 205 · Médio 370 · Alto 1.600 ·
Sem base 583.

## ⚠️ `score_risco` não é este score

A `score_risco` está nas mesmas views diárias, é **ilimitada** e **maior = pior**
(`exc×3 + acel×2 + fren×2 + curva×1`). Valores acima de 100 são normais ali:
**10.483 linhas** da `vw_saneago_motoristas` passam de 100 e o **máximo é 613**.

Se um visual do painel mostrar "score" acima de 100, é essa coluna — não o
`score_geotab`, que é limitado a 100 por construção.

**Não publique as duas com o rótulo "score" no mesmo relatório.** Sugestão de
rótulos: `score_geotab_ano` → "Score de Segurança (0–100)"; `score_risco` →
"Eventos Ponderados", que é o que a coluna realmente é.

## Armadilhas

- `MIN(100, MAX(0, ...))` é obrigatório — a medida tem de garantir a escala 0–100
  sozinha. Sem o piso, 130 eventos em 1.000 km geram −30 numa regra e distorcem o
  total. Sem o teto, um km negativo (correção de odômetro na origem) inverteria o
  sinal da divisão e a nota passaria de 100.
- `DIVIDE` (não `/`) para não estourar com km = 0.
- **Score por veículo**: use a view pronta `vw_saneago_veiculos_anual`, que já traz
  `km_ano`, as quatro notas e o `score_geotab` por veículo. Não tente montá-lo a
  partir de `vw_saneago_comportamento`: os eventos estão lá, mas o km **não** —
  `odometro` ali é a **leitura acumulada** do dia, não a rodagem, e somar dá número
  absurdo.
- **As views diárias não têm coluna de score.** Ela existiu por algumas horas em
  09/09 e foi removida: os CTEs de agregação faziam a view levar 22 s para abrir, em
  vez de 0,1 s. Para score de período filtrado, é a medida DAX; para score fechado,
  são as views anuais.
- Não confundir com `score_risco` (soma ponderada de eventos, quanto **maior
  pior**, sem teto) nem com `score_seguranca` (média simples das quatro notas,
  sem pesos).
