# Formato de ficheiro da Toth: ideias

Requisito crítico: qualquer elemento inserido (seta, texto, forma…) tem de poder ser removido/editado depois, a qualquer momento, mesmo após fechar e reabrir o ficheiro. Ou seja: edição **não destrutiva**.

## Princípio
Nunca "queimar" anotações na imagem. O ficheiro guarda: imagem original intacta + lista de objetos vetoriais + metadados. O render final é gerado só na exportação (PNG/JPG/PDF).

## Opção A (recomendada): pacote ZIP `.capture` com JSON
```
doc.capture (zip)
├── manifest.json     versão do formato, id, datas, dimensões
├── document.json     camadas e objetos (modelo abaixo)
├── assets/original.png   captura original, imutável
├── assets/<uuid>.png     imagens inseridas pelo utilizador
└── preview.png           miniatura para QuickLook/biblioteca
```
- Legível, versionável, fácil de migrar entre versões; igual em macOS e Windows.
- Implementado: um **ficheiro ZIP único** `.capture` (ver README). As capturas antigas em pasta continuam a abrir.

## Opção B: SQLite (um ficheiro)
Tabelas objects/assets/history. Bom para bibliotecas grandes e consultas; menos transparente e mais difícil de diffar.

## Opção C: SVG + imagem base
Aberto e standard, mas mal cobre efeitos (desfocar, realce, numeração automática) e perde metadados editáveis.

## Modelo do objeto (document.json)
```json
{ "formatVersion": 1,
  "canvas": {"width":1920,"height":1080,"base":"assets/original.png"},
  "objects": [
    {"id":"uuid","type":"arrow","z":3,"visible":true,
     "geometry":{"from":[10,10],"to":[200,80]},
     "style":{"color":"#FF3B30","width":4,"shadow":true}}
  ]}
```
- IDs estáveis (UUID), ordem por `z`, tudo em coordenadas da imagem original (independente de resolução).
- Tipos: arrow, line, rect, ellipse, text, stamp, step, highlight, blur/redact, crop (como parâmetro, não corte destrutivo).

## Garantir "remover elemento inserido antes"
1. Objetos separados com ID: remover = apagar da lista.
2. Histórico de comandos (undo/redo) em memória durante a sessão. Opcional: guardar o histórico no ficheiro.
3. Efeitos como blur e crop guardados como parâmetros sobre o original, reversíveis.
4. Original em `assets/original.png` nunca é modificado.
5. Testes: abrir → remover objeto → guardar → reabrir → render igual ao esperado.

## Windows no futuro
- Formato e modelo definidos acima são neutros. Núcleo portável (parse/serialização/render vetorial) em Rust ou C++ com UI nativa por plataforma, ou UI única (Tauri/Qt) numa 2.ª fase.
- Decisão adiável: começar em Swift puro é mais rápido, mas obriga a reescrever a lógica no Windows. Núcleo em Rust desde já custa mais ao início e poupa depois.
