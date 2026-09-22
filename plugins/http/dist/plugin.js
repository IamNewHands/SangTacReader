// Web fallback stub. On iOS the native SangTacHttpPlugin registers under the
// jsName "Http", which is what the site's frontend talks to.
const { registerPlugin } = require('@capacitor/core')

module.exports = registerPlugin('Http')
