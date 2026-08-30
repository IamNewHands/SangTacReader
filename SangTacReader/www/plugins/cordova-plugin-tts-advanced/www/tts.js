cordova.define("cordova-plugin-tts-advanced.tts", function(require, exports, module) { 
/*

    Cordova Text-to-Speech Plugin
    https://github.com/vilic/cordova-plugin-tts

    by VILIC VANE
    https://github.com/vilic

    MIT License

*/

exports.speak = function (text) {
  return new Promise(function (resolve, reject) {
    var options = {};

    if (typeof text == "string") {
      options.text = text;
    } else {
      options = text;
    }

    cordova.exec(resolve, reject, "TTS", "speak", [options]);
  });
};
exports.speakToFile = function (text) {
  return new Promise(function (resolve, reject) {
    var options = {};

    if (typeof text == "string") {
      options.text = text;
    } else {
      options = text;
    }

    cordova.exec(resolve, reject, "TTS", "speakToFile", [options]);
  });
};
exports.stop = function () {
  return new Promise(function (resolve, reject) {
    cordova.exec(resolve, reject, "TTS", "stop", []);
  });
};

exports.checkLanguage = function () {
  return new Promise(function (resolve, reject) {
    cordova.exec(resolve, reject, "TTS", "checkLanguage", []);
  });
};

exports.getVoices = function () {
  return new Promise(function (resolve, reject) {
    cordova.exec(resolve, reject, "TTS", "getVoices", []);
  });
};

exports.getEngines = function () {
  return new Promise(function (resolve, reject) {
    cordova.exec(resolve, reject, "TTS", "getEngines", []);
  });
};

exports.setEngine = function (engine) {
  return new Promise(function (resolve, reject) {
    var options = {};

    if (typeof engine == "string") {
      options.packageName = engine;
    } else {
      options = engine;
    }
    cordova.exec(resolve, reject, "TTS", "setEngine", [options]);
  });
};

exports.updateMediaSession = function (options) {
  return new Promise(function (resolve, reject) {
    cordova.exec(resolve, reject, "TTS", "updateMediaSession", [options]);
  });
}
exports.stopMediaSession = function () {
  return new Promise(function (resolve, reject) {
    cordova.exec(resolve, reject, "TTS", "stopMediaSession", []);
  });
}

exports.openInstallTts = function () {
  return new Promise(function (resolve, reject) {
    cordova.exec(resolve, reject, "TTS", "openInstallTts", []);
  });
};
});