function _typeof(obj) { "@babel/helpers - typeof"; return _typeof = "function" == typeof Symbol && "symbol" == typeof Symbol.iterator ? function (obj) { return typeof obj; } : function (obj) { return obj && "function" == typeof Symbol && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }, _typeof(obj); }
function _instanceof(left, right) { if (right != null && typeof Symbol !== "undefined" && right[Symbol.hasInstance]) { return !!right[Symbol.hasInstance](left); } else { return left instanceof right; } }
function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, _toPropertyKey(descriptor.key), descriptor); } }
function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); Object.defineProperty(Constructor, "prototype", { writable: false }); return Constructor; }
function _toPropertyKey(arg) { var key = _toPrimitive(arg, "string"); return _typeof(key) === "symbol" ? key : String(key); }
function _toPrimitive(input, hint) { if (_typeof(input) !== "object" || input === null) return input; var prim = input[Symbol.toPrimitive]; if (prim !== undefined) { var res = prim.call(input, hint || "default"); if (_typeof(res) !== "object") return res; throw new TypeError("@@toPrimitive must return a primitive value."); } return (hint === "string" ? String : Number)(input); }
function _classCallCheck(instance, Constructor) { if (!_instanceof(instance, Constructor)) { throw new TypeError("Cannot call a class as a function"); } }
var WebEq = /*#__PURE__*/function () {
  "use strict";

  var _proto = WebEq.prototype;
  _proto.createAlter = function createAlter(freq) {
    var alter = this.audioCtx.createBiquadFilter();
    alter.type = "peaking";
    alter.frequency.value = freq;
    alter.gain.value = 0;
    return alter;
  };
  _proto.applyAlter = function applyAlter() {
    for (var i = 0; i < this.fregAlter.length - 1; i++) {
      this.fregAlter[i].connect(this.fregAlter[i + 1]);
    }
    this.fregAlter[this.fregAlter.length - 1].connect(this.gainNode);
  };
  _proto.setAudio = function (buffer, onEnd, rate){
    var b = this.audioCtx.createBufferSource();
    b.buffer = buffer;
    //b.connect(this.fregAlter[0]);
    b.connect(this.destination);
    b.onended = onEnd || this.onEnded;
    b.playbackRate.value = rate || 1;
    if(rate != 1){
        this.recalcDetune(b);
    }
    this.currentMedia = b;
    b.start();
    return b;
  }
  _proto.recalcDetune = function (media){
    var md = media || this.currentMedia;
    var rate = md.playbackRate.value;
    if(md.detune){
    //    md.detune.value = - (Math.log(rate) / Math.LN2 * 1200);
    }
    
  }
  _proto.stop = function (){
    if(this.currentMedia){
        try{
            this.currentMedia.onended = function(){};
            this.currentMedia.stop();
        }catch(e){}
    }
  }
  _proto.resume = function (){
    if(this.currentMedia){
        this.setAudio(this.currentMedia.buffer, null, this.currentMedia.playbackRate.value);
    }
  }
  function WebEq(audio) {
    _classCallCheck(this, WebEq);
    this.audio = null;
    this.destination = null;
    this.source = null;
    this.audioCtx = null;
    this.fregAlter = [];
    this.minGain = -20;
    this.maxGain = 20;
    this.audio = audio;
    this.audioCtx = new (window.AudioContext || window.webkitAudioContext)({
        "sampleRate": 48000,
        "latencyHint": "playback"
    });
    this.destination = this.audioCtx.destination;
    this.fregAlter = [this.createAlter(60), this.createAlter(170), this.createAlter(310), this.createAlter(600), this.createAlter(1000), this.createAlter(3000), this.createAlter(6000), this.createAlter(12000), this.createAlter(14000), this.createAlter(16000)];
    this.source = this.audioCtx.createMediaElementSource(this.audio);
    this.gainNode = this.audioCtx.createGain();
    this.gainNode.gain.value = 1.1;
    this.gainNode.connect(this.destination);
    this.applyAlter();
    this.source.connect(this.fregAlter[0]);
  }
  _proto.setGain = function setGain(freq, gain) {
    for (var i = 0; i < this.fregAlter.length; i++) {
      if (this.fregAlter[i].frequency.value == freq) {
        this.fregAlter[i].gain.value = gain;
        break;
      }
    }
  };
  _proto.getGain = function getGain(freq) {
    for (var i = 0; i < this.fregAlter.length; i++) {
      if (this.fregAlter[i].frequency.value == freq) {
        return this.fregAlter[i].gain.value;
      }
    }
  };
  _proto.reset = function reset() {
    for (var i = 0; i < this.fregAlter.length; i++) {
      this.fregAlter[i].gain.value = 0;
    }
  };
  _proto.setGainMulti = function setGainMulti(obj) {
    for (var i = 0; i < this.fregAlter.length; i++) {
      if (obj[this.fregAlter[i].frequency.value]) {
        this.fregAlter[i].gain.value = obj[this.fregAlter[i].frequency.value];
      }
    }
  };
  _proto.changeAudio = function changeAudio(audio) {
    if (this.source) {
      this.source.disconnect();
    }
    this.audio = audio;
    this.source = this.audioCtx.createMediaElementSource(this.audio);
    this.source.connect(this.fregAlter[0]);
  };
  _proto.render = function render() {
    var _this = this;
    var div = document.createElement("div");
    var table = document.createElement("table");
    var tr = document.createElement("tr");
    var th = document.createElement("th");
    th.innerHTML = "Tần số";
    tr.appendChild(th);
    th = document.createElement("th");
    th.innerHTML = "Giá trị";
    tr.appendChild(th);
    table.appendChild(tr);
    var _loop = function _loop(i) {
      tr = document.createElement("tr");
      var td = document.createElement("td");
      td.innerHTML = _this.fregAlter[i].frequency.value;
      tr.appendChild(td);
      td = document.createElement("td");
      var input = document.createElement("input");
      input.type = "range";
      input.min = _this.minGain;
      input.max = _this.maxGain;
      input.value = _this.fregAlter[i].gain.value;
      input.oninput = function (e) {
        _this.setGain(_this.fregAlter[i].frequency.value, e.target.value);
      };
      td.appendChild(input);
      tr.appendChild(td);
      table.appendChild(tr);
    };
    for (var i = 0; i < this.fregAlter.length; i++) {
      _loop(i);
    }
    div.appendChild(table);
    return div;
  };
  WebEq.openAudioFile = function openAudioFile() {
    return new Promise(function (resolve, reject) {
      var input = document.createElement("input");
      input.type = "file";
      input.accept = "audio/*";
      input.onchange = function (e) {
        var file = e.target.files[0];
        var audio = document.createElement("audio");
        audio.src = URL.createObjectURL(file);
        audio.onloadedmetadata = function () {
          resolve(audio);
        };
      };
      input.click();
    });
  };
  return _createClass(WebEq);
}();
class TtsProvider {
    constructor(options) {
        this.options = options || {};
        this.props = {
            voice: {
                type: 'string',
                default: 'en-US_AllisonVoice',
                description: 'The voice to use for the TTS.',
            },
            rate: {
                type: 'number',
                default: 1,
                description: 'The rate at which to speak the text.',
            },
            pitch: {
                type: 'number',
                default: 1,
                description: 'The pitch at which to speak the text.',
            },
            volume: {
                type: 'number',
                default: 1,
                description: 'The volume at which to speak the text.',
            },
            language: {
                type: 'string',
                default: 'en-US',
                description: 'The language to use for the TTS.',
            },
        };
    }
    speak(text) {
        console.log(text);
    }
    async getVoices() {
        return [];
    }
    async sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }
    async getMp3File(path){
        var maxTime = 10;
        var time = 0;
        while(time < maxTime){
            time++;
            var response = await fetch(path);
            if(response.status == 200){
                return response.blob();
            }
            await this.sleep(200);
        }
    }
    checkConfig() {
        for(var name in this.props) {
            if(this.props[name].required && !this.options[name]) {
                return "Thiếu giá trị: " + this.props[name].description;
            }
        }
        return null;
    }
    async getVoiceByName(name) {
        return await this.getVoices().then(voices => voices.find(voice => voice.name === name));
    }
}

function serializeQuery(obj) {
    var a = [];
    for (var key in obj) {
        if (obj.hasOwnProperty(key)) {
            a.push(encodeURIComponent(key) + "=" + encodeURIComponent(obj[key]));
        }
    }
    return a.join("&");
}

class VbeeTts extends TtsProvider {
    constructor(options) {
        super(options);
        this.options = options || {};
        this.props = {
            voice: {
                type: 'string',
                default: 'HN - Ngọc Huyền',
                description: 'Giọng đọc.',
            },
            rate: {
                type: 'number',
                default: 1,
                description: 'Tốc độ đọc.',
            },
            apiKey: {
                type: "string",
                default: "",
                required: true,
                description: "API key của VBee."
            },
            appId: {
                type: "string",
                default: "",
                required: true,
                description: "App id của VBee."
            }
        };
        this.url = "https://vbee.vn/api/v1/tts";
    }
    async speak(text, options) {
    }
    async getVoices(){
        return [
            {name: "HN - Ngọc Huyền", value: "hn_female_ngochuyen_full_48k-fhg", gender: 1},
            {name:"HN - Phú Thăng",value:"hn_male_phuthang_news65dt_44k-fhg", gender: 0},
            {name:"HN - Mạnh Dũng",value:"hn_male_manhdung_news_48k-fhg", gender: 0},
            {name:"HN - Thanh Long",value:"hn_male_thanhlong_talk_48k-fhg", gender: 0},
            {name:"HN - Mai Phương",value:"hn_female_maiphuong_vdts_48k-fhg", gender: 1},
            {name:"SG - Tường Vy",value:"sg_female_tuongvy_call_44k-fhg", gender: 1},
            {name:"SG - Lan Trinh",value:"sg_female_lantrinh_vdts_48k-fhg", gender: 1},
            {name:"SG - Trung Kiên",value:"sg_male_trungkien_vdts_48k-fhg", gender: 0},
            {name:"SG - Minh Hoàng",value:"sg_male_minhhoang_full_48k-fhg", gender: 1},
            {name:"SG - Thảo Trinh",value:"sg_female_thaotrinh_full_48k-fhg", gender: 1},
            {name:"Huế - Duy Phương",value:"hue_male_duyphuong_full_48k-fhg", gender: 0},
            {name:"Huế - Hương Giang",value:"hue_female_huonggiang_full_48k-fhg", gender: 1},
        ];
    }
}
class FptAiTts extends TtsProvider {
    constructor(options) {
        super(options);
        this.options = options || {};
        if(!this.options.apiKey) {
            //throw new Error("Thiếu giá trị: apiKey");
            this.options.apiKey = "";
        }
        if(!options.voice){
            this.options.voice = "banmai";
        }
        if(!options.rate){
            this.options.rate = 0;
        }
        this.props = {
            voice: {
                type: 'select',
                default: 'banmai',
                description: 'Giọng đọc',
            },
            rate: {
                type: 'number',
                default: 0,
                min: -3, max: 3,
                description: 'Tốc độ đọc (-3 đến +3)',
            },
            apiKey: {
                type: "string",
                default: "",
                required: true,
                description: "API key của Fpt.ai"
            },
        };
        this.url = "https://api.fpt.ai/hmi/tts/v5";
    }
    async speak(text, options) {
        this.checkConfig();
        if(options.rate){
            this.options.rate = options.rate;
        }
        if(options.voice){
            this.options.voice = options.voice;
        }
        var http = new XMLHttpRequest();
        http.open("POST", this.url, true);
        http.setRequestHeader("api-key", this.options.apiKey);
        http.setRequestHeader("voice", this.options.voice);
        http.setRequestHeader("speed", this.options.rate);
        var ref = this;
        return new Promise((resolve, reject) => {
            http.onreadystatechange = async function () {
                if (http.readyState == 4 && http.status == 200) {
                    var json = JSON.parse(http.responseText);
                    if(json.error == 0){
                        var path = json.async;
                        var blob = await ref.getMp3File(path);
                        resolve(blob);
                    }else{
                        reject(json.message);
                    }
                }
                if(http.readyState == 4 && http.status != 200){
                    reject(JSON.parse(http.responseText).message);
                }
            }
            http.onerror = function () {
                reject(http.responseText);
            }
            http.send(text);
        });
    }
    async getVoices(){
        return [
            {name: "Nữ miền Bắc", value: "banmai"},
            {name: "Nữ miền Nam",value:"lannhi"},
            {name: "Nam miền Bắc",value:"leminh"},
            {name: "Nữ miền Trung",value:"myan"},
            {name: "Nữ miền Bắc",value:"thuminh"},
            {name: "Nam miền Trung",value:"giahuy"},
            {name: "Nữ miền Nam",value:"linhsan"},
        ];
    }
}
class ViettelTts extends TtsProvider {
    
    constructor(options) {
        super(options);
        this.options = options;
        if(!this.options.tokenId) {
           // throw new Error("Thiếu giá trị: tokenId");
            this.options.tokenId = "";
        }
        if(!options.voice){
            this.options.voice = "hn-quynhanh";
        }
        if(!options.rate){
            this.options.rate = 1;
        }
        this.props = {
            voice: {
                type: 'select',
                default: 'hn-quynhanh',
                description: 'Giọng đọc',
            },
            rate: {
                type: 'float',
                default: 1,
                min: 0.7, max: 1.3,
                description: 'Tốc độ đọc (0.7 - 1.3)',
            },
            tokenId: {
                type: "string",
                default: "",
                required: true,
                description: "Token_id của viettelgroup.ai"
            },
        };
        this.url = "https://viettelgroup.ai/voice/api/tts/v1/rest/syn";
    }
    async speak(text, options) {
        this.checkConfig();
        if(options.rate){
            this.options.rate = options.rate;
        }
        if(options.voice){
            this.options.voice = options.voice;
        }
        var voice = this.options.voice;
        var random = Math.random().toString(36).substring(7);
        var param = {
            text: text,
            voice: voice,
            id: random,
            speed: this.options.rate,
            tts_return_option: 2,
            without_filter: true,
        };
        var postBody = JSON.stringify(param);
        var http = new XMLHttpRequest();
        http.open("POST", this.url, true);
        
        http.setRequestHeader("Content-Type", "application/json");
        http.setRequestHeader("token", this.options.tokenId);
        http.responseType = "blob";
        return new Promise((resolve, reject) => {
            http.onreadystatechange = async function () {
                if (http.readyState == 4 && http.status == 200) {
                    var blob = http.response;
                    resolve(blob);
                }
            }
            http.onerror = function () {
                reject(http.response);
            }
            http.send(postBody);
        });
    }
    async getVoices(){
        return [
            {name: "Nữ miền Bắc chất lượng cao", value: "hn-quynhanh"},
            {name: "Nữ miền Nam chất lượng cao",value:"hcm-diemmy"},
            {name: "Nữ miền Trung chất lượng cao",value:"hue-maingoc"},
            {name: "Nữ miền Bắc chất lượng cao",value:"hn-phuongtrang"},
            {name: "Nam miền Bắc",value:"hn-thanhtung"},
            {name: "Nam miền Trung",value:"hue-baoquoc"},
            {name: "Nam miền Nam",value:"hcm-minhquan"},
            {name: "Nữ miền Bắc",value:"trinhthiviettrinh"},
            {name: "Nữ miền Nam",value:"lethiyen"},
            {name: "Nữ miền Nam",value:"nguyenthithuyduyen"},
            {name: "Nam miền Bắc",value:"phamtienquan"},
        ];
    }
}
class ZaloTts extends TtsProvider {
    
    constructor(options) {
        super(options);
        this.options = options;
        if(!this.options.apiKey) {
            //throw new Error("Thiếu giá trị: apiKey");
            this.options.apiKey = "";
        }
        if(!options.voice){
            this.options.voice = "1";
        }
        if(!options.rate){
            this.options.rate = 1;
        }
        this.props = {
            voice: {
                type: 'select',
                default: '1',
                description: 'Giọng đọc',
            },
            rate: {
                type: 'float',
                default: 1,
                min: 0.8, max: 1.2,
                description: 'Tốc độ đọc (0.8 - 1.2)',
            },
            apiKey: {
                type: "string",
                default: "",
                required: true,
                description: "ApiKey của zalo"
            },
        };
        this.url = "https://api.zalo.ai/v1/tts/synthesize";
    }
    async speak(text, options) {
        this.checkConfig();
        if(options.rate){
            this.options.rate = options.rate;
        }
        if(options.voice){
            this.options.voice = options.voice;
        }
        var param = {
            input: text,
            speaker_id: this.options.voice,
            speed: this.options.rate,
            encode_type: 0,
        };
        var postBody = serializeQuery(param);
        var http = new XMLHttpRequest();
        http.open("POST", this.url, true);
        
        http.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
        http.setRequestHeader("apikey", this.options.apiKey);
        var ref = this;
        return new Promise((resolve, reject) => {
            http.onreadystatechange = async function () {
                if (http.readyState == 4 && http.status == 200) {
                    var json = JSON.parse(http.responseText);
                    if(json.error_code == 0){
                        await ref.sleep(50);
                        var blob = await ref.getMp3File(json.data.url);
                        resolve(blob);
                    }
                }
            }
            http.onerror = function () {
                reject(http.responseText);
            }
            http.send(postBody);
        });
    }
    async getVoices(){
        return [
            {name: "Nữ miền Bắc", value: "1"},
            {name: "Nữ miền Nam",value:"2"},
            {name: "Nam miền Bắc",value:"3"},
            {name: "Nam miền Nam",value:"4"},
        ];
    }
}
class BingTts extends TtsProvider {
    
    constructor(options) {
        super(options);
        this.options = options;
        if(!options.voice){
            this.options.voice = "0";
        }
        if(!options.rate){
            this.options.rate = 1;
        }
        if(!options.pitch){
            this.options.pitch = 1;
        }
        if(options.isClone){
            this.onEngineLoaded = this.cloneEngine;
        }
        this.props = {
            voice: {
                type: 'select',
                default: '0',
                description: 'Giọng đọc',
            },
            rate: {
                type: 'float',
                default: 1,
                min: 0.5, max: 5,
                description: 'Tốc độ đọc (0.5 - 5)',
            },
            pitch: {
                type: 'float',
                default: 1,
                min: 0.5, max: 3,
                description: 'Cao giọng (0.5 - 2)',
            }
        };
        this.isScriptLoaded = false;
        this.loadScript();

    }
    async cloneEngine(){
        await this.waitForScriptLoaded();
        // var baseObj = bingTtsEngine;
        // var newObj = {};
        // for(var key in baseObj){
        //     newObj[key] = baseObj[key];
        // }
        this.engine = new BingTtsEngine();
    }
    loadScript(){
        var ref = this;
        ui.scriptmanager.load("/bingtts.js?v=13", () => {
            ref.isScriptLoaded = true;
            ref.onEngineLoaded && ref.onEngineLoaded();
        });
    }
    async waitForScriptLoaded(){
        var ref = this;
        return new Promise((resolve, reject) => {
            var check = function(){
                if(ref.isScriptLoaded){
                    ref.engine = new BingTtsEngine();
                    resolve();
                }
                else{
                    setTimeout(check, 100);
                }
            }
            check();
        });
    }
    async time4out(i){
        return new Promise(function(rs){
            //console.log("tts request timeout");
            setTimeout(rs, i, "timeout");
        });
    }
    async speak(text, options, rt = 0) {
        await this.waitForScriptLoaded();
        this.checkConfig();
        text = text.replace(/\d+/, match => {
            return convertNumberToVietnameseText(match);
        });
        text = fixBlankText(text);
        if(options.rate){
            this.options.rate = options.rate;
        }
        if(options.voice){
            this.options.voice = options.voice;
        }
        if(options.pitch){
            this.options.pitch = options.pitch;
        }
        var param = {
            voiceId: this.options.voice,
            rate: this.options.rate,
            pitch: (this.options.pitch - 1) * 100,
        };
        if( this.engine.cache && 
            this.engine.cache._audioStreamer && 
            this.engine.cache._audioStreamer._connection && 
            this.engine.cache._audioStreamer._connection.readyState == 3){
            // await this.engine.speak("", { voiceId: "0"});
            await this.cloneEngine();
        }
        var fi = await Promise.race([this.time4out(3000), this.engine.speak(text, param)]);
        if(fi == "timeout" && rt < 4){
            await this.cloneEngine();
            return this.speak(text, options, rt+1);
        }
        return fi;
    }
    async getVoices(){
        return [
            {name: "Hoài My", value: "0", gender: 1},
            {name: "Nam Anh", value: "1", gender: 0},
            {name: "Diễn cảm Nam-1", value: "2", gender: 0},
            {name: "Diễn cảm Nữ-2", value: "3", gender: 1},
            {name: "Diễn cảm Nam-3", value: "4", gender: 0},
            {name: "Diễn cảm Nữ-4", value: "5", gender: 1},
            {name: "Diễn cảm Nữ-5", value: "6", gender: 1},
            {name: "Diễn cảm Nam-6", value: "7", gender: 0},
            {name: "Diễn cảm Nữ-7", value: "8", gender: 1},
            {name: "Diễn cảm Nam-8", value: "9", gender: 0},
        ];
    }
}
class AndroidTts extends TtsProvider {
    constructor(options) {
        super(options);
        this.options = options;
        this.props = {
            engine: {
                type: 'select',
                default: 'com.google.android.tts',
                description: 'Nguồn cấp',
            },
            voice: {
                type: 'select',
                default: 'vi-VN-language',
                description: 'Giọng đọc',
            },
            rate: {
                type: 'float',
                default: 1,
                min: 0.5, max: 5,
                description: 'Tốc độ đọc',
            },
            pitch: {
                type: 'float',
                default: 1,
                min: 0.5, max: 3,
                description: 'Độ cao giọng',
            },
        };
        this.initEngine = "com.google.android.tts";
        if(!options.voice){
            this.options.voice = "vi-VN-language";
        }
        if(!options.rate){
            this.options.rate = 1;
        }
        if(options.engine){
            this.options.engine = options.engine;
            TTS.setEngine && TTS.setEngine(options.engine);
            this.initEngine = options.engine;
        } else {
            this.options.engine = this.initEngine;
        }
    }
    
    async speak(text, options) {
        this.checkConfig();
        if(options.rate){
            this.options.rate = options.rate;
        }
        if(options.voice){
            this.options.voice = options.voice;
        }
        if(options.engine && options.engine != this.initEngine){
            this.options.engine = options.engine;
            TTS.setEngine && TTS.setEngine(options.engine);
            this.initEngine = options.engine;
            await this.sleep(1000); // wait for engine to load
        }
        var param = {
            text: text,
            identifier: this.options.voice,
            rate: this.options.rate,
            pitch: this.options.pitch,
        };
        var arrayBuffer = await TTS.speakToFile(param);
        return new Blob([arrayBuffer], {type: 'audio/wav'});
    }
    async getVoices(){
        var num = 0;
        var genderMapping = {
            "vi-vn-x-gft-network": "Nữ",
            "vi-vn-x-vie-network": "Nữ",
            "vi-vn-x-vid-local": "Nam",
            "vi-vn-x-vic-local": "Nữ",
            "vi-vn-x-gft-local": "Nữ",
            "vi-vn-x-vie-local": "Nữ",
            "vi-vn-x-vif-network": "Nam",
            "vi-vn-x-vif-local": "Nam",
            "vi-vn-x-vid-network": "Nam",
            "vi-vn-x-vic-network": "Nữ",
        }
        return (await TTS.getVoices()).filter(e=>e.language.match(/vi|vn/i)).map(e=>{
            var id = e.identifier;
            var isNetwork = id.match(/network/i);
            num++;
            var ret = {name: `Giọng ${num} (${isNetwork?"Online":"Offline"})`, value: e.identifier};
            if(genderMapping[e.identifier]){
                var gender = genderMapping[e.identifier];
                if(gender == "Nam"){
                    ret.gender = 0;
                }else{
                    ret.gender = 1;
                }
            }
            return ret;
        });
    }
    async getEngines(){
        return await TTS.getEngines();
    }
}
class SangtacvietTts extends TtsProvider {
    constructor(options) {
        super(options);
        this.options = options;
        if(!options.voice){
            this.options.voice = "voice-1";
        }
        if(!options.rate){
            this.options.rate = 1.5;
        }
        this.props = {
            voice: {
                type: 'select',
                default: 'voice-1',
                description: 'Giọng đọc',
            },
            rate: {
                type: 'float',
                default: 1.5,
                min: 0.5, max: 5,
                description: 'Tốc độ đọc',
            },
        };
    }
    
    async speak(text, options, retry = 0) {
        if(retry > 3){
            throw new Error("Không thể tạo file mp3");
        }
        this.checkConfig();
        if(options.rate){
            this.options.rate = options.rate;
        }
        if(options.voice){
            this.options.voice = options.voice;
        }
        var param = {
            text: text,
            voice: this.options.voice,
            rate: this.options.rate,
        };
        var body = serializeQuery(param);
        var http = new XMLHttpRequest();
        var domain = window["STV_SERVER"] || "https://sangtacviet.vip";
        http.open("GET", domain+"/io/s1213/tts?"+body, true);
        http.responseType = "blob";
        var ref = this;
        return new Promise((resolve, reject) => {
            http.onreadystatechange = async function () {
                if (http.readyState == 4 && http.status == 200) {
                    var blob = http.response;
                    resolve(blob);
                }
                if(http.readyState == 4 && http.status == 502){
                    await ref.sleep(100);
                    retry++;
                    resolve(await ref.speak(text, options, retry));
                }
            }
            http.onerror = async function () {
                if(retry < 3){
                    retry++;
                    await ref.sleep(100);
                    resolve(await ref.speak(text, options, retry));
                    return;
                }
                var err = "Lỗi không xác định";
                try{
                    err = http.responseText; // catch unaccessible error
                }catch(e){}
                reject(err);
            }
            http.send();
        });
    }
    async getVoices(){
        return [
            {name: "Giọng Nam 1", value: "voice-1"}
        ];
    }
}
var ttsEngine = {
    randomizer: {
        voices: [],
        random: function(min, max) {
            return Math.floor(Math.random() * (max - min + 1)) + min;
        },
        getRandomMale: async function(){
            var provider = this.random(0,1);
            switch(provider){
                case 0:
                    return await AndroidTts.randomMaleVoice();
                case 1:
                    return await BingTts.randomMaleVoice();
            }
        },
        getRandomFemale: async function(){
            var provider = this.random(0,1);
            switch(provider){
                case 0:
                    return await AndroidTts.randomFemaleVoice();
                case 1:
                    return await BingTts.randomFemaleVoice();
            }
        },
        getRandomVoice: async function(female){
            if(female){
                return await this.getRandomFemale();
            }else{
                return await this.getRandomMale();
            }
        },
        addVoiceToPool: async function(female){
            var vc = await this.getRandomVoice(female);
            this.voices.push(vc);
        },
        playScript: {
            speaking: null,
            declare: null,
            speaker: {},
            clamation: {
                pitchModifier: +0,
                speedModifier: +0,
            },
            ask: {
                pitchModifier: +0,
                speedModifier: +0,
            },
        }
    },
    provider: null,
    webeq: null,
    createProvider: function (name,options) {
        switch (name) {
            case "google":
                this.provider = new AndroidTts(options);
                break;
            case "zalo":
                this.provider = new ZaloTts(options);
                break;
            case "fpt":
                this.provider = new FptAiTts(options);
                break;
            case "viettel":
                this.provider = new ViettelTts(options);
                break;
            case "bing":
                this.provider = new BingTts(options);
                break;
            case "stv":
                this.provider = new SangtacvietTts(options);
                break;
            default:
                throw new Error("Không tìm thấy provider");
        }
    },
    init: function (providerName, options, noEq) {
        this.createProvider(providerName,options);
        this.audio = new Audio();
        this.mdAudio = new Audio();
        // this.mdAudio.loop = true;
        // this.mdAudio.src = "/s1213tts.php?text=0123";
        // this.mdAudio.volume = 0;
        var ref = this;
        this.audio.addEventListener('ended', () => {
            ref.audio.currentTime = 0;
            ref.onSentenceEnd();
        });
        
        if(this.playbackSetting.volume){
            this.audio.volume = this.playbackSetting.volume;
        }
        this.webeq = new WebEq(true ? new Audio() : ref.audio);
        this.webeq.onEnded = () => {
            ref.onSentenceEnd();
        }
        //this.webeq = new WebEq(noEq ? new Audio() : ref.audio);
    },
    queue: [],
    bufferQueue: [],
    isSpeaking: false,
    isPaused: false,
    isStopped: false,
    audio: null,
    currentAudio: null,
    requestAudio: function (text, options, itemid) {
        this.queue.push({text: text, options: options, haveMp3: false, itemid: itemid});
        this.processQueue();
    },
    requestAudioInstant: async function (text, options, itemid, rtr = 0) {
        var speakItem = {text: text, options: options, haveMp3: false, itemid: itemid};
        try{
            var blob = await this.provider.speak(speakItem.text, speakItem.options);
            speakItem.haveMp3 = true;
            speakItem.audioBuffer = await this.decodeAudio(blob);
            speakItem.duration = speakItem.audioBuffer.duration;
            speakItem.blob = blob;
            return speakItem;
        }catch(e){
            if(e.toString().match(/decode audio/i)){
                if(this.provider instanceof BingTts){
                    this.provider.engine.reset();
                }
            }
            console.log(e);
            if (window.app) {
                app.debug.report(e, "TTS requestAudioInstant error");
            }
            rtr ++;
            if(rtr > 2){
                return null;
            }
            await this.sleep(1000);
            return this.requestAudioInstant(text, options, itemid, rtr);
        }
    },
    requestAndPlay: async function(text, options) {
        var audioItem = await this.requestAudioInstant(text, options);
        this.playWithEq(audioItem);
    },
    processQueue: async function () {
        if ( this.isSpeaking || this.isPaused || this.isStopped ) {
            return;
        }
        if (this.queue.length > 0) {
            for (var i = 0; i < this.queue.length; i++) {
                var item = this.queue[i];
                if (!item.haveMp3 && !item.isProcessing) {
                    item.isProcessing = true;
                    console.log("processing ", item.text);
                    var blob = await this.provider.speak(item.text, item.options).catch(e=>{
                        if(window.app){
                            window.app.toast(e);
                        }
                    });
                    if(!blob){
                        console.log("Không tìm thấy blob");
                        item.isProcessing = false;
                        return;
                    }
                    if(typeof blob == "string"){
                        console.log("Không tìm thấy blob");
                        item.isProcessing = false;
                        return;
                    }
                    item.blob = blob;
                    item.haveMp3 = true;
                    item.isProcessing = false;
                    item.audioBuffer = await this.decodeAudio(blob);
                    item.duration = item.audioBuffer.duration;
                    this.onBlobEnd(item);
                }
            }
        }
    },
    clearQueue: function () {
        this.queue = [];
        this.onSentenceEnd= function(){};
        this.onBlobEnd = function(){};
    },
    play: function (audioItem) {
        if(this.playbackSetting.rate == 1){
            return this.playWithEq(audioItem);
        }
        this.audio.pause();
        this.audio.currentTime = 0;
        var objUrl = null;
        try{
            //objUrl = URL.createObjectURL(blob);
            objUrl = URL.createObjectURL(audioItem.blob);
        }catch(e){
            console.log(e);
            console.log(audioItem.blob);
            throw e;
        }
        this.currentAudio = audioItem;
        if(!objUrl){
            return;
        }
        if(this.audio.src){
            try{
                URL.revokeObjectURL(this.audio.src);
            }catch(e){
                console.log(e);
            }
        }
        this.audio.src = objUrl;
        if(this.playbackSetting.rate){
            this.audio.playbackRate = this.playbackSetting.rate;
        }
        this.audio.play();
    },
    playWithEq: function(audioItem){
        this.webeq.stop();
        this.currentAudio = audioItem;
        if(this.playbackSetting.rate){
            this.playbackSetting.rate = 1;
            this.audio.playbackRate = 1; //this.playbackSetting.rate;
        }
        this.webeq.setAudio(audioItem.audioBuffer);
        this.audio.pause = function(){
            ttsEngine.webeq.stop();
        }
        this.audio.play = function(){
            ttsEngine.webeq.resume();
        }
        this.mdAudio.play();
    },
    pause: function(){

    },
    stop: function () {
        this.isStopped = true;
        this.audio.pause();
        this.audio.currentTime = 0;
        this.clearQueue();
        this.isStopped = false;
        this.webeq.stop();
    },
    onSentenceEnd: function () {},
    onBlobEnd: function () {},
    sleep: function (ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    },
    decodeAudio: async function (blob) {
        return this.webeq.audioCtx.decodeAudioData(await blob.arrayBuffer());
    },
    waitSingle: function () {
        var waitObject = {
            stillWaiting: true,
            resolveFunc: null,
            promise: null
        };
        this.wait().then(function(){
            if(waitObject.stillWaiting){
                waitObject.resolveFunc();
            }
        });
        waitObject.promise = new Promise(function(resolve){
            waitObject.resolveFunc = resolve;
        });
        return waitObject;
    },
    wait: async function (waitedTime) {
        if(!waitedTime){
            waitedTime = 0;
        }
        if(waitedTime > 10000){
            return "error";
        }
        if(!this.currentAudio){
            await this.sleep(100);
            return await this.wait(waitedTime + 100);
        }
        //var audioBuffer = await this.decodeAudio(this.currentAudio.blob);
        console.log(this.currentAudio);
        var duration = this.currentAudio.duration;
        console.log("audioBuffer.duration: " + duration + "s");
        // if(this.audio.paused){
        //     await this.sleep(100);
        //     if(this.audio.paused){
        //         return await this.wait(waitedTime + 100);
        //     }
        // }
        
        // dispose audio buffer
        
        //audioBuffer = null;
        if(this.playbackSetting.delay != 0){
            if(this.playbackSetting.delay < 0 && duration > 0.5 && isFinite(duration)){
                
                var sleepms = ((duration / this.audio.playbackRate) + this.playbackSetting.delay) * 1000;
                console.log(sleepms);
                console.log(duration, this.audio.playbackRate, this.playbackSetting.delay)
                if(sleepms < 0){
                    console.log("sleepms < 0");
                    console.log(duration, this.audio.playbackRate, this.playbackSetting.delay)
                }
                return this.sleep(sleepms);
            }
            if(this.playbackSetting.delay > 0){
                return new Promise((resolve, reject) => {
                    ttsEngine.onSentenceEnd = async function () {
                        await ttsEngine.sleep(this.playbackSetting.delay * 1000);
                        resolve();
                    }
                });
            }
        }
        return new Promise((resolve, reject) => {
            ttsEngine.onSentenceEnd = function () {
                resolve();
            }
        });
    },
    getFirstItem: async function () {
        console.log("in queue",this.queue.length);
        if(this.queue.length < 1){
            return null;
        }
        if(this.queue[0].haveMp3){
            return this.queue.shift();
        }
        else {
            while(!this.queue[0].haveMp3){
                await this.sleep(100);
            }
            return this.queue.shift();
        }
    },
    onFirstLoad: function(calb){
        this.onBlobEnd = function(){
            this.onBlobEnd = function(){}
            calb();
        }
    },
    playbackSetting:{
        rate: 1,
        delay: 0,
        volume: 1,
    },
    playbackProps: {
        rate: {
            type: 'float',
            default: 1,
            min: 0.3, max: 5,
            description: 'Tốc độ phát lại',
        },
        volume: {
            type: 'float',
            default: 1,
            min: 0, max: 1,
            description: 'Âm lượng (0 - 1)',
        },
        delay: {
            type: 'float',
            default: 0,
            min: -1, max: 1,
            description: 'Ngừng giữa các câu (-1s - 1s)',
        },
    },
    isPlaying: function(){
        return !this.audio.paused;
    },
    tokenize: function(text){
        return text.split(/[.!?]/).filter(e=>e.trim() != "");
    }
}

function convertNumberToVietnameseText(number) {
    const viNumbers = ['', 'một', 'hai', 'ba', 'bốn', 'năm', 'sáu', 'bảy', 'tám', 'chín'];
    const viTens = ['', 'mười', 'hai mươi', 'ba mươi', 'bốn mươi', 'năm mươi', 'sáu mươi', 'bảy mươi', 'tám mươi', 'chín mươi'];
    const viTeens = ['mười', 'mười một', 'mười hai', 'mười ba', 'mười bốn', 'mười lăm', 'mười sáu', 'mười bảy', 'mười tám', 'mười chín'];
    const viLargeUnits = ['', 'nghìn', 'triệu', 'tỷ', 'nghìn tỷ', 'triệu tỷ', 'tỷ tỷ'];

    if (number === 0) {
        return 'không';
    }

    let result = '';
    let unitIndex = 0;

    while (number > 0) {
        const chunk = number % 1000;
        if (chunk > 0) {
            const chunkText = convertChunkToVietnameseText(chunk, viNumbers, viTens, viTeens);
            const largeUnitText = viLargeUnits[unitIndex];

            if (result !== '') {
                result = chunkText + ' ' + largeUnitText + ' ' + result;
            } else {
                result = chunkText + ' ' + largeUnitText;
            }
        }

        unitIndex++;
        number = Math.floor(number / 1000);
    }

    return result.trim().replace(/mươi linh/g, "mươi").replace(/mươi năm/g, "mươi lăm");
}

function convertChunkToVietnameseText(chunk, viNumbers, viTens, viTeens) {
    let chunkText = '';

    const hundredsDigit = Math.floor(chunk / 100);
    const tensDigit = Math.floor((chunk % 100) / 10);
    const unitDigit = chunk % 10;

    if (hundredsDigit > 0) {
        chunkText += viNumbers[hundredsDigit] + ' trăm ';
        if (tensDigit === 0 && unitDigit > 0) {
            chunkText += 'linh ';
        }
    }

    if (tensDigit > 0) {
        if (tensDigit === 1) {
            chunkText += viTeens[unitDigit];
        } else {
            chunkText += viTens[tensDigit] + ' ';
        }
    }

    if (tensDigit !== 1 && unitDigit > 0) {
        chunkText += viNumbers[unitDigit];
    }

    return chunkText.trim();
}

function fixBlankText(text){
    var haveSpeakableWord = text.match(/[a-zA-Z0-9]/);
    if(!haveSpeakableWord){
        var map = {
            ".": "chấm",
            ",": "phẩy",
            "?": "hỏi",
            "!": "chấm than",
            ":": "hai chấm",
            ";": "chấm phẩy",
            "(": "mở ngoặc",
            ")": "đóng ngoặc",
            "[": "mở ngoặc vuông",
            "]": "đóng ngoặc vuông",
            "{": "mở ngoặc nhọn",
            "}": "đóng ngoặc nhọn",
            "-": "gạch ngang",
            "_": "gạch dưới",
            "+": "cộng",
            "=": "bằng",
            "*": "nhân",
            "/": "chia",
            "%": "phần trăm",
            "<": "nhỏ hơn",
            ">": "lớn hơn",
            "~": "ngã",
            "`": "gạch chéo",
            "|": "gạch đứng",
            "°": "độ",
            "$": "đô la",
            "€": "euro",
            "£": "bảng anh",
            "#": "thăng",
            "@": "a còng",
            "^": "mũ",
            "&": "và",
        }
        var newText = "";
        for(var i = 0; i < text.length; i++){
            var c = text[i];
            if(map[c]){
                newText += map[c] + " ";
            }else{
                newText += c;
            }
        }
        return newText;
    }
    return text;
}