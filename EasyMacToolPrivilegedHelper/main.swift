import Foundation

let listener = NSXPCListener(machServiceName: "com.easy.EasyMacTool.PrivilegedCleanup")
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
