# Guia do Toth · Toth guide

[Português](#português) · [English](#english)

## Português

### Funcionalidades

**Captura**
- **Região com o ecrã congelado** ao carregar no atalho: a captura é a do momento do atalho, mesmo que o ecrã mude depois. Arraste para escolher a área, **mova-a e redimensione-a** pelas alças, e só ao **confirmar** (botão *Capturar* ou **Enter**) segue para o editor. **Esc** cancela. Funciona com vários monitores.
- **Captura com rolagem:** depois de escolher a área, clique em **Rolagem** (ao lado de *Cancelar* e *Capturar*). A partir daí **role a janela como quiser**, para qualquer lado (cima, baixo, esquerda, direita), devagar ou depressa, e pode voltar atrás e passar outra vez pela mesma zona: o Toth percebe sozinho o movimento e vai juntando tudo. Só termina quando clicar em **Concluir** na barra flutuante (ou **Cancelar** para descartar). **Pausar/Retomar** deixa-o parar a captura e continuar depois, a partir de qualquer zona já capturada (o Toth guarda várias capturas recentes para voltar a alinhar). Se no fim não conseguir juntar nada, oferece **Tentar de novo**. O Toth não mexe na janela por si e não precisa de nenhuma permissão além da gravação de ecrã. Cabeçalhos e rodapés fixos aparecem uma só vez. Limites: imagens até cerca de 30 000 px de lado; role um eixo de cada vez (na diagonal não alinha); se rolar depressa demais a barra avisa e basta voltar um pouco atrás; conteúdo animado, vídeos ou páginas que carregam enquanto rola podem deixar emendas.
- **Gravação de vídeo (MP4):** depois de escolher a área, clique no ícone de **vídeo**. Uma barra só com ícones permite **gravar**, **pausar e retomar** e **parar** (o vídeo abre logo no editor). O **áudio do sistema** e o **microfone** podem ser ligados ou desligados a qualquer momento. O ficheiro é um MP4 normal (H.264 e AAC) em `~/Pictures/Capture`.

**Editor de vídeo**
- **Três linhas** (vídeo, áudio do sistema, microfone), cada fonte na sua faixa. Cada clipe é um **bloco inteiro**: clique para o marcar e arraste para o mover. O bloco entra na junção mais próxima e o resto desloca-se, **sem partir nem apagar** o que lá está (⌥ ao largar pousa-o livremente por cima).
- **Marcar um trecho** (⇧+arrastar, ou as teclas I/O, ou arrastar num espaço): o leitor mostra o **ponto exato** da ponta (com o número do quadro) e as setas afinam-no quadro a quadro. Depois: **cortar e juntar**, **cortar deixando um espaço** (sem vídeo e sem som), **copiar**, **colar** (inserindo ou por cima) e **inverter**.
- **Quebra** (tecla B, ícone, ou botão direito): divide o clipe em dois blocos sem cortar nada.
- **Por linha:** a marcação, o corte, a cópia e o movimento aplicam-se só à linha escolhida. O **olho** inclui ou **suprime** a linha no resultado (também na reprodução e ao guardar) e o **cadeado** protege-a de alterações.
- **Zoom** da linha de tempo (lupas, + − 0, pinça ou ⌘+roda) e deslocamento horizontal.
- Edição **não destrutiva** (o vídeo original não muda), com **desfazer/refazer** e memória ao reabrir. **Guardar** cria um MP4 novo, com o áudio misturado numa só faixa.
- **Ecrã inteiro** pelo menu da barra de menus.
- **Imagem nova**, para além das capturas: **em branco** (tamanho, cor de fundo ou transparente) ou **a partir da área de transferência** (botão *Novo*, menu *Ficheiro*; ⌘N e ⇧⌘N).
- **Atalho global configurável** (por omissão **⌃⇧4**) em *Preferências*; avisa se a combinação é do sistema ou já está em uso.

**Editor (não destrutivo: a imagem original nunca é alterada)**
- **Ferramentas:** Mover, Seta, Linha, Texto, Balão, Retângulo, Elipse, Etapa, Marcador, Pixelização, Blur e Tela.
- **Texto no próprio objeto** (texto, balão, retângulo, elipse): fonte, tamanho, negrito/itálico/sublinhado, cor, alinhamento horizontal e vertical, listas de marcadores ou numeradas.
- **Cores da linha e do preenchimento** à escolha, espessura, opacidade e sombra.
- **Etapas numeradas** (1, 2, 3 · I, II, III · i, ii, iii · A, B, C · a, b, c), com cor do círculo e do número, fonte e **reinício da sequência**. **Redimensionam-se pelos cantos mantendo a proporção** (ou pelo controlo *Tamanho*), e o número ou a letra acompanha a escala e fica sempre centrado; o último tamanho usado é lembrado.
- **Blur e Pixelização** com intensidade ajustável, para ocultar informação sensível. Atuam sobre **tudo o que está por baixo**: a imagem e também os objetos inseridos em camadas inferiores (um objeto por cima do efeito continua nítido).
- **Área de trabalho (Tela):** aumente ou diminua a imagem, com cor de fundo ou transparente; **expande-se sozinha** quando um elemento sai da área.
- **Camadas:** ordem, ocultar, remover. Qualquer elemento pode ser removido ou editado **mais tarde**, mesmo depois de fechar e reabrir.
- **Copiar, colar, duplicar**; cola **imagens e texto de outras apps**. Desfazer/refazer, zoom e deslocamento.
- **Seleção rápida:** com uma ferramenta de desenho ativa, **clicar** num objeto existente seleciona-o e mostra as opções desse objeto; **arrastar** continua a desenhar um novo (por exemplo, uma seta a partir de uma caixa). **⌥ + clique** força a criação por cima de um objeto (útil para as etapas).
- **Exportar PNG** ou **copiar tudo** para a área de transferência.

**Biblioteca**
- **Abrir Biblioteca** (botão no canto inferior direito): grelha com a **pré-visualização atual** de cada captura, para escolher clicando; faixa de miniaturas no editor, que se pode **ocultar/mostrar** (botão «Biblioteca» no rodapé, ou *Ver → Mostrar/ocultar Biblioteca*, ⌥⌘L).
- **Abrir** (barra superior): abre **qualquer imagem do computador** (PNG, JPEG, HEIC, TIFF, GIF, BMP…) no editor. Fica como captura nova (o ficheiro original não é tocado) e as alterações guardam-se; com **Salvar como** exporta em **PNG, JPEG, HEIC ou TIFF**.
- Cada captura é **um só ficheiro `.capture`** (um ZIP normal) em `~/Pictures/Capture`, com nome **sem espaços**: `Toth_AAAA-MM-DD_HH.MM.SS.capture`. Os ficheiros `.capture` **abrem com o Toth** (duplo clique, *Abrir com*, ou arrastar para o ícone do Dock).

**Comodidades**
- **Janela ajustável:** pode ficar estreita (as ferramentas deslizam na barra; as setas «‹ ›» deslizam as ferramentas **de forma contínua**: um clique avança um pouco, mantendo premido continua a deslizar, e a roda/trackpad também; apagam-se quando não há mais para esse lado), e o painel de **Propriedades** está sempre à direita, com uma divisória que se **arrasta** para o redimensionar, até desaparecer para o lado; com o painel escondido aparece uma **faixa larga** com uma pega bem visível: um clique, ou arrastar para a esquerda, volta a abri-lo (também por *Ver → Mostrar/ocultar Propriedades*, ⌥⌘P; duplo clique na divisória esconde-o).
- O Toth também aparece em *Abrir com* para imagens.
- Cada ferramenta **lembra a última personalização**, mesmo depois de fechar a app.
- **Português e inglês**, com mudança imediata em *Preferências*.
- **Privacidade:** não recolhe dados; só usa a internet para procurar atualizações (desligável).


### Usar
Carregue em **⌃⇧4** (ou use o ícone na barra de menus ou o menu *Ficheiro*) → escolha a área → **Enter** → anote → **Salvar como** / **Copiar tudo**. As **Preferências** (engrenagem no rodapé, ou ⌘,) têm o atalho e o idioma.

---

## English

### Features

**Capture**
- **Region capture with a frozen screen:** the screen freezes the moment you press the shortcut, so the capture is that exact moment even if the screen changes afterwards. Drag to choose the area, **move and resize** it with the handles, and only when you **confirm** (*Capture* button or **Enter**) does it go to the editor. **Esc** cancels. Multi-monitor aware.
- **Scrolling capture:** after choosing the area, click **Scroll** (next to *Cancel* and *Capture*). From then on **scroll the window however you like**, in any direction (up, down, left, right), slowly or fast, and you can go back and pass over the same area again: Toth works out the movement by itself and keeps joining everything. It only ends when you click **Finish** on the floating bar (or **Cancel** to discard). **Pause/Resume** lets you stop capturing and carry on later from any area already captured (Toth keeps several recent captures to line up again). If it cannot join anything in the end, it offers **Try again**. Toth never touches the window by itself and needs no permission beyond screen recording. Fixed headers and footers appear only once. Limits: images up to about 30,000 px on a side; scroll one axis at a time (diagonal does not align); if you scroll too fast the bar warns you and going back a little resumes; animated content, videos or pages that load while scrolling may leave seams.
- **Video recording (MP4):** after choosing the area, click the **video** icon. An icon-only bar lets you **record**, **pause and resume** and **stop** (the video opens right away in the editor). **System audio** and the **microphone** can be turned on or off at any time. The file is a regular MP4 (H.264 and AAC) in `~/Pictures/Capture`.

**Video editor**
- **Three lanes** (video, system audio, microphone), each source on its own track. Every clip is a **whole block**: click to select it and drag to move it. The block drops into the nearest junction and the rest shifts along, **without splitting or erasing** what is there (⌥ on release places it freely on top).
- **Mark a part** (⇧+drag, the I/O keys, or drag on a gap): the player shows the **exact point** of the edge (with the frame number) and the arrow keys fine-tune it frame by frame. Then **cut and join**, **cut leaving a gap** (no video and no sound), **copy**, **paste** (inserting or over) and **reverse**.
- **Break** (B key, icon, or right-click): splits a clip into two blocks without cutting anything.
- **Per lane:** marking, cutting, copying and moving apply only to the chosen lane. The **eye** includes or **mutes/hides** a lane in the result (in playback and when saving) and the **lock** protects it from changes.
- **Timeline zoom** (magnifier buttons, + − 0, pinch or ⌘+wheel) and horizontal panning.
- **Non-destructive** editing (the original video never changes), with **undo/redo** and memory on reopening. **Save** creates a new MP4 with the audio mixed into a single track.
- **Full-screen capture** from the menu bar.
- **New images** besides captures: **blank** (size, background color or transparent) or **from the clipboard** (*New* button, *File* menu; ⌘N and ⇧⌘N).
- **Configurable global shortcut** (default **⌃⇧4**) in *Preferences*; it warns if a combination is taken by the system or already in use.

**Editor (non-destructive: the original image is never changed)**
- **Tools:** Move, Arrow, Line, Text, Callout, Rectangle, Ellipse, Step, Highlighter, Pixelate, Blur and Canvas.
- **Text directly in the object** (text, callout, rectangle, ellipse): font, size, bold/italic/underline, color, horizontal and vertical alignment, bulleted or numbered lists.
- Your choice of **line and fill colors**, thickness, opacity and shadow.
- **Numbered steps** (1, 2, 3 · I, II, III · i, ii, iii · A, B, C · a, b, c), with circle and number colors, font, and **sequence restart**. They **resize by their corners keeping the proportions** (or with the *Size* control), and the number or letter scales along and stays centered; the last size used is remembered.
- **Blur and Pixelate** with adjustable strength, to hide sensitive information. They act on **everything beneath them**: the image and also objects on lower layers (an object above the effect stays sharp).
- **Work area (Canvas):** enlarge or shrink the image, with a background color or transparent; it **expands automatically** when an element goes outside the area.
- **Layers:** order, hide, remove. Any element can be removed or edited **later**, even after closing and reopening.
- **Copy, paste, duplicate**; pastes **images and text from other apps**. Undo/redo, zoom and pan.
- **Quick selection:** with a drawing tool active, **clicking** an existing object selects it and shows its options; **dragging** keeps drawing a new one (for example an arrow from a box). **⌥ + click** forces creation on top of an object (handy for steps).
- **Export PNG** or **copy all** to the clipboard.

**Library**
- **Open Library** (button at the bottom right): a grid with the **current preview** of each capture to pick by clicking; a thumbnail strip in the editor.
- **Open** (top bar): opens **any image on your computer** (PNG, JPEG, HEIC, TIFF, GIF, BMP…) in the editor. It becomes a new capture (the original file is never touched) and your changes are saved; **Save as** exports **PNG, JPEG, HEIC or TIFF**.
- Each capture is **a single `.capture` file** (a standard ZIP) in `~/Pictures/Capture`, with a name **without spaces**: `Toth_YYYY-MM-DD_HH.MM.SS.capture`. `.capture` files **open with Toth** (double-click, *Open With*, or drag onto the Dock icon).

**Conveniences**
- **Adjustable window:** it can be narrow (tools slide along the bar; the «‹ ›» arrows scroll the tools **continuously**: a click nudges them, holding keeps them moving, and the wheel/trackpad works too; they dim when there is no more on that side), and the **Properties** panel is always on the right, with a divider you **drag** to resize it until it slides out of sight; when it is hidden a **wide strip** with an obvious grip appears: one click, or dragging left, brings it back (also via *View → Show/Hide Properties*, ⌥⌘P; double-clicking the divider hides it).
- Toth also appears under *Open With* for images.
- Each tool **remembers its last customization**, even after you quit the app.
- **Portuguese and English**, switchable instantly in *Preferences*.
- **Privacy:** it collects no data; it only uses the internet to check for updates (can be turned off).


### Use
Press **⌃⇧4** (or use the menu bar icon or the *File* menu) → choose the area → **Enter** → annotate → **Save as** / **Copy all**. **Preferences** (gear icon in the footer, or ⌘,) hold the shortcut and the language.
