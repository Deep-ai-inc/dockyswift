import Foundation
import ApplicationServices
import Cocoa

let kAXWindowIDAttribute: CFString = "AXWindowID" as CFString

import Foundation
import ApplicationServices
import Cocoa


class AccessibilityHelper {
    private var runningApplicationsDict: [String: NSRunningApplication]
    private var previewWindows: [NSWindow] = []
    private var currentAppWindows: [(title: String, windowRef: AXUIElement, windowID: CGWindowID?)] = []
    private var currentDockItemName: String?
    private var isHoveringOverDockItem = false
    private var lastHoveredDockItem: String?
      private var isHoveringOverAnyDockItem = false

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
                                        styleMask: [.borderless, .titled],
                                        backing: .buffered,
                                        defer: false)
           previewWindow.title = "Preview - \(title)"
           previewWindow.level = .screenSaver  // Highest level to ensure visibility
           previewWindow.isOpaque = true
           previewWindow.backgroundColor = NSColor.systemRed  // Bright red for high visibility
           previewWindow.hasShadow = true

           let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handlePreviewClick(_:)))
           previewWindow.contentView?.addGestureRecognizer(clickGesture)

           // Add a label to the window for easier identification
           let label = NSTextField(frame: NSRect(x: 10, y: previewSize.height - 30, width: previewSize.width - 20, height: 20))
           label.stringValue = title
           label.isEditable = false
           label.isBezeled = false
           label.drawsBackground = false
           label.textColor = NSColor.white
           previewWindow.contentView?.addSubview(label)

           print("Created preview window for '\(title)' with size: \(previewSize)")

           return previewWindow
       }
    
    private func updatePreviewContent(window: NSWindow, title: String, windowRef: AXUIElement, windowID: CGWindowID?, previewSize: CGSize) {
           guard let windowID = windowID else {
               print("No valid window ID for window: \(title)")
               return
           }

           let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])

           DispatchQueue.main.async {
               if let imageView = window.contentView?.subviews.first as? NSImageView {
                   if let cgImage = cgImage {
                       let thumbnail = NSImage(cgImage: cgImage, size: previewSize)
                       imageView.image = thumbnail
                       print("Successfully updated thumbnail for window: \(title)")
                   } else {
                       print("Failed to create thumbnail for window: \(title)")
                       imageView.image = NSImage(named: "NSApplicationIcon")  // Fallback to default icon
                   }
               } else {
                   let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height))
                   if let cgImage = cgImage {
                       let thumbnail = NSImage(cgImage: cgImage, size: previewSize)
                       imageView.image = thumbnail
                       print("Successfully created thumbnail for window: \(title)")
                   } else {
                       print("Failed to create thumbnail for window: \(title)")
                       imageView.image = NSImage(named: "NSApplicationIcon")  // Fallback to default icon
                   }
                   window.contentView?.addSubview(imageView)
               }
           }
       }

       @objc private func handlePreviewClick(_ gestureRecognizer: NSClickGestureRecognizer) {
           guard let clickedWindow = gestureRecognizer.view?.window,
                 let index = previewWindows.firstIndex(of: clickedWindow),
                 index < currentAppWindows.count else {
               return
           }

           let (_, windowRef, _) = currentAppWindows[index]
           
           // Bring the window to the foreground
           AXUIElementPerformAction(windowRef, kAXRaiseAction as CFString)
           
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

        if let lastApp = runningApps.last {
            let appElement = AXUIElementCreateApplication(lastApp.processIdentifier)
            if let dockChildren = subelementsFromElement(appElement, forAttribute: kAXChildrenAttribute as String) {
                for dockItem in dockChildren {
                    processDockItemsRecursively(from: dockItem)
                }
            }
        }

        // If we're not hovering over any dock item, hide the previews
        if !isHoveringOverAnyDockItem {
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
    print("Hello, World!")
    PermissionsService.acquireAccessibilityPrivileges()

    let helper = AccessibilityHelper()
    helper.processAllDockItems()
    
    helper.logMouseLocationContinuously()

    app.run()
}

main()
