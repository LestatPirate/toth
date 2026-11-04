# Guia do Toth · Toth guide

[Português](#português) · [English](#english)

## Português

### Funcionalidades

**Captura**
- **Região com o ecrã congelado** ao carregar no atalho: a captura é a do momento do atalho, mesmo que o ecrã mude depois. Arraste para escolher a área, **mova-a e redimensione-a** pelas alças, e só ao **confirmar** (botão *Capturar* ou **Enter**) segue para o editor. **Esc** cancela. Funciona com vários monitores.
- **Captura com rolagem:** depois de escolher a área, clique em **Rolagem** (ao lado de *Cancelar* e *Capturar*). A partir daí **role a janela como quiser**, para qualquer lado (cima, baixo, esquerda, direita), devagar ou depressa, e pode voltar atrás e passar outra vez pela mesma zona: o Toth percebe sozinho o movimento e vai juntando tudo. Só termina quando clicar em **Concluir** na barra flutuante (ou **Cancelar** para descartar). **Pausar/Retomar** deixa-o parar a captura e continuar depois, a partir de qualquer zona já capturada (o Toth guarda várias capturas recentes para voltar a alinhar). Se no fim não conseguir juntar nada, oferece **Tentar de novo**. O Toth não mexe na janela por si e não precisa de nenhuma permissão além da gravação de ecrã. Cabeçalhos e rodapés fixos aparecem uma só vez. Limites: imagens até cerca de 30 000 px de lado; role um eixo de cada vez (na diagonal não alinha); se rolar depressa demais a barra avisa e basta voltar um pouco atrás; conteúdo animado, vídeos ou páginas que carregam enquanto rola podem deixar emendas.
- **Captura de janela:** no seletor, carregue em **Espaço** (ou no ícone de janela na barra do topo) e passe o rato pelas janelas: a que está por baixo fica em destaque; um clique captura **só essa janela**, mesmo que esteja parcialmente tapada, **com ou sem sombra** (botão na barra; com sombra a margem fica transparente). O ícone de vídeo nessa barra grava a janela sob o rato. Também em *Ficheiro → Capturar janela*.
- **Gravação de vídeo (MP4):** depois de escolher a área, clique no ícone de **vídeo**. Uma barra só com ícones permite **gravar**, **pausar e retomar** e **parar** (o vídeo abre logo no editor). O **áudio do sistema** e o **microfone** podem ser ligados ou desligados a qualquer momento. O ficheiro é um MP4 normal (H.264 e AAC) em `~/Pictures/Capture`.

**Editor de vídeo**
- **Três linhas** (vídeo, áudio do sistema, microfone), cada fonte na sua faixa. Cada clipe é um **bloco inteiro**: clique para o marcar e arraste para o mover. O bloco entra na junção mais próxima e o resto desloca-se, **sem partir nem apagar** o que lá está (⌥ ao largar pousa-o livremente por cima).
- **Marcar um trecho** (⇧+arrastar, ou as teclas I/O, ou arrastar num espaço): o leitor mostra o **ponto exato** da ponta (com o número do quadro) e as setas afinam-no quadro a quadro. Depois: **cortar e juntar**, **cortar deixando um espaço** (sem vídeo e sem som), **copiar**, **colar** (inserindo ou por cima) e **inverter**.
- **Quebra** (tecla B, ícone, ou botão direito): divide o clipe em dois blocos sem cortar nada.
- **Por linha:** a marcação, o corte, a cópia e o movimento aplicam-se só à linha escolhida. O **olho** inclui ou **suprime** a linha no resultado (também na reprodução e ao guardar) e o **cadeado** protege-a de alterações.
- **Zoom** da linha de tempo (lupas, + − 0, pinça ou ⌘+roda) e deslocamento horizontal.
- **Tela do vídeo** (botão na barra): aparecem alças sobre o vídeo para o **redimensionar com o rato** (cantos em proporção, ⇧ para livre; lados mudam só uma medida) e uma alça redonda para o **rodar**; ou use os campos de largura, altura e rotação, 25/50/75 % e «Original». Aplica-se à reprodução e ao ficheiro guardado (rodado, o ficheiro fica com a caixa envolvente).
- **Anotar** (botão na barra, ou A): o leitor dá lugar ao editor de imagem sobre o fotograma atual, com **todas as ferramentas** (setas, texto, balões, carimbos, pixelização, desfoque, reparo…). Cada anotação começa na posição de reprodução e dura 3 s; na linha **«Anotações»** cada uma é um bloco que se arrasta (ou pelas pontas) para mudar o início e o fim, ou use os campos *Início*/*Fim* («= agora»). **Seguir:** ponha a reprodução perto do fim da anotação, arraste o elemento para onde deve estar nesse instante e carregue em *Seguir*: ela desloca-se em linha reta do início ao fim. As anotações entram na reprodução e no MP4 guardado.
- **Áudio:** botão direito no nome de uma linha de áudio para o **volume** (0–200 %) e o **fade** de entrada e saída de cada clipe. O botão de áudio na barra **importa música** (MP3, M4A, WAV, AIFF…) para a linha «Música», a começar na posição de reprodução, e **grava uma narração** com o microfone (o vídeo toca enquanto fala; ao parar, entra na linha «Narração»). O **microfone** escolhe-se aí ou nas Preferências. Uma linha acrescentada tira-se pelo botão direito no nome.
- **Velocidade:** marque um clipe e escolha 0,25× a 4× no botão de velocímetro; o som acompanha sem mudar de tom (um distintivo «2×» aparece no clipe).
- **Miniaturas** na linha do vídeo (botão na barra; por omissão a linha é simples).
- As linhas são **estreitas** e a linha de tempo **rola na vertical** quando há muitas (anotações que se sobrepõem no tempo ficam em filas separadas).
- Edição **não destrutiva** (o vídeo original não muda), com **desfazer/refazer** e memória ao reabrir. **Guardar** cria um MP4 novo (cortes, anotações e o áudio misturado numa só faixa), ou um **GIF animado** (10 imagens/s, até 640 px), ou **só o áudio** (M4A).
- **Ecrã inteiro** pelo menu da barra de menus.
- **Imagem nova**, para além das capturas: **em branco** (tamanho, cor de fundo ou transparente) ou **a partir da área de transferência** (botão *Novo*, menu *Ficheiro*; ⌘N e ⇧⌘N).
- **Atalho global configurável** (por omissão **⌃⇧4**) em *Preferências*; avisa se a combinação é do sistema ou já está em uso.

**Editor (não destrutivo: a imagem original nunca é alterada)**
- **Ferramentas:** Mover, Seta, Linha, Texto, Balão, Retângulo, Elipse, Etapa, Carimbo, Marcador, Pixelização, Blur, Reparo e Tela.
- **Carimbos:** símbolos do sistema (pintados com a cor escolhida), emojis, qualquer texto curto, ou **imagens suas** (*Importar imagens…*; ficam numa biblioteca de carimbos e entram no documento como imagem). Um clique põe o carimbo com o tamanho padrão; arrastar escolhe o tamanho (sempre em proporção).
- **Reparo:** *Preencher* apaga o que está na região e preenche-a a partir do que a rodeia (bom em fundos lisos ou gradientes); *Clonar* cobre a região com outra zona da imagem (arraste a alça verde para escolher de onde copiar). Como o Blur, atua sobre tudo o que está por baixo e é não destrutivo.
- **Texto no próprio objeto** (texto, balão, retângulo, elipse): fonte, tamanho (até 400), negrito/itálico/sublinhado, cor, alinhamento horizontal e vertical, listas de marcadores ou numeradas. A caixa **ajusta-se ao texto enquanto escreve**, e ao redimensionar o objeto **a letra acompanha** (maior ou menor) se «Redimensionar em proporção» estiver marcado; desmarcado, só a caixa muda e o texto quebra de linha.
- **Cores da linha e do preenchimento** à escolha, espessura, opacidade e sombra.
- **Etapas numeradas** (1, 2, 3 · I, II, III · i, ii, iii · A, B, C · a, b, c), com cor do círculo e do número, fonte e **reinício da sequência**. **Redimensionam-se pelos cantos mantendo a proporção** (ou pelo controlo *Tamanho*), e o número ou a letra acompanha a escala e fica sempre centrado; o último tamanho usado é lembrado.
- **Blur e Pixelização** com intensidade ajustável, para ocultar informação sensível. Atuam sobre **tudo o que está por baixo**: a imagem e também os objetos inseridos em camadas inferiores (um objeto por cima do efeito continua nítido).
- **Área de trabalho (Tela):** aumente ou diminua a imagem, com cor de fundo ou transparente; **expande-se sozinha** quando um elemento sai da área. Na Tela, clique na **imagem** (ou escolha «Imagem» no painel) para a **mover, redimensionar** (em proporção pelos cantos, ⇧ para livre, ou só uma medida pelos lados) e **rodar** (alça redonda ou ±90° no painel). A imagem original nunca é alterada e «Restaurar original» volta atrás.
- **Rodar qualquer elemento:** com o elemento selecionado, arraste a alça redonda acima dele (encosta aos 15°; ⌥ liberta) ou use a rotação no painel (deslizador, graus, ±90°, Endireitar).
- **Camadas:** ordem, ocultar, remover. Qualquer elemento pode ser removido ou editado **mais tarde**, mesmo depois de fechar e reabrir.
- **Zoom nítido:** as capturas são em píxeis nativos (o dobro dos pontos num ecrã Retina). «Ajustar» nunca amplia para lá de um píxel da imagem por píxel do ecrã e **1:1** mostra exatamente um píxel da imagem por píxel do ecrã; a percentagem no rodapé é relativa aos píxeis do ecrã. Assim a captura aparece tão nítida como estava no ecrã, e o ficheiro guardado tem sempre a resolução nativa.
- **Copiar, colar, duplicar**; cola **imagens e texto de outras apps**. As imagens coladas entram **ao tamanho real** (píxel a píxel; só se reduzem se não couberem na área) e, por omissão, **redimensionam-se em proporção** pelos cantos (⇧ liberta; secção «Imagem colada» no painel, com largura, altura e «Tamanho real»). Desfazer/refazer, zoom e deslocamento.
- **Seleção rápida:** com uma ferramenta de desenho ativa, **clicar** num objeto existente seleciona-o e mostra as opções desse objeto; **arrastar** continua a desenhar um novo (por exemplo, uma seta a partir de uma caixa). **⌥ + clique** força a criação por cima de um objeto (útil para as etapas).
- **Ferramentas de uma vez:** depois de desenhar, a ferramenta volta a Mover; **duplo clique** no ícone prende-a para desenhar vários seguidos. **Esc** volta a Mover, e outro Esc limpa a seleção (na Tela, Esc cancela as alterações). **Setas** deslocam o objeto selecionado (⇧: 10 px); **começar a escrever** num objeto de texto abre a edição; o objeto sob o rato fica destacado e o **botão direito** abre um menu com as ações mais comuns.
- **Vários de uma vez:** **⇧+clique** junta objetos à seleção, **arrastar no vazio** (com Mover) faz um laço, **⌘A** seleciona tudo. Mover, apagar, duplicar, copiar, setas e cores aplicam-se a todos. **⌥+arrastar** duplica. Ao mover, o objeto **encosta** às bordas e centros dos outros e da imagem (guias rosa; ⌘ desliga). Com vários selecionados, a **caixa do grupo** tem cantos para **redimensionar em proporção** e uma alça redonda para **rodar tudo**.
- **Disposição** (painel e menu *Organizar*): **alinhar** à esquerda, ao centro, à direita, ao topo, ao meio, à base (entre si; um só alinha-se à área) e **distribuir** na horizontal ou vertical (3 ou mais). **Agrupar** (⌘G) e **Desagrupar** (⇧⌘G): clicar num membro seleciona o grupo inteiro; as cópias de um grupo formam um grupo novo.
- **Exportar PNG**, **copiar tudo** (imagem e ficheiro PNG) ou **arrastar** a pega do rodapé para levar o PNG para outra app ou para o Finder.

**Biblioteca**
- **Abrir Biblioteca** (botão no canto inferior direito): grelha com a **pré-visualização atual** de cada captura, para escolher clicando; faixa de miniaturas no editor, que se pode **ocultar/mostrar** (botão «Biblioteca» no rodapé, ou *Ver → Mostrar/ocultar Biblioteca*, ⌥⌘L).
- **Abrir** (barra superior): abre **qualquer imagem do computador** (PNG, JPEG, HEIC, TIFF, GIF, BMP…) no editor. Fica como captura nova (o ficheiro original não é tocado) e as alterações guardam-se; com **Salvar como** exporta em **PNG, JPEG, HEIC ou TIFF**.
- Cada captura é **um só ficheiro `.capture`** (um ZIP normal) em `~/Pictures/Capture`, com nome **sem espaços**: `Toth_AAAA-MM-DD_HH.MM.SS.capture`. Os ficheiros `.capture` **abrem com o Toth** (duplo clique, *Abrir com*, ou arrastar para o ícone do Dock).

**Comodidades**
- **Janela ajustável:** pode ficar estreita (as ferramentas deslizam na barra, com uma **barra de rolagem** por baixo que se arrasta, como a da faixa de miniaturas; as setas «‹ ›» deslizam as ferramentas **de forma contínua**: um clique avança um pouco, mantendo premido continua a deslizar, e a roda/trackpad também; apagam-se quando não há mais para esse lado), e o painel de **Propriedades** está sempre à direita, com uma divisória que se **arrasta** para o redimensionar, até desaparecer para o lado; com o painel escondido aparece uma **faixa larga** com uma pega bem visível: um clique, ou arrastar para a esquerda, volta a abri-lo (também por *Ver → Mostrar/ocultar Propriedades*, ⌥⌘P; duplo clique na divisória esconde-o).
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
- **Window capture:** in the selector, press **Space** (or the window icon in the top bar) and move over the windows: the one underneath is highlighted; a click captures **only that window**, even if partly covered, **with or without its shadow** (button in the bar; with the shadow the margin is transparent). The video icon in that bar records the window under the mouse. Also via *File → Capture window*.
- **Video recording (MP4):** after choosing the area, click the **video** icon. An icon-only bar lets you **record**, **pause and resume** and **stop** (the video opens right away in the editor). **System audio** and the **microphone** can be turned on or off at any time. The file is a regular MP4 (H.264 and AAC) in `~/Pictures/Capture`.

**Video editor**
- **Three lanes** (video, system audio, microphone), each source on its own track. Every clip is a **whole block**: click to select it and drag to move it. The block drops into the nearest junction and the rest shifts along, **without splitting or erasing** what is there (⌥ on release places it freely on top).
- **Mark a part** (⇧+drag, the I/O keys, or drag on a gap): the player shows the **exact point** of the edge (with the frame number) and the arrow keys fine-tune it frame by frame. Then **cut and join**, **cut leaving a gap** (no video and no sound), **copy**, **paste** (inserting or over) and **reverse**.
- **Break** (B key, icon, or right-click): splits a clip into two blocks without cutting anything.
- **Per lane:** marking, cutting, copying and moving apply only to the chosen lane. The **eye** includes or **mutes/hides** a lane in the result (in playback and when saving) and the **lock** protects it from changes.
- **Timeline zoom** (magnifier buttons, + − 0, pinch or ⌘+wheel) and horizontal panning.
- **Video canvas** (toolbar button): handles appear over the video to **resize it with the mouse** (corners proportionally, ⇧ for free; sides change one dimension) and a round handle to **rotate** it; or use the width, height and rotation fields, 25/50/75 % and “Original”. It applies to playback and to the saved file (rotated, the file gets the bounding box).
- **Annotate** (toolbar button, or A): the player gives way to the image editor over the current frame, with **every tool** (arrows, text, callouts, stamps, pixelate, blur, repair…). Each annotation starts at the playhead and lasts 3 s; in the **“Annotations”** lane each one is a block you drag (or by its ends) to change the start and the end, or use the *Start*/*End* fields (“= now”). **Follow:** put the playhead near the end of the annotation, drag the element to where it should be at that instant and press *Follow*: it moves in a straight line from start to end. Annotations go into playback and into the saved MP4.
- **Audio:** right-click an audio lane name for its **volume** (0–200 %) and the **fade** in and out of each clip. The audio button in the bar **imports music** (MP3, M4A, WAV, AIFF…) into a “Music” lane, starting at the playhead, and **records a narration** with the microphone (the video plays while you speak; when you stop, it goes into the “Narration” lane). The **microphone** is chosen there or in Preferences. An added lane is removed by right-clicking its name.
- **Speed:** mark a clip and choose 0.25× to 4× with the speedometer button; the sound follows without changing pitch (a “2×” badge appears on the clip).
- **Thumbnails** in the video lane (toolbar button; the lane is plain by default).
- Lanes are **narrow** and the timeline **scrolls vertically** when there are many (annotations that overlap in time go into separate rows).
- **Non-destructive** editing (the original video never changes), with **undo/redo** and memory on reopening. **Save** creates a new MP4 (cuts, annotations and the audio mixed into a single track), an **animated GIF** (10 frames/s, up to 640 px) or **audio only** (M4A).
- **Full-screen capture** from the menu bar.
- **New images** besides captures: **blank** (size, background color or transparent) or **from the clipboard** (*New* button, *File* menu; ⌘N and ⇧⌘N).
- **Configurable global shortcut** (default **⌃⇧4**) in *Preferences*; it warns if a combination is taken by the system or already in use.

**Editor (non-destructive: the original image is never changed)**
- **Tools:** Move, Arrow, Line, Text, Callout, Rectangle, Ellipse, Step, Stamp, Highlighter, Pixelate, Blur, Repair and Canvas.
- **Stamps:** system symbols (painted in your color), emojis, any short text, or **your own pictures** (*Import pictures…*; they live in a stamp library and enter the document as images). One click places the stamp at the default size; dragging chooses the size (always proportional).
- **Repair:** *Fill* erases what is in the region and fills it from its surroundings (good on plain or gradient backgrounds); *Clone* covers the region with another part of the image (drag the green handle to choose where to copy from). Like Blur, it acts on everything beneath it and is non-destructive.
- **Text directly in the object** (text, callout, rectangle, ellipse): font, size (up to 400), bold/italic/underline, color, horizontal and vertical alignment, bulleted or numbered lists. The box **fits the text as you type**, and when you resize the object **the text scales along** (bigger or smaller) if “Resize proportionally” is on; off, only the box changes and the text wraps.
- Your choice of **line and fill colors**, thickness, opacity and shadow.
- **Numbered steps** (1, 2, 3 · I, II, III · i, ii, iii · A, B, C · a, b, c), with circle and number colors, font, and **sequence restart**. They **resize by their corners keeping the proportions** (or with the *Size* control), and the number or letter scales along and stays centered; the last size used is remembered.
- **Blur and Pixelate** with adjustable strength, to hide sensitive information. They act on **everything beneath them**: the image and also objects on lower layers (an object above the effect stays sharp).
- **Work area (Canvas):** enlarge or shrink the image, with a background color or transparent; it **expands automatically** when an element goes outside the area. In Canvas, click the **image** (or choose “Image” in the panel) to **move, resize** (proportionally by the corners, ⇧ for free, or one dimension by the sides) and **rotate** it (round handle or ±90° in the panel). The original image is never altered and “Restore original” goes back.
- **Rotate any element:** with the element selected, drag the round handle above it (snaps to 15°; ⌥ frees it) or use the rotation in the panel (slider, degrees, ±90°, Straighten).
- **Layers:** order, hide, remove. Any element can be removed or edited **later**, even after closing and reopening.
- **Sharp zoom:** captures are in native pixels (twice the points on a Retina screen). “Fit” never enlarges beyond one image pixel per screen pixel and **1:1** shows exactly one image pixel per screen pixel; the percentage in the footer is relative to screen pixels. The capture looks as sharp as it did on screen, and the saved file always has the native resolution.
- **Copy, paste, duplicate**; pastes **images and text from other apps**. Pasted images come in **at their real size** (pixel for pixel; they only shrink if they do not fit the area) and, by default, **resize proportionally** by the corners (⇧ frees them; “Pasted image” section in the panel, with width, height and “Real size”). Undo/redo, zoom and pan.
- **Quick selection:** with a drawing tool active, **clicking** an existing object selects it and shows its options; **dragging** keeps drawing a new one (for example an arrow from a box). **⌥ + click** forces creation on top of an object (handy for steps).
- **One-shot tools:** after drawing, the tool returns to Move; **double-click** the icon to lock it and draw several in a row. **Esc** returns to Move, and another Esc clears the selection (in Canvas, Esc cancels the changes). **Arrow keys** nudge the selected object (⇧: 10 px); **starting to type** on a text object opens editing; the object under the mouse is highlighted and the **right button** opens a menu with the common actions.
- **Several at once:** **⇧+click** adds objects to the selection, **dragging on empty space** (with Move) draws a marquee, **⌘A** selects all. Moving, deleting, duplicating, copying, arrow keys and colors apply to all. **⌥+drag** duplicates. When moving, the object **snaps** to the edges and centers of the others and of the image (pink guides; ⌘ disables). With several selected, the **group box** has corners to **resize proportionally** and a round handle to **rotate everything**.
- **Arrange** (panel and *Arrange* menu): **align** left, center, right, top, middle, bottom (to each other; a single object aligns to the area) and **distribute** horizontally or vertically (3 or more). **Group** (⌘G) and **Ungroup** (⇧⌘G): clicking a member selects the whole group; copies of a group form a new group.
- **Export PNG**, **copy all** (image and PNG file) or **drag** the grip in the footer to take the PNG to another app or to the Finder.

**Library**
- **Open Library** (button at the bottom right): a grid with the **current preview** of each capture to pick by clicking; a thumbnail strip in the editor.
- **Open** (top bar): opens **any image on your computer** (PNG, JPEG, HEIC, TIFF, GIF, BMP…) in the editor. It becomes a new capture (the original file is never touched) and your changes are saved; **Save as** exports **PNG, JPEG, HEIC or TIFF**.
- Each capture is **a single `.capture` file** (a standard ZIP) in `~/Pictures/Capture`, with a name **without spaces**: `Toth_YYYY-MM-DD_HH.MM.SS.capture`. `.capture` files **open with Toth** (double-click, *Open With*, or drag onto the Dock icon).

**Conveniences**
- **Adjustable window:** it can be narrow (tools slide along the bar, with a draggable **scrollbar** underneath, like the thumbnail strip; the «‹ ›» arrows scroll the tools **continuously**: a click nudges them, holding keeps them moving, and the wheel/trackpad works too; they dim when there is no more on that side), and the **Properties** panel is always on the right, with a divider you **drag** to resize it until it slides out of sight; when it is hidden a **wide strip** with an obvious grip appears: one click, or dragging left, brings it back (also via *View → Show/Hide Properties*, ⌥⌘P; double-clicking the divider hides it).
- Toth also appears under *Open With* for images.
- Each tool **remembers its last customization**, even after you quit the app.
- **Portuguese and English**, switchable instantly in *Preferences*.
- **Privacy:** it collects no data; it only uses the internet to check for updates (can be turned off).


### Use
Press **⌃⇧4** (or use the menu bar icon or the *File* menu) → choose the area → **Enter** → annotate → **Save as** / **Copy all**. **Preferences** (gear icon in the footer, or ⌘,) hold the shortcut and the language.
