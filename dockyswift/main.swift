import Foundation
import ApplicationServices
import Cocoa

let kAXWindowIDAttribute: CFString = "AXWindowID" as CFString

import Foundation
import ApplicationServices
import Cocoa

class ClickableImageView: NSImageView {
    var onMouseUp: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }
}
class AccessibilityHelper {
    private var runningApplicationsDict: [String: NSRunningApplication]
    private var previewWindows: [NSWindow] = []
    private var currentAppWindows: [(title: String, windowRef: AXUIElement, windowID: CGWindowID?)] = []
    private var imageViewToWindowRef: [NSImageView: AXUIElement] = [:]
    private var currentDockItemName: String?
    private var isHoveringOverDockItem = false
    private var lastHoveredDockItem: String?
    private var isHoveringOverAnyDockItem = false
    private var isHoveringOverAnyDockItemPreview = false
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

    func getUnmodifiedMouseLocation() -> CGPoint {
    return NSEvent.mouseLocation
    }

    func checkIfMouseIsOverPreviewWindows() -> Bool {
        print("Checking if mouse is over any preview window QUACK QUACK QUACK")
        let mouseLocation = getUnmodifiedMouseLocation()
        print("MOUSE LOCATION WHEN CHECKING FOR PREVIEW WINDOWS: \(mouseLocation)")
        for previewWindow in previewWindows {
            let windowFrame = previewWindow.frame
            print("PREVIEW WINDOW FRAME: \(windowFrame)")
            if windowFrame.contains(mouseLocation) {
                print("AFFIRMATIVELY OVER PREVIEW WINDOW")
                isHoveringOverAnyDockItemPreview = true
                return true
            }
        }
        print("AINT OVER PREVIEW WINDOW NUH-HUH")
        isHoveringOverAnyDockItemPreview = false
        return false
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

  
    func getWindows(for app: NSRunningApplication) -> [(title: String, windowRef: AXUIElement, windowID: CGWindowID?)] {
        var result: [(title: String, windowRef: AXUIElement, windowID: CGWindowID?)] = []

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard error == .success, let windowListRef = windowsValue, let windowList = windowListRef as? [AXUIElement] else {
            return result
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let cgWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return result
        }

        for window in windowList {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success, let title = titleValue as? String {
                var windowIDValue: CGWindowID?

                for cgWindow in cgWindows {
                    if let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t,
                       ownerPID == app.processIdentifier,
                       let windowTitle = cgWindow[kCGWindowName as String] as? String,
                       windowTitle == title,
                       let windowNumber = cgWindow[kCGWindowNumber as String] as? CGWindowID {
                        windowIDValue = windowNumber
                        break
                    }
                }

                result.append((title: title, windowRef: window, windowID: windowIDValue))
            }
        }

        return result
    }
   
    private func areWindowArraysEqual(_ arr1: [(title: String, windowRef: AXUIElement, windowID: CGWindowID?)],
                                      _ arr2: [(title: String, windowRef: AXUIElement, windowID: CGWindowID?)]) -> Bool {
        guard arr1.count == arr2.count else { return false }
        
        for (window1, window2) in zip(arr1, arr2) {
            if window1.title != window2.title || window1.windowID != window2.windowID {
                return false
            }
        }
        
        return true
    }
    func displayWindowPreviews(windows: [(title: String, windowRef: AXUIElement, windowID: CGWindowID?)], atPosition position: CGPoint, size: CGSize) {
          print("displayWindowPreviews called with \(windows.count) windows")
          print("Dock item position: \(position), size: \(size)")

          // Remove existing preview windows if they're for a different app
          if !areWindowArraysEqual(currentAppWindows, windows) {
              hideAllPreviews()
          }

          guard !windows.isEmpty else {
              print("No windows to display")
              return
          }

          let previewSize = CGSize(width: 300, height: 225)  // Increased size for visibility
          let spacing: CGFloat = 20
          let totalWidth = CGFloat(windows.count) * (previewSize.width + spacing) - spacing

          // Calculate the starting X position to center the previews
          let startX = position.x - totalWidth / 2

          guard let screen = NSScreen.main else {
              print("Unable to get main screen")
              return
          }

          print("Main screen frame: \(screen.frame)")
          print("Main screen visibleFrame: \(screen.visibleFrame)")

          // Calculate the Y position for previews
          let dockHeight = screen.frame.height - screen.visibleFrame.height
          let previewY = screen.visibleFrame.minY + dockHeight + 20  // 20 pixels above the dock

          print("Calculated dock height: \(dockHeight)")
          print("Calculated preview Y: \(previewY)")

          for (index, (title, windowRef, windowID)) in windows.enumerated() {
              if index >= previewWindows.count {
                  // Create a new preview window if needed
                  let previewWindow = createPreviewWindow(title: title, windowRef: windowRef, windowID: windowID, previewSize: previewSize)
                  previewWindows.append(previewWindow)
              }

              let previewWindow = previewWindows[index]

              // Update the preview content
              updatePreviewContent(window: previewWindow, title: title, windowRef: windowRef, windowID: windowID, previewSize: previewSize)

              // Position the preview window
              let previewX = startX + CGFloat(index) * (previewSize.width + spacing)
              let screenPositionedFrame = NSRect(x: previewX, y: previewY, width: previewSize.width, height: previewSize.height)
              previewWindow.setFrame(screenPositionedFrame, display: true)

              print("Setting window frame for '\(title)' to: \(screenPositionedFrame)")

              // Delay ordering front to ensure setup is complete
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                  previewWindow.orderFront(nil)
                  print("Window ordered front for: \(title)")
              }
          }

          // Remove any excess preview windows
          while previewWindows.count > windows.count {
              previewWindows.last?.close()
              previewWindows.removeLast()
          }

          currentAppWindows = windows
      }

    private func createPreviewWindow(title: String, windowRef: AXUIElement, windowID: CGWindowID?, previewSize: CGSize) -> NSWindow {
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered,
                                     defer: false)
        previewWindow.title = "Preview - \(title)"
        previewWindow.level = .floating
        previewWindow.isOpaque = false
        previewWindow.backgroundColor = NSColor.clear
        previewWindow.hasShadow = true
        previewWindow.ignoresMouseEvents = false
        previewWindow.acceptsMouseMovedEvents = true

        return previewWindow
    }
    private func updatePreviewContent(window: NSWindow, title: String, windowRef: AXUIElement, windowID: CGWindowID?, previewSize: CGSize) {
          guard let windowID = windowID else {
              print("No valid window ID for window: \(title)")
              return
          }

          let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])

          DispatchQueue.main.async {
              let imageView: ClickableImageView
              if let existingImageView = window.contentView?.subviews.first as? ClickableImageView {
                  imageView = existingImageView
              } else {
                  imageView = ClickableImageView(frame: NSRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height))
                  window.contentView?.addSubview(imageView)
              }

              if let cgImage = cgImage {
                  let thumbnail = NSImage(cgImage: cgImage, size: previewSize)
                  imageView.image = thumbnail
                  print("Successfully updated thumbnail for window: \(title)")
              } else {
                  print("Failed to create thumbnail for window: \(title)")
                  imageView.image = NSImage(named: "NSApplicationIcon")  // Fallback to default icon
              }

              // Store the windowRef directly in the imageView's tag property
              imageView.tag = unsafeBitCast(windowRef, to: Int.self)

              self.imageViewToWindowRef[imageView] = windowRef

              imageView.onMouseUp = { [weak self] in
                  self?.handleImageViewClick(imageView)
              }

              window.makeFirstResponder(imageView)
              print("Added click handler for window: \(title)")
          }

      }
    private func handleImageViewClick(_ sender: NSImageView) {
        print("Image view clicked")

        // Retrieve the windowRef from the dictionary
        guard let windowRef = imageViewToWindowRef[sender] else {
            print("No windowRef found for the clicked image view")
            return
        }

        // Bring the window to the foreground
        let error = AXUIElementPerformAction(windowRef, kAXRaiseAction as CFString)
        if error != .success {
            print("Failed to perform AXRaiseAction: \(error)")
        }

        // Activate the application
        if let app = runningApplicationsDict[currentDockItemName ?? ""] {
            app.activate(options: .activateIgnoringOtherApps)
        }
     }

    func hideAllPreviews() {
        for previewWindow in previewWindows {
            previewWindow.orderOut(nil)
        }
        previewWindows.removeAll()
        currentAppWindows.removeAll()
        imageViewToWindowRef.removeAll()
        print("All previews hidden")
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
                       isHoveringOverAnyDockItem = true
                       if lastHoveredDockItem != itemName {
                           print("Mouse entered dock item: \(itemName). Listing windows...")
                           hideAllPreviews()  // Hide previous previews before showing new ones
                           let windows = getWindows(for: app)
                           print("Found \(windows.count) windows for \(itemName)")
                           displayWindowPreviews(windows: windows, atPosition: itemPosition, size: itemSize)
                           lastHoveredDockItem = itemName
                           currentDockItemName = itemName  // Update currentDockItemName here
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

        isHoveringOverAnyDockItem = false  // Reset at the start of each cycle
        isHoveringOverAnyDockItemPreview = false

        if let lastApp = runningApps.last {
            let appElement = AXUIElementCreateApplication(lastApp.processIdentifier)
            if let dockChildren = subelementsFromElement(appElement, forAttribute: kAXChildrenAttribute as String) {
                for dockItem in dockChildren {
                    processDockItemsRecursively(from: dockItem)
                }
            }
        }

        _ = checkIfMouseIsOverPreviewWindows()
        // If we're not hovering over any dock item OR a preview, hide the previews
        if !isHoveringOverAnyDockItem && !isHoveringOverAnyDockItemPreview {
            hideAllPreviews()
            lastHoveredDockItem = nil
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


let app = NSApplication.shared

func main() {
    print("quack duck")
//    PermissionsService.acquireAccessibilityPrivileges()


    
    let helper = AccessibilityHelper()
    helper.processAllDockItems()
    
    helper.logMouseLocationContinuously()

    // Ensure the application is set up to receive events
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)

    // Create a window to keep the application running
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "Accessibility Helper"
    window.makeKeyAndOrderFront(nil)

    NSApplication.shared.run()}

main()
