import Foundation
import ApplicationServices
import Cocoa

let kAXWindowIDAttribute: CFString = "AXWindowID" as CFString

class AccessibilityHelper {
    
    private var runningApplicationsDict: [String: NSRunningApplication]
    
    init() {
        guard AXIsProcessTrusted() else {
            print("Accessibility permissions are not enabled. Please go to System Preferences -> Security & Privacy -> Privacy -> Accessibility and add this application.")
            exit(1)
        }
        
        self.runningApplicationsDict = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
            if let appName = app.localizedName {
                return (appName, app)
            }
            return nil
        }, uniquingKeysWith: { (first, _) in first })
    }
    
    func getMouseLocation() -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        if let screenHeight = NSScreen.main?.frame.height {
            return CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)
        }
        return mouseLocation
    }

    func subelementsFromElement(_ element: AXUIElement, forAttribute attribute: String) -> [AXUIElement]? {
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)

        guard result == .success else {
            return nil
        }

        var subElements: CFArray?
        let secondResult = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &subElements)

        guard secondResult == .success, let array = subElements as? [AXUIElement] else {
            return nil
        }

        return array
    }
    func getWindowInfoByName(title: String) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        
        for windowInfo in windowInfoList ?? [] {
            if let windowTitle = windowInfo[kCGWindowName as String] as? String, windowTitle == title,
               let windowID = windowInfo[kCGWindowNumber as String] as? UInt32 {
                return windowID
            }
        }
        return nil
    }

    func getWindows(for app: NSRunningApplication) -> [(title: String, windowRef: AXUIElement, windowID: CGWindowID)] {
        var result: [(title: String, windowRef: AXUIElement, windowID: CGWindowID)] = []

        // Create an AXUIElement for the application
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Prepare a CFTypeRef to hold the attribute's value
        var windowsValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        // Check if the window list was successfully obtained
        guard error == .success, let windowListRef = windowsValue, let windowList = windowListRef as? [AXUIElement] else {
            return result
        }

        // Get a list of all windows currently on screen
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let cgWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return result
        }
        
        for window in windowList {
            // Try to get the window title
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success, let title = titleValue as? String {
                
                // Try to find the corresponding CGWindowID
                var windowIDValue: CGWindowID = 0
                var successful = false
                
                for cgWindow in cgWindows {
                    if let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t, ownerPID == app.processIdentifier,
                       let windowNumber = cgWindow[kCGWindowNumber as String] as? CGWindowID {
                        windowIDValue = windowNumber
                        successful = true
                        break
                    }
                }
                
                if successful {
                    result.append((title: title, windowRef: window, windowID: windowIDValue))
                }
            }
        }
        
        return result
    }
    func saveWindowPreview(windowID: CGWindowID, withTitle title: String) {
        // Dealing with deprecated method issue: you need macOS < 14.0 or alternative new methods.
        let options: CGWindowImageOption = [.boundsIgnoreFraming]
        guard let windowImageRef = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, options) else {
            print("Failed to capture window image for window ID: \(windowID)")
            return
        }

        let windowImage = NSImage(cgImage: windowImageRef, size: NSZeroSize)

        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = tempDirectory.appendingPathComponent("\(title).png")

        guard let tiffData = windowImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            print("Failed to convert window image to PNG data.")
            return
        }

        do {
            try pngData.write(to: fileURL)
            print("Saved window preview to \(fileURL.path)")
        } catch {
            print("Error saving window preview: \(error)")
        }
    }

    func associateDockItemWithProcesses(for element: AXUIElement) {
        var itemName: String = "Unknown"
        var itemPosition: CGPoint = .zero
        var itemSize: CGSize = .zero
        var itemSubrole: String = "Unknown"

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success, let titleValue = value as? String {
            itemName = titleValue
        }

        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let positionValue = value as! AXValue? {
            AXValueGetValue(positionValue, .cgPoint, &itemPosition)
        }

        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let sizeValue = value as! AXValue? {
            AXValueGetValue(sizeValue, .cgSize, &itemSize)
        }

        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success, let subroleValue = value as? String {
            itemSubrole = subroleValue
        }

        if itemSubrole == "AXApplicationDockItem" {
            print("Item: \(itemName), Position: (\(itemPosition.x), \(itemPosition.y)), Size: (\(itemSize.width), \(itemSize.height))")

            if let app = runningApplicationsDict[itemName] {
                print("Dock Item: \(itemName) is associated with process ID: \(app.processIdentifier) and bundle ID: \(app.bundleIdentifier ?? "Unavailable")")
                
                let correctedMouseLocation = getMouseLocation()
                let itemRect = CGRect(origin: itemPosition, size: itemSize)
                if itemRect.contains(correctedMouseLocation) {
                    print("Mouse is currently inside the rectangle of dock item: \(itemName). Listing windows...")
                    let windows = getWindows(for: app)
                    for (title, _, windowID) in windows {
                        print("Window Title: \(title)")
                        saveWindowPreview(windowID: windowID, withTitle: title)
                    }
                }
            } else {
                print("No running application found for Dock Item: \(itemName)")
            }
        }
    }

    func processDockItemsRecursively(from element: AXUIElement) {
        associateDockItemWithProcesses(for: element)
        if let children = subelementsFromElement(element, forAttribute: kAXChildrenAttribute as String) {
            for child in children {
                processDockItemsRecursively(from: child)
            }
        }
    }

    func processAllDockItems() {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")

        if let lastApp = runningApps.last {
            let appElement = AXUIElementCreateApplication(lastApp.processIdentifier)
            if let dockChildren = subelementsFromElement(appElement, forAttribute: kAXChildrenAttribute as String) {
                for dockItem in dockChildren {
                    processDockItemsRecursively(from: dockItem)
                }
            }
        }
    }

    func logMouseLocationContinuously() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            let mouseLocation = self.getMouseLocation()
            print("Current mouse position: (\(mouseLocation.x), \(mouseLocation.y))")
            
            self.processAllDockItems()
        }
    }
}

class PermissionsService {
    var isTrusted: Bool

    init() {
        self.isTrusted = AXIsProcessTrusted()
    }

    func pollAccessibilityPrivileges() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isTrusted = AXIsProcessTrusted()
            if !self.isTrusted {
                self.pollAccessibilityPrivileges()
            }
        }
    }

    static func acquireAccessibilityPrivileges() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let enabled = AXIsProcessTrustedWithOptions(options)

        if !enabled {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "This application requires accessibility permissions to function properly. Please go to System Preferences -> Security & Privacy -> Privacy -> Accessibility and add this application."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

func main() {
    print("Hello, World!")
    PermissionsService.acquireAccessibilityPrivileges()

    let helper = AccessibilityHelper()
    helper.processAllDockItems()
    
    // Start logging the mouse location every second
    helper.logMouseLocationContinuously()

    RunLoop.current.run()
}

main()
