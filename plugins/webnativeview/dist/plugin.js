// Web fallback stub. On iOS the native SangTacWebNativeViewPlugin registers
// under the jsName "WebNativeView".
const { registerPlugin } = require('@capacitor/core')

module.exports = registerPlugin('WebNativeView')
