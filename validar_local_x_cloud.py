"""Compara o Postgres LOCAL com o Cloud SQL em tres camadas.

  1. ESTRUTURA  tabelas, colunas (nome+tipo) e, a parte, a POSICAO das colunas.
                Divergencia de nome/tipo e SEMPRE defeito; divergencia so de
                posicao e benigna para a copia (que usa lista explicita), mas
                muda a ordem de um SELECT *.
  2. CONTAGEM   linhas por tabela. Divergencia em tabela de FATO costuma ser
                defasagem de snapshot (o sync local roda todo dia util 08:00).
  3. CONTEUDO   compara o conteudo linha a linha e, quando difere, diz QUAIS
                COLUNAS divergem -- que e o que separa "dado atualizado depois
                da carga" de "copia corrompida".

DOIS CUIDADOS QUE INVALIDAM A COMPARACAO SE ESQUECIDOS:

  a) NUNCA usar md5(linha::text): isso serializa na ORDEM das colunas, e as
     tabelas tem ordens diferentes nos dois bancos (o local cresceu por ALTER
     TABLE ADD COLUMN, a nuvem nasceu na ordem do DDL). Daria 100% de
     divergencia com dado identico. Aqui a linha e montada com ROW() sobre a
     lista de colunas em ordem ALFABETICA, igual dos dois lados.

  b) ORDER BY sempre com COLLATE "C": os bancos tem collations diferentes
     (Portuguese_Brazil.1252 x en_US.UTF8) e a ordem mudaria o md5 agregado
     sem o dado mudar.

Rodar: python validar_local_x_cloud.py
"""
import os
import psycopg2
from dotenv import load_dotenv

load_dotenv(r"C:\Users\ygor.kouzak\Downloads\ProjetosPy\geotab\.env")

LIMITE_CHECKSUM_TOTAL = 700_000   # acima disso, amostra em vez de tabela inteira
TAMANHO_AMOSTRA = 800
MAX_DIAGNOSTICO = 40              # linhas divergentes a dissecar coluna a coluna


def conectar(pfx, schema):
    c = psycopg2.connect(
        host=os.environ[pfx + "HOST"], port=os.environ[pfx + "PORTA"],
        dbname=os.environ[pfx + "BANCO"], user=os.environ[pfx + "USUARIO"],
        password=os.environ[pfx + "SENHA"],
        sslmode=os.environ.get(pfx + "SSLMODE", "require"),
        options="-c search_path=" + schema)
    c.set_session(autocommit=True)
    return c


def um(conn, sql, args=None):
    with conn.cursor() as cur:
        cur.execute("SET statement_timeout = 0")
        cur.execute(sql, args)
        return cur.fetchone()


def varios(conn, sql, args=None):
    with conn.cursor() as cur:
        cur.execute("SET statement_timeout = 0")
        cur.execute(sql, args)
        return cur.fetchall()


def titulo(t):
    print("\n" + "=" * 78)
    print(t)
    print("=" * 78)


def estrutura(loc, nuv, sl, sn):
    titulo("1. ESTRUTURA")
    problemas, posicionais = [], []

    q_tab = "SELECT tablename FROM pg_tables WHERE schemaname=%s ORDER BY 1"
    a = {r[0] for r in varios(loc, q_tab, (sl,)) if "_bkp_" not in r[0]}
    b = {r[0] for r in varios(nuv, q_tab, (sn,))}
    print("  tabelas         local=%-4d nuvem=%-4d" % (len(a), len(b)), end="  ")
    if a == b:
        print("identicas")
    else:
        print("DIVERGEM -> so local: %s | so nuvem: %s" % (sorted(a - b), sorted(b - a)))
        problemas.append("tabelas")

    q_col = ("SELECT table_name, ordinal_position, column_name, data_type "
             "FROM information_schema.columns WHERE table_schema=%s ORDER BY 1,2")
    comuns = a & b
    ca = [r for r in varios(loc, q_col, (sl,)) if r[0] in comuns]
    cb = [r for r in varios(nuv, q_col, (sn,)) if r[0] in comuns]
    conj_a = {(t, c, d) for t, _, c, d in ca}
    conj_b = {(t, c, d) for t, _, c, d in cb}
    pos_a = {(t, p, c) for t, p, c, _ in ca}
    pos_b = {(t, p, c) for t, p, c, _ in cb}
    print("  colunas         local=%-4d nuvem=%-4d" % (len(ca), len(cb)), end="  ")
    if conj_a != conj_b:
        print("DIVERGEM em NOME/TIPO (grave)")
        for x in sorted(conj_a ^ conj_b)[:12]:
            print("      %s: %s" % ("local" if x in conj_a else "nuvem", x))
        problemas.append("colunas")
    elif pos_a != pos_b:
        posicionais = sorted({t for t, _, _ in pos_a ^ pos_b})
        print("mesmos nomes e tipos; so a POSICAO difere em %d tabelas" % len(posicionais))
        print("      %s" % posicionais)
        print("      (benigno p/ a copia, que usa lista explicita de colunas;")
        print("       muda a ordem das colunas num SELECT *)")
    else:
        print("identicas (nome, tipo e posicao)")

    q_fn = ("SELECT proname||'('||pg_get_function_identity_arguments(p.oid)||')' "
            "FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=%s")
    q_vw = "SELECT viewname FROM pg_views WHERE schemaname=%s"
    for rot, q in (("funcoes", q_fn), ("views", q_vw)):
        x = {r[0] for r in varios(loc, q, (sl,))}
        y = {r[0] for r in varios(nuv, q, (sn,))}
        print("  %-15s local=%-4d nuvem=%-4d" % (rot, len(x), len(y)), end="  ")
        if x == y:
            print("identicas")
        else:
            print("DIVERGEM -> so local: %s | so nuvem: %s" % (sorted(x - y), sorted(y - x)))
            problemas.append(rot)
    return problemas, sorted(comuns), posicionais


def chave(conn, schema, tabela):
    r = varios(conn, """
        SELECT a.attname FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
        WHERE i.indisprimary AND n.nspname = %s AND c.relname = %s
        ORDER BY array_position(i.indkey, a.attnum)""", (schema, tabela))
    return [x[0] for x in r]


def colunas_alfabeticas(conn, schema, tabela):
    r = varios(conn, """SELECT column_name FROM information_schema.columns
                        WHERE table_schema=%s AND table_name=%s
                        ORDER BY column_name""", (schema, tabela))
    return [x[0] for x in r]


def expr_linha(cols):
    """Serializa a linha em ordem ALFABETICA -- imune a diferenca de posicao."""
    return "md5(ROW(%s)::text)" % ", ".join('"%s"' % c for c in cols)


def dados(loc, nuv, sl, sn, tabelas):
    titulo("2. CONTAGEM POR TABELA")
    print("  %-30s%12s%12s%12s" % ("TABELA", "LOCAL", "NUVEM", "DIFERENCA"))
    contagens = {}
    for t in tabelas:
        na = um(loc, 'SELECT count(*) FROM %s."%s"' % (sl, t))[0]
        nb = um(nuv, 'SELECT count(*) FROM %s."%s"' % (sn, t))[0]
        contagens[t] = (na, nb)
        d = na - nb
        print("  %-30s%12s%12s%12s" % (t, format(na, ","), format(nb, ","),
                                       ("+" + format(d, ",")) if d else "="))

    titulo("3. CONTEUDO  (linha serializada em ordem alfabetica de colunas)")
    veredito = {}
    for t in tabelas:
        na, nb = contagens[t]
        pk = chave(loc, sl, t)
        cols = colunas_alfabeticas(loc, sl, t)
        if not pk:
            print("  %-28s sem chave primaria -- pulado" % t)
            veredito[t] = ("sem PK", None)
            continue
        expr = expr_linha(cols)

        if na == nb and na <= LIMITE_CHECKSUM_TOTAL:
            ordem = ", ".join('"%s"::text COLLATE "C"' % c for c in pk)
            molde = ("SELECT md5(string_agg(%s, '' ORDER BY %s)) FROM {sch}.\"%s\" x"
                     % (expr, ordem, t))
            ha = um(loc, molde.format(sch=sl))[0]
            hb = um(nuv, molde.format(sch=sn))[0]
            if ha == hb:
                print("  %-28s checksum da tabela inteira: IDENTICO" % t)
                veredito[t] = ("identico", None)
                continue
            print("  %-28s checksum da tabela inteira: DIVERGENTE -- dissecando..." % t)

        # amostra da NUVEM conferida contra o LOCAL, pela chave primaria
        lista_pk = ", ".join('"%s"' % c for c in pk)
        frac = min(100.0, max(0.05, TAMANHO_AMOSTRA * 100.0 / max(nb, 1)))
        amostra = varios(nuv, 'SELECT %s, %s FROM %s."%s" x TABLESAMPLE SYSTEM (%s) LIMIT %d'
                         % (lista_pk, expr, sn, t, frac, TAMANHO_AMOSTRA))
        if not amostra:
            amostra = varios(nuv, 'SELECT %s, %s FROM %s."%s" x LIMIT %d'
                             % (lista_pk, expr, sn, t, TAMANHO_AMOSTRA))
        cond = " AND ".join('"%s" = %%s' % c for c in pk)
        confere = ausentes = 0
        divergentes = []
        for linha in amostra:
            chaves, h_nuv = linha[:-1], linha[-1]
            r = um(loc, 'SELECT %s FROM %s."%s" x WHERE %s' % (expr, sl, t, cond), chaves)
            if r is None:
                ausentes += 1
            elif r[0] == h_nuv:
                confere += 1
            else:
                divergentes.append(chaves)

        n = len(amostra)
        print("  %-28s amostra %4d -> iguais: %d | ausentes no local: %d | diferentes: %d"
              % (t, n, confere, ausentes, len(divergentes)))

        culpadas = {}
        for chaves in divergentes[:MAX_DIAGNOSTICO]:
            sel = ", ".join('"%s"::text' % c for c in cols)
            ra = um(loc, 'SELECT %s FROM %s."%s" WHERE %s' % (sel, sl, t, cond), chaves)
            rb = um(nuv, 'SELECT %s FROM %s."%s" WHERE %s' % (sel, sn, t, cond), chaves)
            if ra is None or rb is None:
                continue
            for nome, va, vb in zip(cols, ra, rb):
                if va != vb:
                    culpadas[nome] = culpadas.get(nome, 0) + 1
        if culpadas:
            ordenadas = sorted(culpadas.items(), key=lambda kv: -kv[1])
            print("       colunas que divergem (em %d linhas dissecadas): %s"
                  % (min(len(divergentes), MAX_DIAGNOSTICO),
                     ", ".join("%s(%d)" % (k, v) for k, v in ordenadas)))

        if ausentes == 0 and not divergentes:
            veredito[t] = ("amostra OK", None)
        elif ausentes == 0:
            veredito[t] = ("difere", set(culpadas))
        else:
            veredito[t] = ("AUSENTES NO LOCAL", set(culpadas))
    return contagens, veredito


def main():
    loc = conectar("SUPABASE_", "public")
    nuv = conectar("GCP_", "geotab")
    print("LOCAL : %s/%s (schema public)" % (os.environ["SUPABASE_HOST"], os.environ["SUPABASE_BANCO"]))
    print("NUVEM : %s/%s (schema geotab)" % (os.environ["GCP_HOST"], os.environ["GCP_BANCO"]))

    problemas, tabelas, posicionais = estrutura(loc, nuv, "public", "geotab")
    contagens, veredito = dados(loc, nuv, "public", "geotab", tabelas)

    titulo("VEREDITO")
    graves = [t for t, (v, _) in veredito.items() if v == "AUSENTES NO LOCAL"]
    difs = {t: c for t, (v, c) in veredito.items() if v == "difere"}
    atrasadas = [t for t in tabelas if contagens[t][0] != contagens[t][1]]

    if problemas:
        print("  [X] ESTRUTURA divergente em: %s" % problemas)
    else:
        print("  [OK] Estrutura: mesmas tabelas, colunas, tipos, funcoes e views.")
        if posicionais:
            print("       (ordem das colunas difere em %d tabelas -- ver secao 1)" % len(posicionais))

    if graves:
        print("  [X] Ha linhas na NUVEM que NAO existem no local: %s" % graves)
    else:
        print("  [OK] Nenhuma linha orfa: toda linha amostrada da nuvem existe no local.")

    if difs:
        print("  [!] Linhas com conteudo diferente (nuvem mais velha que o local):")
        for t, c in sorted(difs.items()):
            print("       %-28s colunas: %s" % (t, sorted(c) if c else "(nao dissecado)"))
    else:
        print("  [OK] Conteudo identico em todas as linhas comparadas.")

    if atrasadas:
        print("  [!] O local tem MAIS linhas em: %s" % atrasadas)
        print("      Esperado se o sync local rodou depois da carga.")
        print("      Fechar a defasagem com: python copiar_para_cloudsql.py")
    else:
        print("  [OK] Contagens iguais em todas as tabelas.")

    loc.close()
    nuv.close()
    return 1 if (problemas or graves) else 0


if __name__ == "__main__":
    raise SystemExit(main())
