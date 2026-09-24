-- Remove o espaco em branco das bordas de placa/veiculo (2026-09-24).
--
-- ORIGEM: a Geotab devolve `licensePlate` (e `name`) com espaco nas bordas em
-- parte da frota -- 207 de 1.988 placas. O sync copiava como vinha.
--
-- POR QUE IMPORTA: os JOINs do projeto NAO sofrem (sao por device_id). Quem
-- sofre e o Power BI: "ABC1D23" e "ABC1D23 " sao valores DISTINTOS -- aparecem
-- duas vezes num filtro, quebram relacionamento por placa e fazem um veiculo
-- "sumir" de um visual mesmo estando no banco.
--
-- ONDE ESTAVA (varredura das 73 colunas de texto das tb_*):
--   tb_cadastro.placa ......... 207    tb_cadastro.veiculo ......... 13
--   tb_status.placa ........... 207
--   tb_odometro_mensal.placa .. 3.726  tb_odometro_mensal.veiculo .. 450
-- Nenhuma coluna de CHAVE (id, device_id) foi afetada.
--
-- A correcao na ORIGEM esta no geotab_supabase.py (.strip() nos 3 pontos de
-- escrita + btrim no SQL de tb_odometro_mensal). Este arquivo limpa o passivo.
--
-- IDEMPOTENTE: rodar de novo nao faz nada (o WHERE so pega o que esta sujo).

UPDATE tb_cadastro
   SET placa = btrim(placa), veiculo = btrim(veiculo)
 WHERE placa <> btrim(placa) OR veiculo <> btrim(veiculo);

UPDATE tb_status
   SET placa = btrim(placa)
 WHERE placa <> btrim(placa);

UPDATE tb_odometro_mensal
   SET placa = btrim(placa), veiculo = btrim(veiculo)
 WHERE placa <> btrim(placa) OR veiculo <> btrim(veiculo);
