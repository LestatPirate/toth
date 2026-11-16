#!/usr/bin/env python3
# Copyright © 2026 Alex Felizardo. Licença MIT: ver LICENSE.
"""Gera o site (GitHub Pages) a partir de scripts/site/index.src.html, que é bilingue:
  docs/index.html     inglês (raiz: o que os motores de busca indexam por omissão)
  docs/pt/index.html  português
No fonte, <span data-pt>…</span><span data-en>…</span> marcam os textos; <img|meta|link|title … data-pt|data-en> idem.
A versão vem de scripts/build-app.sh. Correr depois de publicar a release (o botão aponta para o zip dessa versão)."""
import re, pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "scripts/site/index.src.html").read_text()
version = re.search(r'VERSION="\$\{VERSION:-([0-9.]+)\}"', (root / "scripts/build-app.sh").read_text()).group(1)
SITE = "https://lestatpirate.github.io/toth/"
ZIP = f"https://github.com/LestatPirate/toth/releases/download/v{version}/Toth-{version}.zip"
# Só a raiz redireciona: quem prefere português (escolha guardada, ou navegador em português sem escolha) vai para /pt/.
REDIRECT = """(function(){var l=null;try{l=localStorage.getItem('toth-lang')}catch(e){}
if(l==='pt'||(!l&&(navigator.language||'').toLowerCase().indexOf('pt')===0)){location.replace('pt/'+location.hash)}})();"""

def build(lang):
    other = "en" if lang == "pt" else "pt"
    s = src
    # tira os elementos da outra língua
    def drop_span(m):
        assert "<span" not in m.group(1), "span dentro de span: " + m.group(0)[:80]
        return ""
    s = re.sub(rf"<span data-{other}>(.*?)</span>", drop_span, s, flags=re.S)
    s = re.sub(rf"<title data-{other}>.*?</title>\n?", "", s, flags=re.S)
    s = re.sub(rf"[ \t]*<(?:img|meta|link)\b[^>]*\sdata-{other}>\n?", "", s)
    # desembrulha os da língua pedida
    def keep_span(m):
        assert "<span" not in m.group(1), "span dentro de span: " + m.group(0)[:80]
        return m.group(1)
    s = re.sub(rf"<span data-{lang}>(.*?)</span>", keep_span, s, flags=re.S)
    s = s.replace(f" data-{lang}>", ">")
    assert "data-pt" not in s and "data-en" not in s, "marcas de língua por tratar"
    pt = lang == "pt"
    for k, v in {
        "LANG": lang, "VERSION": version, "ZIP": ZIP, "BASE": "../" if pt else "",
        "SELF": SITE + ("pt/" if pt else ""), "URL_EN": SITE, "URL_PT": SITE + "pt/",
        "HREF_PT": "./" if pt else "pt/", "HREF_EN": "../" if pt else "./",
        "ON_PT": "on" if pt else "", "ON_EN": "" if pt else "on",
        "REDIRECT": "" if pt else REDIRECT,
    }.items():
        s = s.replace("{{" + k + "}}", v)
    assert "{{" not in s, "marcador por substituir"
    out = root / ("docs/pt/index.html" if pt else "docs/index.html")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(s)
    print(f"{out.relative_to(root)}: {len(s)} bytes, versão {version}")

build("en"); build("pt")
