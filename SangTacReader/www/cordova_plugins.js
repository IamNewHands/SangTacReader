
  cordova.define('cordova/plugin_list', function(require, exports, module) {
    module.exports = [
      {
          "id": "cordova-plugin-fullscreen.AndroidFullScreen",
          "file": "plugins/cordova-plugin-fullscreen/www/AndroidFullScreen.js",
          "pluginId": "cordova-plugin-fullscreen",
        "clobbers": [
          "AndroidFullScreen"
        ]
        },
      {
          "id": "cordova-plugin-nativeclicksound.nativeclick",
          "file": "plugins/cordova-plugin-nativeclicksound/www/nativeclick.js",
          "pluginId": "cordova-plugin-nativeclicksound",
        "clobbers": [
          "nativeclick"
        ]
        },
      {
          "id": "cordova-plugin-tts-advanced.tts",
          "file": "plugins/cordova-plugin-tts-advanced/www/tts.js",
          "pluginId": "cordova-plugin-tts-advanced",
        "clobbers": [
          "TTS"
        ]
        }
    ];
    module.exports.metadata =
    // TOP OF METADATA
    {
      "cordova-plugin-fullscreen": "1.3.0",
      "cordova-plugin-nativeclicksound": "0.0.4",
      "cordova-plugin-tts-advanced": "0.5.2",
      "cordova-plugin-vibration": "3.1.1"
    };
    // BOTTOM OF METADATA
    });
    