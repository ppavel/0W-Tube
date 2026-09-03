import Cocoa

/// Команды меню, у которых нет готового получателя в цепочке ответчиков.
/// AppKit-меню не видит `@StateObject` внутри `NSHostingView`, поэтому такие
/// пункты передают запрос в SwiftUI через центр уведомлений.
extension Notification.Name {
    static let tubeFocusSearch = Notification.Name("ru.tubetv.app.focusSearch")
    static let tubeRepeatSearch = Notification.Name("ru.tubetv.app.repeatSearch")
    static let tubeCloseSheet = Notification.Name("ru.tubetv.app.closeSheet")
}

/// Главное меню приложения. Без него окно не отвечает ни на один системный
/// шорткат: ⌘Q, ⌘W, ⌘M, ⌘H и даже ⌘C/⌘V в поле поиска обрабатываются именно
/// пунктами меню — AppKit ищет эквивалент клавиши в `NSApp.mainMenu`, а не в окне.
enum AppMenu {
    private static let actions = MenuActions()

    static func install(appName: String) {
        let main = NSMenu()
        main.addItem(submenu(appMenu(appName), title: appName))
        main.addItem(submenu(editMenu(), title: "Правка"))
        main.addItem(submenu(viewMenu(), title: "Вид"))

        let windows = windowMenu()
        main.addItem(submenu(windows, title: "Окно"))

        NSApp.mainMenu = main
        // Список открытых окон и «Свернуть все» AppKit дописывает сам.
        NSApp.windowsMenu = windows
    }

    private static func appMenu(_ name: String) -> NSMenu {
        let menu = NSMenu(title: name)
        menu.addItem(item("О программе \(name)",
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())

        let services = NSMenu(title: "Службы")
        menu.addItem(submenu(services, title: "Службы"))
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(item("Скрыть \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Скрыть остальные",
                          #selector(NSApplication.hideOtherApplications(_:)), "h",
                          [.command, .option]))
        menu.addItem(item("Показать все", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Завершить \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    /// Правка нужна целиком ради поля поиска: без этих пунктов ⌘C/⌘V/⌘A/⌘Z
    /// в текстовом поле не работают. Цель у всех — `nil`, то есть первый
    /// ответчик, которым при вводе оказывается редактор поля.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Правка")
        menu.addItem(item("Отменить", NSSelectorFromString("undo:"), "z"))
        menu.addItem(item("Повторить", NSSelectorFromString("redo:"), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Вырезать", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Копировать", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Вставить", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Удалить", #selector(NSText.delete(_:))))
        menu.addItem(item("Выбрать все", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Найти", #selector(MenuActions.focusSearch(_:)), "f", target: actions))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "Вид")
        menu.addItem(item("Обновить", #selector(MenuActions.repeatSearch(_:)), "r", target: actions))
        menu.addItem(.separator())
        menu.addItem(item("Перейти в полноэкранный режим",
                          #selector(NSWindow.toggleFullScreen(_:)), "f",
                          [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Окно")
        menu.addItem(item("Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Масштабировать", #selector(NSWindow.performZoom(_:))))
        menu.addItem(item("Закрыть", #selector(MenuActions.closeFrontWindow(_:)), "w",
                          target: actions))
        menu.addItem(.separator())
        menu.addItem(item("Все окна — вперед", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String,
                             _ action: Selector?,
                             _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command,
                             target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
        entry.target = target
        return entry
    }
}

private final class MenuActions: NSObject, NSMenuItemValidation {
    @objc func focusSearch(_ sender: Any?) {
        NotificationCenter.default.post(name: .tubeFocusSearch, object: nil)
    }

    @objc func repeatSearch(_ sender: Any?) {
        NotificationCenter.default.post(name: .tubeRepeatSearch, object: nil)
    }

    /// Плеер открыт как sheet, а не как отдельное окно, и `performClose:` на окне
    /// с прикрепленным sheet-ом только пищит. Поэтому ⌘W сначала закрывает плеер.
    @objc func closeFrontWindow(_ sender: Any?) {
        let key = NSApp.keyWindow
        if key?.sheetParent != nil || key?.attachedSheet != nil {
            NotificationCenter.default.post(name: .tubeCloseSheet, object: nil)
            return
        }
        (key ?? NSApp.mainWindow)?.performClose(sender)
    }

    /// ⌘W и «Обновить» имеют смысл всегда; остальное AppKit проверяет сам.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}
