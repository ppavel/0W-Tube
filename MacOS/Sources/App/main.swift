import Cocoa

let app = NSApplication.shared

_ = app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()