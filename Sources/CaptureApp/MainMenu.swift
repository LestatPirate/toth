// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit

/// Barra de menus do macOS (aparece enquanto o editor está no Dock). Os atalhos de edição enviam as ações pela cadeia de
/// respostas: se o texto de um objeto está a ser editado, tratam-no a ele; senão, o editor (ou, em último caso, o AppDelegate).
@MainActor
enum MainMenu {
    static func build(target t: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
        }
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            main.setSubmenu(menu, for: item)
            return menu
        }

        // Toth
        let app = submenu("Toth")
        add(app, L("Sobre o Toth"), #selector(AppDelegate.showAbout), target: t)
        add(app, L("Procurar atualizações…"), #selector(AppDelegate.checkForUpdates), target: t)
        app.addItem(.separator())
        add(app, L("Preferências…"), #selector(AppDelegate.showPreferences), ",", target: t)
        app.addItem(.separator())
        add(app, L("Ocultar o Toth"), #selector(NSApplication.hide(_:)), "h")
        add(app, L("Ocultar outros"), #selector(NSApplication.hideOtherApplications(_:)), "h", mods: [.command, .option])
        add(app, L("Mostrar tudo"), #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, L("Sair do Toth"), #selector(NSApplication.terminate(_:)), "q")

        // Ficheiro
        let file = submenu(L("Ficheiro"))
        add(file, L("Nova imagem em branco…"), #selector(AppDelegate.newBlankImage), "n", target: t)
        add(file, L("Nova imagem da área de transferência"), #selector(AppDelegate.newFromClipboard), "n", mods: [.command, .shift], target: t)
        add(file, L("Abrir imagem…"), #selector(AppDelegate.openImage), "o", target: t)
        add(file, L("Abrir Biblioteca"), #selector(AppDelegate.openCapture), "o", mods: [.command, .shift], target: t)
        file.addItem(.separator())
        add(file, L("Capturar região"), #selector(AppDelegate.captureRegion), target: t)
        add(file, L("Capturar ecrã inteiro"), #selector(AppDelegate.captureFullScreen), target: t)
        file.addItem(.separator())
        add(file, L("Salvar como…"), #selector(AppDelegate.saveAs), "s", mods: [.command, .shift], target: t)
        add(file, L("Fechar janela"), #selector(NSWindow.performClose(_:)), "w")

        // Editar
        let edit = submenu(L("Editar"))
        add(edit, L("Desfazer"), Selector(("undo:")), "z")
        add(edit, L("Refazer"), Selector(("redo:")), "z", mods: [.command, .shift])
        edit.addItem(.separator())
        add(edit, L("Cortar"), Selector(("cut:")), "x")
        add(edit, L("Copiar"), Selector(("copy:")), "c")
        add(edit, L("Colar"), Selector(("paste:")), "v")
        add(edit, L("Duplicar"), Selector(("duplicate:")), "d")
        add(edit, L("Selecionar tudo"), #selector(NSText.selectAll(_:)), "a")

        // Ver
        let view = submenu(L("Ver"))
        add(view, L("Ampliar"), #selector(AppDelegate.zoomIn), "+", target: t)
        add(view, L("Reduzir"), #selector(AppDelegate.zoomOut), "-", target: t)
        add(view, L("Ajustar"), #selector(AppDelegate.zoomFit), "0", target: t)
        add(view, L("Tamanho real"), #selector(AppDelegate.zoomActual), "1", target: t)
        view.addItem(.separator())
        add(view, L("Mostrar/ocultar Propriedades"), #selector(AppDelegate.toggleProperties), "p", mods: [.command, .option], target: t)
        add(view, L("Mostrar/ocultar Biblioteca"), #selector(AppDelegate.toggleLibrary), "l", mods: [.command, .option], target: t)

        // Janela
        let window = submenu(L("Janela"))
        add(window, L("Minimizar"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, L("Trazer tudo para a frente"), #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
        return main
    }
}
