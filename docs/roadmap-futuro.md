# Ideias para versões futuras

Ideias ainda por implementar (exceto onde indicado). Todas devem continuar 100% locais, sem nuvem e sem dependências com licença incómoda (ver THIRD_PARTY_NOTICES.md). Contribuições são bem-vindas (ver README).

## 1. Captura por rolagem — FEITA
O utilizador rola a janela (qualquer sentido, com idas e voltas, Pausar/Retomar) e o Toth junta as capturas. Ver `docs/DEVELOPMENT.md`.

## 2. Ferramenta Reparo (remover um elemento e preencher com o que o rodeia)
- Nível 1: clonar/carimbo com pincel macio. Nível 2: preenchimento por vizinhança (PatchMatch próprio), bom em fundos de interface, fraco em fotografia. Nível 3 (IA): modelo de inpainting em CoreML local — **só depois de ler e aprovar a licença do modelo**; aumenta muito o tamanho da app.
- Camada não destrutiva (guarda a máscara; recalcula), como Blur/Pixelização.
- Esforço: pequeno a médio (níveis 1–2).

## 3. Captura e edição de vídeo (MP4)
- Gravar a região em MP4 (ScreenCaptureKit + AVAssetWriter, H.264/HEVC + AAC do sistema), com áudio do PC e microfone opcionais (permissão de microfone). Opção «Vídeo» na barra de captura depois de delimitar a área.
- Editor com linha de tempo: cortar/dividir (AVMutableComposition), anotações com **início e fim** (barras na linha de tempo; desenhadas na exportação com o `Renderer` via compositor próprio), redimensionar em píxeis com ou sem proporção (esticar ou ajustar com margens), retirar áudio, importar áudio, narração gravada por cima.
- Riscos: tamanho do trabalho (a maior funcionalidade), áudio do sistema com DRM, desempenho em 4K, `.capture` com vídeo (guardar como ficheiro dentro do pacote), patentes H.264/HEVC (baixo risco por usar o codificador do sistema; confirmar).
- Fases: (1) gravar + ver + exportar; (2) linha de tempo, cortar, redimensionar; (3) anotações com tempos; (4) áudio.

## Ordem sugerida
Reparo básico → rolagem vertical (depois horizontal) → vídeo fase 1–4 → Reparo por IA (se a licença do modelo for aprovada).
