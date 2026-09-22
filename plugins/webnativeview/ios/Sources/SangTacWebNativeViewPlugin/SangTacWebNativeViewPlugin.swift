import Foundation
import Capacitor
import WebKit

/**
 SangTacWebNativeViewPlugin — offline stub for the APK's custom
 `com.sangtacviet.capacitorwebnative.WebNativeViewPlugin`.

 Why a stub: the original is a *Java reflection* bridge. The site's JS
 (app.v2.js, `AndroidView` wrapper around line 8360) does things like

     AndroidView.create("android.webkit.WebView")
     AndroidView.createHandler("android.view.View$OnScrollChangeListener",
                               "onScrollChange", "onwebviewscrollchanged")

 i.e. it instantiates Android classes by name and mirrors the rendered native
 view into a bitmap that the page shows as an `<img>` (lock / unlock / setSize /
 getViewData). Those class names do not exist on iOS, so a 1:1 port is
 impossible; a faithful iOS version must map the specific classes the site asks
 for onto WKWebView equivalents.

 Which feature needs it: only the comic / image viewer
 (`app.surf.comic`, call sites around app.v2.js:5974 and 6413). The novel text
 reader does NOT go through this plugin.

 This stub registers the plugin under the correct jsName so the frontend's calls
 resolve instead of throwing, and reports no reflected methods. Consequence:
 the comic module is degraded until a WKWebView-backed implementation lands.
 */
@objc(SangTacWebNativeViewPlugin)
public class SangTacWebNativeViewPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "SangTacWebNativeViewPlugin"
    public let jsName = "WebNativeView"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "createView", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "createObject", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "createHandler", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "invoke", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "invokeObject", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getViewData", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBuffer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "lock", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unlock", returnType: CAPPluginReturnPromise)
    ]

    private var nextId = 1

    private func allocate() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    @objc func createView(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? ""
        CAPLog.print("[SangTacWNV] createView(\(name)) — unsupported on iOS, returning inert view")
        call.resolve(["viewId": allocate(), "methods": []])
    }

    @objc func createObject(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? ""
        CAPLog.print("[SangTacWNV] createObject(\(name)) — unsupported on iOS")
        call.resolve(["viewId": allocate(), "methods": []])
    }

    @objc func createHandler(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? ""
        CAPLog.print("[SangTacWNV] createHandler(\(name)) — unsupported on iOS")
        call.resolve(["viewId": allocate(), "methods": []])
    }

    @objc func invoke(_ call: CAPPluginCall) {
        call.resolve(["return": NSNull()])
    }

    @objc func invokeObject(_ call: CAPPluginCall) {
        call.resolve(["return": NSNull()])
    }

    @objc func getViewData(_ call: CAPPluginCall) {
        call.resolve(["width": 0, "height": 0, "data": "[]"])
    }

    @objc func getBuffer(_ call: CAPPluginCall) {
        call.reject("WebNativeView.getBuffer is not implemented on iOS")
    }

    @objc func setSize(_ call: CAPPluginCall) { call.resolve() }
    @objc func lock(_ call: CAPPluginCall) { call.resolve() }
    @objc func unlock(_ call: CAPPluginCall) { call.resolve() }
}
