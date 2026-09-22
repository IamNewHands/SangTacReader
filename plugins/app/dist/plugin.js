// Web fallback stub. On iOS the native SangTacAppPlugin registers under the
// jsName "App".
const { registerPlugin } = require('@capacitor/core')

module.exports = registerPlugin('App')
