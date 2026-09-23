var STV_SERVER = "https://sangtacviet.app";
var defaultBookCover = "https://static.sangtacvietcdn.xyz/img/bookcover256.jpg";
function checkDomainAlive(dm){
	var xhr = new XMLHttpRequest();
	xhr.open("GET", dm + "/warp.php", true);
	xhr.send();
	xhr.onload = function(){
		if(xhr.status == 200){
			if(xhr.responseText.match(/working|yes|no/)){
				STV_SERVER = dm;
			}
		}
	}
}
const isCachedFrontend = window.hasOwnProperty("Capacitor");
function evalValue(value){
	var tempv = eval(value);
	if(typeof tempv == "undefined" || tempv == null){
		return false;
	}
	return tempv.toString();
}
function printStackTrace() {
	var err = new Error();
	console.log(err.stack);
}
function bigIntCompare(a, b) {
	// compare 2 string number
	if(a.length != b.length){
		return a.length < b.length;
	}
	for(var i = 0; i < a.length; i++){
		if(a[i] != b[i]){
			return a[i] < b[i];
		}
	}
	return false;
}
function setTimeoutOnce(key, callback, time){
	if(window[key]){
		clearTimeout(window[key]);
	}
	window[key] = setTimeout(callback, time);
}
if(window.BigInt){
	bigIntCompare = function(a, b) {
		return BigInt(a) < BigInt(b);
	}
}
if(!window.IntersectionObserver){
	window.IntersectionObserver = function(callback){
		this.callback = callback;
		this.observe = function(node){}
		this.unobserve = function(node){}
		this.disconnect = function(){}
	}
}
const onDbLoad = {
    isLoaded: false,
    event: [],
    addEventListener: function (callback){
        this.event.push(callback);
    },
    onDbLoad: function (){
		if(this.isLoaded){
			return;
		}
		console.log("db loaded");
		printStackTrace();
        this.event.forEach(function (callback){
            callback();
        });
        this.isLoaded = true;
    },
    waitForLoad: async function (){
        if(this.isLoaded){
            return;
        }
        return new Promise((resolve, reject) => {
            this.addEventListener(function (){
                resolve();
            });
        });
    }
}
function getSafariVersion() {
	var ua = navigator.userAgent;
	var match = ua.match(/Version\/(\d+).(\d+)/);
	if (match) {
		return {
			major: match[1],
			minor: match[2]
		};
	}
	match = ua.match(/CPU .*?OS (\d+)_(\d+)/);
	if (match) {
		return {
			major: match[1],
			minor: match[2]
		};
	}
	return {
		major: 0,
		minor: 0
	}; // For compatibility
}
function randomNodeId() {
	return "node-" + Math.random().toString(36).substr(2, 9);
}
function fullUrl(url){
	if(url.startsWith("http")){
		return url;
	}
	var baseDomain = window.location.origin;
	if(origin.contain("local")){
		baseDomain = STV_SERVER;
	}
	if (!app.net.networkManagerXHR.isDomainAlive(baseDomain)) {
		baseDomain = app.net.networkManagerXHR.bestDomain();
	}
	if (app.config && app.config.ux && app.config.ux.app_domain) {
		var preferedDomain = app.config.ux.app_domain;
		if (preferedDomain != "auto" && baseDomain != preferedDomain) {
			baseDomain = app.net.networkManagerXHR.bestDomain();
		}
	}
	var r = baseDomain + url;
	r = r.replace("/?","/index.php?");
	return r;
}
function getlastread(host,id){
	var record = app.history.get(host,id);
	if(record){
		return record.chapter;
	}
	return 0;
}
function timeElapsed(time, suffix, short){
	if(!time){ return " ";}
	var btime = time;
	if(time.indexOf("GMT") <= 0 && time.indexOf("UTC") <= 0 && time.indexOf("Z") <= 0){
		time = time + " GMT+0700";
	}
	var timedifsec=(new Date().getTime()-new Date(time).getTime())/1000;
	if(!timedifsec){
		return btime;
	}
	var word = short ? 
		["w","d","h","m","s"," " + app.text.just_in_time] : 
		[
			app.text.last_week,
			app.text.last_day,
			app.text.last_hour,
			app.text.last_minute,
			app.text.last_second,
			app.text.just_in_time
		];
	var prepend = short ? "" : " "; // add space before word
	if(!timedifsec){
		return time;
	}
	var timedif={
		second:Math.floor(timedifsec)
		,minute:Math.floor(timedifsec/60)
		,hour:Math.floor(timedifsec/3600)
		,day:Math.floor(timedifsec/86400)
		,week:Math.floor(timedifsec/604800)
	}
	if(!suffix){
		return timedif;
	}else{
		if(timedif.week>0){
			return timedif.week+prepend+word[0];
		}else
		if(timedif.day>0){
			return timedif.day+prepend+word[1];
		}else
		if(timedif.hour>0){
			return timedif.hour+prepend+word[2];
		}else 
		if(timedif.minute>0){
			return timedif.minute+prepend+word[3];
		}else
		if(timedif.second < 1){
			return word[5];
		} else return timedif.second+prepend+word[4];
	}
}
function currentTime(){
	var t = new Date();
	return t.getHours()+":"+t.getMinutes().toString().padStart(2,"0");
}
function formatError(mes, o){
	if(o.status){
		return `${mes}(${o.status})`;
	}
	return mes;
}
function getCookie(cname) {
	var name = cname + "=";
	var ca = document.cookie.split(';');
	for (var i = 0; i < ca.length; i++) {
		try {
			var c = decodeURIComponent(ca[i]);
			while (c.charAt(0) == ' ') {
				c = c.substring(1);
			}
			if (c.indexOf(name) == 0) {
				return c.substring(name.length, c.length);
			}
		} catch(e) {
			console.log('Cookie error: '+ca[i]);
		}
	}
	return "";
}
function syncCookie(){
	try {
		Capacitor.Plugins.App.SyncCookie();
	} catch(e) {}
}
function setCookie(name,value,days) {
    var expires = "";
    if (days) {
        var date = new Date();
        date.setTime(date.getTime() + (days*24*60*60*1000));
        expires = "; expires=" + date.toUTCString();
    }
    document.cookie = name + "=" + (value || "")  + expires + "; path=/";
	syncCookie();
}
function isFullscreen(){
	if (!document.webkitIsFullScreen && !document.mozFullScreen && !document.msFullscreenElement)
	{
		return false;
	}
	return true;
}
function sleepAllList(){
	q("div[view=booklist], div[view=bookgrid]").forEach(function(v) {
		if(v.sleep)v.sleep();
	});
}
function wakeAllList(){
	q("div[view=booklist], div[view=bookgrid]").forEach(function(v) {
		if(v.wake)v.wake();
	});
}
function wakeAllNode(nodes){
	nodes.forEach(function(v) {
		if(v.wake)v.wake();
	});
}
function decryptAes(encrypted, key, iv) {
	encrypted = CryptoJS.enc.Base64.parse(encrypted);
	key = CryptoJS.enc.Utf8.parse(key);
	iv = CryptoJS.enc.Utf8.parse(iv);
	var decrypted = CryptoJS.AES.decrypt({ciphertext: encrypted}, key, {iv: iv});
	return decrypted.toString(CryptoJS.enc.Utf8);
}
async function getChapterListOnline(host,id,force){
	var chapterList = [];
	var url = '/index.php?ngmar=chapterlist&h='+host+'&bookid='+id+'&sajax=getchapterlist';
	if(force) url += '&force=true';
	return app.net.get(url).then(async function(x){
		if(x.code == 1){
			if(x.enckey){
				eval(atob(x.enckey));
			}
			if(x.oridata && app.language != "vi"){
				x.data = x.oridata;
				if(app.language != "zh"){
					x.data = await translateWithGoogle(x.data, "zh", app.language);
				}
			}
			var list = x.data.trim().split('-//-');
			if(host == "uukanshu") list.reverse();
			if(!x.unlocked)x.unlocked = {};
			for(var i=0;i<list.length;i++){
				var chapinfo = list[i].split('-/-');
				var chap = {
					cid: chapinfo[1],
					title: chapinfo[2],
				};
				if(chap.cid in x.unlocked || chapinfo[3] == "unvip"){
					chap.unvip = true;
				}else if(chapinfo[3] == "vip"){
					chap.vip = true;
				}
				chapterList.push(chap);
			}
			return chapterList;
		}
		else{
			return [];
		}
	}).catch(function(e){
		console.log(e);
		return [];
	});
}
async function getChapterList(host,id,force){
	var cacheKey = `chapterList_${host}_${id}`;
	if(app.platform.haveNetwork){
		var clist = await getChapterListOnline(host,id,force);
		if(clist.length > 0){
			app.storage.cache.set(cacheKey,JSON.stringify(clist));
			return clist;
		}
	}
	var chapterList = await app.storage.cache.getCacheOrPersist(cacheKey);
	if(!chapterList){
		return [];
	}
	return JSON.parse(chapterList);
	
}
async function getChapterListCache(host,id){
	var cacheKey = `chapterList_${host}_${id}`;
	var chapterList = await app.storage.cache.getCacheOrPersist(cacheKey);
	if(!chapterList){
		return await getChapterList(host,id,false);
	}
	return JSON.parse(chapterList);
}
function arrToObj(arr){
	var obj = {};
	for(var i=0;i<arr.length;i++){
		obj[arr[i]] = true;
	}
	return obj;
}
async function getchapterlist(host,id,force,container, touchOffset = 90, compare = true){
	var preloader = app.createPreloader("Đang tải...");
	container.appendChild(preloader);
	var list = await getChapterList(host,id,force);
	container.removeChild(preloader);
	if(list.length == 0){
		container.appendChild(app.createNodata("Không thể tải danh sách chương!"))
		return;
	}
	var lastread = getlastread(host,id);
	var scrollOffset = 0;
	var obs = createFrameObserver(container);
	var p = container.parentElement;
	//p.style.height = "auto";
	var createPart = function(){
		var part = document.createElement("div");
		var partContent = document.createElement("div");
		part.appendChild(partContent);
		container.appendChild(part);
		app.applySleepWake(part, obs);
		partContent.className = "clistpart";
		return partContent;
	}
	var elecount = 0;
	var maxPerPart = 50;
	var currentPart = createPart();
	var offsetFromTop = 0;
	var isCompareBigInt = false;
	var lastreadNum = parseInt(lastread);
	if(lastread.toString().length > 8){
		isCompareBigInt = true;
	}
	var offlineBook = null;
	var downloadedList = {};
	if(app.offlineBook.isBookExist(host,id)){
		offlineBook = app.offlineBook.getExistedBook({
			host: host,
			id: id
		});
		if(offlineBook){
			downloadedList = arrToObj(await offlineBook.getChapterDownloadedWithOldBug());
		}
	}
	for(var i=0; i < list.length; i++){
		var chap = list[i];
		var cid = chap.cid;
		var r = document.createElement('div');
		
		if(i>2900){
			r.textContent = (chap.title || "").replace(/([\t\n]+|<br>|&nbsp;)/g,"").replace(/Thứ ([\d\,]+) chương/i,"Chương $1:")
			.replace(/^(.+)Chương/i, "Chương $1");
		}else{
			r.textContent = (chap.title || "").replace(/([\t\n]+|<br>|&nbsp;)/g,"").replace(/Thứ ([\d\,]+) chương/,"Chương $1:");
		}
		if(compare){
			if(isCompareBigInt){
				if(bigIntCompare(cid, lastread)){
					r.classList.add("chapreaded");
				}
			}else{
				if(parseInt(cid) < lastreadNum) r.classList.add("chapreaded");
			}
		}
		if(cid == lastread){
			r.classList.add("chaplastreaded");
			scrollOffset = 40 * (i-5);
		}
		r.setAttribute("cid", cid);
		if(chap.unvip){
			r.classList.add("unvip");
		}
		if(chap.vip){
			r.classList.add("vip");
		}
		if(cid in downloadedList){
			r.classList.add("downloaded");
		}
		//container.appendChild(r);
		currentPart.appendChild(r);
		elecount++;
		if(elecount >= maxPerPart){
			currentPart.parentElement.style.height = (elecount*40)+"px";
			currentPart.parentElement.setAttribute("offset", offsetFromTop);
			offsetFromTop+=elecount*40;
			currentPart = createPart();
			elecount = 0;
		}
	}
	currentPart.parentElement.style.height = (elecount*40)+"px";
	currentPart.parentElement.setAttribute("offset", offsetFromTop);
	p.style.height = p.scrollHeight;
	container.style.height = p.scrollHeight;
	container.style.width = p.scrollWidth;
	container.style.position = "absolute";
	var divheight = p.scrollHeight - 40;
	var scrollheight = 40 * list.length + 40  - p.scrollHeight;
	container.scrollheight = scrollheight;
	container.divheight = divheight;
	if(list.length > 50){
		var animatingScroller = false;
		var containerBounds = container.getBoundingClientRect();
		var clamp = function(y){
			if(y < containerBounds.top + 20){
				return 20;
			}
			if(y > containerBounds.bottom - 20){
				return containerBounds.height - 20;
			}
			return y - containerBounds.top;
		}
		if(p.q(".dragbar").style.display!="inline-block"){
			p.q(".dragbar").style.display = "inline-block";
			var tmove = function(e){
				//var percent = (e.touches[0].clientY - 93) / container.divheight;
				var percent = (clamp(e.touches[0].clientY) - 20) / container.divheight;
				var offset = percent * container.scrollheight;
				offset =40 * Math.round(offset/40);
				animatingScroller = true;
				container.scrollTo(0,offset);
				// if(e.touches[0].clientY - touchOffset >= 0 && e.touches[0].clientY - touchOffset <= container.divheight){
				// 	p.q(".dragbar").style.top = (e.touches[0].clientY - touchOffset) + "px";
				// }
				p.q(".dragbar").style.top = (percent * container.divheight) + "px";
				setTimeoutOnce("chapterlist_scroller",function(){
					animatingScroller = false;
				}, 100);
				e.stopPropagation();
				e.preventDefault();
			};
			p.q(".dragbar").addEventListener("touchstart", function(e){
				e.stopPropagation();
				p.addEventListener("touchmove", tmove);
			});
			p.addEventListener("touchend", function(e){
				p.removeEventListener("touchmove", tmove);
			});
			p.q(".navbtn").addEventListener("click",function(){
				gsap.to(p, {scrollTop:scrollOffset, duration:0.5});
			});
			container.addEventListener("scroll", function(e){
				if(!animatingScroller){
					var percent = container.scrollTop / container.scrollheight;
					var offset = percent * container.divheight;
					p.q(".dragbar").style.top = offset + "px";
				}
			});
		}
	}
	setTimeout(function(){
		container.scrollTo(0,scrollOffset);
		var percent = scrollOffset / container.scrollheight;
		var offset = percent * container.divheight;
		p.q(".dragbar").style.top = (offset + 20) + "px";
		if(offset+20 > container.divheight){
			p.q(".dragbar").style.top = (container.divheight) + "px";
		}
	},50);
}
var keys = {37: 1, 38: 1, 39: 1, 40: 1};

function preventDefault(e) {
  e.preventDefault();
}

function preventDefaultForScrollKeys(e) {
  if (keys[e.keyCode]) {
    preventDefault(e);
    return false;
  }
}
var supportsPassive = false;
try {
  window.addEventListener("test", null, Object.defineProperty({}, 'passive', {
    get: function () { supportsPassive = true; } 
  }));
} catch(e) {}

var wheelOpt = supportsPassive ? { passive: false } : false;
var wheelEvent = 'onwheel' in document.createElement('div') ? 'wheel' : 'mousewheel';

function disableScroll() {
  window.addEventListener('DOMMouseScroll', preventDefault, false); // older FF
  window.addEventListener(wheelEvent, preventDefault, wheelOpt); // modern desktop
  window.addEventListener('touchmove', preventDefault, wheelOpt); // mobile
  window.addEventListener('keydown', preventDefaultForScrollKeys, false);
}
function enableScroll() {
  window.removeEventListener('DOMMouseScroll', preventDefault, false);
  window.removeEventListener(wheelEvent, preventDefault, wheelOpt); 
  window.removeEventListener('touchmove', preventDefault, wheelOpt);
  window.removeEventListener('keydown', preventDefaultForScrollKeys, false);
}
function isIos(){
	return navigator.userAgent.match(/iPhone|iPad|iPod/i);
}
function isAndroid(){
	return navigator.userAgent.match(/Android/i);
}
(function(app){
	app.storage = app.storage || {};
	var Capacitor = window.Capacitor;
	if(Capacitor && Capacitor.Plugins.Preferences){
		var prefs = Capacitor.Plugins.Preferences;
		app.storage.get = async function(key){
			return await prefs.get({
				key: key
			}).value;
		}
		app.storage.set = async function(key, value){
			return await prefs.set({
				key: key,
				value: value
			});
		}
		app.storage.keys = async function(){
			return await prefs.keys();
		}
	}else{
		app.storage.get = async function(key){
			return localStorage.getItem(key);
		}
		app.storage.set = async function(key, value){
			return localStorage.setItem(key, value);
		}
		app.storage.keys = async function(){
			return Object.keys(localStorage);
		}
	}
	app.storage.getItem = function(key){
		return localStorage.getItem(key);
	};
	app.storage.setItem = function(key, value){
		return localStorage.setItem(key, value);
	};
	app.storage.cache = {
		get: async function(key){
			return await app.storage.get(key);
		},
		set: async function(key, value){
			return await app.storage.set(key, value);
		},
		getFile: async function(key){
			return await app.storage.get(key);
		},
		setFile: async function(key, value){
			return await app.storage.set(key, value);
		},
		getCacheOrPersist: async function(key){
			return await app.storage.get(key);
		},
		deleteFile: async function(key){
			return await app.storage.set(key, null);
		}
	};
	if(Capacitor && Capacitor.Plugins.CapacitorSQLite){
		ui.scriptmanager.load("/asset/app.v2.db.js?v2", function(){
			app.storage.cache = {
				get: async function(key){
					return await getCache(key);
				},
				set: async function(key, value){
					return await setCache(key, value);
				},
				getFile: async function(key){
					return await getFile(key);
				},
				setFile: async function(key, value){
					return await setFile(key, value);
				},
				getCacheOrPersist: async function(key){
					return await getCacheOrPersist(key);
				},
				deleteFile: async function(key){
					return await deleteFile(key);
				}
			}
		}, !isCachedFrontend);
	}else{
		onDbLoad.onDbLoad();
	}
})(app);
app.toast = function(msg){
	console.log(msg);
	app.context.info(msg, true);
};
//app.objectStore
(function(app){
	app.objectStore = function(key){
		this.key = key;
		this.type = "array";
		this.active = null;
		this.load =async function(){
			var k = this.key;
			var that = this;
			await onDbLoad.waitForLoad();
			return app.storage.cache.getFile(k).then(async function(data){
				if(data){
					that.data = JSON.parse(data);
					await app.storage.cache.getFile("active_"+k).then(function(active){
						that.active = that.data[parseInt(active)];
						if(!that.active){
							that.active = that.data[0];
						}
					});
					return that.data;
				}else{
					return null;
				}
			});
		}
		this.save = async function(){
			var t = this;
			var k = this.key;
			await onDbLoad.waitForLoad();
			return app.storage.cache.setFile(k, JSON.stringify(t.data)).then(async function(){
				var i = t.data.indexOf(t.active);
				return app.storage.cache.setFile("active_"+k, "" + i);
				
			});
		}
		this.add = function(item){
			this.data.push(item);
			this.active = item;
		}
		this.prepend = function(item){
			this.data.unshift(item);
			this.active = item;
		}
		this.remove = function(item){
			var index = this.data.indexOf(item);
			if(index > -1){
				this.data.splice(index, 1);
			}
			if(this.active == item){
				this.active = null;
			}
		}
		this.clear = function(){
			this.data = [];
			this.active = null;
		}
		this.get = function(key){
			return this.data[key];
		}
		this.set = function(key, value){
			this.data[key] = value;
		}
		return this;
	}
})(app);

(function(app){

	function isDomainMatchOrigin(url){
		var u = new URL(url);
		var isStvDomain = app.net.networkManagerXHR.isStvDomain(u.origin);
		if(isStvDomain){
			return u.origin == window.location.origin;
		}
		return true;
	}

	app.net = app.net || {};
	app.net.get = async function(url,force,retry) {
		url = fullUrl(url);
		if(!retry) retry = 0;
		return new Promise(function(resolve, reject) {
			if (app.net.getCapacitor && (!isDomainMatchOrigin(url) || (retry == 0 && !app.net.networkManagerXHR.isStvDomainAndAlive(url)))) {
				app.net.getCapacitor(url).then(resolve).catch(async function(e) {
					if (retry < 3) {
						retry++;
						try {
							resolve(await app.net.get(url, force, retry));
						} catch (e) {
							reject(e);
						}
					} else {
						reject(e);
					}
				});
				return;
			}
			var http = new XMLHttpRequest();
			http.open("GET", url);
			http.setRequestHeader("x-stv-transport", "web");
			http.onreadystatechange = async function() {
				if (http.readyState == 4 && http.status == 200) {
					try {
						var data = JSON.parse(http.responseText);
						resolve(data);
					} catch (e) {
						resolve(http.responseText);
					}
				}
				if (http.readyState == 4 && http.status == 502) {
					if (retry < 3) {
						retry++;
						try{
							resolve(await app.net.get(url,force, retry));
						}catch(e){
							reject(e);
						}
					} else {
						reject(http.responseText);
					}
				}
				//console.log(http.readyState, http.status);
			}
			http.onerror = function(e) {
				if(force){
					resolve({code:-1, message: e, status: http.status});
				}else{
					reject({code:-1, message: e, status: http.status});
				}
			}
			http.send();
		});
	};
	app.net.debugInfo = {
		format: function(){
			return `Last URL: ${this.lastUrl}\nHTTP Client: ${this.httpClient}\nLast Response: ${JSON.stringify(this.lastResponse)}`;
		}
	}
	app.net.post = async function(url, data, retry) {
		if(!retry) retry = 0;
		url = fullUrl(url);
		return new Promise(function(resolve, reject) {
			if (app.net.postCapacitor && (
				!isDomainMatchOrigin(url) || 
				(retry == 0 && !app.net.networkManagerXHR.isStvDomainAndAlive(url))
			)) {
				app.net.postCapacitor(url, data).then((a)=>{
					app.net.debugInfo.lastUrl = url;
					app.net.debugInfo.lastResponse = app.net.debugInfo.capacitorResponse;
					app.net.debugInfo.httpClient = "native";
					resolve(a);
				}).catch(async function(e) {
					if (retry < 3) {
						retry++;
						try {
							resolve(await app.net.post(url, data, retry));
						} catch (e) {
							reject(e);
						}
					} else {
						reject(e);
					}
				});
				return;
			}
			if(navigator.onLine == false){
				reject("offline");
				return;
			}
			var http = new XMLHttpRequest();
			http.open("POST", url)
			if (typeof data == "object") {
				data = JSON.stringify(data);
				http.setRequestHeader("Content-Type", "application/json");
			} else {
				http.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
			}
			http.onreadystatechange = async function() {
				if (http.readyState == 4 && http.status == 200) {
					app.net.debugInfo.lastUrl = url;
					app.net.debugInfo.lastResponse = {
						headers: http.getAllResponseHeaders(),
						body: http.responseText,
					}
					app.net.debugInfo.httpClient = "cronet";
					try {
						var data2 = JSON.parse(http.responseText);
						resolve(data2);
					} catch (error) {
						resolve(http.responseText);
					}
				}
				if (http.readyState == 4 && http.status == 502) {
					if (retry < 3) {
						retry++;
						try{
							let r = await app.net.post(url, data, retry);
							resolve(r);
						}catch(e){
							reject(e);
						}
					} else {
						reject(http.responseText);
					}
				}
			}
			http.send(data);
		});
	};
	app.net.getCache = async function(url) {
		var cache = await app.storage.cache.get(url);
		if (cache) {
			try {
				var j = JSON.parse(cache);
				return j;
			} catch (e) {
				return cache;
			}
		}
		var tocache = await app.net.get(url);
		// not string or number
		if (typeof tocache != "string" && typeof tocache != "number") {
			await app.storage.cache.set(url, JSON.stringify(tocache));
		} else {
			await app.storage.cache.set(url, tocache);
		}
		return tocache;
	}
	app.net.postCache = async function(url, data) {
		var cache = await app.storage.cache.get(url);
		if (cache) {
			try {
				var j = JSON.parse(cache);
				return j;
			} catch (e) {
				return cache;
			}
		}
		var tocache = await app.net.post(url, data);
		if (typeof tocache != "string" && typeof tocache != "number") {
			await app.storage.cache.set(url, JSON.stringify(tocache));
		} else {
			await app.storage.cache.set(url, tocache);
		}
		return tocache;
	}
	app.net.getCacheLater = async function(url) {
		try{
			var tocache = await app.net.get(url);
			if (typeof tocache != "string" && typeof tocache != "number") {
				await app.storage.cache.set(url, JSON.stringify(tocache));
			} else {
				await app.storage.cache.set(url, tocache);
			}
			return tocache;
		}catch(e){
			var cache = await app.storage.cache.get(url);
			if (cache) {
				try {
					var j = JSON.parse(cache);
					return j;
				} catch (e) {
					return cache;
				}
			}else{
				return null;
			}
		}
	}

	

	var networkManager = {
		domains: [], // {name: string, status: string, ping: number, lastCheck: number}
		verifyDomain: async function(domain) {
			var result = {
				name: domain,
				status: "unknown",
				ping: 0,
				lastCheck: Date.now()
			};
			if (window.Capacitor && Capacitor.Plugins.Http) {
				try {
					var response = await Capacitor.Plugins.Http.get({
						url: domain + "/warp.php",
						timeout: 5000,
						headers: {
							"x-stv-transport": "web",
							"x-requested-with": "com.sangtacviet.mobilereader",
							"User-Agent": navigator.userAgent,
							ipv6: false
						}
					});
					if (response.status >= 200 && response.status < 300) {
						result.status = "alive";
						result.ping = Date.now() - result.lastCheck;
					} else {
						result.status = "dead";
						result.ping = -1;
					}
				} catch (error) {
					if (error.message.includes("timeout")) {
						result.status = "dead";
						result.ping = -1;
					} else {
						result.status = "dead";
						result.ping = -1;
					}
				}
				result.checkedWith = "okhttp";
				return result;
			}
			return result; // Fallback for non-Capacitor environments
		},
		defaultDomains: ["https://sangtacviet.com", "https://dns1.stv-appdomain-00000001.org", "https://sangtacviet.app"],
		bestDomain: function() {
			if (this.domains.length == 0) {
				return this.defaultDomains[0];
			}
			if (app.config && app.config.ux && app.config.ux.app_domain) {
				var preferedDomain = app.config.ux.app_domain;
				var prefered = this.domains.find(d => d.name == preferedDomain && d.status == "alive");
				if (prefered) {
					return preferedDomain; // Prefer this domain if alive
				}
			}
			var best = this.domains[0];
			for (var i = 1; i < this.domains.length; i++) {
				var domain = this.domains[i];
				if (domain.status == "alive" && (best.status != "alive" || domain.ping < best.ping)) {
					best = domain;
				}
			}
			if (best.status == "alive") {
				return best.name;
			} else {
				return this.defaultDomains[0];
			}
		},
		checkDomains: async function() {
			var promises = [];
			var ref = this;
			for(var domain of this.defaultDomains){
				promises.push(this.verifyDomain(domain).then(result => {
					var existing = ref.domains.find(d => d.name === result.name);
					if (existing) {
						existing.status = result.status;
						existing.ping = result.ping;
						existing.lastCheck = result.lastCheck;
					} else {
						ref.domains.push(result);
					}
				}).catch(error => {
					console.error("Error checking domain " + domain + ": " + error);
					var existing = ref.domains.find(d => d.name === domain);
					if (existing) {
						existing.status = "dead";
						existing.ping = -1;
						existing.lastCheck = Date.now();
					} else {
						ref.domains.push({
							name: domain,
							status: "dead",
							ping: -1,
							lastCheck: Date.now()
						});
					}
				}));
			}
			await Promise.all(promises); // Wait for all domain checks to complete
		},
	};
	networkManager.checkDomains();
	app.net.networkManager = networkManager;
	var networkManagerXHR = {
		domains: [{
			name: "https://sangtacviet.app",
			status: "alive",
			ping: 100,
			lastCheck: Date.now()
		}], // {name: string, status: string, ping: number, lastCheck: number}
		verifyDomain: async function(domain) {
			var result = {
				name: domain,
				status: "unknown",
				ping: 0,
				lastCheck: Date.now()
			};
			var xhr = new XMLHttpRequest();
			xhr.open("GET", domain + "/warp.php", true);
			xhr.timeout = 5000;
			result.checkedWith = "xhr";
			xhr.setRequestHeader("x-stv-transport", "web");
			return new Promise((resolve, reject) => {
				xhr.onload = function() {
					if (xhr.status >= 200 && xhr.status < 300) {
						result.status = "alive";
						result.ping = Date.now() - result.lastCheck;
					} else {
						result.status = "dead";
						result.ping = -1;
					}
					resolve(result);
				};
				xhr.onerror = function() {	
					result.status = "dead";
					result.ping = -1;
					resolve(result);
				};
				xhr.ontimeout = function() {
					result.status = "timeout";
					result.ping = -1;
					resolve(result);
				};
				xhr.send();
			});
		},
		defaultDomains: ["https://dns1.stv-appdomain-00000001.org", "https://sangtacviet.com", "https://sangtacviet.app"],
		bestDomain: function() {
			if (this.domains.length == 0) {
				return this.defaultDomains[0];
			}
			if (app.config && app.config.ux && app.config.ux.app_domain) {
				var preferedDomain = app.config.ux.app_domain;
				var prefered = this.domains.find(d => d.name == preferedDomain && d.status == "alive");
				if (prefered) {
					return preferedDomain; // Prefer this domain if alive
				}
			}
			var best = this.domains[0];
			for (var i = 1; i < this.domains.length; i++) {
				var domain = this.domains[i];
				if (domain.status == "alive" && (best.status != "alive" || domain.ping < best.ping)) {
					best = domain;
				}
			}
			if (best.status == "alive") {
				return best.name;
			} else {
				return this.defaultDomains[0];
			}
		},
		checkDomains: async function() {
			var promises = [];
			var ref = this;
			this.domains = []; // Clear existing domains before checking
			for(var domain of this.defaultDomains){
				promises.push(this.verifyDomain(domain).then(result => {
					var existing = ref.domains.find(d => d.name === result.name);
					if (existing) {
						existing.status = result.status;
						existing.ping = result.ping;
						existing.lastCheck = result.lastCheck;
					} else {
						ref.domains.push(result);
					}
				}).catch(error => {
					console.error("Error checking domain " + domain + ": " + error);
					var existing = ref.domains.find(d => d.name === domain);
					if (existing) {
						existing.status = "dead";
						existing.ping = -1;
						existing.lastCheck = Date.now();
					} else {
						ref.domains.push({
							name: domain,
							status: "dead",
							ping: -1,
							lastCheck: Date.now()
						});
					}
				}));
			}
			await Promise.all(promises); // Wait for all domain checks to complete
		},
		isDomainAlive: function(domain) {
			var existing = this.domains.find(d => d.name === domain);
			if (existing) {
				return existing.status === "alive";
			}
			return false;
		},
		isStvDomainAndAlive: function(url) {
			var parsedUrl = new URL(url);
			var isStvDomain = this.defaultDomains.some(d => d.startsWith(parsedUrl.origin));
			if (isStvDomain) {
				return this.isDomainAlive(parsedUrl.origin);
			}
		},
		isStvDomain: function(url) {
			var parsedUrl = new URL(url);
			return this.defaultDomains.some(d => d.startsWith(parsedUrl.origin));
		}
	};
	app.net.evalCookie = function(headers) {
		if (headers) {
			for (var key in headers) {
				if (key.match(/set-cookie/i)) {
					var cookies = headers[key].split(', ');
					for (var cookie of cookies) {
						document.cookie = cookie; // Set each cookie
					}
				}
			}
		}
	}
	networkManagerXHR.checkDomains();
	app.net.networkManagerXHR = networkManagerXHR;
	try {
		navigator.connection.addEventListener('change', function() {
			networkManager.checkDomains();
			networkManagerXHR.checkDomains();
		});
	} catch (e) {
		console.warn("Network connection change event not supported: " + e);
	}
	if (window.Capacitor && Capacitor.Plugins.Http) {
		var httpPlugin = Capacitor.Plugins.Http;
		app.net.getCapacitor = async function(url) {
			var parsedUrl = new URL(url, window.location.origin);
			var useCookie = networkManager.defaultDomains.indexOf(parsedUrl.origin) >= 0;
			if (useCookie) {
				url = networkManager.bestDomain() + parsedUrl.pathname + parsedUrl.search;
			}
			var headers = {
				"x-stv-transport": "app",
				"x-requested-with": "com.sangtacviet.mobilereader",
				"User-Agent": navigator.userAgent,
				"Cookie": useCookie ? document.cookie : "",
				"Referer": document.referrer || window.location.href,
				"Origin": window.location.origin
			};

			try {
				var response = await httpPlugin.get({
					url: fullUrl(url),
					headers: headers,
					timeout: 10000,
					ipv6: false,
				});
				if (response.status >= 200 && response.status < 300) {
					var responseHeaders = response.headers || {};
					for (var key in responseHeaders) {
						if (useCookie && key.match(/set-cookie/i)) {
							var cookies = responseHeaders[key].split(', ');
							for (var cookie of cookies) {
								document.cookie = cookie; // Set each cookie
							}
						}
					}
					try {
						var data = JSON.parse(response.data);
						return data;
					} catch (e) {
						return response.data; // Return raw data if JSON parsing fails
					}
				}
				else {
					throw new Error("HTTP error: " + response.status);
				}
			} catch (error) {
				if (error.message.includes("timeout")) {
					throw new Error("Request timed out");
				} else {
					throw new Error("Network error: " + error.message);
				}
			}
		}
		app.net.postCapacitor = async function(url, data) {
			var parsedUrl = new URL(url, window.location.origin);
			var useCookie = networkManager.defaultDomains.indexOf(parsedUrl.origin) >= 0;
			if (useCookie) {
				url = networkManager.bestDomain() + parsedUrl.pathname + parsedUrl.search;
			}
			var headers = {
				"x-stv-transport": "app",
				"x-requested-with": "com.sangtacviet.mobilereader",
				"User-Agent": navigator.userAgent,
				"Cookie": useCookie ? document.cookie : "",
				"Referer": document.referrer || window.location.href,
				"Origin": window.location.origin
			};
			if (typeof data == "object") {
				data = JSON.stringify(data);
				headers["Content-Type"] = "application/json";
			} else {
				//data = parseQueryString(data);
				headers["Content-Type"] = "application/x-www-form-urlencoded";
			}
			try {
				var response = await httpPlugin.request({
					url: fullUrl(url),
					data: data,
					headers: headers,
					timeout: 10000,
					method: "POST",
					ipv6: false,
				});
				app.net.debugInfo.capacitorResponse = response;
				if (response.status >= 200 && response.status < 300) {
					var responseHeaders = response.headers || {};
					for (var key in responseHeaders) {
						if (useCookie && key.match(/set-cookie/i)) {
							var cookies = responseHeaders[key].split(', ');
							for (var cookie of cookies) {
								document.cookie = cookie; // Set each cookie
							}
						}
					}
					try {
						var data = JSON.parse(response.data);
						return data;
					} catch (e) {
						return response.data; // Return raw data if JSON parsing fails
					}
				} else {
					throw new Error("HTTP error: " + response.status);
				}
			} catch (error) {
				if (error.message.includes("timeout")) {
					throw new Error("Request timed out");
				} else {
					throw new Error("Network error: " + error.message);
				}
			}
		}
	}
})(app);
(function(app){
	app.search = app.search || {};
	app.search.minc = 0;
	app.search.category = "";
	app.search.findinname = "";
	app.search.findincontent = "";
	app.search.sort = "";
	app.search.host = "";
	app.search.step = "";
	app.search.tag = [];
	app.search.result = [];
	app.search.searchcontainer = null;
	app.search.searchinname = null;
	app.search.page = 0;
	app.search.viewtype = "row-2";
	app.search.changeViewType = function(t){
		this.viewtype = t;
		if(this.currentLoader){
			this.currentLoader.container.innerHTML = "";
			this.currentLoader.setRenderer(t).then(
				function(){
					app.search.currentLoader.autoPopulate();
				}
			);
		}
	}
	app.search.reset = function(){
		app.search.minc = 0;
		app.search.category = "";
		app.search.findinname = "";
		app.search.findincontent = "";
		app.search.sort = "";
		app.search.host = "";
		app.search.tag = [];
		app.search.result = [];
		app.search.page = 0;
		this.assignView(app.topPageUntil('searchfilter'));
		q("input.booksearch")[0].value = "";
	}
	app.search.select = function(e,t){
		if(!e || !e.hasAttribute("v")){
			return;
		}
		e.setAttribute("selected", "true");
		var parent = e.parentNode;
		for(var i=0; i<parent.children.length; i++){
			if(parent.children[i] != e){
				parent.children[i].removeAttribute("selected");
			}
		}
		if(this.hasOwnProperty(t)){
			this[t] = e.getAttribute("v");
		}
	}
	app.search.choose = function(e){
		if(e.getAttribute("selected")){
			e.removeAttribute("selected");
		}else{
			e.setAttribute("selected", "true");
		}
		var parent = e.parentNode;
		var tags=parent.querySelectorAll(".tag");
		this.tag = [];
		for(var i=0; i<tags.length; i++){
			if(tags[i].hasAttribute("selected")){
				this.tag.push(tags[i].getAttribute("v"));
			}
		}
	}
	app.search.applyfilter = function(){
		var p = app.topPage();
		this.findincontent = p.q(".findincontent").value;
		this.host = (p.q(".hostselect") || "").value || "";
		//app.search.get(true);
		this.doNewQuery();
		app.goback();
	}
	app.search.assignView = function(t){
		if(!t) return;
		this.select(t.q(`.minc[v="${this.minc}"]`));
		this.select(t.q(`.category[v="${this.category}"]`));
		this.select(t.q(`.sort[v="${this.sort}"]`));
		this.select(t.q(`.step[v="${this.step}"]`));
		t.q(`.findincontent`) && (t.q(`.findincontent`).value = this.findincontent);
		t.q(`.hostselect`) && (t.q(`.hostselect`).value = this.host);
		for(var i=0; i<this.tag.length; i++){
			var tag = t.q(`.tag[v="${this.tag[i]}"]`);
			tag && tag.setAttribute("selected", "true");
		}
	}
	app.search.onloadHandler = function(suc){
		if(app.search.inf){
			app.search.inf.remove();
		}
		app.removePreloader(app.search.searchcontainer);
		if(suc){
			var inf = app.createInf(function(){
				app.search.page++;
				app.search.get();
			});
			app.search.inf = inf;
			app.search.searchcontainer.appendChild(inf);
		}
	}
	app.search.get = function(force){
		return;
		if(force){
			this.page = 0;
		}
		var query = {
			method: "search",
			minc: this.minc,
			category: this.category,
			findinname: this.findinname,
			find: this.findincontent,
			sort: this.sort,
			host: this.host,
			tag: this.tag.join(","),
			step: this.step,
			p: this.page
		};
		if(force){
			this.searchcontainer.innerHTML = "";
		}
		var ele = document.createElement("div");
		this.searchcontainer.appendChild(ele);
		if(this.viewtype == "grid"){
			app.celoader.bookgrid(ele, {
				//from: "/mobile/booklist.php?" + app.serialize(query),
				from: "/io/searchtp/searchBooks?" + app.serialize(query),
				onload: this.onloadHandler
			});
		}else{
			app.celoader.booklist(ele, {
				//from: "/mobile/booklist.php?" + app.serialize(query),
				from: "/io/searchtp/searchBooks?" + app.serialize(query),
				onload: this.onloadHandler
			});
		}
	}
	app.search.getQuery = function(force){
		var query = {
			method: "search",
			minc: this.minc,
			category: this.category,
			findinname: this.findinname,
			find: this.findincontent,
			sort: this.sort,
			host: this.host,
			tag: this.tag.join(","),
			step: this.step
		};
		return app.serialize(query);
	}
	app.search.doNewQuery = function(){
		this.currentLoader.setBaseLink("/io/searchtp/searchBooks?" + this.getQuery());
		this.currentLoader.reset();
		this.searchcontainer.scrollTop = 0;
	}
	function g(i){
		return document.getElementById(i);
	}
	function gv(i){
		return encodeURIComponent(g(i).value);
	}
	app.search.init = function(p){
		this.searchcontainer = g("searchcontainer");
		this.searchinname = p.q("input.booksearch");
		this.timer = null;
		this.searchinname.addEventListener("keyup", function(e){
			if(app.search.timer){
				clearTimeout(app.search.timer);
			}
			app.search.timer = setTimeout(function(){
				app.search.findinname = app.search.searchinname.value;
				app.search.doNewQuery();
			}, 500);
		});
		this.searchinname.value = this.findinname;
		if(this.currentLoader){
			delete this.currentLoader;
		}
		var bookListLoader = this.currentLoader = new BookListLoader("/io/searchtp/searchBooks?" + this.getQuery(), this.searchcontainer, this.viewtype);
		bookListLoader.loader();
		this.searchcontainer.style.height = (window.innerHeight - p.q(".titlebar").clientHeight) + "px";
		p.q(".titlebar").style.position = "static";
	}
	app.search.faceted = async function(p,host){
		if(this.factedCache){
			var arr = [];
			var t = p.q(".taglist");
			t.innerHTML = "";
			var face = this.factedCache[host];
			if(!face){
				return;
			}
			for(var cat in face.category){
				if(cat.indexOf(" ")>0)
				arr.push({
					name: cat,
					value: face.category[cat]
				});
			}
			arr.sort(function(a,b){return b.value - a.value});
			var num = 0;
			for(var i=0;i<arr.length;i++){
				var cat = arr[i].name;
				var btn = document.createElement("div");
				btn.className = "tag";
				btn.setAttribute("v", slugVietnamese(cat));
				btn.textContent = titleCase(cat)+"("+arr[i].value+")";
				t.appendChild(btn);
				num++;
				if(num == 12){
					await waitFrame();
					num = 0;
				}
			}
			for(var i=0; i<this.tag.length; i++){
				t.q(`.tag[v="${this.tag[i]}"]`).setAttribute("selected", "true");
			}
		}else{
			app.net.get("/searchfaceted.json").then(json=>{
				app.search.factedCache = json;
				app.search.faceted(p,host);
			});
		}
	}
	app.search.onHostChange = function(h){
		app.search.faceted(app.topPage(), h);
	}
})(app);

app.serialize = function(obj) {
	var str = [];
	for (var p in obj)
	    if (obj.hasOwnProperty(p)) {
			str.push(encodeURIComponent(p) + "=" + encodeURIComponent(obj[p]));
	    }
	return str.join("&");
};

(function(app){
	app.prop = app.prop || {};
	app.prop.viewranktype = "viewweek";
})(app);

(function(app){
	app.lang = app.lang || {};
	app.lang.vi = {
		"booklist": "Danh sách sách",
		"booksearch": "Tìm kiếm sách",
		"booksearchresult": "Kết quả tìm kiếm",
		"booksearchresult_empty": "Không có sách nào phù hợp",
		"booksearchresult_empty_host": "Không có sách nào phù hợp tại host này",
		"home": "Tủ sách",
		"home_empty": "Tủ sách trống",
		"community": "Cộng đồng",
		"user": "Cá nhân",
		"followed": "Đã theo dõi thành công",
		"bookmarked": "Đã thêm vào tủ sách",
		"neterror": "Lỗi mạng",
		"other": "Khác",
		"view": "Lượt xem",
		"fontsize": "Cỡ chữ",
		"fontsize_small": "Nhỏ",
		"fontsize_medium": "Trung bình",
		"fontsize_large": "Lớn",
		"fontweight": "Độ đậm",
		"lineheight": "Giãn dòng",
		"paragraph_space": "Giãn đoạn",
		"textcolor": "Màu chữ",
		"liked": "Đã thích",
		"loaderror": "Lỗi tải dữ liệu",
		"nocomment": "Chưa có bình luận nào",
		"comment": "Bình luận",
		"comment_empty": "Chưa có bình luận nào",
		"leftpadding": "Lề trái",
		"rightpadding": "Lề phải",
		"toppadding": "Lề trên",
		"bottompadding": "Lề dưới",
		"textalign": "Căn lề",
		"backgroundimage": "Hình nền",
		"voice": "Giọng đọc",
		"voicerate": "Tốc độ đọc",
		"voicepitch": "Độ cao giọng",
		"playbacksetting": "Cấu hình audio",
		"playbackrate": "Tốc độ phát lại",
		"playbackvolume": "Âm lượng",
		"playbackpause": "Ngừng giữa các câu",
		"playbackeq": "Hiệu chỉnh âm thanh",
		"ttssetting": "Cài đặt TextToSpeech",
		"lrpadding": "Viền 2 bên",
		"textshadow": "Đổ bóng",
		"shadowcolor": "Màu đổ bóng",
		"textindent": "Lề đầu dòng",
		"backgroundcolor": "Màu nền",
		"letterspacing": "Giãn chữ",
		"wordspacing": "Giãn từ",
		"bordertop": "Viền trên",
		"borderbottom": "Viền dưới",
		"reload": "Tải lại",
		"setting": "Cài đặt",
		"app_color": "Màu ứng dụng",
		"allow": "Cho phép",
		"not_allow": "Không cho phép",
		"data": "Dữ liệu",
		"saved_image": "Hình ảnh đã lưu",
		"animated_background": "Nền ảnh động",
		"text_brightness": "Độ sáng chữ",
		"notification": "Thông báo",
		"update_chapter": "Cập nhật chương truyện",
		"reply_comment": "Trả lời bình luận",
		"tagging": "Gắn thẻ bình luận",
		"interface": "Giao diện",
		"godstone": "Thần thạch",
		"goldcoin": "Kim tệ",
		"buy_chapter_history": "Lịch sử mua chương",
		"my_comment": "Bình luận của tôi",
		"my_page": "Trang của tôi",
		"cv_level": "Tu vi",
		"READED_COUNT": "ĐỌC",
		"ACCOUNT_CREATE_DATE": "KHAI SINH",
		"ONLINE_TIME": "ONLINE",
		"COMMENT_COUNT": "BÌNH LUẬN",
		"Novel": "Truyện",
		"source": "nguồn",
		"have_d": "đã có",
		"new_chapter": "chương mới",
		"language": "Ngôn ngữ/Language",
		"my_items": "Túi đồ",
		"reply": "Trả lời",
		"delete": "Xóa",
		"DOWNLOADING": "ĐANG TẢI XUỐNG",
		"DOWNLOADED": "ĐÃ TẢI XUỐNG",
		"history": "Lịch sử",
		"follow": "Theo dõi",
		"bookmark": "Đánh dấu",
		"novel_owner": "Sở hữu",
		"download": "Tải xuống",
		"lasted_update": "Mới cập nhật",
		"ranking": "Xếp hạng",
		"book_push": "Đẩy sách",
		"search": "Tìm kiếm",
		"my_info": "Thông tin cá nhân",
		"account_id": "ID tài khoản",
		"account": "Tài khoản",
		"password": "Mật khẩu",
		"change_password": "Đổi mật khẩu",
		"permission": "Quyền hạn",
		"displayname": "Tên hiển thị",
		"change_signature": "Sửa tiểu sử",
		"login": "Đăng nhập",
		"logout": "Đăng xuất",
		"register": "Đăng ký",
		"chapter": "Chương",
		"info": "Thông tin",
		"like_this_book": "Thích truyện",
		"write_preview": "Viết preview",
		"tags": "Nhãn dán",
		"collection": "Bộ sưu tập",
		"download_this_book": "Tải truyện",
		"read_now": "Đọc ngay",
		"table_of_contents": "Mục lục",
		"fontname": "Font chữ",
		"just_in_time": "vừa mới",
		"last_week": "tuần trước",
		"last_month": "tháng trước",
		"last_year": "năm trước",
		"last_day": "ngày trước",
		"last_hour": "giờ trước",
		"last_minute": "phút trước",
		"last_second": "giây trước",
		"yes": "Có",
		"no": "Không",
		"enter_value": "Nhập giá trị",
		"pull_to_refresh": "Kéo xuống để làm mới",
		"release_to_refresh": "Thả ra để làm mới",
		"refreshing": "Đang làm mới",
		"refresh_done": "Làm mới thành công",
		"refresh_error": "Làm mới thất bại",
		"reenter_password": "Nhập lại mật khẩu",
		"book_name": "Tên",
		"book_author": "Tác giả",
		"book_category": "Thể loại",
		"book_status": "Tình trạng",
		"book_addtime": "Ngày nhập",
		"book_hname": "Tên hán việt",
		"book_ogname": "Tên gốc",
		"book_ogauthor": "Tác giả gốc",
		"book_host": "Nguồn",
		"book_tag": "Thẻ",
		"loading_content": "Đang tải nội dung...",
		"text_for_test_font": "AbcDefGhiJklMnoPqrStuVwxYz 0123456789 ÁáÀàẢảÃãẠạ ÂâẤấẦầẨẩẪẫẬậ ĂăẮắẰằẲẳẴẵẶặ Đđ ÊêẾếỀềỂểỄễỆệ ÍíÌìỈỉĨĩỊị ÓóÒòỎỏÕõỌọ ÔôỐốỒồỔổỖỗỘộ ƠơỚớỜờỞởỠỡỢợ ÚúÙùỦủŨũỤụ ƯưỨứỪừỬửỮữỰự ÝýỲỳỶỷỸỹỴỵ",
		"font_manager": "Quản lý font",
		"notification_new_chapter": "Truyện {0} nguồn {1} có {2} chương mới",
		"notification_reply_comment": "{0} đã trả lời bình luận của bạn",
		"notification_reply_comment_world": "{0} đã trả lời bình luận của bạn trên một truyền ngôn",
		"notification_reply_comment_user": "{0} đã trả lời bình luận của bạn trên trang cá nhân",
		"unknown": "Không rõ",
		"ongoing": "Còn tiếp",
		"completed": "Hoàn thành",
		"paused": "Tạm ngưng",
		"interaction": "Tương tác",
		"click_at_left_binding_action": "Chức năng khi nhấp trái",
		"click_at_right_binding_action": "Chức năng khi nhấp phải",
		"display": "Hiển thị",
		"display_type": "Kiểu hiển thị",
		"up_down_slide": "Trượt trên dưới",
		"continuos": "Liên tục",
		"page_flip": "Lật trang",
		"page_flip_fast": "Lật trang(nhanh)",
		"simulated_page_flip": "Mô phỏng",
		"static_chapter_name": "Tên chương cố định",
		"top": "Trên",
		"bottom": "Dưới",
		"no_display": "Không hiển thị",
		"prepend_chapter_name": "Tên chương đầu chương",
		"talk_sentence_italic": "In nghiêng câu thoại",
		"open_menu": "Mở menu",
		"slide_down": "Trượt xuống",
		"slide_up": "Trượt lên",
		"slide_left": "Trang trước",
		"slide_right": "Trang kế",
		"none": "Không",
		"listview_short": "Danh sách rút gọn",
		"listview": "Danh sách",
		"listview_extended": "Chi tiết",
		"gridview": "Lưới",
		"gridview_short": "Lưới rút gọn",
		"gridview_extended": "Lưới chi tiết",
		"synchronize_history": "Đồng bộ lịch sử",
		"synchronize_history_desc": "Chọn một vị trí để đồng bộ lịch sử đọc truyện",
		"synchronize_history_slot_empty": "Vị trí trống",
		"saves": "Lưu trữ",
		"allow_synchronize_overwrite": "Cho phép ghi đè dữ liệu đang có trên thiết bị?",
		"ask_for_synchronize": "Bạn có muốn gửi dữ liệu từ thiết bị này lên server không?",
		"you_have_not_login": "Bạn chưa đăng nhập",
	}
	app.lang.en = {
		"booklist": "Book list",
		"booksearch": "Search book",
		"booksearchresult": "Search result",
		"booksearchresult_empty": "No book found",
		"booksearchresult_empty_host": "No book found at this host",
		"home": "Home",
		"home_empty": "Home is empty",
		"search": "Search",
		"community": "Community",
		"user": "User",
		"followed": "Followed",
		"bookmarked": "Bookmarked",
		"neterror": "Network error",
		"other": "Other",
		"view": "View",
		"fontsize": "Font size",
		"fontsize_small": "Small",
		"fontsize_medium": "Medium",
		"fontsize_large": "Large",
		"fontweight": "Font weight",
		"lineheight": "Line height",
		"paragraph_space": "Paragraph space",
		"textcolor": "Text color",
		"liked": "Liked",
		"loaderror": "Load error",
		"nocomment": "No comment",
		"comment": "Comment",
		"comment_empty": "No comment",
		"leftpadding": "Left padding",
		"rightpadding": "Right padding",
		"toppadding": "Top padding",
		"bottompadding": "Bottom padding",
		"textalign": "Text align",
		"backgroundimage": "Background image",
		"voice": "Voice",
		"voicerate": "Voice rate",
		"voicepitch": "Voice pitch",
		"playbacksetting": "Playback setting",
		"playbackrate": "Playback rate",
		"playbackvolume": "Playback volume",
		"playbackpause": "Playback pause",
		"playbackeq": "Playback equalizer",
		"ttssetting": "TextToSpeech setting",
		"lrpadding": "Left right padding",
		"textshadow": "Text shadow",
		"shadowcolor": "Shadow color",
		"textindent": "Text indent",
		"backgroundcolor": "Background color",
		"letterspacing": "Letter spacing",
		"wordspacing": "Word spacing",
		"bordertop": "Border top",
		"borderbottom": "Border bottom",
		"reload": "Reload",
		"setting": "Setting",
		"app_color": "App color",
		"allow": "Allow",
		"not_allow": "Not allow",
		"data": "Data",
		"saved_image": "Saved image",
		"animated_background": "Animated background",
		"text_brightness": "Text brightness",
		"notification": "Notification",
		"update_chapter": "Update chapter",
		"reply_comment": "Reply comment",
		"tagging": "Tagging",
		"interface": "Interface",
		"godstone": "Godstone",
		"goldcoin": "Gold coin",
		"buy_chapter_history": "Buy chapter history",
		"my_comment": "My comment",
		"my_page": "My page",
		"cv_level": "Cultivation",
		"READED_COUNT": "READ",
		"ACCOUNT_CREATE_DATE": "BIRTH",
		"ONLINE_TIME": "ONLINE",
		"COMMENT_COUNT": "COMMENT",
		"Novel": "Novel",
		"source": "source",
		"have_d": "have",
		"new_chapter": "new chapter",
		"language": "Ngôn ngữ/Language",
		"my_items": "My items",
		"reply": "Reply",
		"delete": "Delete",
		"DOWNLOADING": "DOWNLOADING",
		"DOWNLOADED": "DOWNLOADED",
		"history": "History",
		"follow": "Follow",
		"bookmark": "Bookmark",
		"novel_owner": "My book",
		"download": "Download",
		"lasted_update": "Lasted update",
		"ranking": "Ranking",
		"book_push": "Book push",
		"search": "Search",
		"my_info": "My info",
		"account_id": "Account ID",
		"account": "Account",
		"password": "Password",
		"change_password": "Change password",
		"permission": "Permission",
		"displayname": "Display name",
		"change_signature": "Change signature",
		"login": "Login",
		"logout": "Logout",
		"register": "Register",
		"chapter": "Chapter(s)",
		"info": "Info",
		"like_this_book": "Like",
		"write_preview": "Write preview",
		"tags": "Tags",
		"collection": "Collection",
		"download_this_book": "Download",
		"read_now": "Read",
		"table_of_contents": "Catalog", // short toc
		"fontname": "Font Family",
		"just_in_time": "just now",
		"last_week": "week(s) ago",
		"last_month": "month(s) ago",
		"last_year": "year(s) ago",
		"last_day": "day(s) ago",
		"last_hour": "hour(s) ago",
		"last_minute": "minute(s) ago",
		"last_second": "second(s) ago",
		"yes": "Yes",
		"no": "No",
		"enter_value": "Enter value",
		"pull_to_refresh": "Pull to refresh",
		"release_to_refresh": "Release to refresh",
		"refreshing": "Refreshing",
		"refresh_done": "Refresh done",
		"refresh_error": "Refresh error",
		"reenter_password": "Reenter password",
		"book_name": "Name",
		"book_author": "Author",
		"book_category": "Category",
		"book_status": "Status",
		"book_addtime": "Add time",
		"book_hname": "HanViet",
		"book_ogname": "Original name",
		"book_ogauthor": "Original author",
		"book_host": "Source",
		"book_tag": "Tag",
		"loading_content": "Loading content...",
		"text_for_test_font": "AbcDefGhiJKlMnoPqrStuVwxYz 0123456789", 
		"font_manager": "Font manager",
		"notification_new_chapter": "{0} from {1} have {2} new chapter",
		"notification_reply_comment": "{0} reply your comment",
		"notification_reply_comment_world": "{0} reply your comment on a novel",
		"notification_reply_comment_user": "{0} reply your comment on user page",
		"unknown": "Unknown",
		"ongoing": "Ongoing",
		"completed": "Completed",
		"paused": "Paused",
		"interaction": "Interaction",
		"click_at_left_binding_action": "Click at left action",
		"click_at_right_binding_action": "Click at right action",
		"display": "Display",
		"display_type": "Display type",
		"up_down_slide": "Up down slide",
		"continuos": "Continuos",
		"page_flip": "Page flip",
		"page_flip_fast": "Page flip(fast)",
		"simulated_page_flip": "Simulated",
		"static_chapter_name": "Static chapter name",
		"top": "Top",
		"bottom": "Bottom",
		"no_display": "No display",
		"prepend_chapter_name": "Prepend chapter name",
		"talk_sentence_italic": "Talk sentence italic",
		"open_menu": "Open menu",
		"slide_down": "Slide down",
		"slide_up": "Slide up",
		"slide_left": "Slide left",
		"slide_right": "Slide right",
		"none": "None",
		"listview_short": "List short",
		"listview": "List",
		"listview_extended": "List extended",
		"gridview": "Grid",
		"gridview_short": "Grid short",
		"gridview_extended": "Grid extended",
		"synchronize_history": "Synchronize history",
		"synchronize_history_desc": "Select a position to synchronize reading history",
		"synchronize_history_slot_empty": "Empty slot",
		"saves": "Saves",
		"allow_synchronize_overwrite": "Allow overwrite existing data on device?",
		"ask_for_synchronize": "Do you want to send data from this device to server?",
		"you_have_not_login": "You have not login",
	};
	app.lang.loadOnline = async function(langCode){
		var url = "/mobile/lang/"+langCode+".json";
		return app.net.getCacheLater(url).then(function(data){
			app.lang[langCode] = data;
		});
	};
})(app);

(function(app){
	app.text = app.text || app.lang["vi"] || {};
	app.language = "vi";
	var languageCookie = getCookie("lang");
	app.text.book = app.text.book || {};
	app.text.book.info = function(e){
		var t = e.innerHTML;
		t = t.replace(/script/g, "")
		.replace(/\[url=([^"'])+\](.+?)\[\/\]/g, "<a href='$1' target='_blank'>$2</a>")
		.replace(/\[banquyen=([^"'])+\]/g, "")
		.replace(/\\n/g, "<br>").replace(/\n/g, "<br>")
		.replace(/([\.!！。]+) /g, "$1<br><br>").replace(/　/g, "")
		.replace(/\[color=([A-Za-z0-9\#]+)\](.+?)\[\/\]/g,"<span style=\"color:$1\">$2</span>");
		e.innerHTML = t;
	}
	app.text.book.category = function(e){
		var t = e.innerHTML;
	}
	app.text.autoConvert = function(t, map){
		for(var i=0; i<map.length; i++){
			if(map[i].regex.test(t)){
				t = t.replace(map[i].regex, function(){
					var args = Array.from(arguments);
					return map[i].replace(args.splice(1, args.length-3));
				});
			}
		}
		return t;
	}
	app.text.notificationReplace = function(t){
		var mod = [
			{
				regex: /Truyện (.*?) nguồn (.*?) đã có <b>(\d+)<\/b> chương mới/,
				replace: function(m){
					return app.text.f.notification_new_chapter(...m);
				},
			},
			{
				regex: /(.*?) đã phản hồi bình luận của bạn trên trang cá nhân của anh\/cô ấy./,
				replace: function(m){
					return app.text.f.notification_reply_comment_user(...m);
				},
			},
			{
				regex: /(.*?) đã phản hồi bình luận của bạn về một truyền ngôn/,
				replace: function(m){
					return app.text.f.notification_reply_comment_world(...m);
				},
			},
			{
				regex: /(.*?) đã phản hồi bình luận của bạn/,
				replace: function(m){
					return app.text.f.notification_reply_comment(...m);
				},
			}
		];
		return this.autoConvert(t, mod);
	}
	app.text.changeLanguage = function(langCode){
		if(!app.lang[langCode]){
			app.lang.loadOnline(langCode).then(function(){
				app.text.changeLanguage(langCode);
			}).catch(function(){
				app.toast("Không thể tải ngôn ngữ "+langCode);
			}); 
			return;
		}
		setCookie("lang", langCode, 365);
		app.text = $.extend({}, app.text, app.lang[langCode] || {});
		app.language = langCode;
		q("text").forEach(function(e){
			app.celoader.text(e);
		});
		
	}
	if(languageCookie){
		app.text.changeLanguage(languageCookie);
	}
	app.text.w = new Proxy(app.text, {
		get: function(_, name){
			return {
				toString: function(){
					return app.text[name] || name;
				}
			}
		},
	});
	app.text.f = new Proxy(app.text, {
		get: function(_, name){
			return function(){
				var args = Array.from(arguments);
				var text = app.text[name] || name;
				for(var i=0; i<args.length; i++){
					text = text.replace("{"+i+"}", args[i]);
				}
				return text;
			};
		}
	});
	app.text.pull2refresh = [
        app.text.w.pull_to_refresh, 
        app.text.w.release_to_refresh, 
        app.text.w.refreshing,
        app.text.w.refresh_done,
        app.text.w.refresh_error
    ];
})(app);
//app.context
(function(app){
	app.context = app.context || {};
	app.context.bookinfo = function(e){
		this.showMenu(this.menu.bookinfo);
	}
	app.context.comment = function(e){
		this.showMenu(this.menu.comment);
	}
	app.context.searchViewType = function(targetList){
		this.showMenu(this.menu.searchViewType);
	}
	app.context.hostlist = function(){
		var a = [{name:"Tất cả",value:""}];
		if(!window.hmeta){
			app.toast("Không có kết nối mạng, tải danh sách nguồn thất bại.");
			ui.scriptmanager.load("/stv.host.js", function(){}); // try on background
			return a;
		}
		for(var i in hmeta){
			if(i[0] != "-")
			a.push({
				name: i,
				value: i
			});
		}
		return a;
	}
	app.context.reloadChapterlist = function(){
		var tab = app.topPage().q("tab");
		var ti = tab.q("tabitem.active");
		if(!tab || !tab.current) return; // host list not loaded
		var index = tab.current();
		var view = tab.querySelectorAll("tabview")[index].q(".clistcontainer");
		view.innerHTML = "";
		var bookdata = ti.data;
		getchapterlist(bookdata.host,bookdata.id,true,view);
	}
	app.context.createMenu = function(menu){
		if(menu.type == "mixed"){
			return this.createMixedMenu(menu);
		}
		var div = document.createElement("div");
		div.className = "contextmenu";
		for(var i=0; i<menu.item.length; i++){
			var d = document.createElement("div");
			d.className = "contextmenuitem";
			if(menu.item[i].icon){
				d.innerHTML = `<i class="fas fa-${menu.item[i].icon}"></i> ${menu.item[i].text}`;
			}else{
				d.innerHTML = menu.item[i].text;
			}
			let action = menu.item[i].onclick;
			if(menu.item[i].value){
				d.value = menu.item[i].value;
			}
			d.data = menu.item[i];
			d.addEventListener("click", function(){
				if(menu.type == "select" && menu.selection){
					eval(menu.selection+`='${this.value}'`);
					console.log(menu.selection);
					if(menu.onchange){
						menu.onchange(this.data);
					}
				}
				if(action){
					if(typeof action == "function"){
						action();
					}else{
						eval(action);
					}
				}
			});
			if(menu.selection && menu.item[i].value == evalValue(menu.selection)){
				d.classList.add("selected");
			}
			div.appendChild(d);
		}
		return div;
	}
	app.context.createMixedMenu = function(menu){
		var div = document.createElement("div");
		div.className="mixedcontextmenu";
		for(var i=0; i<menu.item.length; i++){
			var row = document.createElement("div");
			let item = menu.item[i];
			if(item.type == "tap"){
				row.className = "mixedcontextmenu_tap";
				if(item.icon){
					row.innerHTML = `<i class="fas fa-${item.icon}"></i> ${item.text}`;
				}else{
					row.innerHTML = item.text;
				}
				row.addEventListener("click", function(){
					if(item.action){
						if(item.action()){
							div.remove();
						}
					}
				});
			}
			if(item.type == "select"){
				row.className = "mixedcontextmenu_select";
				let selectValue = item.selection;
				let val = eval(selectValue);
				for(var j=0;j<item.item.length;j++){
					let child = document.createElement("div");
					let childItem = item.item[j];
					if(childItem.icon){
						child.innerHTML = `<i class="fas fa-${childItem.icon}"></i><br>${childItem.text||""}`;
					}else{
						child.innerHTML = childItem.text;
					}
					child.value = childItem.value;
					if(childItem.value == val){
						child.classList.add("selected");
					}
					child.addEventListener("click", function(){
						eval(selectValue+"='"+this.value+"'");
						if(item.onchange){
							item.onchange(this.value);
						}
						row.querySelectorAll(".selected").forEach(function(e){
							e.classList.remove("selected");
						});
						this.classList.add("selected");
						if(childItem.action){
							childItem.action();
						}
					});
					row.appendChild(child);
				}
			}
			if(item.type == "row"){
				row.className = "mixedcontextmenu_select";
				for(var j=0;j<item.item.length;j++){
					let child = document.createElement("div");
					let childItem = item.item[j];
					if(childItem.icon){
						child.innerHTML = `<i class="fas fa-${childItem.icon}"></i><br>${childItem.text||""}`;
					}else{
						child.innerHTML = childItem.text;
					}
					child.addEventListener("click", function(){
						if(childItem.action){
							childItem.action();
						}
					});
					row.appendChild(child);
				}
			}
			if(item.type == "toggle"){
				row.className = "mixedcontextmenu_toggle";
				let valueName = item.value;
				let toggleStatus = eval(valueName).toString() == "true";
				row.textContent = item.text;
				if(toggleStatus){
					row.classList.add("selected");
				}
				row.addEventListener("click", function(){
					toggleStatus = !toggleStatus;
					if(toggleStatus && !this.classList.contains("selected")){
						this.classList.add("selected");
					}else if(this.classList.contains("selected")){
						this.classList.remove("selected");
					}
					if(item.action){
						item.action(toggleStatus);
					}
				});
			}
			div.appendChild(row);
		}
		return div;
	};
	app.context.yesno = async function(text, onclick){
		var pop = document.createElement("div");
		pop.className = "popupyesno";
		pop.innerHTML = `<div class="popupyesno_text">${text}</div>
			<div class="popupyesno_button">
				<div class="popupyesno_button_no">${app.text.no}</div>
				<div class="popupyesno_button_yes">${app.text.yes}</div>
			</div>`;
		pop.addEventListener("click", function(e){
			e.stopPropagation();
		});
		return new Promise(function(resolve, reject){
			pop.q(".popupyesno_button_yes").addEventListener("click", function(){
				if(onclick){
					onclick(true);
				}
				resolve(true);
				pop.remove();
			});
			pop.q(".popupyesno_button_no").addEventListener("click", function(){
				if(onclick){
					onclick(false);
				}
				resolve(false);
				pop.remove();
			});
			g("ctxoverlay").appendChild(pop);
		});
	}
	app.context.popup = function(template, onclick){
		var pop = document.createElement("div");
		pop.className = "popupedit";
		if(template.closeOnClick){
			pop.closeOnClick = true;
		}
		pop.innerHTML = `<div class="popupedit_title">${template.title || ""}</div>
			<div class="popupedit_body">${template.body || ""}</div>
			<div class="popupedit_button">${template.button || ""}</div>`;
		pop.addEventListener("click", function(e){
			e.stopPropagation();
		});
		if(onclick){
			pop.addEventListener("click", function(){
				onclick(pop);
			});
		}
		if(pop.qq("input, textarea, [contenteditable]").length > 0){
			pop.setAttribute("hasedit","true");
		}
		pop.qv = function(c){
			return this.q(`.${c}`).value;
		}
		pop.q(".popupedit_button").addEventListener("click", function(e){
			var target = e.target;
			if(target.parentElement && target.parentElement.tagName == "BUTTON"){
				target = target.parentElement;
			}
			if(target.hasAttribute("action")){
				var actionName = target.getAttribute("action");
				if(template.action[actionName]){
					template.action[actionName](pop);
				}
			}
			app.platform.nativeClick();
		});
		pop.q(".popupedit_body").addEventListener("click", function(e){
			var target = e.target;
			if(target.parentElement && target.parentElement.tagName == "BUTTON"){
				target = target.parentElement;
			}
			if(target.hasAttribute("action")){
				var actionName = target.getAttribute("action");
				if(template.action[actionName]){
					template.action[actionName](pop);
				}
				app.platform.nativeClick();
			}
		});
		if(template.data){
			for(var i in template.data){
				var s = pop.q(`.${i}`);
				if(s){
					s.value = template.data[i];
				}
			}
		}
		if(template.focus){
			setTimeout(function(){
				pop.q(`.${template.focus}`).focus();
			}, 100);
			
		}
		return pop;
	}
	app.context.showMenu = function(menu,attach, ev){
		var menupop = this.createMenu(menu);
		g("ctxoverlay").appendChild(menupop);
		var width = menupop.scrollWidth;
		var screenWidth = document.body.scrollWidth;
		var e = ev || event ||(app.perf.topFrame() ? app.perf.topFrame().contentWindow.event : false) || window.eventpass;
		var x = e.clientX;
		var y = e.clientY;
		if(x + width < screenWidth){
			menupop.style.left = x + "px";
		}else{
			menupop.style.left = (x - width) + "px";
		}
		menupop.style.top = e.clientY + "px";
		var menuheight = menupop.scrollHeight;
		// check if menu is out of screen bottom
		if(y + menuheight > document.body.scrollHeight && y - menuheight > 0){
			menupop.style.top = (y - menuheight) + "px";
		}


		if(menu.type == "tap"){
		}
		if(menu.type == "select"){
			menupop.classList.add("contextmenu-select");
		}
		if(attach){
			this.attach = attach;
		}
		ui.tabs.lock(false);
	}
	app.context.showPopup = function(poptemplate,attach){
		var pop = this.popup(poptemplate);
		g("ctxoverlay").appendChild(pop);
		if(attach){
			this.attach = attach;
		}
		ui.tabs.lock(false);
		return pop;
	}
	app.context.info = function(msg, closeOnClick = false){
		var mn = $.extend({
			closeOnClick: closeOnClick
		}, app.context.menu.alert);
		mn.body = mn.body.replace("{text}", msg);
		this.showPopup(mn);
	}
	app.context.timedAlert = function(msg, time = 3){
		var mn = $.extend({
			closeOnClick: true
		}, app.context.menu.alert);
		mn.body = mn.body.replace("{text}", msg);
		var pop = this.showPopup(mn);
		setTimeout(()=>{pop.remove();}, time * 1000);
	}
	app.context.prompt = async function(msg, title = app.text.w.enter_value, initValue = ""){
		var mn = $.extend({}, app.context.menu.prompt);
		mn.body = mn.body.replace("{text}", msg);
		mn.title = title;
		mn.body = mn.body.replace("{default}", initValue);
		return new Promise(function(resolve, reject){
			mn.action.resolve = resolve;
			mn.action.reject = reject;
			app.context.showPopup(mn);
		});
	}
	app.context.colorPicker = async function(initValue, onchange){
		var p = app.render("colorpicker");
		var t = p.q(".colorstring");
		p.style.width = "230px";
		var color = initValue ? initValue : "#f00";
		var cp = iro.ColorPicker(p.q(".colorpickerhold"),{
			color: color,
			width: 200,
		});
		cp.on("color:change", function(color){
			var h = color.hexString;
			t.value = h;
			if(onchange){
				onchange(h);
			}
		});
		return new Promise(function(resolve){
			p.q(".accept").addEventListener("click", function(){
				resolve(cp.color.hexString);
				p.remove();
			});
			p.q(".cancel").addEventListener("click", function(){
				resolve(false);
				p.remove();
			});
			g("ctxoverlay").appendChild(p);
		});
	}
	app.context.resetOverlay = function(){
		var ovl = g("ctxoverlay");
		if(!ovl.hide){
			ovl.hide = function(){
				if(this.children[0]){
					this.lastChild.remove();
					return true;
				}
			}
			ovl.addEventListener("click", function(e){
				if(this.q(".popupyesno")){
					this.q(".popupyesno .popupyesno_button_no").click();
				}
				if(this.q(".popupedit")){
					if(!this.q(".popupedit").closeOnClick){
						return;
					}
				}
				this.hide();
			});
		}
	}
	app.context.resetOverlay();
	app.context.menu = { //contextlist
		bookinfo: {
			type: "tap",
			item: [
				{text: app.text.w.bookmark, onclick: function(){
					var b = app.topPageData();
					app.context.attach = b;
					app.api.bookmark();
				}},
				{text: app.text.w.follow, onclick: function(){
					var b = app.topPageData();
					app.context.attach = b;
					app.api.follow();
				}},
				// {text: "Thêm vào bộ sưu tập", onclick: function(){
				// 	var b = app.topPageData();
				// 	app.pushPage("addtocollection", b);
				// }},
				{text: app.text.w.book_push, onclick: function(){
					var b = app.topPageData();
					app.pushPage("pushbook",b);
				}},
				{text: app.text.w.write_preview, onclick: function(){
					var b = app.topPageData();
					var p = app.pushPage("writepreview",b);
					p.q(".useinfobtn").addEventListener("click", function(){
						p.q(".previewcontent").value = b.info.substr(0,200) + (b.info.length > 200 ? "..." : "");
					});
				}},
			]
		},
		fontmanager: {
			type: "tap",
			item: [
				{text: app.text.w.delete, onclick: function(){
					var attach = app.context.attach;
					var topPage = app.topPage();
					setTimeout(() => {
						app.context.yesno("Xóa font này?", function(yes){
							if(yes){
								app.fontmanager.removeLocalFont(attach.name);
								if(topPage.q(".font-list")){
									topPage.q(".font-list").firstChild.remove();
									topPage.q(".font-list").appendChild(app.fontmanager.render());
								}
							}
						});
					}, 100);
				}},
			]
		},
		selectranktype: {
			type: "select",
			item: [
				{text: "Lượt xem tuần",value:"viewweek",  onclick: function(){
					app.refresh(g("bookrankingview"));
				}},
				{text: "Lượt xem ngày", value:"viewday", onclick: function(){
					app.refresh(g("bookrankingview"));
				}},
				{text: "Lượt xem tổng", value:"view", onclick: function(){
					app.refresh(g("bookrankingview"));
				}},
				{text: "Lượt thích", value:"like", onclick: function(){
					app.refresh(g("bookrankingview"));
				}},
				{text: "Lượt theo dõi", value:"following", onclick: function(){
					app.refresh(g("bookrankingview"));
				}},
				{text: "Lượt đánh dấu", value:"bookmarked", onclick: function(){
					app.refresh(g("bookrankingview"));
				}},
			],
			selection: "app.prop.viewranktype"
		},
		searchViewType: {
			type: "select",
			item: [
				{text: app.text.w.listview_short, icon: "list", value:"row-1",  onclick: function(){
					app.search.changeViewType("row-1");
				}},
				{text: app.text.w.listview, icon: "list", value:"row-2", onclick: function(){
					app.search.changeViewType("row-2");
				}},
				{text: app.text.w.listview_extended, icon: "list", value:"row-3", onclick: function(){
					app.search.changeViewType("row-3");
				}},
				{text: app.text.w.gridview_short, icon: "th", value:"grid-0", onclick: function(){
					app.search.changeViewType("grid-0");
				}},
				{text: app.text.w.gridview, icon: "th", value:"grid-1", onclick: function(){
					app.search.changeViewType("grid-1");
				}},
				{text: app.text.w.gridview_extended, icon: "th", value:"grid-2", onclick: function(){
					app.search.changeViewType("grid-2");
				}},
			],
			selection: "app.search.viewtype"
		},
		comment: {
			type: "select",
			item: [
				{text: "Mới nhất", value:"new", onclick: function(){
					app.comment.reset();
				}},
				{text: "Cũ nhất", value:"old", onclick: function(){
					app.comment.reset();
				}}
			],
			selection: "app.comment.order"
		},
		textbright: {
			type: "select",
			item: [
				{text: "100%", value:"1"},
				{text: "90%", value:"0.9"},
				{text: "80%", value:"0.8"},
				{text: "70%", value:"0.7"},
				{text: "60%", value:"0.6"},
			],
			selection: "app.config.ux.text_brightness",
			onchange: function(d){
				app.theme.syncColor();
				app.context.attach.textContent = d.text;
			}
		},
		readchapter: {
			type: "mixed",
			item: [
				{
					type: "select",
					item: [
						{text: "VP", value:"vp"},
						{text: "BG", value:"bing"},
						{text: "ZH", value:"original"},
						{text: "EN", value:"english"},
					],
					selection: "app.config.reader.transmode",
					onchange: function(value){
						app.reader.setTransMode(value);
						app.reader.reloadAllChapter();
					},
				},
				{
					type: "tap",
					icon: "tasks",
					text: app.text.w.setting,//"Cài đặt",
					action: function(){
						app.reader.openSetting();
					},
				},
				{
					type: "tap",
					icon: "list-ol",
					text: app.text.w.table_of_contents, //"Danh sách chương",
					action: function(){
						app.reader.showDrawer();
					},
				},
				{
					type: "tap",
					icon: "redo",
					text: "Tải lại nội dung",
					action: function(){
						app.reader.reloadCurrentChapter(true);
					},
				},
				{
					type: "tap",
					icon: "scroll",
					text: "Tự động đọc",
					action: function(){
						app.reader.autoScroll();
					},
				},
				{
					type: "tap",
					icon: "download",
					text: "Tải name theo truyện",
					action: function(){
						app.namemanager.showNameByBook();
					},
				},
				{
					type: "tap",
					icon: "download",
					text: "Tải gói name",
					action: function(){
						app.namemanager.showNamePack();
					},
				}
			]
		},
		readcomic: {
			type: "mixed",
			item: [
				{
					type: "select",
					item: [
						{text: "Phân trang", value:"perpage"},
						{text: "Toàn trang", value:"perpair"},
					],
					selection: "app.config.comicReader.transmode",
					onchange: function(value){
						app.comicReader.setTransMode(value);
					},
				},
				{
					type: "tap",
					icon: "tasks",
					text: "Cài đặt",
					action: function(){
						app.comicReader.openSetting();
					},
				},
				{
					type: "tap",
					icon: "list-ol",
					text: "Danh sách chương",
					action: function(){
						app.comicReader.showDrawer();
					},
				},
				{
					type: "tap",
					icon: "redo",
					text: "Tải lại nội dung",
					action: function(){
						app.comicReader.reloadCurrentChapter();
					},
				}
			]
		},
		browser: {
			type: "mixed",
			item: [
				{
					type: "row",
					item: [
						{
							icon: "arrow-left",
							text: "",
							action: function(){
								app.surf.browser.goBack();
							},
						},
						{
							icon: "redo",
							text: "",
							action: function(){
								app.surf.browser.reload();
							},
						},
						{
							icon: "home",
							text: "",
							action: function(){
								app.surf.browser.showIndex();
							},
						},
					],
				},
				{
					type: "tap",
					icon: "arrow-to-bottom",
					text: "Thử nhúng truyện",
					action: function(){
						//app.surf.browser.tryCheckBookUrl();
					}
				},
				{
					type: "tap",
					icon: "tanakh",
					text: "Dịch hình ảnh",
					action: function(){
						app.surf.comic.applyEvent();
					}
				},
			]
		},
		fontfamily: {
			type: "tap",
			item: [
			]
		},
		bookhistory: {
			type: "tap",
			item: [
				{text: app.text.w.delete, onclick: function(){
					console.log(app.context.attach.data);
					var host = app.context.attach.data.host;
					var id = app.context.attach.data.id;
					app.history.delete(host, id);
					$(app.context.attach).fadeOut();
				}},
				{text: "Đánh dấu", onclick: function(){
					app.api.bookmark(app.context.attach.data);}},
				{text: "Theo dõi", onclick: function(){
					app.api.follow(app.context.attach.data);} },
				{text: "Thêm vào bộ sưu tập", onclick: function(){
					var b = app.context.attach.data;
					app.pushPage("addtocollection", b);
				}},
			]
		},
		bookfollowing: {
			type: "tap",
			item: [
				{text: app.text.w.delete, onclick: function(){
					app.api.follow(app.context.attach.data);} },
				{text: "Đánh dấu", onclick: function(){
					app.api.bookmark(app.context.attach.data);}},
				{text: "Thêm vào bộ sưu tập", onclick: function(){
					var b = app.context.attach.data;
					app.pushPage("addtocollection", b);
				}},
			]
		},
		bookmarked: {
			type: "tap",
			item: [
				// {text: "Xóa", onclick:  function(){
				// 	app.api.bookmark(app.context.attach.data);} },
				{text: "Theo dõi", onclick: function(){
					app.api.follow(app.context.attach.data);} },
				// {text: "Thêm vào bộ sưu tập", onclick: function(){
				// 	var b = app.context.attach.data;
				// 	app.pushPage("addtocollection", b);
				// }},
			]
		},
		bookfind: {
			type: "tap",
			item: [
				{text: "Theo dõi", onclick: "app.api.follow()" },
				{text: "Đánh dấu", onclick: "app.api.bookmark()" },
				{text: "Thêm vào bộ sưu tập", onclick: function(){
					var b = app.context.attach.data;
					app.pushPage("addtocollection", b);
				}},
			]
		},
		alert: {
			title: "",
			body: "<center>{text}</center>",
			button: `<button class="w-100" action=cancel>Xác nhận</button>`,
			action: {
				cancel: function(p){
					p.parentElement.hide();
				}
			}
		},
		prompt: {
			title: "",
			body: `<div class="center">{text}</div>
				<input class="value" value="{default}" type="text" placeholder="Giá trị" />`,
			button: `
				<button action=cancel>Hủy</button>
				<button action=apply>Ok</button>
				`,
			action: {
				apply: function(p){
					if(this.resolve){
						this.resolve(p.parentElement.querySelector("input").value);
					}
					this.cancel(p);
				},
				cancel: function(p){
					if(this.reject){
						this.reject();
					}
					p.parentElement.hide();
				}
			},
			focus: "value"
		},
		downloadchapter: {
			title: "",
			body: `Nhập số chương để tải:<br>
				<input class="bookid" type="hidden"/>
				<input class="bookhost" type="hidden"/>
				<input class="numstart" type="text" placeholder="Bắt đầu từ" />
				<input class="total" type="text" placeholder="Số chương" />`,
			button: `
				<button action=cancel class="nameeditcancel">Hủy</button>
				<button action=startdownload class="nameeditbtn">Xác nhận</button>
				`,
			action: {
				startdownload: async function(p){
					var host = p.q(".bookhost").value;
					var bookid = p.q(".bookid").value;
					var startnum =  + (p.q(".numstart").value) - 1;
					var total = + (p.q(".total").value);
					if(startnum < 0){
						startnum = 0;
					}
					if(total < 1){
						total = 1;
					}
					var bookInfo = {
						id: bookid,
						host: host,
					};
					this.cancel(p);
					var book = await app.offlineBook.getNewBook(bookInfo);
					var clist = await getChapterList(host,bookid);
					var lists = clist.slice(startnum,startnum+total).map(e=>e.cid);
					console.log(book);
					var job = new app.BookDownloadManager(host,bookid,lists,book);
					console.log(job);
					job.start();
					
				},
				cancel: function(p){
					p.parentElement.hide();
				}
			},
			focus: "total"
		},
		changeNickname: {
			title: "Sửa tên hiển thị",
			body: `<input class="name"/>`,
			button: `
				<button action=cancel class="nameeditcancel">Hủy</button>
				<button action=save class="nameeditbtn">Xác nhận</button>
				`,
			action: {
				save: async function(p){
					var name = p.q(".name").value;
					if(name.length < 3){
						app.toast("Tên quá ngắn");
					}
					app.net.post("/",app.serialize({
						ajax: "changename",
						newname: name
					})).then(function(d){
						app.toast(d);
						if(d.contain("công") || d == "success"){
							app.user.refreshInfo();
						}
					});
				},
				cancel: function(p){
					p.parentElement.hide();
				}
			},
			focus: "name"
		},
		changePassword: {
			title: "Đổi mật khẩu",
			body: `Mật khẩu cũ:
				<input class="oldpassword"/>
				Mật khẩu mới:
				<input class="newpassword"/>
				Nhập lại mật khẩu mới:
				<input class="newpassword2"/>`,
			button: `
				<button action=cancel class="nameeditcancel">Hủy</button>
				<button action=save class="nameeditbtn">Xác nhận</button>
				`,
			action: {
				save: async function(p){
					var oldpassword = p.q(".oldpassword").value;
					var newpassword = p.q(".newpassword").value;
					var newpassword2 = p.q(".newpassword2").value;
					if(newpassword != newpassword2){
						app.toast("Mật khẩu mới không khớp");
						return;
					}
					app.net.post("/",app.serialize({
						ajax: "changepass",
						oldpass: oldpassword,
						newpass: newpassword
					})).then(function(d){
						if(d == "success"){
							app.toast("Đổi mật khẩu thành công");
							this.cancel(p);
						}else{
							app.toast(d);
						}
					});
				},
				cancel: function(p){
					p.parentElement.hide();
				}
			},
			focus: "oldpassword"
		},
		changeUserInfo: {
			title: "Sửa tiểu sử",
			body: `<textarea class="desc shadowinset rounded" style="min-height:120px"></textarea>`,
			button: `
				<button action=cancel class="nameeditcancel">Hủy</button>
				<button action=save class="nameeditbtn">Xác nhận</button>
				`,
			action: {
				save: async function(p){
					var desc = p.q(".desc").value;
					app.net.post("/",app.serialize({
						ajax: "saveinfo",
						content: desc
					})).then(function(d){
						if(d == "success"){
							app.toast("Đã lưu");
							app.user.refreshInfo();
						}else{
							app.toast(d);
						}
					});
				},
				cancel: function(p){
					p.parentElement.hide();
				}
			},
			focus: "desc"
		},
		namemanager: {
			edit: {
				title: "Sửa chữa",
				body: `<select class="nameedittype" disabled>
					<option value="v0">Name V0(Regex)</option>
					<option value="v1">Name V1(Gốc tiếng việt)</option>
					<option value="v2">Name V2(Gốc tiếng trung)</option>
					<option value="vp">Vietphrase</option>
					<option value="ve">Luật nhân cao cấp</option></select>
					<input class="nameeditbase" type="text" placeholder="Gốc" />
					<input class="nameeditname" type="text" placeholder="Giá trị" />`,
				button: `
					<button action=cancel class="nameeditcancel">Hủy</button>
					<button action=save class="nameeditbtn">Sửa</button>
					`,
				action: {
					save: function(p){
						var type = p.qv("nameedittype");
						var base = p.qv("nameeditbase");
						var name = p.qv("nameeditname");
						app.context.attach.datarow.base = base;
						app.context.attach.datarow.name = name;
						app.context.attach.cells[1].textContent = base;
						app.context.attach.cells[2].textContent = name;
						var index = app.context.attach.datarow.index;
						var map = {
							"v0": "",
							"v1": "@",
							"v2": "$",
							"vp": "#",
							"ve": "~"
						};
						var pack = `${map[type]}${base}=${name}`;
						var isGlobal = app.context.attach.datarow.isglobal;
						if(isGlobal){
							app.namemanager.updateGlobal(index, pack);
						}else{
							app.namemanager.update(index, pack);
						}
						app.reader.runNameForAll();
						this.cancel(p);
					},
					cancel: function(p){
						p.parentElement.hide();
					}
				},
				focus: "nameeditname"
			},
			add: {
				title: "Thêm mới",
				body: `<select class="nameedittype">
					<option value="">Name V0(Regex)</option>
					<option value="@">Name V1(Gốc tiếng việt)</option>
					<option value="$">Name V2(Gốc tiếng trung)</option>
					<option value="#">Vietphrase</option>
					<option value="~">Luật nhân cao cấp</option></select>
					<input class="nameeditbase" type="text" placeholder="Gốc" />
					<input class="nameeditname" type="text" placeholder="Giá trị" />`,
				button: `
					<button action=cancel class="nameeditcancel">Hủy</button>
					<button action=save class="nameeditbtn">Lưu</button>
					`,
				action: {
					save: function(p){
						var type = p.qv("nameedittype");
						var base = p.qv("nameeditbase");
						var name = p.qv("nameeditname");
						var pack = `${type}${base}=${name}`;
						var isglobal = app.topPage().q("tab").current() == 1;
						if(isglobal){
							app.namemanager.appendGlobal(pack);
							console.log("add global", pack);
						}else
						app.namemanager.append(pack);
						this.cancel(p);
					},
					cancel: function(p){
						p.parentElement.hide();
					}
				},
				focus: "nameeditbase"
			},
			menu: {
				type: "tap",
				item: [
					{text: "Gói name theo truyện", onclick: function(){
						app.namemanager.showNameByBook();
					}},
					{text: "Gói name đặc biệt", onclick: function(){
						app.namemanager.showNamePack();
					}},
					{text: "Xóa tất cả name theo truyện", onclick: function(){
						app.namemanager.deleteAllNameCurrent();
					}},
				]
			},
		},
		bookExtendInfo: {
			title: "Thông tin truyện",
			body: "",
			button: `
				<button action=cancel class="w-100">Đóng</button>
				`,
			action: {
				cancel: function(p){
					p.parentElement.hide();
				}
			}
		},
		factionInfo: {
			title: "",
			body: "",
			button: `
				<button action=cancel class="w-50">Đóng</button>
				<button action=join class="w-50">Xin vào</button>
				`,
			action: {
				cancel: function(p){
					p.parentElement.hide();
				},
				join: async function(p){
					var d = app.context.attach.data;
					var ftid = d.id;
					if(await app.context.yesno("Xin vào thế lực này? Nếu đã có xin thế lực khác, lần xin cũ sẽ bị hủy?")){
						app.net.post("/","ajax=faction&sub=joinfaction&ftid="+ftid).then(function(d){
							app.toast(d);
						});
					}
				}
			}
		},
		setting: {
			themeEditor: {
				title: "Chỉnh sửa màu",
				body: `
					<div class="themecolorchanger">
						<div class="bgcolor active"></div>
						<div class="accolor"></div>
						<div class="colorpicker"></div>
					</div>
				`,
				button: `
					<button action=cancel class="w-100">Đóng</button>
					<button action=save class="w-100">Lưu</button>
				`,
				action: {
					cancel: function(p){
						p.parentElement.hide();
					},
					save: function(p){
						app.theme.saveEditor();
						this.cancel(p);
					}
				}
			},
			readThemeEditor: {
				title: "Chỉnh sửa màu",
				body: `
					<div class="themecolorchanger">
						<div class="bgcolor active"></div>
						<div class="accolor"></div>
						<div class="colorpicker"></div>
					</div>
				`,
				button: `
					<button action=cancel class="w-100">Đóng</button>
					<button action=save class="w-100">Lưu</button>
				`,
				action: {
					cancel: function(p){
						p.parentElement.hide();
					},
					save: function(p){
						app.theme.saveEditor();
						this.cancel(p);
					}
				}
			}
		},
		
	}
	app.context.current = function(p,activator){
		if(p == 0){
			var tab = g("tabtimkiem");
			var tabNode = tab.currentTabNode();
			var viewType = tabNode.getAttribute("view");
			if(viewType == "bookranking"){
				this.showMenu(this.menu.selectranktype);
			}
			if(viewType == "bookpush"){
				var ev = event;
				if(this.menu.selectpushdir){
					this.showMenu(this.menu.selectpushdir);
				}else{
					app.net.get("/mobile/bookmanage.php?act=listpushdir").then(function(d){
						app.context.menu.selectpushdir = {
							type: "select",
							item: d.data.map(function(e){
								return {text: e.name, value: e.id, onclick: function(){
									app.prop.pushdir = e.id;
									app.refresh(g("bookdirview"));
								}}
							}),
							selection: "app.prop.pushdir"
						}
						app.context.showMenu(app.context.menu.selectpushdir, null, ev);
					});
				}
			}
			if(viewType == "bookpromote"){
				app.fun.showSearch();
			}
			if(viewType == "bookupdate"){
				app.search.sort = "update";
				app.search.minc = 50;
				app.fun.showSearch();
			}
		}
		if(p == 1){
			if(g("mainview").current() != 0){
				return;
			}
			var tab = g("tabtusach");
			var tabid = tab.current();
			if(tabid == 0){
				this.showMenu(this.menu.bookhistory,activator);
			}
			if(tabid == 1){
				this.showMenu(this.menu.bookfollowing,activator);
			}
			if(tabid == 2){
				this.showMenu(this.menu.bookmarked,activator);
			}
			if(tabid == 3){
				//this.showMenu(this.menu.bookowned,activator);
			}
		}
	}
})(app);

// read history
(async function(app){
	app.history = app.history || {
		loaded: false,
		onLoadWait: null,
		isLoaded: async function(){
			return this.loaded || await this.onLoadWait;
		}
	};
	app.history.onLoadWait = new Promise(function(resolve){
		app.history.onload = function(){
			app.history.loaded = true;
			resolve();
		}
	});
	app.history.get = function(host,id){
		if(!this.readhistory){
			return "";
		}
		return app.history.readhistory[app.history.index[`${host}-${id}`]] || "";
	}
	await onDbLoad.waitForLoad();
	app.history.readhistory = JSON.parse(await app.storage.getItem("readhistory") || "[]");
	app.history.index = {};
	app.history.fetchMaxEntry = 48;
	var storage = "localStorage";
	if(app.storage.cache.getFile.toString().contain("getFile")){
		storage = "sqlite";
		var tmphistory = JSON.parse(await app.storage.cache.getFile("readhistory") || "[]");
		if(tmphistory && tmphistory.length >= app.history.readhistory.length){
			app.history.readhistory = tmphistory;
		}else{
			// migration
			await app.storage.cache.setFile("readhistory", JSON.stringify(app.history.readhistory));
		}
	}
	app.history.storage = {
		save: function(){
			if(storage == "localStorage"){
				app.storage.setItem("readhistory", JSON.stringify(app.history.readhistory));
			}else{
				app.storage.cache.setFile("readhistory", JSON.stringify(app.history.readhistory));
			}
		},
	}
	app.history.setContainer = function(){
		var c = this.container;
		var e = document.createElement("div");
		e.style.height = "100%";
		e.style.width = "100vw";
		e.style.position = "relative";
		var t = this;
		var loader = async function(p){
			var pairs = [];
			for(var i = p * t.fetchMaxEntry; i < (p + 1) * t.fetchMaxEntry; i++){
				if(i >= t.readhistory.length){
					break;
				}
				var b = t.readhistory[i];
				pairs.push([b.host, b.id]);
			}
			if(pairs.length == 0){
				return {list: []};
			}
			return app.net.post("/mobile/booklist.php?method=history","data="+pairs.map(function(e){return e.join("-")}).join("/")).then(function(d){
				if(d.code == 101){
					return {list: []};
				}
				return d;
			}).catch(async function(e){
				console.log("load offline");
				await onDbLoad.waitForLoad();
				var l = pairs.map(e=>app.storage.cache.get(`/mobile/bookinfo.php?hid=${e[1]}&host=${e[0]}`));
				var d = await Promise.all(l);
				d = d.filter(e=>e).map(e=>JSON.parse(e).book);
				return {list: d};
			});
		}
		app.celoader.infbookgrid(e, {
			loader: loader,
			perPage: this.fetchMaxEntry,
			refresh: true
		});
		c.appendChild(e);
	};
	app.history.fetch = function(p){
		var fl = [];
		for(var i = p * this.fetchMaxEntry; i < (p + 1) * this.fetchMaxEntry; i++){
			if(i >= app.history.readhistory.length){
				break;
			}
			var b = app.history.readhistory[i];
			fl.push(`${b.host}-${b.id}`);
		}
		if(fl.length == 0){
			return;
		}
		if(p > 0)return;
		app.net.post("/mobile/booklist.php?method=history","data="+fl.join("/")).then(function(d){
			if(d.code == 101){
				return;
			}
			var oldl = app.history.container.querySelectorAll("[view=bookgrid]");
			if(p == 0){
				for(var i = 0; i < oldl.length; i++){
					oldl[i].remove();
				}
			}
			var ele = document.createElement("div");
			app.history.container.appendChild(ele);
			var grid = app.render("bookgrid",d);
			app.setNew(ele,grid);
		}).catch(async function(){
			var d={
				code:100,
				list:[]
			}
			console.log("load offline");
			await onDbLoad.waitForLoad();
			for(var i = p * app.history.fetchMaxEntry; i < (p + 1) * app.history.fetchMaxEntry; i++){
				if(i >= app.history.readhistory.length){
					break;
				}
				var b = app.history.readhistory[i];
				var url = "/mobile/bookinfo.php?hid="+b.id+"&host="+b.host;
				d.list.push(app.storage.cache.get(url));
			}
			d.list = (await Promise.all(d.list)).filter(e=>e).map(function(e){
				return JSON.parse(e).book;
			});
			var oldl = app.history.container.querySelectorAll("[view=bookgrid]");
			if(p == 0){
				for(var i = 0; i < oldl.length; i++){
					oldl[i].remove();
				}
			}
			var ele = document.createElement("div");
			app.history.container.appendChild(ele);
			var grid = app.render("bookgrid",d);
			app.setNew(ele,grid);
		});
	}
	app.history.buildRecord = function(b,c){
		var r = {
			id: b.id,
			host: b.host,
			title: b.title,
			time: new Date().getTime(),
			chapter: c.id,
			chaptertitle: c.title,
			chaptercount: b.chaptercount,
			icon: b.thumb,
		};
		return r;
	}
	app.history.buildRecord2 = async function(b,c){
		var clist = await getChapterListCache(b.host,b.id);
		var index = clist.findIndex(function(e){
			return e.cid == c.id;
		});
		var r = {
			id: b.id,
			host: b.host,
			title: b.name,
			time: new Date().getTime(),
			chapter: c.id,
			chaptertitle: c.title,
			chaptercount: b.chaptercount,
			icon: b.thumb,
			chapterIndex: index,
		};
		return r;
	}
	app.history.validateData = function(arr){
		if(!arr || !Array.isArray(arr)){
			return false;
		}
		var properties = ["id","host","title","time","chapter","chaptertitle","chaptercount","icon"];
		for(var i = 0; i < arr.length; i++){
			var b = arr[i];
			if(!b || typeof b != "object"){
				return false;
			}
			for(var j = 0; j < properties.length; j++){
				var p = properties[j];
				if(b.hasOwnProperty(p)){
					if(typeof b[p] != "string" && typeof b[p] != "number"){
						if(b[p] !== null){
							return false;
						}
					}
				}else{
					return false;
				}
			}
		}
		return true;
	}
	app.history.buildIndex = function(){
		app.history.index = {};
		for(var i = 0; i < app.history.readhistory.length; i++){
			var b = app.history.readhistory[i];
			app.history.index[`${b.host}-${b.id}`] = i;
		}
	}
	
	app.history.add = function(b){
		if(!app.history.index[`${b.host}-${b.id}`]){
			app.history.readhistory.unshift(b);
			app.history.buildIndex();
			app.history.storage.save();
		}
	}
	app.history.delete = function(host,id){
		var i = app.history.index[`${host}-${id}`];
		if(i != undefined){
			app.history.readhistory.splice(i,1);
			app.history.buildIndex();
			app.history.storage.save();
		}
	}
	app.history.deleteall = function(){
		app.history.readhistory = [];
		app.history.buildIndex();
		//app.storage.set("readhistory",JSON.stringify(app.history.readhistory));
		app.history.storage.save();
	}
	app.history.sort = function(){
		app.history.readhistory.sort(function(a,b){
			return b.time - a.time;
		});
		this.buildIndex();
	}
	app.history.removeDuplicate = function(){
		var h = {};
		var l = [];
		for(var i = 0; i < app.history.readhistory.length; i++){
			var b = app.history.readhistory[i];
			if(!h[`${b.host}-${b.id}`]){
				h[`${b.host}-${b.id}`] = BigInt(b.chapter);
				l.push(b);
			}else{
				if(h[`${b.host}-${b.id}`] < BigInt(b.chapter)){
					h[`${b.host}-${b.id}`] = BigInt(b.chapter);
					l[l.length - 1] = b;
				}
			}
		}
		app.history.readhistory = l;
		this.buildIndex();
	}
	app.history.update = function(b){
		var i = app.history.index[`${b.host}-${b.id}`];
		if(i != undefined){
			app.history.readhistory[i] = b;
			this.sort();
			//app.storage.set("readhistory",JSON.stringify(app.history.readhistory));
			app.history.storage.save();
		}else{
			app.history.add(b);
		}
	}
	app.history.isDirty = false;
	app.history.update2 = async function(b,c){
		var r = await this.buildRecord2(b,c);
		this.update(r);
		this.isDirty = true;
	}
	
	app.history.refresh = function(){
		app.history.container.firstChild.onrefresh(function(){});
	}
	app.history.init = function(){
		app.history.container = g("historyview");
		app.history.scroller = app.history.container.parentElement;
		app.history.buildIndex();
		app.history.removeDuplicate();
		app.history.setContainer();
		app.history.onload();
	}
	app.history.save = function(){
		app.history.storage.save();
	}
	app.history.showSynchronizer = function(){
		var slots = null;
		var popup = {
			title: app.text.w.synchronize_history,
			body: `
				<div class="text-center">
					${app.text.w.synchronize_history_desc}
				</div>
				<div class="synchronize-history-list">
					<div class="synchronize-history-slot">
						<div class="slot-title"></div>
						<div class="slot-download">
							<button action=download1 >
								<i class="fas fa-download"></i>
							</button>
						</div>
						<div class="slot-upload">
							<button action=upload1 >
								<i class="fas fa-upload"></i>
							</button>
						</div>
					</div>
					<div class="synchronize-history-slot">
						<div class="slot-title"></div>
						<div class="slot-download">
							<button action=download2 >
								<i class="fas fa-download"></i>
							</button>
						</div>
						<div class="slot-upload">
							<button action=upload2 >
								<i class="fas fa-upload"></i>
							</button>
						</div>
					</div>
					<div class="synchronize-history-slot">
						<div class="slot-title"></div>
						<div class="slot-download">
							<button action=download3 >
								<i class="fas fa-download"></i>
							</button>
						</div>
						<div class="slot-upload">
							<button action=upload3 >
								<i class="fas fa-upload"></i>
							</button>
						</div>
					</div>
				</div>
			`,
			button: `
				<button action=cancel class="w-100">Đóng</button>
				`,
			action: {
				cancel: function(p){
					p.parentElement.hide();
				},
				download: async function(slotId){
					if(await app.context.yesno(app.text.allow_synchronize_overwrite)){
						app.net.get("/?ajax=loadhistory&client=app&slotId=" + slotId).then(function(d){
							if(app.history.validateData(d)){
								app.history.readhistory = d;
								app.history.removeDuplicate();
								app.history.storage.save();
								app.toast(app.text.completed);
								app.history.refresh();
							} else {
								app.toast("Lỗi tải dữ liệu");
							}
						});
					}
				},
				upload: async function(slotId){
					if(await app.context.yesno(app.text.ask_for_synchronize)){
						var data = "data=" + encodeURIComponent(JSON.stringify(app.history.readhistory));
						app.net.post("/?ajax=savehistory&client=app&slotId=" + slotId, data).then(function(d){
							if(d == "error"){
								app.toast("Lỗi tải dữ liệu");
								return;
							}
							if(d == "nologin"){
								app.toast("Vui lòng đăng nhập để sử dụng tính năng này");
								return;
							}
							slots[slotId].q(".slot-title").textContent = `${app.text.saves} ${d}`;
							slots[slotId].q(".slot-download").style.display = "block";
						});
					}
				}
			},
		};
		var pop = app.context.showPopup(popup);
		var slots = pop.q(".synchronize-history-list").children;
		app.net.get("/?ajax=listsavedhistory&client=app").then(function(d){
			if(d == "error"){
				app.toast("Lỗi tải dữ liệu");
			}
			if(d == "nologin"){
				app.toast("Vui lòng đăng nhập để sử dụng tính năng này");
				return;
			}
			if(d.code == 0){
				for(var i = 0; i < d.slots.length; i++){
					var s = slots[i];
					var serverSlot = d.slots[i];
					if(serverSlot == "none"){
						s.q(".slot-title").textContent = app.text.w.synchronize_history_slot_empty;
						s.q(".slot-download").style.display = "none";
					} else {
						s.q(".slot-title").textContent = `${app.text.saves} ${serverSlot}`;
						s.q(".slot-download").style.display = "block";
					}
				}
			}
		});
		for(var i = 0; i < slots.length; i++){
			popup.action["download" + (i + 1)] = (function(slotId){
				return function(p){
					popup.action.download(slotId);
				};
			})(i);
			popup.action["upload" + (i + 1)] = (function(slotId){
				return function(p){
					popup.action.upload(slotId);
				};
			})(i);
		}
	}
	app.history.init();
})(app);

// comment
(function(app){
	app.comment = app.comment || {};
	app.comment.order = "new";
	app.comment.load = function(t,id,p){
		if(!p){
			p = 0;
		}
		var url = `/mobile/comment.php?act=readcomment&host=${t}&bookid=${id}&start=${p*10}&order=${this.order}`;
		app.net.get(url,true).then(function(d){
			app.comment.render(d.list);
		});
	}
	app.comment.loadEmbed = function(container,t,id,p,fc,fcid){
		container.host = t;
		container.oid = id;
		if(!p){
			p = 0;
		}
		var url = `/mobile/comment.php?act=readcomment&host=${t}&bookid=${id}&start=${p*10}&order=${this.order}`;
		app.net.get(url,true).then(function(d){
			app.removePreloader(container);
			app.comment.renderEmbed(container,d.list,p,fc,fcid);
		});
		if(!container.onrefresh){
			var isEmbeb = container.classList.contains("comments");
			container.onrefresh = function(ended){
				app.comment.reset();
			}
			container.id = randomNodeId();
			var channel = `cmt-${t}-${id}`;
			app.pushserver.connectChannel(channel);
			var listenFunction = function(d){
				console.log(d);
				if(!app.queryAllPage("#"+container.id)
					/*!isInDocumentTree(container,app.topPage(true) || document.body)*/
					){
					console.log("push comment ", channel, "not in document tree");
					console.log(container.id);
					app.pushserver.removeListener(listenFunction, channel);
					return;
				}
				if(d.channel == channel){
					console.log("push comment ", channel);
					app.comment.pushComment(container,d,isEmbeb);
					
				}else{
					console.log("push comment ", channel, "not match");
				}
			}
			app.pushserver.addListener(listenFunction);
			
			if(isEmbeb){
				var view = app.comment.getView();
				view.parentElement.q(".finish").addEventListener("click", function() {
					var rpContext = app.comment.getReplyContext();
					rpContext.set(view.parentElement.q(".comment-input").value);
					rpContext.send(view.parentElement.q(".comment-input"));
				});
			}
			var preloader = app.createPreloader("Đang tải bình luận...");
			container.appendChild(preloader);
			//ui.pullToRefresh(container);
			//container.style.overflow = "auto";
		}
		
		
	}
	app.comment.reset = function(){
		var page = app.topPage();
		var view = page.q(".commentview") || page.q(".comments");
		var parent = view.parentElement;
		parent.page = 0;
		parent.ended = false;
		view.qq(".preloader,[view=commentblock]").forEach(function(e){e.remove();});
		//if(parent.className == "embedcomment"){
			this.loadEmbed(view,view.host,view.oid,0);
		// }else{
		// 	console.log(parent.className);
		// 	this.load(page.host,page.oid);
		// }
		
	}
	app.comment.render = function(l){
		var page = app.topPage();
		var view = page.q(".commentview");
		var parent = view.parentElement;
		if(!l){
			if(view.children.length == 0){
				var nodata = app.createNodata("Tải bình luận thất bại");
				view.appendChild(nodata);
			}
		}
		if(l.length == 0){
			parent.ended = true;
			if(view.children.length == 0){
				var nodata = app.createNodata("Chưa có bình luận nào");
				view.appendChild(nodata);
			}
			return;
		}
		if(view){
			for(var i=0; i<l.length;i++){
				var c = app.render("commentblock",l[i]);
				view.appendChild(c);
				this.applyEvent(c);
				var rp = c.q(".cmtreplies");
				for(var j=0;j<l[i].reply.length;j++){
					var r = app.render("commentblock",l[i].reply[j]);
					this.applyEvent(r);
					rp.appendChild(r);
				}
			}
		}
	}
	app.comment.renderEmbed = async function(c,l,page,fc,fcid){
		var view = c;
		var isEmbeb = c.classList.contains("comments");
		page = parseInt(page);
		if(view){
			if(!l){
				if(view.children.length == 0){
					var nodata = app.createNodata("Tải bình luận thất bại",true);
					view.appendChild(nodata);
				}
			}
			if(l.length == 0){
				if(view.children.length == 0){
					var nodata = app.createNodata("Chưa có bình luận nào",true);
					view.appendChild(nodata);
				}
				if(view.q(".preloader")){
					view.q(".preloader").remove();
				}
				return;
			}
			for(var i=0; i<l.length;i++){
				var c = app.render("commentblock",l[i]);
				view.appendChild(c);
				await waitFrame();
				hrefEvent(c);
				this.applyEvent(c,isEmbeb);
				var rp = c.q(".cmtreplies");
				for(var j=0;j<l[i].reply.length;j++){
					var r = app.render("commentblock",l[i].reply[j]);
					r.data.isReply = true;
					r.data.rootCmt = l[i];
					this.applyEvent(r,isEmbeb);
					rp.appendChild(r);
					await waitFrame();
					hrefEvent(r);
				}
			}
			if(view.q(".preloader")){
				view.q(".preloader").remove();
			}
			if(l.length == 10){
				var inf = app.createInf(function(){
					app.comment.loadEmbed(view,view.host,view.oid,parseInt(page) + 1);
				});
				view.appendChild(inf);
			}
			if(isEmbeb)
			view.parentElement.style.height = view.scrollHeight + "px";
			if(fc){
				
				var scrollElement = app.topPage().q(".perf-frame");
				if(!scrollElement){
					scrollElement = app.topPage();
				}else{
					scrollElement = scrollElement.contentDocument.body.children[0];
				}
				if(fcid){
					var fce = scrollElement.q("[data-id=\""+fcid+"\"]");
					if(fce){
						fc = fce.offsetTop;
						fce.q(".content").style.border = "2px solid var(--ac-25)";
					}
				}
				gsap.to(scrollElement,{scrollTop:fc,duration:0.5});
			}
		}
	}
	app.comment.applyEvent = function(e,isEmbeb){
		e.q(".avatar").addEventListener("click",function(){
			app.fun.showUser(e.data.userid);
			app.platform.nativeClick();
		});
		e.q(".name").addEventListener("click",function(){
			app.fun.showUser(e.data.userid);
			app.platform.nativeClick();
		});
		e.q(".cmtresp").addEventListener("click",function(){
			if(isEmbeb){
				app.comment.setReplyContextEmbeb(e.data, e);
			}else
			app.comment.setReplyContext(e.data);
			app.platform.nativeClick();
		});
		e.setAttribute("data-id", e.data.id);
	}
	app.comment.getView = function(){
		var page = app.topPage();
		var view = page.q(".commentview") || page.q(".comments");
		return view;
	}
	app.comment.getReplyContext = function(){
		var view = this.getView();
		if(view){
			if(view.replyContext){
				return view.replyContext;
			}
			view.replyContext = this.replyContext();
			return view.replyContext;
		}
	};
	app.comment.pushComment = function(container, commentdata, isEmbeb){
		if(commentdata.type == "del"){
			var c = container.q("[data-id='"+commentdata.id+"']");
			if(c){
				c.remove();
			}
		}
		if(commentdata.type == "new" || commentdata.type == "reply"){
			var dataHtml = commentdata.data;
			var regex = /src="(.*?)".*?bg-gray">([\s\S]*?)<\/div>[\s\S]*?cmtid="(\d+)".*?href="\/user\/(\d+)\/">([\s\S]*?)<\/a>/;
			var match = dataHtml.match(regex);
			if(!match){
				return;
			}
			var objData = {
				id: match[3],
				userid: match[4],
				name: match[5],
				avatar: match[1],
				content: match[2],
				time: new Date().toString()
			};
			if(container.q("[data-id='"+objData.id+"']")){
				return;
			}
			if(commentdata.type == "reply"){
				var rootCmt = container.q("[data-id='"+commentdata.cmtid+"']");
				if(!rootCmt){
					return;
				}
				var rootCmtData= rootCmt.data;
				var r = app.render("commentblock",objData);
				r.data.isReply = true;
				r.data.rootCmt = rootCmtData;
				this.applyEvent(r,container.classList.contains("comments"),isEmbeb);
				hrefEvent(r);
				r.style.opacity = 0;
				rootCmt.q(".cmtreplies").appendChild(r);
				gsap.to(r,{opacity:1,duration:0.5});
			}else{
				var r = app.render("commentblock",objData);
				this.applyEvent(r,container.classList.contains("comments"),isEmbeb);
				r.style.opacity = 0;
				hrefEvent(r);
				if(app.comment.order == "old"){
					container.appendChild(r);
				}else{
					container.insertBefore(r, container.firstChild);
				}
				gsap.to(r,{opacity:1,duration:0.5});
			}
		}
	}
	app.comment.replyContext = function(){
		var obj =  {
			cmtid:0,
			cmtUserid:0,
			cmtUsername: "",
			cmtContent:"",
			contextId: "",
			isTag: false,
			isLock: false,
			set: function(content){
				this.cmtContent = app.comment.formatText(content);
				var view = app.comment.getView();
				this.contextId = view.host + "_" + view.oid;
			},
			clear: function(){
				var replyInfoDiv = app.topPage().q(".replyinfo");
				if(replyInfoDiv){
					replyInfoDiv.q(".infotext").innerHTML = "";
					replyInfoDiv.style.display = "none";
					app.topPage().q(".commentinput").focus();
				}
				this.cmtid = 0;
				this.cmtUserid = 0;
				this.cmtContent = "";
				this.contextId = "";
				this.isTag = false;
			},
			send: function(input){
				if(!app.user.isLogin){
					app.fun.showLogin();
					return;
				}
				if(this.cmtContent.length == 0){
					app.toast("Vui lòng nhập nội dung");
					return;
				}
				if(this.isLock){
					return;
				}
				
				this.isLock = true;
				var that = this;
				var params = "";
				if(this.cmtid == "0"){
					var contextId = this.contextId.split("_");
					params = `ajax=postcomment&host=${contextId[0]}&bookid=${contextId[1]}&content=${encodeURIComponent(this.cmtContent)}`;
				}else{
					params = `ajax=replycomment&cid=${this.cmtid}&content=`;
					if(this.isTag){
						var tag = `@[${this.cmtUserid}]${this.cmtUsername}[/] ${this.cmtContent}`;
						params += encodeURIComponent(tag);
					}else{
						params += encodeURIComponent(this.cmtContent);
					}
				}
				app.net.post("/",params).then(function(r){
					if(r == "success"){
						input.value = "";
						input.innerHTML = "";
					}else{
						
					}
					that.isLock = false;
				});
			}
		}
		return obj;
	}
	app.comment.setReplyContext = function(data){
		var replyInfoDiv = app.topPage().q(".replyinfo");
		var rpContext= this.getReplyContext();
		if(data.isReply){
			var rootCmt = data.rootCmt;
			if(replyInfoDiv){
				replyInfoDiv.q(".infotext").innerHTML = "Đang trả lời <b>@"+data.name+"</b>";
				replyInfoDiv.style.display = "block";
			}
			rpContext.cmtid = rootCmt.id;
			rpContext.cmtUserid = data.userid;
			rpContext.isTag = true;
			rpContext.cmtUsername = data.name;
		}else{
			if(replyInfoDiv){
				replyInfoDiv.q(".infotext").innerHTML = "Đang trả lời <b>"+data.name+"</b>";
				replyInfoDiv.style.display = "block";
			}
			rpContext.cmtid = data.id;
			rpContext.cmtUserid = data.userid;
			rpContext.isTag = false;
			rpContext.cmtUsername = data.name;
		}
		focusLast(app.topPage().q(".commentinput"));
	}
	app.comment.setReplyContextEmbeb = function(data, parent){
		var view = parent.replyView;
		if(!view){
			view = app.render("embedcommentposter",{});
			parent.q(".cmtfooter").appendChild(view);
			parent.replyView = view;
			view.style.padding = "8px 0px";
			var rp = view.replyContext = app.comment.replyContext();
			if(data.isReply){
				var rootCmt = data.rootCmt;
				rp.cmtid = rootCmt.id;
				rp.cmtUserid = data.userid;
				rp.isTag = true;
				rp.cmtUsername = data.name;
			}else{
				rp.cmtid = data.id;
				rp.cmtUserid = data.userid;
				rp.isTag = false;
				rp.cmtUsername = data.name;
			}
			view.q(".finish").addEventListener("click",function(){
				rp.set(view.q("textarea").value);
				rp.send(view.q("textarea"));
			});
		}
		focusLast(view.q("textarea"));
	}
	app.comment.formatText = function(html){
		var d = document.createElement("div");
		d.innerHTML = html;
		return d.innerText;
	}
})(app);

ui.scriptmanager.load("/asset/app.v2.read.js",function(){},!isCachedFrontend);







//app.user
(function(app){
	app.user = {};
	app.user.isLogin = false;
	app.user.isAdmin = false;
	app.user.info = null;
	app.user.online = function(){
		return app.net.post("/index.php?ngmar=onl2&u=" + app.user.info.id,
			"sajax=online").then(function(r){
				var a = getCookie("access");
				if(a.length < 32){
					app.user.isLogin = false;
					app.user.info = null;
					syncCookie();
				}
			});
	};
	app.user.checklogin = async function(background = false, refresh = false){
		try{
			await app.net.networkManagerXHR.checkDomains();
		}catch(e){
			app.debug.reportRaw("network check failed: " + e.toString());
		}
		if(app.user.info){
			if(!background){
				app.debug.reportRaw("skip login check, user info already exists, userid: " + app.user.info.id);
				if(q(`#mainview div[view=userme]`)[0]){
					app.rerender(q(`#mainview div[view=userme]`)[0]);
				}
			}
			return app.user.online();
		}
		if(getCookie("access").length < 32){
			app.user.isLogin = false;
			app.user.info = null;
			if(!background || refresh){
				setTimeout(function(){
					if(!app.user.isLogin)
					console.log("Logging out..");
					syncCookie();
					if(q(`#mainview div[view=userme]`)[0]){
						app.rerender(q(`#mainview div[view=userme]`)[0]);
					}
				}, 100);
			}
			return;
		}
		app.net.post("/mobile/userinfo.php", "").then(data=>{
			if(data.code == 400){
				app.user.isLogin = true;
				app.user.info = data;
				if(data.perm == "admin"){
					app.user.isAdmin = true;
				}
			}else{
				app.debug.reportRaw("user login check failed: " + JSON.stringify(data) + " request info: " + app.net.debugInfo.format());
				app.user.isLogin = false;
				app.user.info = null;
				console.log(!background || refresh);
			}
			if(!background || refresh){
				setTimeout(function(){
					if(!app.user.isLogin)
					console.log("Logging out..");
					if(q(`#mainview div[view=userme]`)[0]){
						app.rerender(q(`#mainview div[view=userme]`)[0]);
					}
				}, 100);
			}
			syncCookie();
		}).catch(e=>{
			app.debug.reportRaw("user login check network error: " + JSON.stringify(e));
			app.user.isLogin = false;
			app.user.info = null;
		});
	}
	app.user.refreshInfo = function(){
		app.net.get("/mobile/userinfo.php").then(data=>{
			if(data.code == 400){
				app.user.isLogin = true;
				app.user.info = data;
				if(data.perm == "admin"){
					app.user.isAdmin = true;
				}
			}else{
				app.user.isLogin = false;
				app.user.info = null;
			}
			if(q(`#mainview div[view=userme]`)[0]){
				app.rerender(q(`#mainview div[view=userme]`)[0]);
			}
		});
		syncCookie();
	}
	app.user.getUser =async function(uid){
		return await app.net.get("/mobile/userinfo.php?target=" + uid);
	}
	app.user._permLevel = function(){
		if(!app.user.isLogin){
			return 0;
		}
		switch(app.user.info.perm){
			case "locked": return 0;
			case "member": return 1;
			case "vip": return 2;
			case "converter": return 2;
			case "mod": return 3;
			case "admin": return 4;
		}
	}
	app.user.interval = setInterval(function(){
		app.user.checklogin(true);
	},1000*60*2);
	app.user.checklogin(true);
	app.user.__defineGetter__("permLevel",app.user._permLevel);
})(app);

//app.preloader
(function(app){
	app.preloader = {};
	app.preloader.movingBar = `<div class="progress">
			<div class="indeterminate"></div>
		</div>`;
	app.preloader.circlehtml = `    <div class="preloader-wrapper big active">
			<div class="spinner-layer spinner-blue">
			<div class="circle-clipper left">
				<div class="circle"></div>
			</div><div class="gap-patch">
				<div class="circle"></div>
			</div><div class="circle-clipper right">
				<div class="circle"></div>
			</div>
			</div>

			<div class="spinner-layer spinner-red">
			<div class="circle-clipper left">
				<div class="circle"></div>
			</div><div class="gap-patch">
				<div class="circle"></div>
			</div><div class="circle-clipper right">
				<div class="circle"></div>
			</div>
			</div>

			<div class="spinner-layer spinner-yellow">
			<div class="circle-clipper left">
				<div class="circle"></div>
			</div><div class="gap-patch">
				<div class="circle"></div>
			</div><div class="circle-clipper right">
				<div class="circle"></div>
			</div>
			</div>

			<div class="spinner-layer spinner-green">
			<div class="circle-clipper left">
				<div class="circle"></div>
			</div><div class="gap-patch">
				<div class="circle"></div>
			</div><div class="circle-clipper right">
				<div class="circle"></div>
			</div>
			</div>
		</div>`;
})(app);

//app.platform
(function(app){
	app.platform = {};
	app.platform.isAndroid = false;
	app.platform.isIOS = false;
	app.platform.isWeb = false;
	app.platform.toFullscreen = function(){
		if(window.fullscreen){
			return;
		}
		if(this.isAndroid){
			AndroidFullScreen.immersiveMode(function(){
				console.log("immersiveMode success");
				Capacitor.Plugins.StatusBar.hide();
				window.fullscreen = true;
			});
		}else if(this.isIOS){
			Capacitor.Plugins.StatusBar.hide();
			window.fullscreen = true;
		}else{
			if(!document.documentElement.requestFullscreen){
				document.documentElement.requestFullscreen = document.documentElement.webkitRequestFullscreen || document.documentElement.mozRequestFullScreen || document.documentElement.msRequestFullscreen;
			}
			if(!document.documentElement.requestFullscreen){
				return;
			}
			document.documentElement.requestFullscreen({
				navigationUI: "hide",
			});
			window.fullscreen = true;
		}
	}
	app.platform.exitFullscreen = function(){
		if(window.fullscreen){
			if(!document.documentElement.requestFullscreen){
				return;
			}
			if(document.onFullscreenExit){
				document.onFullscreenExit();
			}
		}
		if(this.isAndroid){
			AndroidFullScreen.showSystemUI(function(){
				console.log("showSystemUI success");
				window.fullscreen = false;
				//app.platform.overlayStatusBar(true);
				Capacitor.Plugins.StatusBar.setOverlaysWebView({overlay: true});
			});
		}else if(this.isIOS){
			Capacitor.Plugins.StatusBar.show();
			window.fullscreen = false;
			
		}else{
			try{
				document.exitFullscreen();
				window.fullscreen = false;
			}catch(e){}
		}
	}
	app.platform.setStatusColor = function(color){
		// if(isStatusOverlay){
		// 	return;
		// }
		if(this.isIOS){
			Capacitor.Plugins.StatusBar.setStyle({style: color});
		}
		if(this.isAndroid && false){
			Capacitor.Plugins.StatusBar.setBackgroundColor({color: color});
			if(color == "#ffffff"){
				Capacitor.Plugins.StatusBar.setStyle({style: "LIGHT"});
			}else if(color == "#333333"){
				Capacitor.Plugins.StatusBar.setStyle({style: "DARK"});
			}else{
				Capacitor.Plugins.StatusBar.setStyle({style: "DEFAULT"});
			}
		}
		if(this.isAndroid){
			if(app.theme.isDarkBackground()){
				Capacitor.Plugins.StatusBar.setStyle({style: "DARK"});
			}else
			Capacitor.Plugins.StatusBar.setStyle({style: "LIGHT"});
		}
	}
	app.platform.openInBrowser = function(url){
		window.openInBrowser(url);
	}
	app.platform.vibrate = function(time){
		if(navigator.vibrate){
		//	navigator.vibrate(time);
		//	Capacitor.Plugins.Haptics.impact();
			this.nativeClick();
		}
	}
	app.platform.nativeClick = function(){
		if(this.isAndroid || this.isIOS){
			nativeclick.trigger();
		}
	}
	app.platform.nativeclick = app.platform.nativeClick;
	app.platform.stateStack = [];
	app.platform.pushState = function(layer){
		if(this.isWeb){
			this.stateStack.push(layer);
			history.pushState({layer: layer}, "", "");
		}else{
			this.stateStack.push(layer);
		}
	}
	app.platform.back =async function(){
		var ovl = g("ctxoverlay");
		if(!ovl.hide) {
			app.context.resetOverlay();
		}
		if(ovl.hide && ovl.hide()){
			if(this.isExiting){
				Capacitor.Plugins.App.exitApp();
			}
			return;
		}
		if(q(".drawer.open")[0]){
			q(".drawer.open")[0].classList.remove("open");
			return;
		}
		if(app.topPage() && app.topPage().q(".ntwebview")){
			if(await app.surf.browser.goBack()){
				return;
			}
		}
		if(this.stateStack.length > 0 || g("overlay").children.length > 0){
			this.stateStack.pop();
			var layer = this.stateStack[this.stateStack.length - 1];
			app.popPage();
		}else{
			if(this.isWeb){
				history.back();
			}else{
				if(this.isExiting){
					Capacitor.Plugins.App.exitApp();
				}else{
					this.isExiting = true;
					app.context.timedAlert("Bấm back lần nữa để thoát...", 1);
					setTimeout(function(){
						app.platform.isExiting = false;
					}, 1000);
				}
			}
		}
	}
	app.platform.tryShare = async function(title, text, url, images = []){
		if(navigator.canShare && navigator.canShare()){
			try{
				var shareObj = {
					title: title,
					text: text,
					url: url,
				};
				if(images.length > 0){
					shareObj.files = images;
				}
				await navigator.share(shareObj);
			}catch(e){
				console.log(e);
			}
		}else{
			if(!this.isWeb){
				if(await Capacitor.Plugins.Share.canShare()){
					var shareObj = {
						title: title,
						text: text,
						url: url,
					};
					if(images.length > 0){
						shareObj.files = images;
					}
					await Capacitor.Plugins.Share.share(shareObj);
				}
			}
		}
	}
	app.platform.isOverlayWebview = false;
	app.platform.viewport = {
		// 520dpi
		width: "device-width",
		initialScale: 1,
		minimumScale: 1,
		maximumScale: 1,
		userScalable: "no",
		viewportFit: "cover",
		setScale: function(scale){
			this.initialScale = scale;
			this.minimumScale = scale;
			this.maximumScale = scale;
		},
		getViewportValue: function(){
			var w = window.innerWidth;
			var bestWidth = 360;
			if(w < bestWidth){
				this.width = bestWidth;
				var scale = w / bestWidth;
				this.setScale(scale);
			}
			return `width=${this.width}, initial-scale=${this.initialScale}, minimum-scale=${this.minimumScale}, maximum-scale=${this.maximumScale}, user-scalable=${this.userScalable}, viewport-fit=${this.viewportFit}`;
		},
		setViewport: function(){
			var meta = g("metaviewport")
			meta.setAttribute("content", this.getViewportValue());
		}
	}
	app.platform.overlayStatusBar = function(enable){
		if(this.isWeb){
			return;
		}
		if(this.isOverlayWebview == enable){
			return;
		}
		if(enable){
			var mainview = window.mainview || g("mainview");
			if(app.platform.isIOS){
				console.log("ios overlay webview");
				document.body.setAttribute("ovlwv", "true");
				requestAnimationFrame(function(){
					Capacitor.Plugins.StatusBar.setOverlaysWebView({overlay: true});
					g("metaviewport").setAttribute("content", "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover");
					setTimeout(function(){
						requestAnimationFrame(function(){
							window.onresize();
						});
					}, 100);
				});
			}else{
				if(document.body.hasAttribute("ovlwv")){
					if(mainview.style.height != "100vh"){
						mainview.style.height = "100vh";
					}
					return;
				}
				document.body.setAttribute("ovlwv", "true");
				mainview.style.height = "100vh";
				requestAnimationFrame(function(){
					Capacitor.Plugins.StatusBar.setOverlaysWebView({overlay: true});
					g("metaviewport").setAttribute("content", "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover");
				});
			}
			
			
			
		}else{
			// document.body.removeAttribute("ovlwv");
			// g("mainview").style.marginTop = "0px";
			// requestAnimationFrame(function(){
			// 	Capacitor.Plugins.StatusBar.setOverlaysWebView({overlay: false});
			// 	g("metaviewport").setAttribute("content", "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no");
			// });
		}
		this.isOverlayWebview = enable;
	}
	app.platform.ocr = async function(){
		return Capacitor.Plugins.MainClass.mlKitOcrScreen({lang: "zh", bounding: null});
	}
	app.platform.toggleStatusBar = function(enable){
		if(this.isWeb){
			return;
		}
		if(this.isAndroid){
			if(enable || enable === null){
				AndroidFullScreen.setSystemUiVisibility(AndroidFullScreen.SYSTEM_UI_FLAG_LAYOUT_STABLE
					| AndroidFullScreen.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
					| AndroidFullScreen.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
					| AndroidFullScreen.SYSTEM_UI_FLAG_HIDE_NAVIGATION
					| AndroidFullScreen.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
				Capacitor.Plugins.StatusBar.show();
				Capacitor.Plugins.StatusBar.setOverlaysWebView({overlay: true});
			}else{
				AndroidFullScreen.immersiveMode();
				Capacitor.Plugins.StatusBar.hide();
			}
		}else{
			Capacitor.Plugins.StatusBar.hide();
		}
	}
	app.platform.haveNetwork = true;
	app.platform.statusBarHeight = 0;
	app.platform.handlerAppUrlStart = async function(){
		if(window.Capacitor){
			var url = await Capacitor.Plugins.App.getLaunchUrl();
			if(url){
				app.url.handler(url.url);
			}
		}
	}
	var rootCss = st.create("");
	rootCss.use();
	rootCss.set(":root","");
	var keyboardCss = st.create("");
	keyboardCss.use();
	if(window.Capacitor){
		if(window.Capacitor.getPlatform){
			Capacitor.platform = window.Capacitor.getPlatform();
		}
		app.platform.isAndroid = Capacitor.platform.toLowerCase() == "android";
		app.platform.isIOS = Capacitor.platform.toLowerCase() == "ios";
		if(!app.platform.isAndroid && !app.platform.isIOS){
			app.platform.isWeb = true;
		}
		if(app.platform.isAndroid){
			var chromeVersion = navigator.userAgent.match(/Chrome\/(\d+)/);
			if(chromeVersion && chromeVersion.length > 1){
				var majorVersion = parseInt(chromeVersion[1]);
				if(majorVersion < 100){
					q(".applag")[0].style.display = "block";
				}
			}
			Capacitor.Plugins.App.addListener("appStateChange", function(state){
			});
		}
		if(app.platform.isIOS){
			window.getSafeHeight = function(){
				var el = document.createElement('div');
				el.style.position = 'absolute';
				el.style.height = `env(safe-area-inset-top)`;
				el.style.width = '1px';
				el.style.top = '0';
				el.style.left = '0';
				el.style.visibility = 'hidden';
				el.style.pointerEvents = 'none';
				el.style.zIndex = '-1';
				document.body.appendChild(el);
				var topHeight = el.getBoundingClientRect().height;
				el.style.height = `env(safe-area-inset-bottom)`;
				var bottomHeight = el.getBoundingClientRect().height;
				document.body.removeChild(el);
				return {
					top: topHeight,
					bottom: bottomHeight
				}
			}
		}
		window.openInBrowser = window.open;
		if(Capacitor.Plugins.Browser){
			window.open = function(url){
				Capacitor.Plugins.Browser.open({url: url});
			}
		}
		Capacitor.Plugins.App.addListener("backButton", function(){
			app.platform.back();
		});
		var winHeight = (window.visualViewport || {}).height || window.innerHeight;
		var maxWinHeight = null;
		app.platform.paddingBottom = 0;
		window.onresize = function(){
			if(window.isCheckingStatusBarHeight){
				if(app.platform.isIOS){
					var safeArea = window.getSafeHeight();
					app.platform.statusBarHeight = safeArea.top;
					app.platform.paddingBottom = safeArea.bottom;
					window.isCheckingStatusBarHeight = false;
					console.log("detect status bar height: " + app.platform.statusBarHeight);
				}else{
					var newh = window.innerHeight - winHeight;
					if(newh > 0){
						app.platform.statusBarHeight = newh;
						window.isCheckingStatusBarHeight = false;
						console.log("detect status bar height: " + app.platform.statusBarHeight);
					}
				}
			}
			var vw100 = (window.visualViewport || {}).width || window.innerWidth;
			var vh100 = (window.visualViewport || {}).height || window.innerHeight;
			if(!maxWinHeight || vh100 > maxWinHeight){
				maxWinHeight = vh100;
			}
			// keyboard open fix
			if(vh100 < winHeight - 150){
				vh100 = Math.max(maxWinHeight, winHeight);
			}
			var vh100subtop = vh100 - 40;
			var vh100subtopbot = vh100 - 100;
			rootCss.update(":root", {
				"--status-bar-height": app.platform.statusBarHeight + "px",
				"--vh100": vh100 + "px",
				"--vw100": vw100 + "px",
				"--vh100subtop": vh100subtop + "px",
				"--vh100subtopbot": vh100subtopbot + "px",
				"--olvh100subtopbot": (vh100subtopbot - app.platform.statusBarHeight) + "px",
				"--olvh100subtopbotkb": (vh100subtopbot - app.platform.statusBarHeight) + "px",
				"--olvh100subtop": (vh100subtop - app.platform.statusBarHeight) + "px",
				"--titlebarovl": (app.platform.statusBarHeight + 40) +"px",
				"--ntitlebarovl": "-" + (app.platform.statusBarHeight + 45) +"px",
				"--screensafebottom": app.platform.paddingBottom + "px",
			});
			mainview.style.height = "100vh";
		}
		if(Capacitor.Plugins.Keyboard){
			Capacitor.Plugins.Keyboard.addListener("keyboardWillShow", function(kbInfo){
				var kbHeight = kbInfo.keyboardHeight;
				//if(!rootCss.collection["body[keyboardopen]"]){
					keyboardCss.set("body[keyboardopen]",{
						"--olvh100subtopbotkb": (parseInt(rootCss.collection[":root"].css["--olvh100subtopbot"]) - kbHeight) + "px",
					});
					keyboardCss.set(":root",{
						"--kbheight": kbHeight + "px",
						"--nkbheight": -kbHeight + "px",
						"--popwithkb": "5%"
					});
				//}
				app.input.focus();
			});
			keyboardCss.set(":root",{
				"--kbheight": "30%",
				"--nkbheight": "-30%",
				"--popwithkb": "5%"
			});
			Capacitor.Plugins.Keyboard.addListener("keyboardWillHide", function(kbInfo){
				app.input.blur();
			});
		}else{
			keyboardCss.set(":root",{
				"--kbheight": "30%",
				"--nkbheight": "-30%",
				"--popwithkb": "5%"
			});
		}
		rootCss.update(":root", {
			"--kbheight": "0px",
			"--nkbheight": "0px",
			"--status-bar-height": "0px",
			"--vh100": "100vh",
			"--vw100": "100vw",
			"--vh100subtop": "calc(100vh - 40px)",
			"--vh100subtopbot": "calc(100vh - 100px)",
			"--olvh100subtopbot": "calc(100vh - 100px)",
			"--olvh100subtopbotkb": "calc(100vh - 100px)",
			"--olvh100subtop":  "calc(100vh - 40px)",
			"--titlebarovl": "40px",
			"--ntitlebarovl": "-45px"
		});
		window.isCheckingStatusBarHeight = true;
		app.platform.overlayStatusBar(true);
		Capacitor.Plugins.App.addListener("appUrlOpen", function(data){
			var url = data.url;
			app.url.handler(url);
		});
		g("mainview").style.height = g("mainview").scrollHeight + "px";

		if(app.platform.isIOS){
			var safariVer = getSafariVersion();
			app.platform.isSafariWeb = true;
			app.platform.safariVer = safariVer.major;
		}
	}else{
		app.platform.isWeb = true;
		
		app.platform.viewport.setViewport();
		app.platform.haveNetwork = true;
		
		if (window.matchMedia('(display-mode: standalone)').matches) {
			//g("mainview").style.height = "auto";
			g("mainview").style.height = g("mainview").scrollHeight + "px";
		}else{
			g("mainview").style.height = "100%";
		}
		rootCss.update(":root", {
			"--kbheight": "0px",
			"--nkbheight": "0px",
			"--status-bar-height": "0px",
			"--vh100": "100%",
			"--vw100": "100vw",
			"--vh100subtop": "calc(100vh - 40px)",
			"--vh100subtopbot": "calc(100vh - 100px)",
			"--olvh100subtopbot": "calc(100vh - 100px)",
			"--olvh100subtopbotkb": "calc(100vh - 100px)",
			"--olvh100subtop":  "calc(100vh - 40px)",
			"--titlebarovl": "40px",
			"--ntitlebarovl": "-45px"
		});
		keyboardCss.set(":root",{
			"--kbheight": "30%",
			"--nkbheight": "-30%",
			"--popwithkb": "10%"
		});
		rootCss.set(".downloadbtn",{display: "none"});
		var safariVer = getSafariVersion();
		if(safariVer && safariVer.major){
			app.platform.isSafariWeb = true;
			app.platform.safariVer = safariVer.major;

			if(app.platform.safariVer < 13){
			}
		}
	}
	g("mainview").ontabchange = function(tabid){
		var isDarkBackground =app.theme.isDarkBackground();
		if(app.platform.isAndroid){
			if(tabid == 3){
				Capacitor.Plugins.StatusBar.setStyle({style: "DARK"});
			}else{
				if(!isDarkBackground){
					Capacitor.Plugins.StatusBar.setStyle({style: "LIGHT"});
				}
				else {
					Capacitor.Plugins.StatusBar.setStyle({style: "DARK"});
				}
			}
		}
		if(tabid == 0 || tabid == 1){
			try{
				var childTab = this.currentTabNode().q("tab");
				var childTabView = childTab.currentTabNode();
				if(childTabView.q('[sleepwake]')){
					wakeAllNode(queryInViewport(childTabView.q('[sleepwake]').parentElement).inViewport);
				}
			}
			catch(e){
				console.log(e);
			}
		}
	}
})(app);

//app.debug
(function(app){
	app.debug = {};
	app.debug.logData = "";
	app.debug.isShow = false;
	app.debug.execOnEnter = true;
	app.debug.autoScroll = true;
	app.debug.prettify = function(data, indent){
		if(typeof data == "function"){
			return data.toString();
		}
		if(typeof data == "string"){
			return data;
		}
		if(typeof data == "number"){
			return data;
		}
		if(data instanceof RegExp){
			return data.toString();
		}
		var skipEmptyString = false;
		if(data instanceof CSSStyleDeclaration){
			skipEmptyString = true;
		}
		if(data === false){
			return "false";
		}
		if(data == null || data == undefined){
			return "null";
		}
		// if(data.toString().includes("[object")){
		// 	return data;
		// }
		var tmpObject = {};
		var indentText = "";
		if(!indent){
			indent = 0;
		}
		if(indent){
			for(var i = 0; i < indent; i++){
				indentText += " ";
			}
		}
		if(indent > 4){
			return "{...}";
		}
		for(var key in data){
			var value = data[key];
			if(typeof value == "object" && value !== null){
				tmpObject[key] = this.prettify(value, indent + 4);
			}
			if(typeof value == "string"){
				if(skipEmptyString && value.length == 0){
					continue;
				}
				tmpObject[key] = value.toString().substring(0,20);
			}
			if(typeof value == "number" 
			|| typeof value == "boolean" 
			|| typeof value == "array"){
				tmpObject[key] = value.toString().substring(0,10);
			}
			if(value == null || value == undefined){
				//tmpObject[key] = "null";
				continue;
			}
			if(value == undefined){
				//tmpObject[key] = "undefined";
			}
			if(typeof value == "function"){
				tmpObject[key] = value.toString().substring(0, 50).replace(/[\r\n\t]/g,"") + "...";
			}
			
			if(value && value.tagName){
				tmpObject[key] = "Element<" + value.tagName + ">";
			}
			if(!tmpObject[key]){
				tmpObject[key] = value;
			}
		}
		var lines = [];
		for(var k in tmpObject){
			var v = tmpObject[k];
			lines.push(indentText + "    " + k + ": " + v);
		}
		return "{\n" + lines.join(",\n") + "\n" + indentText + "}";
	}
	app.debug.log = function(msg){
		if(app.debug.enabled){
			// if message is object or array, convert to string
			if(typeof msg != "string"){
				msg = this.prettify(msg);
			}

			app.debug.logData += msg + "\n";
			if(g("debug")){
				var view = g("debug");
				view.value = app.debug.logData;
				if(this.autoScroll){
					view.scrollTop = view.scrollHeight;
				}
			}
		}
	}
	app.debug.show = function(){
		var p = app.pushPage("pagedebug",{});
		p.q("#debug").value = app.debug.logData;
		var cbxAutoScroll = p.q("#debug-autoscroll");
		cbxAutoScroll.checked = this.autoScroll;
		cbxAutoScroll.onchange = function(){
			app.debug.autoScroll = this.checked;
		}
		var cbxExecOnEnter = p.q("#debug-exec-on-enter");
		cbxExecOnEnter.checked = this.execOnEnter;
		cbxExecOnEnter.onchange = function(){
			app.debug.execOnEnter = this.checked;
		}
		p.q("#debugexc").onkeyup = function(e){
			if(app.debug.execOnEnter && e.keyCode == 13){
				app.debug.exec(this.value);
				this.value = "";
			}
		}
	}
	app.debug.exec = function(){
		var cmd = g("debugexc").value;
		var val= "";
		try{
			if(cmd.trim()[0] == "{"){
				cmd = "var tmpObj = " + cmd + "; tmpObj";
			}
			val = eval(cmd);
		}catch(e){
			val = e.message;
		}
		app.debug.log(val);
		g("debugexc").value = "";
	}
	app.debug.clear = function(){
		app.debug.logData = "";
		if(g("debug")){
			g("debug").value = "";
		}
	}
	window.onerror=function(msg, url, lineNo, columnNo, error){
		if(/scrollTo/.test(msg)){
			return;
		}
		var stack = error ? error.stack : "";
		ajax("sajax=reportappscript&data=APP:"+encodeURIComponent(msg + stack)+"&file="+encodeURIComponent(url)+"&line="+lineNo,function() {});
		//alert("Error: " + msg + "\nURL: " + url + "\nLine: " + lineNo);
	}
	app.debug.report = function(err){
		var msg = "";
		if (typeof err == "string") {
			msg = err;
		} else if (err instanceof Error) {
			msg = err.message + "\n" + err.stack;
		} else {
			msg = JSON.stringify(err);
		}
		ajax("sajax=reportappscript&data=APP:"+encodeURIComponent(msg),function() {});
	}
	app.debug.reportRaw = function(data){
		ajax("sajax=reportappscript&data=APP:"+encodeURIComponent(data));
	}
	app.debug.enabled = false;
	app.debug.turnOn = function(){
		app.debug.log("debug enabled");
		var _oldLog = console.log;
		console.log = function(msg){
			app.debug.log(msg);
			_oldLog.apply(console, arguments);
		}
		window.onerror = function(msg, url, line){
			app.debug.log("error: " + msg + " at " + url + ":" + line);
		}
		var dbgbutton = document.createElement("button");
		dbgbutton.className = "debugbtn";
		dbgbutton.innerHTML = "debug";
		dbgbutton.style.top = "100px";
		dbgbutton.onclick = function(){
			app.debug.show();
		}
		document.body.appendChild(dbgbutton);
		app.debug.enabled = true;
	}
	if(app.debug.enabled){
		app.debug.turnOn();
	}
})(app);

//app.api
(function(app){
	app.api = {};
	app.api.bookmark = async function(bookdata){
		if(!app.user.isLogin){
			app.fun.showLogin();
			return;
		}
		if(!bookdata){
			bookdata = app.context.attach;
		}
		return app.net.get("/mobile/jsonify.php?ajax=addbookmark&id="+bookdata.id+"&host="+bookdata.host,function(down){
			if(down.code == 100){
				if(q("#mainview div[view=bookmarked]")[0]){
					app.rerender(q("#mainview div[view=bookmarked]")[0]);
				}
				app.toast(app.text.followed);
			}
		});
	}
	app.api.follow = async function(bookdata){
		if(!app.user.isLogin){
			app.fun.showLogin();
			return;
		}
		if(!bookdata){
			bookdata = app.context.attach;
		}
		return app.net.get("/mobile/jsonify.php?ajax=followbook&name="+encodeURIComponent(bookdata.name)+"&author="+encodeURIComponent(bookdata.author),function(down){
			if(down.code == 100){
				if(q("#mainview div[view=bookfollowing]")[0]){
					app.rerender(q("#mainview div[view=bookfollowing]")[0]);
				}
				app.toast(app.text.followed);
			}
		});
	}
	app.api.queryLike =async function(list){
		if(!app.user.isLogin){
			return [];
		}
		var url = "/mobile/jsonify.php";
		var params = `ajax=querylikestatus&list=${list.join(",")}`;
		return app.net.post(url,params).then(function(down){
			if(down.code == 100){
				return down.list;
			}else{
				return [];
			}
		});
	};
	app.api.queryBookExtStatus =async function(bookinfo){
		if(!app.user.isLogin){
			return null;
		}
		var url = "/mobile/jsonify.php";
		var params = app.serialize({
			ajax: "querybookmarkstatus",
			bookid: bookinfo.id,
			host: bookinfo.host,
			bookname: bookinfo.name,
			author: bookinfo.author
		});
		return app.net.post(url,params).then(function(down){
			if(down.code == 100){
				return down;
			}else{
				return null;
			}
		});
	};
	app.api.like = async function(type,id){
		if(!app.user.isLogin){
			app.fun.showLogin();
			return {code:0};
		}
		var url = "/mobile/jsonify.php";
		var params = `ajax=like&type=${type}&id=${id}`;
		return app.net.post(url,params).then(function(down){
			if(down.code == 100){
				return down;
			}else{
				return {code:0};
			}
		});
	}
	app.api.likeBook = async function(bookinfo){
		return app.api.like(bookinfo.host,bookinfo.id);
	}
	app.api.unlike = async function(type,id){
		if(!app.user.isLogin){
			app.fun.showLogin();
			return {code:0};
		}
		var url = "/mobile/jsonify.php";
		var params = `ajax=unlike&type=${type}&id=${id}`;
		return app.net.post(url,params).then(function(down){
			if(down.code == 100){
				return down;
			}else{
				return {code:0};
			}
		});
	}
	app.api.updateBookPage = function(p,bookinfo){
		if(!bookinfo){
			bookinfo = p.data || p.q("div").data;
		}
		app.api.queryBookExtStatus(bookinfo).then((status)=>{
			if(status.like){
				p.qq(".likebook").forEach(function(e){
					e.classList.add("active");
				});
			}else{
				p.qq(".likebook").forEach(function(e){
					e.classList.remove("active");
				});
			}
			if(status.bookmark){
				p.qq(".btnbookmark").forEach(function(e){
					e.classList.add("active");
				});
			}else{
				p.qq(".btnbookmark").forEach(function(e){
					e.classList.remove("active");
				});
			}
			if(status.follow){
				p.qq(".followbook").forEach(function(e){
					e.classList.add("active");
				});
			}else{
				p.qq(".followbook").forEach(function(e){
					e.classList.remove("active");
				});
			}
		});
	}
})(app);

//app.socialpost
(function(app){
	app.socialpost = {};
	app.socialpost.loadImage = function(e,imgUrl){
		var img = document.createElement("img");
		img.src = imgSrc(imgUrl);
		img.className = "postimage";
		var post = e.q(".post");
		post.style.position = "static";
		img.style.width = "100%";
		img.onload = function(){
			if(e.isSleep){
				e.wake();
				e.style.height = post.scrollHeight;
				post.style.position = "absolute";
				setTimeout(function(){
					e.sleep();
				},100);
			}else{
				e.style.height = post.scrollHeight;
				post.style.position = "absolute";
			}
		};
		img.onerror = function(){
			if(e.isSleep){
				e.wake && e.wake();
				e.style.height = post.scrollHeight;
				post.style.position = "absolute";
				setTimeout(function(){
					e.sleep();
				},100);
			}else{
				e.style.height = post.scrollHeight;
				post.style.position = "absolute";
			}
		};
		e.q(".postcontent .imgcontainer").appendChild(img);
	}
	app.socialpost.loadGallery = function(e,imgs){
		var imgcontainer = e.q(".postcontent .imgcontainer");
		imgcontainer.innerHTML = "";
		imgcontainer.classList.add("gallery");
		var displayMode = "grid";
		var showPlus = false;
		if(imgs.length == 1){
			displayMode = "single";
		}
		if(imgs.length == 2){
			displayMode = "double";
		}
		if(imgs.length == 3 || imgs.length == 4){
			displayMode = "quad";
		}
		if(imgs.length > 4){
			displayMode = "grid";
			if(imgs.length > 5){
				showPlus = true;
			}
		}
		imgcontainer.classList.add(displayMode);
		var loaded = 0;
		var needLoad = 0;
		for(var i=0;i<imgs.length;i++){
			var div = document.createElement("div");
			div.className = "imgholder";
			var img = document.createElement("img");
			img.src = imgSrc(imgs[i]);
			img.className = "postimage";
			div.appendChild(img);
			needLoad++;
			switch(displayMode){
				case "single": {
					div.style.width = "100%"; 
					div.style.paddingBottom = "100%";
					break;
				}
				case "double": {
					div.style.width = "50%";
					div.style.paddingBottom = "50%";
					break;
				}
				case "quad": {
					div.style.width = "50%";
					div.style.paddingBottom = "50%";
					break;
				}
				case "grid": {
					div.style.width = "33.33333333333333%";
					div.style.paddingBottom = "33.33333333333333%";
					break;
				}
			}
			img.onload = function(){
				loaded++;
				if(loaded == needLoad){
					if(e.isSleep){
						e.wake();
						e.style.height = e.q(".post").scrollHeight;
						setTimeout(function(){
							e.sleep();
						},100);
					}else{
						e.style.height = e.q(".post").scrollHeight;
					}
				}
			};
			img.onerror = function(){
				img.onload();
			};
			imgcontainer.appendChild(div);
			if(i == 4){
				break;
			}
		}
		imgcontainer.style.maxHeight = "none";
		e.style.height = "auto";
		if(showPlus){
			var plus = document.createElement("div");
			plus.className = "plus";
			plus.innerHTML = `<div>+${imgs.length - 5}</div>`;
			imgcontainer.appendChild(plus);
			
		}
	}
	app.socialpost.parseContentForImgs = function(content){
		var regex = /\[<a href="([^"]*?static.sangtacviet[^"]*?)">.*?<\/a>\]/g;
		var imgs = [];
		var match = regex.exec(content);
		while(match){
			imgs.push(match[1]);
			content = content.replace(match[0],"");
			// reset regex
			regex.lastIndex = 0;
			match = regex.exec(content);
		}
		return {
			content: content,
			imgs: imgs
		};
	}
	app.socialpost.applyEvent = function(e,isgroup){
		e.q(".avatar").addEventListener("click",function(){
			app.fun.showUser(e.data.author);
			app.platform.nativeClick();
		});
		e.q(".displayname").addEventListener("click",function(){
			app.fun.showUser(e.data.author);
			app.platform.nativeClick();
		});
		e.q(".postcontent").addEventListener("click",function(){
			app.fun.showPost(e.data, isgroup);
			app.platform.nativeClick();
		});
		e.q(".postcontent").classList.add("limit");
		e.q(".commentbtn").addEventListener("click",function(){
			if(!isgroup){
				//app.fun.showComment("topic",e.data.id);
			}else{
				//app.fun.showComment("grouptopic",e.data.id);
			}
			app.fun.showPost(e.data, isgroup, true);
			app.platform.nativeClick();
		});
		e.q(".sharebtn").addEventListener("click",function(){
			var content = e.data.content;
			var title = content.substr(0,100);
			var url = STV_SERVER + "/truyen-ngon/" + e.data.id + "/";
			app.platform.tryShare(title,content,url);
		});
		if(e.data.book){
			var bookrow = app.render("bookrow", e.data.book);
			bookrow.addEventListener("click",function(e){
				app.fun.openBook(this.data.lid);
				app.platform.nativeClick();
				e.stopPropagation();
			});
			e.q(".postcontent").appendChild(bookrow);
		}
		if(e.data.video){
			var video = app.render("videopreview", e.data.video);
			e.q(".postcontent").appendChild(video);
		}
		if(e.data.image){
			app.socialpost.loadImage(e,e.data.image);
		}else{
			e.style.height = e.q(".post").scrollHeight;
			console.log("height",e.style.height)
		}
		var imgsFromBody = app.socialpost.parseContentForImgs(e.data.content);
		if(imgsFromBody.imgs.length > 0){
			app.socialpost.loadGallery(e,imgsFromBody.imgs);
			e.q(".content").innerHTML = imgsFromBody.content;
		}
		hrefEvent(e.q(".content"));
		var obs = createFrameObserver(e.parentElement,false,true);
		app.applySleepWake(e,obs);
	}
	app.socialpost.loadSinglePost = function(e, isgroup, focusCmt){
		e.q(".avatar").addEventListener("click",function(){
			app.fun.showUser(e.data.author);
			app.platform.nativeClick();
		});
		e.q(".name").addEventListener("click",function(){
			app.fun.showUser(e.data.author);
			app.platform.nativeClick();
		});
		e.q(".commentbtn").addEventListener("click",function(){
			gsap.to(e,{scrollTop: e.q(".post").scrollHeight, duration: 0.5});
		});
		e.q(".sharebtn").addEventListener("click",function(){
			var content = e.data.content;
			var title = content.substr(0,100);
			var url = STV_SERVER + "/truyen-ngon/" + e.data.id + "/";
			app.platform.tryShare(title,content,url);
		});
		if(e.data.book){
			var bookrow = app.render("bookrow", e.data.book);
			bookrow.addEventListener("click",function(e){
				app.fun.openBook(this.data.lid);
				app.platform.nativeClick();
				e.stopPropagation();
			});
			e.q(".postcontent").appendChild(bookrow);
		}
		if(e.data.video){
			var video = app.render("video", e.data.video);
			video.q("iframe").src = "https://www.youtube.com/embed/"+e.data.video.vid+"?autoplay=1";
			e.q(".postcontent").appendChild(video);
		}
		var imgsFromBody = app.socialpost.parseContentForImgs(e.data.content);
		if(imgsFromBody.imgs.length > 0){
			for(var i = 0; i < imgsFromBody.imgs.length; i++){
				var img = document.createElement("img");
				img.src = imgSrc(imgsFromBody.imgs[i]);
				img.className = "postimage";
				e.q(".postcontent").appendChild(img);
				img.style.width = "100%";
			}
			e.q(".content").innerHTML = imgsFromBody.content;
		}
		hrefEvent(e.q(".content"));
		if(e.data.image){
			var img = document.createElement("img");
			img.src = imgSrc(e.data.image);
			img.className = "postimage";
			e.q(".postcontent").appendChild(img);
			img.style.width = "100%";
		}
		var post = e.q(".post");
			post.style.position = "static";
		var cmtsection = e.q(".embedcomment");
		var host = "topic";
		if(isgroup){
			host = "grouptopic";
		}
		var cmts = app.render("embedcomment",{});
		cmtsection.appendChild(cmts);
		var scrollToY = 0;
		if(focusCmt){
			scrollToY = post.scrollHeight;
			console.log(scrollToY)
		}
		app.comment.loadEmbed(cmts.q(".comments"),host,e.data.id,0,scrollToY,focusCmt);
		
	}
	app.socialpost.likeBtnEvent = function(btn,isgroup){
		var root = app.findRoot(btn);
		var topic = root.data;
		var isLiked = btn.classList.contains("active");
		var type = isgroup ? "grouptopic":"topic";
		if(isLiked){
			app.api.unlike(type,topic.id).then(function(down){
				btn.classList.remove("active");
				topic.liked--;
				root.q(".liked").innerHTML = topic.liked;
			});
		}else{
			app.api.like(type,topic.id).then(function(down){
				btn.classList.add("active");
				topic.liked++;
				root.q(".liked").innerHTML = topic.liked;
			});
		}
	}
	app.socialpost.queryLikeStatus = function(l, isgroup){
		var toQuery = [];
		var hashMap = {};
		var type = isgroup ? "grouptopic":"topic";
		for(var i = 0; i < l.length; i++){
			var root = app.findRoot(l[i]);
			toQuery.push(`${type}:${root.data.id}`);
			hashMap[root.data.id] = l[i];
			l[i].onclick = function(){
				app.socialpost.likeBtnEvent(this,isgroup);
			}
		}
		app.api.queryLike(toQuery).then(function(down){
			for(var i = 0; i < down.length; i++){
				var btn = hashMap[down[i].objectid];
				btn.classList.add("active");
			}
		});
	}
	app.socialpost.channel = {
		preview:{
			title: "Kênh truyện",
			channelCode: "book",
			fetch: function(container, page, infinite){
				if(page == 0){
					var preloader = app.createPreloader();
					container.appendChild(preloader);
				}
				app.net.get("/?ajax=topic&sub=gettopicmobile&ttype=book&p="+page,true).then(async function(down){
					if(infinite){
						infinite.remove();
					}
					app.removePreloader(container);
					if(down.code == -1){
						container.appendChild(app.createNodata(formatError("Không thể tải dữ liệu",down)));
					}
					if(down.length == 0){
						container.appendChild(app.createNodata("Không có bài viết nào"));
					}
					var likeBtns = [];
					for(var i=0;i<down.length;i++){
						var item = down[i];
						var p = app.render("post",item);
						container.appendChild(p);
						await waitFrame();
						app.socialpost.applyEvent(p);
						var lbtn = p.q(".likebtn");
						lbtn.root = p;
						likeBtns.push(p.q(".likebtn"));
					}
					if(down.length > 0){
						var inf = app.createInf(
							function(){
								app.socialpost.channel.preview.fetch(container,parseInt(page)+1,inf);
							}
						);
						container.appendChild(inf);
					}
					app.socialpost.queryLikeStatus(likeBtns);
				});
			}
		},
		world:{
			title: "Kênh linh tinh",
			channelCode: "other",
			fetch: function(container, page, infinite){
				if(page == 0){
					var preloader = app.createPreloader();
					container.appendChild(preloader);
				}
				app.net.get("/?ajax=topic&sub=gettopicmobile&ttype=other&p="+page,true).then(async function(down){
					app.removePreloader(container);
					if(infinite){
						infinite.remove();
					}
					if(down.code == -1){
						container.appendChild(app.createNodata(formatError("Không thể tải dữ liệu",down)));
					}
					if(down.length == 0){
						container.appendChild(app.createNodata("Không có bài viết nào"));
					}
					var likeBtns = [];
					for(var i=0;i<down.length;i++){
						var item = down[i];
						var p = app.render("post",item);
						container.appendChild(p);
						await waitFrame();
						app.socialpost.applyEvent(p);
						var lbtn = p.q(".likebtn");
						lbtn.root = p;
						likeBtns.push(lbtn);
					}
					if(down.length > 0){
						var inf = app.createInf(
							function(){
								app.socialpost.channel.world.fetch(container,parseInt(page)+1,inf);
							}
						);
						container.appendChild(inf);
					}
					app.socialpost.queryLikeStatus(likeBtns);
				});
			}
		},
		user:{
			title: "Các bài viết của ",
			channelCode: "other",
			fetch: function(container, uid, page, infinite){
				if(page == 0){
					var preloader = app.createPreloader();
					container.appendChild(preloader);
				}
				app.net.get("/?ajax=topic&sub=gettopicmobile&ttype=person&user="+uid+"&p="+page,true).then(function(down){
					app.removePreloader(container);
					if(infinite){
						infinite.remove();
					}
					if(down.code == -1){
						container.appendChild(app.createNodata(formatError("Không thể tải dữ liệu",down)));
					}
					if(down.length == 0){
						container.appendChild(app.createNodata("Không có bài viết nào"));
					}
					var likeBtns = [];
					for(var i=0;i<down.length;i++){
						var item = down[i];
						var p = app.render("post",item);
						container.appendChild(p);
						app.socialpost.applyEvent(p);
						var lbtn = p.q(".likebtn");
						lbtn.root = p;
						likeBtns.push(p.q(".likebtn"));
					}
					if(down.length > 0){
						var inf = app.createInf(
							function(){
								app.socialpost.channel.user.fetch(container,uid,parseInt(page)+1,inf);
							}
						);
						container.appendChild(inf);
					}
					app.socialpost.queryLikeStatus(likeBtns);
				});
			}
		},
		faction:{
			title: "Kênh thế lực",
			channelCode: "faction",
			fetch: function(container, page, infinite){
				if(page == 0){
					var preloader = app.createPreloader();
					container.appendChild(preloader);
				}
				app.net.get("/?ajax=topic&sub=gettopicmobile&ttype=faction&p="+page,true).then(function(down){
					app.removePreloader(container);
					if(infinite){
						infinite.remove();
					}
					if(down.code == -1){
						container.appendChild(app.createNodata(formatError("Không thể tải dữ liệu",down)));
					}
					if(down.length == 0){
						container.appendChild(app.createNodata("Không có bài viết nào"));
					}
					var likeBtns = [];
					for(var i=0;i<down.length;i++){
						var item = down[i];
						var p = app.render("post",item);
						container.appendChild(p);
						app.socialpost.applyEvent(p, true);
						var lbtn = p.q(".likebtn");
						lbtn.root = p;
						likeBtns.push(p.q(".likebtn"));
					}
					if(down.length > 0){
						var inf = app.createInf(
							function(){
								app.socialpost.channel.faction.fetch(container,parseInt(page)+1,inf);
							}
						);
						container.appendChild(inf);
					}
					app.socialpost.queryLikeStatus(likeBtns, true);
				});
			}
		},
	};
	app.socialpost.postNew = function(channel, content, isgroup, url = null){
		if(!app.user.isLogin){
			app.user.showLogin();
			return;
		}
		var channelCode = this.channel[channel].channelCode;
		var data = {
			ajax: "topic",
			sub: isgroup ? "postnewgrouptopic" :"postnewtopic",
			content: content,
			channel: channelCode
		};
		if(url){
			data.url = url;
		}
		var params = app.serialize(data);
		return app.net.post("/",params,true);
	}
})(app);

//app.url
(function(app){
	app.url = {};
	app.url.mappings = {
		"/truyenn?/([a-zA-Z0-9]+)/\\d+/(\\d+)/#cmtid=(\\d+)": function(match){
			var host = match[1];
			if(host == "reply"){
				return;
			}
			var id = match[2];
			var cmtId = match[3];
			app.fun.openBookByHost(host,id);
			app.fun.showComment(host,id,cmtId);
		},
		"/truyenn?/([a-zA-Z0-9]+)/\\d+/(\\d+)/": function(match){
			var host = match[1];
			if(host == "reply"){
				return;
			}
			var id = match[2];
			app.fun.openBookByHost(host,id);
		},
		"/truyen-ngon/(\\d+)/": function(match){
			var postId = match[1];
			app.fun.showSinglePost(postId, false);
		},
		"/binh-luan/#cmtid=(\\d+)": function(match){
			app.fun.showComment('broadcast',0)
		},
		"/truyen-ngon/\\d*?/?#topic=(\\d+)&cmtid=(\\d+)": function(match){
			var postId = match[1];
			var cmtId = match[2];
			app.fun.showSinglePost(postId, false, cmtId);
		},
		"/user/(\\d+)/": function(match){
			var uid = match[1];
			app.fun.showUser(uid);
		}
	};
	app.url.handler = function(url){
		for(var i in app.url.mappings){
			var match = url.match(new RegExp(i));
			if(match){
				app.url.mappings[i](match);
				return;
			}
		}
	}
	app.url.test = function(url){
		for(var i in app.url.mappings){
			var match = url.match(new RegExp(i));
			if(match){
				return true;
			}
		}
		return false;
	}

})(app);
(function(app){
	app.browser = {};
	app.browser.instance = null;
	app.browser.open = function(url){
		if(app.browser.instance == null){
			app.browser.instance = window.open(url);
		}else{
			
		}
	}
})(app);
(function(app){
	app.input = {
		isKeyboardOpen: false,
	};
	app.input.focus = function(input){
		document.body.setAttribute("keyboardopen","true");
		app.input.isKeyboardOpen = true;
	}
	app.input.blur = function(input){
		document.body.removeAttribute("keyboardopen");
		app.input.isKeyboardOpen = false;
	}
	app.input.apply = function(page){
		var inputElement = page.querySelectorAll("input[type=text],input[type=password],textarea");
		if(inputElement){
			for(var i=0;i<inputElement.length;i++){
				var input = inputElement[i];
				input.addEventListener("focus",this.focus);
				input.addEventListener("blur",this.blur);
			}
		}
	}
})(app);

//app.namemanager
(function(app){
	app.namemanager = {
	};
	app.namemanager.get =async function(key){
		try{
			return JSON.parse(await app.storage.cache.getFile(key));
		}catch(e){
			return null;
		}
	}
	var dbUpdateSingle = function(){
		if(app.namemanager.saveDataSingle){
			return app.namemanager.saveDataSingleInst;
		}
		if(window.dbGate){
			app.namemanager.saveDataSingleInst = dbGate.single();
			return app.namemanager.saveDataSingleInst;
		}else{
			return null
		}
	}
	app.namemanager.set =async function(key,value){
		await app.storage.cache.setFile(key,JSON.stringify(value));
	}
	app.namemanager.namecontext = "";
	app.namemanager.nametree = {}
	app.namemanager.phrasetree = {}
	app.namemanager.namedata = [];
	app.namemanager.parsedNameData = [];
	app.namemanager.parsedNameDataGlobal = [];
	app.namemanager.nameglobal = [];
	app.namemanager.loadGlobalName = async function(){
		if(this.nameglobal.length > 0){
			return;
		}
		var data = await app.namemanager.get("name_global");
		if(data == null){
			return;
		}else{
			app.namemanager.nameglobal = data;
			app.namemanager.refreshCacheGlobal();
		}
	}
	app.namemanager.refreshCache = function(){
		this.namedatacache = this.namedata.join("\n");
	}
	app.namemanager.refreshCacheGlobal = function(){
		this.namedatacacheglobal = this.nameglobal.join("\n");
	}
	app.namemanager.saveGlobalName = async function(){
		await app.namemanager.set("name_global",app.namemanager.nameglobal);
	}
	app.namemanager.parseData =async function(key){
		if(key == "name_"){
			return;
		}
		var data = await app.namemanager.get(key);
		if(data == null){
			return;
		}else{
			app.namemanager.namedata = data;
			app.namemanager.refreshCache();
		}
	}
	app.namemanager.update = function(idx, name){
		this.namedata[idx] = name;
		this.saveData();
		app.namemanager.refreshCache();
	}
	app.namemanager.append = function(name){
		this.namedata.push(name);
		this.saveData();
		app.namemanager.refreshCache();
	}
	app.namemanager.appendPack = function(pack){
		var lines = pack.split("\n");
		lines.forEach(function(e){
			if(e && e.indexOf("=") > 0 && app.namemanager.namedata.indexOf(e) == -1){
				app.namemanager.namedata.push(e);
			}
		});
		this.saveData();
		app.namemanager.refreshCache();
		app.toast("Đã nhập gói name");
	}
	app.namemanager.updateGlobal = function(idx, name){
		this.nameglobal[idx] = name;
		this.saveGlobalName();
		app.namemanager.refreshCacheGlobal();
	}
	app.namemanager.appendGlobal = async function(name){
		this.nameglobal.push(name);
		await this.saveGlobalName();
		app.namemanager.refreshCacheGlobal();
	}
	app.namemanager.saveData =async function(key, instant = false){
		if(key=="name_" || !this.namecontext){
			return;
		}
		var dbGate = dbUpdateSingle();
		if(dbGate && !instant){
			dbGate.query((async function(){
				await app.namemanager.set(key || this.namecontext,this.namedata);
				//app.reader.runNameForAll();
			}).bind(this));
		}
		else{
			await app.namemanager.set(key || this.namecontext,this.namedata);
			//app.reader.runNameForAll();
		}
	}
	app.namemanager.parseFunction = function(e){
		if(e!=""){
			var row = e.split("=");
			if(row.length<2){}
			else{
				if(row[0]!=""){
					if(row[0].charAt(0)=="@"){
						row[0]=row[0].substring(1).split("|");
						if(row[1]!=null)row[1]=row[1].split("|");
						return {
							ver: "v1",
							base: row[0],
							name: row[1],
						}
					}else 
					if(row[0].charAt(0)=="#"){
						return {
							ver: "vp",
							base: row[0].substring(1),
							name: row[1],
						}
					}else 
					if(row[0].charAt(0)=="$"){
						var sear=row[0].substring(1);
						var rep=row.joinlast(1);
						return {
							ver: "v2",
							base: sear,
							name: rep,
						};
					}else 
					if(row[0].charAt(0)=="~"){
						return {
							ver: "ve",
							base: row[0].substring(1),
							name: "",
						};
					}
					else{
						return {
							ver: "v0",
							base: row[0],
							name: row[1],
						};
					}
				}
			}
		}
		return null;
	}
	app.namemanager.resetContext = function(){
		this.namecontext = "";
		this.namedata = [];
		this.parsedNameData = [];
		this.parsedNameDataGlobal = [];
		this.namedatacache = "";
		this.refreshCache();
	}
	app.namemanager.parseNameTree = function(){
		app.namemanager.parsedNameData = [];
		this.namedata.forEach(function(r,i){
			var name = app.namemanager.parseFunction(r);
			if(name){
				name.index = i;
				app.namemanager.parsedNameData.push(name);
			}
		});
	}
	app.namemanager.parseNameTreeGlobal = function(){
		app.namemanager.parsedNameDataGlobal = [];
		this.nameglobal.forEach(function(r,i){
			var name = app.namemanager.parseFunction(r);
			if(name){
				name.index = i;
				name.isglobal = true;
				app.namemanager.parsedNameDataGlobal.push(name);
			}
		});
	}
	app.namemanager.loadContext =async function(book){
		var datakey = `name_${book.name}_${book.author}`;
		if(this.namecontext == datakey){
			return;
		}
		await this.parseData(datakey);
		this.namecontext = datakey;
		this.loadGlobalName();
	}
	app.namemanager.updateNameData = function(v){
		var rows = v.split("\n");
		this.namedata = rows;
		//rows.forEach(element => {
		////	if(this.nameglobal.indexOf(element)==-1){
		//		this.namedata.push(element);
		//	}
		//});
	}
	app.namemanager.namerowFunction = function(e){
		var t = e.target;
		var r = t.parentElement.parentElement;
		if(t.className.contain("b1")){
			console.log("delete");
			console.log(r.datarow);
			var d = r.datarow;
			var isGlobal = d.isglobal;
			var idx = Array.from(this.querySelectorAll(".namerow")).indexOf(r);
			if(isGlobal){
				app.namemanager.nameglobal.splice(idx,1);
				app.namemanager.saveGlobalName();
			}else{
				app.namemanager.namedata.splice(idx,1);
				app.namemanager.saveData();
			}
			app.namemanager.refreshCache();
			app.namemanager.refreshCacheGlobal();
			r.remove();
		}
		else if(t.className.contain("b2")){
			console.log("edit");
			console.log(r.datarow);
			var popupTemplate = $.extend({},app.context.menu.namemanager.edit);
			popupTemplate.data = {
				nameeditbase: r.datarow.base,
				nameeditname: r.datarow.name,
				nameedittype: r.datarow.ver,
			};
			app.context.showPopup(popupTemplate, r);
		}
	}
	app.namemanager.loadTable1 = function(p){
		p = p || app.topPage();
	}
	app.namemanager.showManager =async function(book){
		console.log(book);
		var dname = book.tname;
		if(dname.length > 20){
			dname = dname.substr(0,20) + "...";
		}
		var p = app.pushPage("pagernamepage",{
			bookname: dname || "Name riêng",
		});
		var tab = p.q("tab");
		ui.smtab(tab,0,0,0,1,true).setTabColor("#ffffff");
		await this.loadContext(book);
		var tabview1 = p.q("tabview");
		var tabbar = tab.q("tabbar");
		var table1 = ui.table("Loại","Gốc","Tên","Thao tác");
		table1.className ="nametable";
		this.parseNameTree();
		this.parseNameTreeGlobal();
		for(var i=0;i<this.parsedNameData.length;i++){
			var name = this.parsedNameData[i];
			table1.row(name.ver,name.base,name.name,`
				<button class="nmgbtn b1 fa-icon-text">${"\uf00d"}</button> 
				<button class="nmgbtn b2 fa-icon-text">${"\uf040"}</button>
			`);
			name.row = table1.lastChild;
			name.row.classList.add("namerow");
			table1.lastChild.datarow = name;
		}
		table1.addEventListener("click",this.namerowFunction);
		tabview1.appendChild(table1);
		var tabview2 = p.q("tabview + tabview");
		var table2 = ui.table("Loại","Gốc","Tên","Thao tác");
		table2.className ="nametable";
		for(var i=0;i<this.parsedNameDataGlobal.length;i++){
			var name = this.parsedNameDataGlobal[i];
			table2.row(name.ver,name.base,name.name,`
				<button class="nmgbtn b1 fa-icon-text">${"\uf00d"}</button> 
				<button class="nmgbtn b2 fa-icon-text">${"\uf040"}</button>
			`);
			name.row = table2.lastChild;
			name.row.classList.add("namerow");
			table2.lastChild.datarow = name;
		}
		table2.addEventListener("click",this.namerowFunction);
		tabview2.appendChild(table2);
		table1.q("tr").classList.add("th-sticky");
		table2.q("tr").classList.add("th-sticky");

		var searchinput = p.q("input.search");
		searchinput.addEventListener("keyup", function() {
			var selector = searchinput.getAttribute("searchsel");
			var currentTabView = tab.currentTabNode().q(".nametable");
			ui.filterSel(searchinput, currentTabView, selector);
			console.log(searchinput.value, selector);
		});
	}
	app.namemanager.showMenu = function(){
		var menu = app.context.menu.namemanager.menu;
		app.context.showMenu(menu);
	}
	app.namemanager.altSaveNS = function(){
		this.saveData();
	}
	app.namemanager.showAddName = function(){
		var popupTemplate = $.extend({},app.context.menu.namemanager.add);
		app.context.showPopup(popupTemplate);
	}
	app.namemanager.showNameByBook = function(){
		var book = app.reader.bookinfo;
		if(!book)return;
		var p = app.pushPage("namebybook", book);
		var list = p.q(".list");
		app.net.get("/mobile/namepack.php?m=book&book="+book.id+"&host="+book.host).then(async function(down){
			down = down.data;
			if(!down){
				list.appendChild(app.createNodata("Có lỗi khi tải danh sách gói name cho truyện này."));
				return;
			}
			if(down.length == 0){
				list.appendChild(app.createNodata("Chưa có gói name cho truyện này."));
				return;
			}
			for(var i=0;i<down.length;i++){
				let item = app.render("namepackbybookrow", down[i]);
				item.q(".download").addEventListener("click",function(){
					app.namemanager.appendPack(item.data.content);
				});
				list.appendChild(item);
			}
		});
	}
	app.namemanager.showNamePack = function(){
		var p = app.pushPage("namepackmanager", {});
		var pub = p.q(".publiclist");
		var my = p.q(".mylist");
		var keyword = "";
		var loader = function(){
			app.net.get("/io/namepack/query?q="+encodeURIComponent(keyword)).then(async function(down){
				code = down.code;
				if(!code || code!=400){
					pub.innerHTML = "";
					pub.appendChild(app.createNodata("Có lỗi khi tải danh sách gói name đặc biệt."));
					return;
				}
				var publist = down.public;
				var mylist = down.mypack;
				if(publist){
					pub.innerHTML = "";
					if(publist.length == 0){
						pub.appendChild(app.createNodata("Không tìm thấy gói name nào."));
					}
					for(var i=0;i<publist.length;i++){
						let item = app.render("namepackrow", publist[i]);
						item.q(".download").addEventListener("click",function(){
							app.namemanager.appendPack(item.data.content);
						});
						pub.appendChild(item);
					}
				}
				if(mylist){
					my.innerHTML = "";
					if(mylist.length == 0){
						my.appendChild(app.createNodata("Bạn chưa tạo gói name nào."));
					}
					for(var i=0;i<mylist.length;i++){
						let item = app.render("namepackrowedit", mylist[i]);
						item.q(".edit").addEventListener("click",function(){});
						item.q(".download").addEventListener("click",function(){
							app.namemanager.appendPack(item.data.content);
						});
						my.appendChild(item);
					}
				}
			});
		}
		var tab = p.q("tab");
		ui.smtab(tab,0,0,0,1,true).setTabColor("#ffffff");
		var search = p.q(".search");
		p.q(".search").addEventListener("keyup",function(){
			setTimeoutOnce("namepacksearch",function(){
				keyword = search.value;
				loader();
			},500);
		});
		loader();
	}
	app.namemanager.deleteAllNameCurrent = function(){
		this.namedata = [];
		this.saveData(null, true);
		app.topPage().q("tabview").qq(".namerow").forEach(e=>e.remove());
	}
})(app);

// app.surf
(function(app){
	app.surf = {};
	app.surf.launch = function(){
		if(app.platform.isAndroid){
			this.browser.init();
		}
		else {
			window.surfWindow = window.open(STV_SERVER + '/surf.php');
		}
	}
	app.surf.open = function(url){
		if(app.platform.isAndroid){
			this.browser.init();
		}
		app.browser.open("http://"+STV_SERVER+"/surf.php?link="+encodeURIComponent(url));
	}
	app.surf.listenEvent = function(){
		document.addEventListener("onwebviewpageload", function(){
			console.log("onwebviewpageload");
			app.surf.browser.updateTabText();
		});
	}
	app.surf.IsolatedWv =async function(){
		var webview = await AndroidView.create("android.webkit.WebView");
		webview.node.className = "ntwebview";
		webview.node.style.position = "absolute";
		webview.isUnlockOnPointerDown = false;
		//var webclient = await AndroidView.createObject("android.webkit.WebViewClient");
		var webclient = await AndroidView.createHandler(
			"android.webkit.WebViewClient","onPageFinished","onwebviewpageload");
		webview.setWebViewClient(""+webclient.id);
		
		//console.log(webclient);
		//await webview._setSize("100%","100%");
		return webview;
	}
	app.surf.getChapter =async function(url){
		var surl = STV_SERVER+"/surf.php?detectcontent=true&appcontext=true&link="+encodeURIComponent(url);
		var iframe = document.createElement("iframe");
		setCookie("allowscript",'true',30);
		setCookie("allowqt",'true',30);
		iframe.src = surl;
		iframe.style.display = "none";
		document.body.appendChild(iframe);
		iframe.onload = function(){
			setTimeout(function(){
				iframe.remove();
			},1000);
		}
		return new Promise(function(resolve,reject){
			app.surf.addEvent(function(data){
				if(data.event == "surf_content" && data.currentUrl == url){
					resolve(data);
					return true;
				}
			});
			setTimeout(function(){
				iframe.remove();
				reject();
			}, 30000);
		});
	}
	app.surf.getBookInfo =async function(url,chint){
		var surl = STV_SERVER+"/surf.php?detectbook=true&link="+encodeURIComponent(url)+"&appcontext=true&chapterhint="+encodeURIComponent(chint);
		var iframe = document.createElement("iframe");
		setCookie("allowscript",'true',30);
		setCookie("allowqt",'true',30);
		iframe.src = surl;
		iframe.style.display = "none";
		document.body.appendChild(iframe);
		iframe.onload = function(){
			setTimeout(function(){
				iframe.remove();
			},1000);
		}
		return new Promise(function(resolve,reject){
			app.surf.addEvent(async function(data){
				if(data.event == "surf_bookinfo" && data.currentUrl == url){
					if(!data.chapterList || data.chapterList.length == 0){
						if(data.chapterListUrl){
							try{
								var clist = await app.surf.getChapterList(data.chapterListUrl);
								data.chapterList = clist;}
							catch(e){
								console.log(e);
								data.chapterList = [];
							}
						}
					}
					data.host = "surf";
					data.id = data.currentUrl;
					data.tname = await translateWithQt(data.name);
					if(data.author){
						data.hauthor = await translateWithQt(data.author);
					}
					if(data.description){
						data.info = await translateWithQt(data.description);
					}
					resolve(data);
					return true;
				}
			});
			setTimeout(function(){
				iframe.remove();
				reject();
			}, 30000);
		});
	}
	app.surf.events = [];
	app.surf.addEvent = function(e){
		this.events.push(e);
	};
	app.surf.callback = function(data){
		for(var i=0;i<this.events.length;i++){
			if(this.events[i](data)){
				this.events.splice(i,1);
				i--;
			}
		}
	}
	app.surf.init = function(){
		var posibleEvents = ["surf_content","surf_bookinfo"]
		window.addEventListener("message",function(e){
			console.log(e);
			if(posibleEvents.indexOf(e.data.event) >= 0){
				var data = e.data;
				app.surf.callback(data);
			}
			if(e.data.event == "surf_onload"){
				var source = e.source;
				source.postMessage({isApp: true}, "*");
			}
			if(e.data.event == "surf_openbook"){
				var source = e.source;
				source.blur();
				window.focus();
				app.fun.openSurfBook(e.data.url);
			}
		});
	}
	app.surf.init();
	app.surf.openBrowser = function(initUrl){
		
	}
	app.surf.browser = {
		tabbar: null,
		titlebar: null,
		addrbar: null,
		tabviews: null,
		currentTab: null,
		indexUrl: "https://m.kuaikanmanhua.com",
		ictScript: "/asset/app.v2.surf.trans.js",
		applyWebSetting: async function(wv){
			var settings = await wv.getSettings();
			settings.setJavaScriptEnabled(true);
			settings.setJavaScriptCanOpenWindowsAutomatically(true);

		},
		loadUrl: function(tab,url){},
		checkICT: function(tab){},
		evalScript: function(tab,script){
			var wv = tab.tab;
			wv.loadUrl("javascript:(function(){"+script+"})();");
		},
		loadTranslate: function(tab){
			var url = STV_SERVER + "/asset/app.v2.surf.trans.js?v=4";
			this.evalScript(tab,`if(!document.querySelector('script[src*="app.v2.surf"]')){var script = document.createElement('script');
				script.src='${url}';document.body.appendChild(script);}`);
		},
		newTab: async function(initUrl){
			if(!initUrl){
				initUrl = this.indexUrl;
			}
			var d = document.createElement("div");
			d.className = "wvtab";
			d.innerHTML = '<span class="wvtabtitle">Trang web</span><span class="wvtabclose">&times;</span>';
			this.tabbar.appendChild(d);
			
			var wv = await app.surf.IsolatedWv();
			this.tabviews.appendChild(wv.node);
			var w = document.body.scrollWidth;
			var h = document.body.scrollHeight - this.titlebar.scrollHeight - this.tabbar.clientHeight;
			await wv._setSize(w,h);
			await this.applyWebSetting(wv);
			if(initUrl){
				//setTimeout(function(){
					wv.loadUrl(initUrl);
					d.tabUrl = initUrl;
					app.surf.browser.addrbar.value = initUrl;
				//},2000);
			}
			d.tab = wv;
			this.changeTab(d);
			d.addEventListener("click",function(){
				app.surf.browser.changeTab(this);
			});
			d.q(".wvtabclose").addEventListener("click",function(e){
				e.stopPropagation();
				app.surf.browser.closeTab(this.parentNode);
			});
		},
		updateTabText: async function(){
			for(var i=0;i<app.surf.browser.tabbar.children.length;i++){
				var t = app.surf.browser.tabbar.children[i];
				var wv = t.tab;
				var title = await wv.getTitle();
				if(title && title.length > 0){
					t.q(".wvtabtitle").textContent = title;
				}
				var url = await wv.getUrl();
				if(url && url.length > 0){
					if(t.tabUrl != url && t.scrollThresholdIndex > 0){
						t.scrollThresholdIndex = 0;
					}
					t.tabUrl = url;
				}
					
				if(t == app.surf.browser.currentTab){
					this.addrbar.value = url;
				}
				this.loadTranslate(t);
			}
		},
		updatePageTitle: async function(){
			this.pageTitleTimer = setInterval(async function(){
				if(app.surf.browser.isClosed){
					clearInterval(app.surf.browser.pageTitleTimer);
					return;
				}
				for(var i=0;i<app.surf.browser.tabbar.children.length;i++){
					var t = app.surf.browser.tabbar.children[i];
					var wv = t.tab;
					var title = await wv.getTitle();
					if(title && title.length > 0)
					t.q(".wvtabtitle").textContent = title;
					
				}
			}, 3000);
		},
		closeTab:async function(t){
			var wv = t.tab;
			await wv.unlockView();
			wv.node.remove();
			await wv.destroyDrawingCache();
			await wv.destroy();
			t.remove();
			if(this.tabbar.children.length == 0){
				this.close();
			}else{
				if(this.currentTab == t){
					this.currentTab = null;
					this.currentWv = null;
				}
				this.changeTab(this.tabbar.children[0]);
			}
		},
		changeTab: function(t){
			if(this.currentTab){
				this.currentTab.classList.remove("active");
				var tmp = this.currentTab.tab;
				tmp.unlockView();
			}
			this.currentTab = t;
			t.classList.add("active");
			this.currentWv = t.tab;
			this.currentWv.lockView();
			this.addrbar.value = this.currentTab.tabUrl || "";
			app.surf.comic.setWebview(this.currentWv.node);
		},
		page: null,
		init: function(initUrl){
			this.isClosed = false;
			//this.updatePageTitle();
			if(this.page && isInDocumentTree(this.page)){
				//app.bringToTop(this.page);
				var wv = app.surf.browser.currentWv;
					wv.lockView();
					wv.loadUrl(initUrl);
					app.surf.browser.currentTab.tabUrl = initUrl;
					app.bringToFront(this.page);
				return;
			}
			var p = this.page = app.pushPage("pagebrowser",{},function(en){
				app.surf.browser.newTab(initUrl);
			});
			this.tabbar = p.q(".tabs");
			this.tabviews = p.q(".webviews");
			this.titlebar = p.q(".titlebar");
			this.addrbar = p.q(".url");
			this.addrbar.addEventListener("keydown",function(e){
				if(e.keyCode == 13){
					var url = this.value;
					if(!url.match(/^https?:/)){
						url = "http://"+url;
					}
					var wv = app.surf.browser.currentWv;
					wv.loadUrl(url);
					app.surf.browser.currentTab.tabUrl = url;
				}
			});
			
			p.q(".newtab").addEventListener("click",function(){
				app.surf.browser.newTab();
			});
			p.q(".showmenu").addEventListener("click",function(){
				//return;
				var mn = app.context.menu.browser;
				app.surf.browser.currentWv.draw().then(()=>{
					app.surf.browser.currentWv.unlockView();
				});
				app.context.showMenu(mn);
			});
		},
		isClosed: true,
		goBack:async function(){
			if(this.isClosed){
				return false;
			}
			var wv = this.currentWv;
			if(await wv.canGoBack()){
				wv.goBack();
				return true;
			}
			return false;
		},
		close: function(){
			this.currentWv.unlockView();
			this.isClosed = true;
			app.goback();
			this.disposeAll();
		},
		disposeAll:async function(){
			for(var i=0;i<this.tabbar.children.length;i++){
				var t = this.tabbar.children[i];
				var wv = t.tab;
				//await wv.onPause();
				//await wv.removeAllViews();
				await wv.destroyDrawingCache();
				//await wv.pauseTimers();
    			await wv.destroy();
			}
			this.tabbar = null;
			this.tabviews = null;
			this.titlebar = null;
			this.addrbar = null;
		},
		reload: async function(){
			var wv = this.currentWv;
			wv.reload();
		}
	}
	ui.scriptmanager.load("/asset/app.v2.comicprovider.js",null,true);
	app.surf.comic = {
		webview: null,
		context: null,
		setWebview: function(wv){
			this.webview = wv;
		},
		getScrollY: async function(){
			return parseInt((await this.webview.view.getScrollY())) / devicePixelRatio;
		},
		performTrans: async function(){
			var bounding = {
				x: 0,
				y: 105 * devicePixelRatio,
				w: + this.webview.getAttribute("width") * devicePixelRatio,
				h: + this.webview.getAttribute("height") * devicePixelRatio
			}
			this.activatedOffsetY = await this.getScrollY();
			var result = await this.context.mlKitOcrScreen({
				lang: "zh",
				bounding: `${bounding.x},${Math.floor(bounding.y)},${Math.floor(bounding.w)},${Math.floor(bounding.h)}`
			});
			var blocks = result.result;
			var l = Object.keys(blocks).length;
			for(var i=0;i<l;i++){
				let bl = this.constructBlock(blocks[i+""]);
				if(bl){
					this.translateBlock(bl).then((function(){
						this.sendBlockToWebview(bl);
					}).bind(this));
				}
			}
		},
		objectToArray: function(obj){
			var arr = [];
			for(var k in obj){
				arr.push(obj[k]);
			}
			return arr;
		},
		constructBlock: function(block){
			var corner = block.cornerPoints;
			var lines = this.objectToArray(block.lines);
			if(!(/[\u3400-\u9FBF]/.test(lines[0].text))){
				return null;
			}
			var text = lines.map(l=>{
				var t = l.text;
				t = t.replace(/^-/, "一")
					.replace(/-$/, "一")
					.replace(/1$/, "的")
					.replace(/|/g, "")
				return t;
			}).join("");
			var rect = this.cornerPointsToRect(corner);
			this.scaleRectDownToView(rect);
			rect.y += this.activatedOffsetY - 105;
			return {
				text,
				top: rect.y,
				left: rect.x,
				width: rect.w,
				height: rect.h
			}
		},
		translateBlock: async function(block){
			var text = block.text;
			var result = await translateWithQt(text);
			block.text = result;
		},
		sendBlockToWebview: function(block){
			var payload = encodeURIComponent(JSON.stringify(block));
			var script = `addTranslatedBlock('${payload}');`;
			this.webview.view.loadUrl("javascript:(function(){"+script+"})();");
		},
		cornerPointsToRect: function(points){
			var x = Math.min(points[0].x, points[1].x, points[2].x, points[3].x);
			var y = Math.min(points[0].y, points[1].y, points[2].y, points[3].y);
			var w = Math.max(points[0].x, points[1].x, points[2].x, points[3].x) - x;
			var h = Math.max(points[0].y, points[1].y, points[2].y, points[3].y) - y;
			return {x,y,w,h};
		},
		scaleRectDownToView: function(rect){
			var r = window.devicePixelRatio;
			rect.x = rect.x / r;
			rect.y = rect.y / r;
			rect.w = rect.w / r;
			rect.h = rect.h / r;
		},
		scaleRectUpToScreen: function(rect){
			var r = window.devicePixelRatio;
			rect.x = rect.x * r;
			rect.y = rect.y * r;
			rect.w = rect.w * r;
			rect.h = rect.h * r;
		},
		initEvent: function(){
			document.addEventListener("onwebviewscrollchanged", function(){
				app.surf.comic.checkThreshold().then(function(result){
					if(result === true){
						console.log("scroll threshold reached");
						app.surf.comic.performTrans();
					}
				});
			});
		},
		applyEvent: async function(){
			var currentPageUrl = await this.webview.view.getUrl();
			if(app.comicReader.init(currentPageUrl)){
				return;
			}
			var scrollChangeListener = await AndroidView.createHandler("android.view.View$OnScrollChangeListener","onScrollChange","onwebviewscrollchanged");
			this.webview.view.setOnScrollChangeListener(scrollChangeListener.id +"");
		},
		isChecking: false,
		checkThreshold: async function(){
			if(this.timer || this.isChecking){
				return;
			}
			var h = parseInt(this.webview.style.height);
			var c = this.webview.scrollThresholdIndex || 0;
			this.isChecking = true;
			var y = await this.getScrollY();
			this.isChecking = false;
			if(y > h * c * 0.8){
				this.webview.scrollThresholdIndex = c + 1;
				this.timer = setTimeout(function(){
					app.surf.comic.timer = null;
					app.surf.comic.isChecking = false;
				}, 500);
				this.activatedOffsetY = y;
				return true;
			}
			return false;
		},
	}
	if(window.Capacitor && window.Capacitor.Plugins.MlKit){
		app.surf.comic.context = window.Capacitor.Plugins.MlKit;
		app.surf.comic.initEvent();
	}
	app.surf.listenEvent();
})(app);

//app.pushserver
(function(app){
	app.pushserver = {
		server: "wss://push.sangtacvietcdn.xyz",
		wsClient: null,
		channelConnected: [],
	};
	app.pushserver.addEvent = function(){
		this.wsClient.onmessage = function(e){
			var data = JSON.parse(e.data);
			app.pushserver.onMessage(data);
		}
		this.wsClient.onopen = function(){
			console.log("pushserver connected");
			app.pushserver.reconnectChannel();
		}
		this.wsClient.onclose = function(){
			if(app.pushserver.channelConnected.length > 0)
				setTimeoutOnce("ws-reconnect", function(){
					app.pushserver.wsClient = new WebSocket(app.pushserver.server);
					app.pushserver.addEvent();	
				}, 500);
		}
	}
	app.pushserver.init = function(){
		if(!app.pushserver.wsClient){
			app.pushserver.wsClient = new WebSocket(app.pushserver.server);
			app.pushserver.addEvent();
		}else{
			//check re
			if(app.pushserver.wsClient.readyState == WebSocket.CLOSED){
				this.reset();
				app.pushserver.wsClient = new WebSocket(app.pushserver.server);
				app.pushserver.addEvent();
			}
		}
	};
	app.pushserver.isOnline = function(){
		if(app.pushserver.wsClient){
			return app.pushserver.wsClient.readyState == WebSocket.OPEN;
		}
		return false;
	}
	app.pushserver.connectChannel = function(channel, retry){
		if(this.channelConnected.indexOf(channel) >= 0){
			return;
		}
		if(!retry){
			retry = 0;
		}
		if(retry > 5){
			return;
		}

		if(!app.pushserver.isOnline()){
			app.pushserver.init();
		}
		if(this.wsClient.readyState == WebSocket.OPEN){
			if(this.channelConnected.indexOf(channel) < 0){
				app.pushserver.wsClient.send("connect "+channel);
				console.log("connect "+channel);
				this.channelConnected.push(channel);
			}
		}else if(this.wsClient.readyState == WebSocket.CONNECTING){
			setTimeout(function(){
				app.pushserver.connectChannel(channel , retry+1);
				console.log("connect "+channel);
			},1000);
		}
		
	};
	app.pushserver.reconnectChannel = function(){
		if(this.wsClient.readyState == WebSocket.CONNECTING){
			return;
		}
		for(var i=0;i<this.channelConnected.length;i++){
			app.pushserver.wsClient.send("connect "+this.channelConnected[i]);
			console.log("connect "+this.channelConnected[i]);
		}
	}
	app.pushserver.listener = [];
	app.pushserver.onMessage = function(data){
		if(this.listener.length == 0){
			setTimeout(function(){
				if(app.pushserver.listener.length == 0){
					app.pushserver.reset();
				}
			}, 60000);
		}
		for(var i=0;i<app.pushserver.listener.length;i++){
			try{
				app.pushserver.listener[i](data);
			}catch(e){
				console.log(e);
			}
		}
	};
	app.pushserver.addListener = function(e){
		app.pushserver.listener.push(e);
	}
	app.pushserver.reset = function(){
		app.pushserver.wsClient && app.pushserver.wsClient.close();
		app.pushserver.wsClient = null;
		app.pushserver.listener = [];
		app.pushserver.channelConnected = [];
	}
	app.pushserver.removeListener = function(e, c){
		var index = app.pushserver.listener.indexOf(e);
		if(index >= 0){
			app.pushserver.listener.splice(index, 1);
		}
		index = app.pushserver.channelConnected.indexOf(c);
		if(index >= 0){
			app.pushserver.channelConnected.splice(index, 1);
		}
		if(app.pushserver.listener.length == 0){
			// wait 1 minute to reset
			setTimeout(function(){
				if(app.pushserver.listener.length == 0){
					app.pushserver.reset();
				}
			}, 60000);
		}
	}
})(app);
 

//app.theme
(function(app){
	app.theme = {
		css: st.create(),
		store: new app.objectStore("themeset"),
	};
	app.theme.init = function(){
		this.store.load().then(result=>{
			if(result == null){
				console.log("theme not found");
				app.theme.saveDefault();
			}else{
				var active = app.theme.store.active;
				app.theme.setBgAcText(active);
				console.log("theme found");
			}
			app.platform.handlerAppUrlStart();
		});
	};
	app.theme.css.use();
	app.theme.generator = {
		"--bg-5": "diff --background 5%",
		"--bg-10": "diff --background 10%",
		"--bg-15": "diff --background 15%",
		"--bg-25": "diff --background 25%",
		"--bg-50": "diff --background 50%",
		"--bg-75": "diff --background 75%, brightness --bg-75",
		"--bg-100": "diff --background 100%",
		"--ac-25": "diff --accent-color 25%",
		"--ac-50": "diff --accent-color 50%",
		"--ac-75": "diff --accent-color 75%",
		"--ac-100": "invert --accent-color 100%",
		"--ac-text": "text --accent-color 100%",
		"--bg-tps": "transparent --background 00",
		"--bg-tps-50": "transparent --background 50",
		"--bg-tps-88": "transparent --background 88",
		"--active": "diff --background 15%, transparent --active ad",
	}
	app.theme.parseLine = function(line){
		var arr = line.split(",");
		var operation = [];
		for(var i=0;i<arr.length;i++){
			var item = arr[i].trim().split(" ");
			var result = {};
			result.type = item[0];
			result.name = item[1];
			result.value = item[2];
			operation.push(result);
		}
		return operation;
	}
	app.theme.alterColorByPercent = function(color, percent) {
		percent = parseInt(percent);
		if(ui.color.isDark(color)){
			return ui.color.lighter(color, percent);
		}
		return ui.color.darker(color, percent);
	}
	app.theme.generatorExcute = function(css){
		css.getValue = function(name){
			return css.collection[":root"].css[name];
		}
		css.setValue = function(name, value){
			css.collection[":root"].css[name] = value;
		}
		var background = css.getValue("--background");
		var accent = css.getValue("--accent-color");
		var textColor = css.getValue("--color");
		if(!textColor){
			textColor = ui.color.optimalTextColor(background);
		}
		if(!background && textColor){
			background = ui.color.invert(textColor);
		}
		var bright = 100;
		if(app.config && app.config.ux){
			var tb = app.config.ux.text_brightness;
			var perc = bright = 100 - Math.floor(parseFloat(tb) * 100);
			if(perc < 0 || perc > 40){ perc = bright = 0;}
			textColor = ui.color.getAlterColor(textColor, perc);
			console.log(bright);
		}
		css.setValue("--color", textColor);
		css.setValue("--background", background);
		css.setValue("--accent-color", accent);
		for(var rule in this.generator){
			var ruleInstruction = this.parseLine(this.generator[rule]);
			var lastVar = null;
			//console.log(ruleInstruction);
			for(var ins of ruleInstruction){
				if(ins.type == 'diff'){
					lastVar = this.alterColorByPercent(css.getValue(ins.name), ins.value);
					css.setValue(rule, lastVar);
					//console.log(rule, lastVar);
				}
				if(ins.type == 'same'){
					css.setValue(rule, css.getValue(ins.value));
				}
				if(ins.type == "invert"){
					css.setValue(rule, ui.color.invert(css.getValue(ins.name)));
				}
				if(ins.type == "darklight"){
					if(ui.color.isDark(css.getValue(ins.name))){
						css.setValue(rule, "#ffffff");
					}else{
						css.setValue(rule, "#000000");
					}
				}
				if(ins.type == "transparent"){
					css.setValue(rule, css.getValue(ins.name) + ins.value);
				}
				if(ins.type == "text"){
					var c = css.getValue(ins.name);
					var grayScale = ui.color.grayScaleFloat(c) / 255;
					if(grayScale > 0.7){
						css.setValue(rule, "#000000");
					}else{
						css.setValue(rule, "#ffffff");
					}
				}
				if(ins.type == "brightness"){
					var c = css.getValue(ins.name);
					c = ui.color.getAlterColor(c, bright);
					css.setValue(rule, c);
				}
			}
		}
		css.refresh();
		return css;
	}
	app.theme.getColorVar = function(name){
		if(name.contain("var")){
			name = name.match(/\((.*?)\)/)[1];
		}
		return app.theme.css.getValue(name);
	}
	app.theme.setTheme = function(theme){
		if(app.theme.themes.indexOf(theme) < 0){
			return;
		}
		app.theme.theme = theme;
		localStorage.setItem("theme", theme);
	}
	app.theme.isDarkBackground = function(){
		return ui.color.isDark(app.theme.css.getValue("--background"));
	}
	app.theme.syncColor = function(){
		this.setBgAcText(this.store.active);
	}
	app.theme.css.set(":root",`--color: #000000;
	--background: #ffffff;
	--accent-color: #00aaff;
	--accent-color-dark: #00aaff;
	--accent-color-light: #00aaff;
	--accent-color-text: #ffffff;
	--accent-color-text-dark: #ffffff;`)
	app.theme.generatorExcute(app.theme.css);
	app.theme._onBgColorChange = [];
	app.theme.onBgColorChange = function(callback){
		app.theme._onBgColorChange.push(callback);
	}
	app.theme.setBgColor = function(color){
		app.theme.css.setValue("--background", color);
		app.theme.css.setValue("--color", "");
		app.theme.generatorExcute(app.theme.css);
		for(var callback of app.theme._onBgColorChange){
			callback();
		}
	}
	app.theme._onAccentColorChange = [];
	app.theme.onAccentColorChange = function(callback){
		app.theme._onAccentColorChange.push(callback);
	}
	app.theme.setAccentColor = function(color){
		app.theme.css.setValue("--accent-color", color);
		app.theme.generatorExcute(app.theme.css);
		for(var callback of app.theme._onAccentColorChange){
			callback();
		}
	}
	app.theme.setTextColor = function(color){
		app.theme.css.setValue("--color", color);
		app.theme.generatorExcute(app.theme.css);
	}
	app.theme.setBgAcText = function(obj){
		app.theme.setBgColor(obj.background);
		app.theme.setAccentColor(obj.accent);
		app.theme.setTextColor(obj.text);
	}
	app.theme.saveDefault = function(){
		this.store.data = [
			{background: "#333333", accent: "#00aaff", text: "#ffffff"},
			{background: "#ffffff", accent: "#00aaff", text: "#000000"},
			// white background pink accent
			{background: "#ffffff", accent: "#ff00ff", text: "#000000"},
			// black background pink accent
			{background: "#333333", accent: "#ff00ff", text: "#ffffff"},
			// white background purple accent
			{background: "#ffffff", accent: "#ff00ff", text: "#000000"},
			// white background light green accent
			{background: "#ffffff", accent: "#2a892a", text: "#000000"},
			// black background light green accent
			{background: "#333333", accent: "#2a892a", text: "#ffffff"},

		];
		this.store.active = this.store.data[0];
		this.store.save();
	}
	if(app.platform.isIOS){
		app.theme.css.set("html", "touch-action: manipulation;");
	}
	app.theme.init();
	app.theme.loadThemeChoose = function(){
		var l = this.store.data;
		var container = q(".themesetchoose")[0];
		container.innerHTML = "";
		var activeIndex = this.store.data.indexOf(this.store.active);
		for(var i = 0; i < l.length; i++){
			let item = l[i];
			var button = app.render("theme-choose-button",{});
			button.q(".bgcolor").style.backgroundColor = item.background;
			button.q(".accolor").style.backgroundColor = item.accent;
			if(i == activeIndex){
				button.classList.add("active");
			}
			button.addEventListener("click", function(){
				app.theme.setBgAcText(item);
				app.theme.store.active = item;
				app.theme.store.save();
				app.platform.nativeclick();
			});
			button.addEventListener("contextmenu", function(){
				app.theme.setBgAcText(item);
				app.theme.store.active = item;
				app.theme.adjustTheme(item);
			});
			container.appendChild(button);
		}
		var btn = app.render("theme-choose-button",{});
		btn.innerHTML = `<i class="fas fa-wrench" style="line-height:45px;"></i>`;
		btn.addEventListener("click", function(){
			app.theme.createTheme();
			app.platform.nativeclick();
		});
		btn.classList.add("edit");
		container.appendChild(btn);
	}
	app.theme.adjustTheme = function(theme){
		var popupTemplate = $.extend({},app.context.menu.setting.themeEditor);
		var p = app.context.showPopup(popupTemplate, theme);
		var bg = p.q(".bgcolor");
		var ac = p.q(".accolor");
		var cp = iro.ColorPicker(p.q(".colorpicker"),{
			color: app.theme.getColorVar("--background"),
			width: 200,
		});
		bg.addEventListener("click", function(){
			if(!this.classList.contains("active")){
				ac.classList.remove("active");
				cp.color.hexString = app.theme.getColorVar("--background");
				this.classList.add("active");
				
			}
		});
		ac.addEventListener("click", function(){
			if(!this.classList.contains("active")){
				bg.classList.remove("active");
				cp.color.hexString = app.theme.getColorVar("--accent-color");
				this.classList.add("active");
				
			}
		});
		cp.on("color:change", function(color){
			if(bg.classList.contains("active")){
				app.theme.setBgColor(color.hexString);
			}else if(ac.classList.contains("active")){
				app.theme.setAccentColor(color.hexString);
			}
		});
	}
	app.theme.createTheme = function(){
		var n = {background: "#ffffff", accent: "#00aaff", text: "#000000"};
		app.theme.store.data.push(n);
		app.theme.store.active = n;
		app.theme.setBgAcText(n);
		this.adjustTheme(n);
	}
	app.theme.saveEditor = function(){
		var active = app.theme.store.active;
		active.background = app.theme.getColorVar("--background");
		active.accent = app.theme.getColorVar("--accent-color");
		active.text = app.theme.getColorVar("--color");
		app.theme.store.save();
	}
})(app);

// app.perf
(function(app){
	app.perf = {
		enabled: false,
		cssLink: {}
	};
	app.perf.initCss = `
		html,body{
			background-color: transparent !important;
		}
	`;
	app.perf.createFrame = function(){
		var frame = document.createElement("iframe");
		frame.className = "perf-frame";
		var csses = document.querySelectorAll("link[rel=stylesheet],style");
		var head = [];
		for(var i=0;i<csses.length;i++){
			var css = csses[i];
			if(css.href){
				head.push(`<link rel="stylesheet" href="${css.href}">`);
			}else{
				head.push(`<style>${css.textContent}</style>`);
			}
		}
		head.push(`<style>${app.perf.initCss}</style>`);
		frame.srcdoc = `<html><head>${head.join("")}</head><body></body></html>`;
		frame.q = function(selector){
			return frame.contentDocument.querySelector(selector);
		}
		frame.qq = function(selector){
			return frame.contentDocument.querySelectorAll(selector);
		}
		return frame;
	}
	var exports = ["onImgError","imgSrc"];
	HTMLIFrameElement.prototype.q = function(s){
		return this.contentDocument.querySelector(s)
	}
	HTMLIFrameElement.prototype.qq = function(s){
		return this.contentDocument.querySelectorAll(s)
	}
	app.perf.pushPageToFrame = function(e, aniEvent){
		if(app.platform.isWeb){
			return;// this.pushPageToShadow(e, aniEvent); // a/b test
		}
		if(app.platform.isSafariWeb || app.platform.isIOS){
			if(app.platform.safariVer < 10){
				return e;
			}
		}
		var frame = app.perf.createFrame();
		frame.style.opacity = 0;
		var parent = g("overlay");
		var d = document.createElement("div");
		frame.onload = async function(){
			if(aniEvent){
				await aniEvent;
			}
			app.perf.copyAttributes(document.body, frame.contentDocument.body);
			var scrollPos = e.scrollTop;
			
			
			//e.style.width = "100%";
			//e.style.height = "100%";
			var w = frame.contentWindow;
			w.app = app;
			w.ui = ui;
			for(var i=0;i<exports.length;i++){
				var name = exports[i];
				w[name] = window[name];
			}
			w.$ = w.jQuery = w.$ || w.jQuery || w.app.$;
			requestAnimationFrame(function(){
				frame.contentDocument.body.appendChild(e);
				e.classList.add("perf-div");
				frame.style.opacity = 1;
				if(e.hasAttribute("swipe")){
					app.applyDragOut(e, d);
				}
			});
			var tb = e.q(".titlebar");
			if(tb){
				tb.style.zIndex = 100;
			}
			e.scrollTop = scrollPos;
			d.body = frame.contentDocument.body;
		};
		frame.setAttribute("allowtransparency", "true");
		d.className = "perf-holder";
		d.appendChild(frame);
		d.q = function(s){
			return e.q(s);
		}
		d.qq = function(s){
			return e.qq(s);
		}
		d.self = e;
		parent.appendChild(d);
		return d;
	}
	app.perf.pushPageToShadow = function(e, aniEvent){
		if(app.platform.isSafariWeb || app.platform.isIOS){
			if(app.platform.safariVer < 10){
				return e;
			}
		}
		var perfDiv = document.createElement("div");
		perfDiv.className = "perf-div-x";
		e.classList.add("perf-div");
		var shadowHolder = document.createElement("div");
		var shadow = shadowHolder.attachShadow({mode: "open"});
		// var contentHolder = document.createElement("div");
		// contentHolder.appendChild(e);
		// contentHolder.className = "perf-content";
		shadow.appendChild(e);
		shadowHolder.className = "perf-holder";
		shadowHolder.style.width = "100%";
		shadowHolder.style.height = "100%";
		app.perf.copyAttributes(document.body, shadowHolder);
		var csses = document.querySelectorAll("link[rel=stylesheet],style");
		var head = [];
		for(var i=0;i<csses.length;i++){
			var css = csses[i];
			if(css.href){
				head.push(`<link rel="stylesheet" href="${css.href}">`);
			}else{
				head.push(`<style>${css.textContent}</style>`);
			}
		}
		head.push(`<style>${app.perf.initCss}</style>`);
		var style = document.createElement("div");
		style.innerHTML = head.join("");
		style.className = "perf-style";
		shadow.appendChild(style);

		perfDiv.q = function(s){
			return e.q(s);
		}
		perfDiv.qq = function(s){
			return e.qq(s);
		}
		perfDiv.self = e;
		Object.defineProperty(e, "parentElement", {
			get: function(){
				return shadowHolder;
			},
		});
		Object.defineProperty(perfDiv, "isRoot", {
			get: function(){
				return e.isRoot;
			},
			set: function(v){
				e.isRoot = v;
			}
		});
		Object.defineProperty(perfDiv, "data", {
			get: function(){
				return e.data;
			},
			set: function(v){
				e.data = v;
			}
		});
		Object.defineProperty(perfDiv, "children", {
			get: function(){
				return e.children;
			},
			set: function(v){
				e.children = v;
			}
		});
		Object.defineProperty(perfDiv, "contentDocument", {
			get: function(){
				return perfDiv.shadowRoot;
			}
		});
		Object.defineProperty(perfDiv, "contentWindow", {
			get: function(){
				return window;
			}
		});
		perfDiv.appendChild(shadowHolder);
		if(e.hasAttribute("swipe")){
			aniEvent.then(function(){
				app.applyDragOut(e, perfDiv);
			});
		}
		shadow.addEventListener("click", function(e){
			window.event = e;
		});
		shadow.addEventListener("contextmenu", function(e){
			window.event = e;
		});
		return perfDiv;
	}
	app.perf.copyAttributes = function(e1, e2){
		for(var i=0;i<e1.attributes.length;i++){
			var attr = e1.attributes[i];
			e2.setAttribute(attr.name, attr.value);
		}
	}
	app.perf.topFrame = function(){
		var perfHolder = g("overlay").querySelectorAll(".perf-holder");
		if(perfHolder.length == 0){
			return null;
		}
		var last = perfHolder[perfHolder.length-1];
		var frame = last.querySelector("iframe");
		if(frame){
			return frame;
		}
		if(last.shadowRoot){
			return last.shadowRoot;
		}
		return null;
	}
})(app);

// app.fontmanager
(async function(app){
	app.fontmanager = {
		fonts: [
			{name:"helvetica", haveDecrypt: true, isWeb: true},
			{name:"opensans", haveDecrypt: true, isWeb: true},
			{name:"stvverdana",haveDecrypt: true, isWeb: true},
			{name:"roboto",haveDecrypt: true, isWeb: true},
			{name:"stvarial",haveDecrypt: true, isWeb: true},
			{name:"stvtahoma",haveDecrypt: true, isWeb: true},
			{name:"palatinolinotype",haveDecrypt: true, isWeb: true},
			{name:"nunito",haveDecrypt: true, isWeb: true},
			{name:"sourceserifpro",haveDecrypt: true, isWeb: true},
			{name:"robotoslab",haveDecrypt: true, isWeb: true},
		],
		webEncryptedUrl: "/ctp/cssoutput.css?v=" + Math.random(),
		webUrl: "/font/font.css?v=4",
		localCss: st.create(),
		selected: "nunito"
	};
	app.fontmanager.localCss.use();
	app.fontmanager.openNewFont = function(){
		openFontFilePicker().then(async function(e){
			console.log(e);
			return img2Base64(await e[0].getFile());
		}).then(async function(b64){
			var blob = await app.images.mani.base64ToBlob(b64);
			var font = {
				name: await app.context.prompt("Font name"),
				haveDecrypt: false,
				isWeb: false,
				blob: blob,
				url: URL.createObjectURL(blob)
			};
			app.fontmanager.saveFontToDb(font.name, b64).then(function(){
				app.fontmanager.saveLocalList();
			});
			app.fontmanager.fonts.push(font);
			app.fontmanager.applyCss();
			console.log(font);
			app.toast("Font added: "+font.name);
			var topPage = app.topPage();
			if(topPage.q(".font-list")){
				topPage.q(".font-list").firstChild.remove();
				topPage.q(".font-list").appendChild(app.fontmanager.render());
			}
		}).catch(function(e){
			console.log(e);
			app.toast("Error");
		});
	}
	app.fontmanager.applyCss = function(){
		var localList = this.fonts.filter(f => !f.isWeb);
		var t = [];
		for(var i=0;i<localList.length;i++){
			t.push(`@font-face {
				font-family: "${localList[i].name}";
				src: url("${localList[i].url}");
			}`);
		}
		this.localCss.textContent = t.join("\n");
	}
	app.fontmanager.blobToBase64 = function(blob){
		return new Promise(function(resolve, reject){
			var reader = new FileReader();
			reader.onloadend = function() {
				resolve(reader.result);
			}
			reader.readAsDataURL(blob);
		});
	}
	app.fontmanager.saveFontToDb = async function(fontName,b64){
		await app.storage.cache.setFile("font_"+fontName, b64);
	}
	function dataURItoBlob(dataURI) {
		let [metadata, data] = dataURI.split(',');
		let mime = metadata.match(/:(.*?);/)[1];
		let byteCharacters = atob(data);
		let byteNumbers = new Uint8Array(byteCharacters.length);
		for (let i = 0; i < byteCharacters.length; i++) {
			byteNumbers[i] = byteCharacters.charCodeAt(i);
		}
		return new Blob([byteNumbers], { type: mime });
	}
	app.fontmanager.loadFontFromDb = function(fontName){
		return new Promise(function(resolve, reject){
			app.storage.cache.getFile("font_"+fontName).then(function(base64){
				var blob = dataURItoBlob(base64);
				resolve(blob);
			});
		});
	}
	app.fontmanager.saveLocalList = async function(){
		var localList = this.fonts.filter(f => !f.isWeb);
		var t = [];
		for(var i=0;i<localList.length;i++){
			t.push(localList[i].name);
		}
		await app.storage.cache.setFile("localFonts", t.join(","));
	}
	app.fontmanager.loadLocalList = async function(){
		var list = await app.storage.cache.getFile("localFonts");
		if(list){
			list = list.split(",");
			for(var i=0;i<list.length;i++){
				var font = {name: list[i],
					haveDecrypt: false,
					isWeb: false,
					blob: null,
					url: null
				};
				font.blob = await app.fontmanager.loadFontFromDb(font.name);
				font.url = URL.createObjectURL(font.blob);
				this.fonts.push(font);
			}
		}
		this.applyCss();
	}
	app.fontmanager.removeLocalFont = function(fontName){
		var index = this.fonts.findIndex(f => f.name == fontName && !f.isWeb);
		if(index >= 0){
			this.fonts.splice(index, 1);
			this.applyCss();
			this.saveLocalList();
			app.storage.cache.setFile("font_"+fontName, "");
		}
	}
	app.fontmanager.init = async function(){
		await onDbLoad.waitForLoad();
		await this.loadLocalList();
	}
	app.fontmanager.init();
	app.fontmanager.isDecrypt = function(fontName){
		return this.fonts.findIndex(f => f.name == fontName && f.haveDecrypt) >= 0;
	}
	app.fontmanager.isWebFont = function(fontName){
		return this.fonts.findIndex(f => f.name == fontName && f.isWeb) >= 0;
	}
	app.fontmanager.render = function(){
		var d = document.createElement("div");
		d.classList.add("font-manager");
		for(var i=0;i<this.fonts.length;i++){
			let font = this.fonts[i];
			var f = document.createElement("div");
			f.classList.add("fontitem");
			f.classList.add(font.haveDecrypt ? "decrypt" : "encrypt");
			f.classList.add(font.isWeb ? "web" : "local");
			f.innerHTML = font.name + "<br>" + app.text.text_for_test_font;
			f.style.fontFamily = font.name;
			// f.onclick = function(){
			// 	if(!this.className.contain("selected")){
			// 		app.fontmanager.selected = this.innerText;
			// 		this.classList.add("selected");
			// 		d.q(".font.selected").classList.remove("selected");
			// 	}
			// }
			if(!font.isWeb){
				ui.hold(f, function(){
					app.context.showMenu(app.context.menu.fontmanager, font);
				});
			}
			d.appendChild(f);
		}
		return d;
	}
	app.fontmanager.getFontUrl = function(isEncrypt){
		if(isEncrypt){
			return this.webEncryptedUrl;
		}else{
			return this.webUrl;
		}
	}
	app.fontmanager.openFontManager = function(){
		var p = app.pushPage("fontmanager", {});
		var view = p.q(".font-list");
		view.appendChild(this.render());
		p.q(".go-back").onclick = function(){
			app.popPage();
		}
	}
})(app);

// app.images
(function(app){
	app.images = {};
	app.images.load = async function(src,imTag){
		var img = new Image();
		img.referrerPolicy = "no-referrer";
		if(imTag){
			if(app.config && app.config.ux && !app.config.ux.allow_image_preload){
				imTag.style.animation = "none";
			}
		}
		var pm = new Promise(function(resolve, reject){
			var completed = false;
			var timer = setTimeout(function(){
				if(completed){
					return;
				}
				completed = true;
				if(imTag){
					if(imTag.onerror){
						imTag.onerror();
					}else{
						onImgError(imTag);
					}
				}
				reject();
			}, 20000);
			img.onload = function(){
				if(completed){
					return;
				}
				completed = true;
				resolve(img);
				if(imTag){
					imTag.src = img.src;
				}
				clearTimeout(timer);
			}
			img.onerror = function(){
				if(completed){
					return;
				}
				completed = true;
				if(imTag){
					if(imTag.onerror){
						imTag.onerror();
					}else{
						onImgError(imTag);
					}
				}else{
					reject();
				}
				clearTimeout(timer);
			}
			
		});
		
		img.src = src;
		return pm;
	}
	app.images.download = async function(url, headers = {}){
		var p = Capacitor.Plugins.Http;
		var rs = await p.get({
			url: url,
			headers: headers,
			responseType: "blob"
		});
		var contentType = rs.headers["content-type"]
							|| rs.headers["Content-Type"]
							|| rs.headers["Content-type"]
							|| rs.headers["content-Type"];
		//var blob = new Blob([atob(rs.data)], {type: contentType});
		var blob = this.mani.base64ToBlobWithoutHeader(rs.data, contentType);
		return blob;
	}
	app.images.downloadAndAssign = async function(url, imTag, headers = {}){
		var blob = await this.download(url, headers);
		return new Promise(function(r){
			imTag.onload = function(){
				r();
				URL.revokeObjectURL(imTag.src);
			}
			imTag.onerror = function(e){
				// print error
				//printStackTrace();
				console.log(`Loading ${url} failed`);
			}
			imTag.src = URL.createObjectURL(blob);
		});
	}
	app.images.mani = {
		canvas: document.createElement("canvas"),
		ctx: null,
		init: function(){
			this.ctx = this.canvas.getContext("2d");
			this.imgResIdManager.load().then(rs=>{
				if(rs == null){
					this.imgResIdManager.data = [];
					this.imgResIdManager.save();
				}
			});
		},
		resize: function(img, width, height){
			this.canvas.width = width;
			this.canvas.height = height;
			this.ctx.drawImage(img, 0, 0, width, height);
			return this.canvas.toDataURL("image/jpeg");
		},
		png2jpg: function(img){
			this.canvas.width = img.width;
			this.canvas.height = img.height;
			this.ctx.drawImage(img, 0, 0);
			return this.canvas.toDataURL("image/jpeg");
		},
		getDominateColor: function(img){
			// draw 50x50 image
			this.canvas.width = 50;
			this.canvas.height = 50;
			this.ctx.drawImage(img, 0, 0, 50, 50);
			var data = this.ctx.getImageData(0, 0, 50, 50).data;
			var r = 0, g = 0, b = 0;
			var count = 0;
			for(var i=0;i<data.length;i+=4){
				if(data[i+3] > 128){
					r += data[i];
					g += data[i+1];
					b += data[i+2];
					count++;
				}
			}
			if(count == 0){
				return null;
			}
			return {
				r: r/count,
				g: g/count,
				b: b/count
			}
		},
		getColorPalette: function(img){
			this.canvas.width = img.width;
			this.canvas.height = img.height;
			this.ctx.drawImage(img, 0, 0);
			var data = this.ctx.getImageData(0, 0, img.width, img.height).data;
			var colors = {};
			for(var i=0;i<data.length;i+=4){
				if(data[i+3] > 128){
					var color = data[i]+","+data[i+1]+","+data[i+2];
					if(colors[color]){
						colors[color]++;
					}else{
						colors[color] = 1;
					}
				}
			}
			var colorArr = [];
			for(var color in colors){
				colorArr.push({
					color: color,
					count: colors[color]
				});
			}
			colorArr.sort(function(a,b){
				return b.count - a.count;
			});
			return colorArr;
		},
		isPng: function(base64){
			return base64.substring(0, 22) == "data:image/png;base64,";
		},
		isJpg: function(base64){
			return base64.substring(0, 23) == "data:image/jpeg;base64,";
		},
		isGif: function(base64){
			return base64.substring(0, 22) == "data:image/gif;base64,";
		},
		loadImg: async function(base64){
			var img = new Image();
			img.src = base64;
			await new Promise(function(resolve,reject){
				img.onload = function(){
					resolve();
				}
				img.onerror = function(){
					reject();
				}
			});
			return img;
		},
		saveImg: async function(base64){
			if(this.isPng(base64) || this.isGif(base64)){
				base64 = this.png2jpg(await this.loadImg(base64));
			}
			var randomResId ="img." + Math.random().toString(36).substr(2);
			var res = await app.storage.cache.setFile(randomResId, base64);
			this.imgResIdManager.data.push(randomResId);
			this.imgResIdManager.save();
			return randomResId;
		},
		isRescId: function(base64){
			return base64.substring(0, 4) == "img.";
		},
		getImg: async function(resIdOrBase64){
			if(resIdOrBase64.substring(0, 4) == "img."){
				return await app.storage.cache.getFile(resIdOrBase64);
			}else{
				return resIdOrBase64;
			}
		},
		deleteImg: async function(resId){
			if(resId.substring(0, 4) == "img."){
				await app.storage.cache.setFile(resId, "");
			}
		},
		imgResIdManager: new app.objectStore("imgResIdManager"),
		cleanImgStore: async function(){
			var resIds = this.imgResIdManager.data;
			for(var i=0;i<resIds.length;i++){
				await app.storage.cache.setFile(resIds[i], "");
			}
			this.imgResIdManager.data = [];
			this.imgResIdManager.save();
		},
		getImgAsBlobUrl: async function(resIdOrBase64){
			var img = await this.getImg(resIdOrBase64);
			return URL.createObjectURL(await this.base64ToBlob(img));
		},
		base64ToBlob: async function(base64){
			var arr = base64.split(",");
			var mime = arr[0].match(/:(.*?);/)[1];
			var bstr = atob(arr[1]);
			var n = bstr.length;
			var u8arr = new Uint8Array(n);
			while(n--){
				u8arr[n] = bstr.charCodeAt(n);
			}
			return new Blob([u8arr], {type:mime});
		},
		base64ToBlobWithoutHeader: async function(base64, mime){
			var bstr = atob(base64);
			var n = bstr.length;
			var u8arr = new Uint8Array(n);
			while(n--){
				u8arr[n] = bstr.charCodeAt(n);
			}
			return new Blob([u8arr], {type:mime});
		},
		openGallery: async function(choose){
			var p = app.pushPage("pagegallery");
			var rs, rj = null;
			var promise = new Promise(function(resolve, reject){
				rs = resolve;
				rj = reject;
			});
			var container = p.q(".gridview");
			p.q(".add").addEventListener("click", function(){
				openImageFilePicker(true).then(async (imgRef)=>{
					var imgFile = await imgRef[0].getFile();
					var base64 = await img2Base64(imgFile);
					var resId = await app.images.mani.saveImg(base64);
					rs(resId);
					if(choose){
						p.q(".close").click();
					}else{
						let imgId = resId;
						let imgPreview = app.render("imgpreview", {imgpreviewimg:base64});
						imgPreview.q(".removebtn").addEventListener("click",function(){
							app.images.mani.imgResIdManager.data.splice(app.images.mani.imgResIdManager.data.indexOf(imgId), 1);
							app.images.mani.imgResIdManager.save();
							app.images.mani.deleteImg(imgId);
							container.removeChild(imgPreview);
						});
						imgPreview.setAttribute("data-imgid", imgId);
						imgPreview.q(".progresscanvas").remove();
						container.appendChild(imgPreview);
					}
				});
			});
			
			var imgIdList = this.imgResIdManager.data;
			for(var i = 0; i < imgIdList.length ; i++){
				let imgId = imgIdList[i];
				let imgPreview = app.render("imgpreview", {imgpreviewimg:""});
				imgPreview.q(".removebtn").addEventListener("click",function(){
					app.images.mani.imgResIdManager.data.splice(app.images.mani.imgResIdManager.data.indexOf(imgId), 1);
					app.images.mani.imgResIdManager.save();
					URL.revokeObjectURL(imgPreview.q(".imgpreviewimg").src);
					app.images.mani.deleteImg(imgId);
					container.removeChild(imgPreview);
				});
				this.getImg(imgId).then(async (base64)=>{
					imgPreview.q(".imgpreviewimg").src = await this.getImgAsBlobUrl(base64);
				});
				imgPreview.setAttribute("data-imgid", imgId);
				imgPreview.q(".progresscanvas").remove();
				imgPreview.addEventListener("click", function(e){
					if(choose){
						rs(imgPreview.getAttribute("data-imgid"));
						p.q(".close").click();
					}
				});
				container.appendChild(imgPreview);
			}
			p.q(".close").addEventListener("click", function(){
				// dispose all blob url
				var imgList = container.querySelectorAll("img");
				for(var i = 0; i < imgList.length ; i++){
					try{
						URL.revokeObjectURL(imgList[i].src);
					}catch(e){}
				}
				app.goback();
				rj();
			});
			return promise;
		},
		isDeleted: function(resId){
			return this.imgResIdManager.data.indexOf(resId) == -1;
		},
		blur: async function(resIdOrBase64, radius){
			var img = await this.getImg(resIdOrBase64);
			var canvas = document.createElement("canvas");
			var ctx = canvas.getContext("2d");
			var imgObj = new Image();
			imgObj.src = img;
			await new Promise((resolve, reject)=>{
				imgObj.onload = resolve;
			});
			canvas.width = imgObj.width;
			canvas.height = imgObj.height;
			ctx.filter = "blur("+radius+"px)";
			ctx.drawImage(imgObj, 0, 0);
			return canvas.toDataURL();
		},
		applyFilter: async function(resIdOrBase64, filter){
			var u = null;
			try{
				u = new URL(resIdOrBase64);
			}catch(e){}
			if(u && u.origin != location.origin){
				var imgObj = new Image();
				await app.images.downloadAndAssign(resIdOrBase64,imgObj);
			}else if(!resIdOrBase64.src){
				var img = await this.getImg(resIdOrBase64);
				var imgObj = new Image();
				imgObj.src = img;
				await new Promise((resolve, reject)=>{
					imgObj.addEventListener("load", resolve);
				});
			}else{
				imgObj = resIdOrBase64;
				var url = new URL(imgObj.src);
				if(url.origin != location.origin){
					await app.images.downloadAndAssign(imgObj.src,imgObj);
				}
			}
			var canvas = document.createElement("canvas");
			var ctx = canvas.getContext("2d");
			
			canvas.width = imgObj.width;
			canvas.height = imgObj.height;
			ctx.filter = filter;
			ctx.drawImage(imgObj, 0, 0);
			return this.getImgAsBlobUrl(canvas.toDataURL());
		},

	}
	app.images.mani.init();
})(app);

//app.ads
(async function(app){
	await onDbLoad.waitForLoad();
	app.ads = {
		ads: [],
	},
	app.ads.init = function(){
		this.adsProvider = app.storage.cache.getFile("adsProvider");
		this.lastAdsTime = +app.storage.cache.getFile("lastAdsTime");
		this.totalMinute = +app.storage.cache.getFile("totalMinuteRemain");
		setInterval(()=>{
			app.ads.totalMinute++;
			app.storage.cache.setFile("totalMinuteRemain", this.totalMinute);
		}, 60000);
		if(window.Capacitor && false){
			// pending update
			this.context = Capacitor.Plugins.AdMob;
			this.context.initialize({
				requestTrackingAuthorization: false,
				testingDevices: [],
				initializeForTesting: true,
			}).then(function(){
				//app.ads.showBanner();
			});
		}else{
			this.context = {};
		}
		setInterval(()=>{
			if(app.user.permLevel < 2){
				app.ads.showPopads();
			}
		}, 60 * 1000 * 60);
		// listen to cross orgin message close popup
		window.addEventListener("message", function(e){
			if(e.data == "closepopup"){
				app.ads.closePopup();
			}
		});
	}
	function onAdsViewed(){
		app.ads.totalMinute -= 55;
		app.storage.cache.setFile("totalMinuteRemain", app.ads.totalMinute);
		app.storage.cache.setFile("lastAdsTime", Date.now());
	}
	app.ads.showBanner = async function(){
		var options = {
			adId: 'ca-app-pub-3940256099942544/6300978111',
			adSize: 'ADAPTIVE_BANNER',
			position: 'BOTTOM_CENTER',
			margin: 100,
			isTesting: true
		};
		this.context.showBanner(options);
	}
	app.ads.showInster = async function(){
		if(this.totalMinute < 55){
			return;
		}
		var options = {
			adId: '',
			isTesting: true
		};
		await AdMob.prepareInterstitial(options);
		await AdMob.showInterstitial();
		onAdsViewed();
	}
	app.ads.showPopads = async function(){
		var frame = STV_SERVER + "/adframe.php";
		var lastPopTime = +app.storage.cache.getFile("lastPopTime");
		// check if passed 59 minutes
		if(Date.now() - lastPopTime < 59*60*1000){
			return;
		}
		app.storage.cache.setFile("lastPopTime", Date.now());
		var iframe = document.createElement("iframe");
		iframe.src = frame;
		iframe.style = "position: fixed; top: 0; left: 0; width: 100%; height: 100%; z-index: 99999999; border: none; background: transparent;";
		iframe.id = "popads";
		document.body.appendChild(iframe);
		var close = function(){
			iframe.remove();
		}
	};
	app.ads.closePopup = function(){
		var iframe = document.getElementById("popads");
		if(iframe){
			iframe.remove();
		}
	}
	setTimeout(()=>{
		//if(app.user.permLevel < 2)
		//app.ads.init();
	}, 30000);
})(app);

// app.items
(async function(app){
	app.items = {
		http: null,
		inv: {
			grouped: {
				danduoc: [],
				linhthach: [],
				consume: [],
			},
			congphap: [],
			voky: [],
			activate: []
		},
		loadInv: function(){
			if(!app.user.isLogin){
				app.context.info("Bạn chưa đăng nhập", true);
				return;
			}
			// return this.http.get({ url: STV_SERVER + "/mobile/jsonify.php?ajax=getinv" })
			// .then(function(r){
			// 	var j = JSON.parse(r.data);
			// 	app.items.sortInv(j.list);
			// });
			return app.net.get("/mobile/jsonify.php?ajax=getinv" )
			.then(function(r){
				app.items.sortInv(r.list);
				app.items.inv.activate = r.act;
			});
		},
		sortInv: function(arr){
			var group = {
				danduoc: [],
				linhthach: [],
				consume: [],
			}
			var congphap = [];
			var voky = [];
			var ids = {};
			for(var i=0;i<arr.length;i++){
				let item = arr[i];
				if(item.t != "3" && item.t!="4"){
					var id = `${item.t} ${item.e} ${item.l} ${item.b}`;
					if(id in ids){
						ids[id].ids.push(item.i);
						ids[id].c++;
					}else{
						ids[id] = item;
						item.ids = [item.i];
						item.c = 1;
						if(item.t == "2"){
							group.danduoc.push(item);
						}else if(item.t == "1"){
							group.linhthach.push(item);
						}else{
							group.consume.push(item);
						}
					}
				}else{
					if(item.t == "3"){
						congphap.push(item);
					}
					if(item.t == "4"){
						voky.push(item);
					}
				}
			}
			this.inv.grouped = group;
			this.inv.congphap = congphap;
			this.inv.voky = voky;
		},
		init: function(){},
		showPage: function(){
			var p = app.pushPage("pageinventory");
			var tab = p.q("tab");
			ui.smtab(tab, true, false, false, null, true);
			tab.ontabchange = (function(tabid){
				if(tabid == 1){
					var listlinhthach = tab.q("tabview:nth-child(2)");
					this.loadListIntoView(this.inv.grouped.linhthach, listlinhthach);
				}
				if(tabid == 4){
					var listconsume = tab.q("tabview:nth-child(5)");
					this.loadListIntoView(this.inv.grouped.consume, listconsume);
				}
				if(tabid == 2){
					var listcongphap = tab.q("tabview:nth-child(3)");
					this.loadListIntoView(this.inv.congphap, listcongphap);
				}
				if(tabid == 3){
					var listvoky = tab.q("tabview:nth-child(4)");
					this.loadListIntoView(this.inv.voky, listvoky);
				}
				if(tabid == 5){
					var listact = tab.q("tabview:nth-child(6)");
					this.loadListIntoView(this.inv.activate, listact);
				}
			}).bind(this);
			this.loadInv().then((function(){
				var listdanduoc = tab.q("tabview");
				this.loadListIntoView(this.inv.grouped.danduoc, listdanduoc);
			}).bind(this));
		},
		loadListIntoView: function(list, view){
			if(view.children.length > 0){
				return;
			}
			for(var i=0;i<list.length;i++){
				var e = app.celoader.item(null, list[i]);
				view.appendChild(e);
			}
		},
		getItemIcon: function(item){
			switch(item.t){
				case "1": return "/linhthach.jpg";
				case "2": return "/danduoc.jpg";
				case "3": {
					if(item.l >= 50) return "/game/asset/item/thon-thien-ma-cong-than-quyen.png";
					return "/congphap.jpg";
				}
				case "4": return "/vuky.jpg";
				case "7": {
					switch(item.e){
						case "19": return "/asset/hoa.jpg";
						case "20": return "/asset/thuy.jpg";
						case "21": return "/asset/kim.jpg";
						case "22": return "/asset/moc.jpg";
						case "23": return "/asset/tho.jpg";
						case "24": return "/asset/phong.jpg";
						case "25": return "/asset/loi.jpg";
						case "26": return "/asset/quang.jpg";
						case "27": return "/asset/bang.jpg";
						case "28": return "/asset/am.jpg";
					}
				}
				default: {
					var item_name = item.g;
					return "/game/asset/item/"+item_name+".png";
				}
			}
		},
		getItemBorder: function(item){
			if(item.t == "1"){
				return "none";
			}
			switch(item.l){
				case "2": return "2px solid #07f747";
				case "3": return "2px solid #00aeff";
				case "4": return "2px solid #bb00ff";
				case "5": return "2px solid #ffa200";
				case "6": return "2px solid yellow";
				case "7": return "2px double #07f747";
				case "8": return "2px double #00aeff";
				case "9": return "2px double #bb00ff";
				case "10": return "2px double #ffa200";
			}
			if(+item.l == 50){
				return "none;border-style: solid;border-width: 2px;animation: color-change 5s infinite";
			}
			if(+item.l > 40){

			}
		}
	};
})(app);

async function translateWithQt(text){
	var http = new XMLHttpRequest();
	var url = STV_SERVER+"/index.php";
	var post = "sajax=trans&content="+encodeURIComponent(text);
	http.open("POST", url, true);
	http.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
	return new Promise(function(resolve,reject){
		http.onreadystatechange = function() {
			if(http.readyState == 4 && http.status == 200) {
				resolve(http.responseText);
			}
		}
		http.send(post);
	});
}
var observerOption = {
	threshold: [0, 0.25, 0.5, 0.75, 1],
	rootMargin: "360px 10px 360px 10px"
}
var bottomBbserverOption = {
	threshold: [1],
}
const observer = new IntersectionObserver(async function(entries, observer) {
	var j = 0;
	for(var i = 0; i < entries.length ; i++){
		var entry = entries[i];
		if(entry.intersectionRatio > 0){
			if(entry.target.onVisible){
				if(j > 3){
					await entry.target.onVisible();
					j = 0;
				}else{
					entry.target.onVisible();
					j++;
				}
			}
		}else{
			if(entry.target.onHidden){
				entry.target.onHidden();
			}
		}
	}
});
const activatedObserver = [];
function registerObserver(obs){
	obs.observing = [];
	var fc = obs.observe;
	obs.observe = function(){
		obs.observing.push(arguments[0]);
		fc.apply(obs, arguments);
	}
	var ufc = obs.unobserve;
	obs.unobserve = function(){
		obs.observing.splice(obs.observing.indexOf(arguments[0]), 1);
		ufc.apply(obs, arguments);
	}
	activatedObserver.push(obs);
	obs.tempDisable = function(){
		if(obs.disconnect){
			obs.disconnect();
			obs.isDisconnected = true;
		}
	}
	obs.continue = function(){
		if(obs.disconnect&&obs.isDisconnected){
			obs.observing.forEach(function(target){
				target&&fc.apply(obs, [target]);
			});
			obs.isDisconnected = false;
		}
	}
	obs.clean = function(){
		[...obs.observing].forEach(e => {
			if(!document.body.contains(e)){
				obs.unobserve(e);
			}
		});
	}
}
function tempDisableObserver(){
	activatedObserver.forEach(function(obs){
		obs.tempDisable();
	});
	console.log("tempDisableObserver");
	//printStackTrace();
}
function reactivateObserver(){
	activatedObserver.forEach(function(obs){
		obs.continue();
	});
	//console.log("reactivateObserver");
	//printStackTrace();
}
registerObserver(observer);
const bottomObserver = new IntersectionObserver(function(entries, observer) {
	entries.forEach(entry => {
		if(entry.intersectionRatio < 1 && entry.intersectionRect.bottom < 0){
			if(entry.target.onBottom){
				entry.target.onBottom();
			}
		}else{
			if(entry.target.onTop){
				entry.target.onTop();
			}
		}
		console.log(entry);
	});
});
var observerRefs = [];
function createFrameObserver(frame, mg, lowRate){
	if(frame.observer){
		return frame.observer;
	}
	var options = $.extend({},observerOption,{root: findScrollableParent(frame)});
	if(mg){
		options.rootMargin = `${mg}px 0px ${mg}px 0px`;
	}
	if(lowRate){
		options.threshold = [0, 0.5, 1];
	}
	var obs = new IntersectionObserver(function(entries, observer) {
		entries.forEach(entry => {
			if(entry.intersectionRatio > 0){
				//console.log(entry);
				if(entry.target.onVisible){
					entry.target.onVisible();
				}
			}else{
				if(entry.target.onHidden){
					entry.target.onHidden();
				}
			}
		});
	}, options);
	frame.observer = obs;
	frame.id = randomNodeId();
	observerRefs.push({
		frame: frame,
		obs: obs,
		stillAlive: function(){
			return app.queryAllPage("#"+frame.id) != null;
		}
	});
	return obs;
}
function isScrollable(el) {
	return el.scrollHeight > el.clientHeight;
}
function findScrollableParent(el, maxSearch = 5) {
	var cur = el;
	var count = 0;
	while (cur && !isScrollable(cur)) {
		cur = cur.parentElement;
		count++;
		if(count > maxSearch){
			return null;
		}
	}
	return cur;
}
// auto clean memory
setInterval(function(){
	for(var i=0;i<observerRefs.length;i++){
		var ref = observerRefs[i];
		if(!ref.stillAlive()){
			ref.obs.disconnect();
			observerRefs.splice(i,1);
		}
	}
},10000);
function getPxFromTranslate(str){
	var px = str.match(/[\-\d]+/);
	return parseInt(px[0]);
}

function forceHttps(url){
	return url.replace("http://","https://");
}

var randomDefaultImg = [
	"https://i.pinimg.com/236x/36/8f/70/368f70378e191db65611ef1d3b57800d.jpg",
	"https://toigingiuvedep.vn/wp-content/uploads/2022/04/hinh-anh-kiem-hiep-cuc-dep.jpg",
	"https://img5.thuthuatphanmem.vn/uploads/2021/12/17/hinh-anh-tien-hiep-tu-chan_031724306.jpg",
	"https://img5.thuthuatphanmem.vn/uploads/2021/12/17/hinh-anh-tien-hiep_031724704.jpg",
	"https://i.pinimg.com/236x/3b/b2/a0/3bb2a04441ffe0d2b40c25a82a5890f7.jpg",
	"https://haycafe.vn/wp-content/uploads/2022/04/Hinh-anh-phong-canh-co-trang-Trung-Quoc.jpg",
	"https://img5.thuthuatphanmem.vn/uploads/2021/12/17/anh-tien-hiep-trung-quoc_031718347.jpg",
	"https://toigingiuvedep.vn/wp-content/uploads/2021/05/background-co-trang-hoa-anh-dao-dep.jpg",
];
function onImgError(img){
	//console.log("onImgError",img);
	img.src = randomDefaultImg[Math.floor(Math.random()*randomDefaultImg.length)];
	img.onerror = () => {onImgErrorAgain(img);};
}
function onImgErrorAgain(img){
	if(!img){
		return;
	}
	img.src = defaultBookCover;
	img.onerror = null;
}
function imgSrc(url){
	url = forceHttps(url);
	url = url.replace("static.sangtacviet.com","static.sangtacvietcdn.xyz");
	return url;
}
function hrefEvent(e){
	var link = e.qq("a");
	for(var i=0;i<link.length;i++){
		var a = link[i];
		var href = a.getAttribute("href");
		if(app.url.test(href)){
			a.addEventListener("click",function(e){
				e.preventDefault();
				app.url.handler(this.getAttribute("href"));
			});
		}
	}
}
function randomBackground(){
	var img = randomDefaultImg[Math.floor(Math.random()*randomDefaultImg.length)];
	return img;
}
function isWindowBottom(w){
	return w.innerHeight + w.scrollY >= w.document.body.scrollHeight - 2;
}
function isWindowTop(w){
	return w.scrollY <= 0;
}
function padRight(str, pad, length){
	var s = str;
	while(s.length < length){
		s += pad;
	}
	return s;
}
String.prototype.padRight = function(pad, length){
	var s = this;
	while(s.length < length){
		s += pad;
	}
	return s;
}
Array.prototype.joinlast = function(last){
	for(var i=0;i<last;i++)this.shift();
	return this.join("=");
};


function addEvent(sel, eve, fun){
	var eventList = eve.split(" ");
	q(sel).forEach(function(e){
		eventList.forEach(function(ev){
			e.addEventListener(ev, fun);
		});
	});
}
Element.prototype.addAllEvent = function(eve, fun){
	var eventList = eve.split(" ");
	var e = this;
	eventList.forEach(function(ev){
		e.addEventListener(ev, fun);
	});
}
Element.prototype.qEvent = function(sel, eve, fun){
	var eventList = eve.split(" ");
	this.qq(sel).forEach(function(e){
		eventList.forEach(function(ev){
			e.addEventListener(ev, fun);
		});
	});
}
function getBookStep(num){
	if(num == "0"){
		return app.text.unknown;//"Không rõ";
	}
	if(num == "1"){
		return app.text.ongoing;//"Còn tiếp";
	}
	if(num == "2"){
		return app.text.paused;//"Tạm ngưng";
	}
	return app.text.completed;//"Hoàn thành";
}

function showOpenFilePickerPolyfill(options) {
    return new Promise((resolve) => {
        const input = document.createElement("input");
        input.type = "file";
        input.multiple = options.multiple;
        input.accept = options.types
            .map((type) => type.accept)
            .flatMap((inst) => Object.keys(inst).flatMap((key) => inst[key]))
            .join(",");

        input.addEventListener("change", () => {
            resolve(
                [...input.files].map((file) => {
                    return {
                        getFile: async () =>
                            new Promise((resolve) => {
                                resolve(file);
                            }),
                    };
                })
            );
        });

        input.click();
    });
}
if (typeof window.showOpenFilePicker !== 'function') {
    window.showOpenFilePicker = showOpenFilePickerPolyfill
}
async function openImageFilePicker(single){
	var file = await window.showOpenFilePicker({
		multiple: !single,
		types: [
			{
				description: 'Image files',
				accept: {
					'image/*': ['.jpg', '.jpeg', '.png', '.gif', '.webp'],
				},
			},
		],
	});
	return file;
}
async function img2Base64(img){
	return new Promise((resolve)=>{
		var reader = new FileReader();
		reader.readAsDataURL(img);
		reader.onload = function () {
			resolve(reader.result);
		};
	});
}
async function fontFile2Blob(file){
	return new Promise((resolve)=>{
		var reader = new FileReader();
		reader.readAsArrayBuffer(file);
		reader.onload = function () {
			resolve(new Blob([reader.result], {type: file.type}));
		};
	});
}
async function openFontFilePicker(){
	var file = await window.showOpenFilePicker({
		multiple: false,
		types: [
			{
				description: 'Font files',
				accept: {
					'font/*': ['.ttf', '.otf', '.woff', '.woff2'],
				},
			},
		],
	});
	return file;
}
async function getFontFileFamilyName(blob){
	return new Promise((resolve)=>{
		var reader = new FileReader();
		reader.readAsArrayBuffer(blob);
		reader.onload = function () {
			var font = new FontFace("temp", reader.result);
			font.load().then(function(loaded_face) {
				document.fonts.add(loaded_face);
				resolve(loaded_face.family);
			});
		};
	});
}
async function getFontFamily(blob){
	return new Promise((resolve)=>{
		var reader = new FileReader();
		reader.readAsArrayBuffer(blob);
		reader.onload = function () {
			var font = new FontFace("temp", reader.result);
			font.load().then(function(loaded_face) {
				document.fonts.add(loaded_face);
				resolve(loaded_face);
			});
		};
	});
}
async function readClipboardText(){
	return new Promise((resolve)=>{
		navigator.clipboard.readText().then(function(text){
			resolve(text);
		});
	});
}
async function uploadImageWithProgress(file, onprogress){
	return new Promise((resolve)=>{
		var param = `sajax=cboximg&imgdata=` + encodeURIComponent(file);
		var xhr = new XMLHttpRequest();
		xhr.open("POST", STV_SERVER + "/index.php");
		xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
		xhr.upload.onprogress = function(e){
			var percent = Math.round((e.loaded / e.total) * 100);
			onprogress(percent);
		};
		xhr.onload = function(){
			onprogress(101);
			resolve(xhr.response);
		};
		xhr.onerror = function(){
			resolve(false);
		}
		xhr.send(param);

	});
}
function drawProgressBarCanvasCirle(canvas, percent){
	var ctx = canvas.getContext("2d");
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	// ctx.beginPath();
	// ctx.arc(canvas.width/2, canvas.height/2, canvas.width/2, 0, 2 * Math.PI);
	// ctx.fill();
	// ctx.fillStyle = "white";
	// ctx.beginPath();
	// ctx.arc(canvas.width/2, canvas.height/2, canvas.width/2 - 2, 0, 2 * Math.PI);
	// ctx.fill();
	ctx.fillStyle = app.theme.getColorVar("--accent-color");
	ctx.beginPath();
	ctx.moveTo(canvas.width/2, canvas.height/2);
	ctx.lineTo(canvas.width/2, 0);
	ctx.arc(canvas.width/2, canvas.height/2, canvas.width/2, -Math.PI/2, 2 * Math.PI * percent / 100  -Math.PI/2);
	ctx.fill();
}

function setCaretPosition(elemId, caretPos) {
    var elem = document.getElementById(elemId);

    if(elem != null) {
        if(elem.createTextRange) {
            var range = elem.createTextRange();
            range.move('character', caretPos);
            range.select();
        }
        else {
            if(elem.selectionStart) {
                elem.focus();
                elem.setSelectionRange(caretPos, caretPos);
            }
            else
                elem.focus();
        }
    }
}
function focusLast(e){
	if(e != null) {
		e.focus();
		e.selectionStart = e.selectionEnd = e.value ? e.value.length : e.innerText.length;
	}
}
const _gif_book = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" style="display: inline-block;transform: rotateX(45deg) skewX(10deg);" width="60px" height="60px" viewBox="0 0 100 100" preserveAspectRatio="xMidYMid" class="svgl">
<path d="M40 25 L65 25 C80 25,80 25,80 40 L80 60 C80 75,80 75,65 75 L40 75 C20 75,20 75,20 60 L20 40 C20 25,20 25,40 25 Z" fill="none" stroke="rgba(0, 0, 0, 0.6015625)" stroke-width="2"></path><path d="M50 25 L65 25 C80 25,80 25,80 40 L80 60 C80 75,80 75,65 75 L50 75" fill="none" stroke="rgba(0, 0, 0, 0.6015625)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" class="rotate"></path>
<path d="M50 25 L65 25 C80 25,80 25,80 40 L80 60 C80 75,80 75,65 75 L50 75" fill="none" stroke="rgba(0, 0, 0, 0.6015625)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" class="rotate"></path><path d="M50 25 L65 25 C80 25,80 25,80 40 L80 60 C80 75,80 75,65 75 L50 75" fill="none" stroke="rgba(0, 0, 0, 0.6015625)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" class="rotate"></path></svg>`;

function AndroidView(viewId){
	var context = Capacitor.Plugins.WebNativeView;
	this.node = document.createElement("img");//document.createElement("canvas");
	//this.ct2d = this.node.getContext("2d");
	//this.ucNode = document.createElement("canvas");
	//this.ucCt2d = this.ucNode.getContext("2d");
	var view = this;
	var unlockFunc = function(){
		view.draw();
		context.unlock({});
		window.removeEventListener("pointerdown", unlockFunc);
	}
	this.isUnlockOnPointerDown = true;
	this.node.addEventListener("touchstart",function(){
		var boundingWithScreen = this.getBoundingClientRect();
		// scale with real screen size
		var pixelRatio = window.devicePixelRatio;
		var x = boundingWithScreen.left * pixelRatio;
		var y = boundingWithScreen.top * pixelRatio;
		w = boundingWithScreen.width * pixelRatio;
		h = boundingWithScreen.height * pixelRatio;
		// remove all after dot
		x = Math.floor(x);
		y = Math.floor(y);
		w = Math.floor(w);
		h = Math.floor(h);
		context.lock({
			viewId: viewId,
			left: x,
			top: y,
			width: w,
			height: h
		});
		if(view.isUnlockOnPointerDown){
			window.addEventListener("pointerdown", unlockFunc);
		}
	});
	this.draw = async function (){
		var rs = await context.getViewData({viewId: viewId});
		this.node.src = NativeView.getBuffer(viewId);
		// var bufferArray = new Uint32Array(JSON.parse(rs.data));
		// var buffer = new Uint8ClampedArray(bufferArray.buffer);
		// var imageData = new ImageData(buffer, rs.width, rs.height);
		// this.ucNode.width = rs.width;
		// this.ucNode.height = rs.height;
		// this.ucCt2d.putImageData(imageData, 0, 0);
		// // draw with scale by device pixel ratio
		// var pixelRatio = window.devicePixelRatio;
		// this.ct2d.drawImage(this.ucNode, 0, 0, rs.width, rs.height, 0, 0, 
		// 	rs.width / pixelRatio, rs.height / pixelRatio);
	}
	this._setSize =async function(w,h){
		//this.node.width = w;
		//this.node.height = h;
		this.node.style.width = w + "px";
		this.node.style.height = h + "px";
		await context.setSize({
			viewId: viewId,
			width: w,
			height: h
		});
	}
	this.node.view = this;
	this.viewId = viewId;
	this.node.id = "ntview_" + viewId;
	this.lockView = async function(){
		var boundingWithScreen = this.node.getBoundingClientRect();
		// scale with real screen size
		var pixelRatio = window.devicePixelRatio;
		var x = boundingWithScreen.left * pixelRatio;
		var y = boundingWithScreen.top * pixelRatio;
		w = boundingWithScreen.width * pixelRatio;
		h = boundingWithScreen.height * pixelRatio;
		// remove all after dot
		x = Math.floor(x);
		y = Math.floor(y);
		w = Math.floor(w);
		h = Math.floor(h);
		await context.lock({
			viewId: viewId,
			left: x,
			top: y,
			width: w,
			height: h
		});
	}
	this.unlockView = function(){
		context.unlock({});
	}
	return this;
}
AndroidView.create=async function(name){
	var rs = await Capacitor.Plugins.WebNativeView.createView({name: name});
	var view = new AndroidView(rs.viewId);
	var mets = rs.methods;
	for(var i=0; i<mets.length; i++){
		/**
		 * Method definition:
		 * {
		 * 	methodId: number
		 * 	isPublic: boolean
		 *  isStatic: boolean
		 * 	name: string
		 * 	paramCount: number
		 * 	returnType: string
		 * }
		 */
		var met = mets[i];
		if(view[met.name]){
			//add number of param to method name
			met.name += met.paramCount;
			if(view[met.name]){
				// add number of param to method name
				met.name += met.paramCount;
			}
		}
		(function(met,methodId){
			view[met.name] = async function(){
				var args = [];
				for(var i=0; i<arguments.length; i++){
					args.push(arguments[i]);
				}
				var rs = await Capacitor.Plugins.WebNativeView.invoke({
					viewId: view.viewId,
					methodId: methodId,
					params: args
				});
				if(rs.error){
					throw rs.error;
				}else{
					if(rs.viewId){
						return AndroidView.jsonToObject(rs);
					}
					return rs.return;
				}
			}
		})(mets[i],i);
	}
	return view;
}
AndroidView.jsonToObject=function(rs){
	var view = {
		id: rs.viewId,
	}
	var mets = rs.methods;
	for(var i=0; i<mets.length; i++){
		var met = mets[i];
		if(view[met.name]){
			met.name += met.paramCount;
			if(view[met.name]){
				met.name += met.paramCount;
			}
		}
		(function(met,methodId){
			view[met.name] = async function(){
				var args = [];
				for(var i=0; i<arguments.length; i++){
					args.push(arguments[i]);
					if(arguments[i] && arguments[i].id){
						args[i] = arguments[i].id;
					}
				}
				var rs = await Capacitor.Plugins.WebNativeView.invokeObject({
					viewId: view.id,
					methodId: methodId,
					params: args
				});
				if(rs.error){
					throw rs.error;
				}else{
					if(rs.viewId){

					}
					return rs.return;
				}
			}
		})(mets[i],i);
	}
	return view;
}
AndroidView.createObject=async function(name){
	var rs = await Capacitor.Plugins.WebNativeView.createObject({name: name});
	var view = {
		id: rs.viewId,
	}
	var mets = rs.methods;
	for(var i=0; i<mets.length; i++){
		var met = mets[i];
		if(view[met.name]){
			met.name += met.paramCount;
			if(view[met.name]){
				met.name += met.paramCount;
			}
		}
		(function(met,methodId){
			view[met.name] = async function(){
				var args = [];
				for(var i=0; i<arguments.length; i++){
					args.push(arguments[i]);
					if(arguments[i] && arguments[i].id){
						args[i] = arguments[i].id;
					}
				}
				var rs = await Capacitor.Plugins.WebNativeView.invokeObject({
					viewId: view.id,
					methodId: methodId,
					params: args
				});
				if(rs.error){
					throw rs.error;
				}else{
					if(rs.viewId){
						return AndroidView.jsonToObject(rs);
					}
					return rs.return;
				}
			}
		})(mets[i],i);
	}
	return view;
}
AndroidView.createHandler=async function(className, methodName, eventName){
	var rs = await Capacitor.Plugins.WebNativeView.createHandler({
		name: className,
		targetMethod: methodName,
		eventName: eventName
	});
	var view = {
		id: rs.viewId,
	}
	var mets = rs.methods;
	for(var i=0; i<mets.length; i++){
		var met = mets[i];
		if(view[met.name]){
			met.name += met.paramCount;
			if(view[met.name]){
				met.name += met.paramCount;
			}
		}
		(function(met,methodId){
			view[met.name] = async function(){
				var args = [];
				for(var i=0; i<arguments.length; i++){
					args.push(arguments[i]);
					if(arguments[i] && arguments[i].id){
						args[i] = arguments[i].id;
					}
				}
				var rs = await Capacitor.Plugins.WebNativeView.invokeObject({
					viewId: view.id,
					methodId: methodId,
					params: args
				});
				if(rs.error){
					throw rs.error;
				}else{
					if(rs.viewId){
						return AndroidView.jsonToObject(rs);
					}
					return rs.return;
				}
			}
		})(mets[i],i);
	}
	return view;
}
function fontweightToNumber(weight){
	switch(weight){
		case "normal":
			return 400;
		case "bold":
			return 700;
		case "bolder":
			return 900;
		case "lighter":
			return 100;
		default:
			return parseInt(weight);
	}
}
function getAverageRGB(imgEl) {
	//stack overflow
    var blockSize = 5, // only visit every 5 pixels
        defaultRGB = {r:0,g:0,b:0}, // for non-supporting envs
        canvas = document.createElement('canvas'),
        context = canvas.getContext && canvas.getContext('2d'),
        data, width, height,
        i = -4,
        length,
        rgb = {r:0,g:0,b:0},
        count = 0;

    if (!context) {
        return defaultRGB;
    }

    height = canvas.height = imgEl.naturalHeight || imgEl.offsetHeight || imgEl.height;
    width = canvas.width = imgEl.naturalWidth || imgEl.offsetWidth || imgEl.width;

    context.drawImage(imgEl, 0, 0);

    try {
        data = context.getImageData(0, 0, width, height);
    } catch(e) {
        /* security error, img on diff domain */
        return defaultRGB;
    }

    length = data.data.length;

    while ( (i += blockSize * 4) < length ) {
        ++count;
        rgb.r += data.data[i];
        rgb.g += data.data[i+1];
        rgb.b += data.data[i+2];
    }

    // ~~ used to floor values
    rgb.r = ~~(rgb.r/count);
    rgb.g = ~~(rgb.g/count);
    rgb.b = ~~(rgb.b/count);

    return rgb;

}
Element.prototype.nE = function(){
	return this.nextElementSibling;
}
function float2Percent(f){
	return (+f) * 100 + "%";
}

function getbuyhistory(h,div){
	var pre = app.createPreloader("Đang tải lịch sử...", true);
	div.appendChild(pre);
	app.net.get("/mobile/jsonify.php?ajax=getbuyhistory&host=" + h).then((rs)=>{
		var l = rs.list;
		pre.remove();
		if(!l || l.length == 0){
			div.appendChild(app.createNodata("Bạn chưa từng mua chương nào..",true))
		}
		for(var i=0;i<l.length;i++){
			var record = l[i];
			var row = app.render("buyhistoryrow", record);
			row.setAttribute("cid",record.cid);
			row.setAttribute("bid",record.bid);
			row.setAttribute("host", h);
			div.appendChild(row);
		}
	});
}
const waitFrame = () => new Promise(requestAnimationFrame);
function slugVietnamese(string){
	string = string.toLowerCase();
	string = string.replace(/à|á|ạ|ả|ã|â|ầ|ấ|ậ|ẩ|ẫ|ă|ằ|ắ|ặ|ẳ|ẵ/g,"a");
	string = string.replace(/è|é|ẹ|ẻ|ẽ|ê|ề|ế|ệ|ể|ễ/g,"e");
	string = string.replace(/ì|í|ị|ỉ|ĩ/g,"i");
	string = string.replace(/ò|ó|ọ|ỏ|õ|ô|ồ|ố|ộ|ổ|ỗ|ơ|ờ|ớ|ợ|ở|ỡ/g,"o");
	string = string.replace(/ù|ú|ụ|ủ|ũ|ư|ừ|ứ|ự|ử|ữ/g,"u");
	string = string.replace(/ỳ|ý|ỵ|ỷ|ỹ/g,"y");
	string = string.replace(/đ/g,"d");
	string = string.replace(/\W+/g,"");
	string = string.trim();
	return string;
}
const sleepFor = (milliseconds) => {
	return new Promise(resolve => setTimeout(resolve, milliseconds))
}

function softObserver(rootEle){
	var h = document.body.scrollHeight;
	var sk = false;
	console.log(h);
	rootEle.addEventListener("scroll", function(){
		sk = !sk;
		if(sk){
			return;
		}
		var threshold = rootEle.scrollTop - 250;
		var max = threshold + h + 500;
		var startnode = null;
		for(var i=0;i<rootEle.children.length;i++){
			var o = +rootEle.children[i].getAttribute("offset");
			if(o > threshold && o < max){
				startnode = rootEle.children[i];
				break;
			}
		}
		var n = startnode;
		var endnode = null;
		while(n){
			if(!n.wake){
				return;
			}
			n.wake && n.wake();
			if(n.nextElementSibling){
				n = n.nextElementSibling;
				if(+n.getAttribute("offset") > max){
					endnode = n;
					break;
				}
			}else break;
		}
		n = startnode;
		while(n && n.previousElementSibling){
			n = n.previousElementSibling;
			if(!n.isSleep){
				n.sleep && n.sleep();
			}else break;
		}
		n = endnode;
		while(n){
			if(!n.isSleep){
				n.sleep && n.sleep();
			}else break;
			n = n.nextElementSibling;
		}
	});
}

async function translateObject(obj){
	var mappings = [];
	var toTrans = [];
	var walk = function(obj, path){
		for(var k in obj){
			var p = path + "." + k;
			if(typeof obj[k] == "function"){ continue; }
			if(typeof obj[k] == "object"){
				walk(obj[k], p);
			}else{
				mappings.push(p);
				toTrans.push(obj[k]);
			}
		}
	}
	walk(obj, "");
	if(toTrans.length == 0){
		return obj;
	}
	var translated = await translateWithQt(toTrans.join("=||="));
	translated = translated.split("=||=");
	walk = function(obj, path){
		for(var k in obj){
			if(typeof obj[k] == "function"){ continue; }
			if(typeof obj[k] == "object"){
				walk(obj[k], path + "." + k);
			}else{
				obj[k] = translated.shift();
			}
		}
	}
	walk(obj, "");
	return obj;
}
async function translateWithGoogle(text, lang = "en"){
	var headers = {
		"Content-Type": "application/json+protobuf",
		"X-Goog-Api-Key": "AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520"
	};
	var rpc = JSON.stringify([[[text], "zh", lang], "wt_lib"]);
	var server = "https://translate-pa.googleapis.com/v1/translateHtml";
	if(window.Capacitor){
		var uas = [
			"Mozilla/5.0 (Linux; Android 10; SM-G960U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4324.181 Mobile Safari/537.36",
			"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.3029.110 Safari/537.3",
			"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4324.181 Safari/537.36",
			"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.3029.110 Safari/537.3",
		]
		headers["User-Agent"] = uas[Math.floor(Math.random()*uas.length)];
		var context = Capacitor.Plugins.Http;
		var rs = await context.request({
			url: server,
			method: "POST",
			headers: headers,
			data: rpc
		});
		if(rs.status == 200){
			try{
				var json = JSON.parse(rs.data);
				if(json[0] && json[0][0]){
					return json[0][0];
				}
			}catch(e){
				throw e;
			}
		}
		throw new Error("Translate failed");
	} else {
		var http = new XMLHttpRequest();
		http.open("POST", server, true);
		for(var k in headers){
			http.setRequestHeader(k, headers[k]);
		}
		http.send(rpc);
		return new Promise(function(resolve,reject){
			http.onreadystatechange = function() {
				if(http.readyState == 4 && http.status == 200) {
					try{
						var json = JSON.parse(http.responseText);
						if(json[0] && json[0][0]){
							resolve(json[0][0]);
						}else{
							reject();
						}
					}catch(e){
						reject();
					}
				}
			}
			http.onerror = function(){
				reject();
			}
		});
	}
}
async function translateObjectWithGoogle(obj, lang = "en"){
	var mappings = [];
	var toTrans = [];
	var walk = function(obj, path){
		for(var k in obj){
			var p = path + "." + k;
			if(typeof obj[k] == "function"){ continue; }
			if(typeof obj[k] == "object"){
				walk(obj[k], p);
			}else{
				mappings.push(p);
				toTrans.push(`<span>${obj[k]}</span>`);
			}
		}
	}
	walk(obj, "");
	if(toTrans.length == 0){
		return obj;
	}
	var translated = await translateWithGoogle(toTrans.join(""), lang);
	translated = translated.replace(/<span>/g, "").split("</span>");
	walk = function(obj, path){
		for(var k in obj){
			if(typeof obj[k] == "function"){ continue; }
			if(typeof obj[k] == "object"){
				walk(obj[k], path + "." + k);
			}else{
				obj[k] = translated.shift()
			}
		}
	}
	walk(obj, "");
	return obj;
}

function createPromise(){
	var resolve, reject;
	var promise = new Promise(function(res,rej){
		resolve = res;
		reject = rej;
	});
	promise.resolve = resolve;
	promise.reject = reject;
	return promise;
}

function tryParseBookCate(cates){
	if(!cates || !cates.trim()) return [];
	var reps = {
		"cùng người": "đồng nhân",
		"CP": "Cp",
		"chỗ làm việc": "Công sở",
		"NP": "Np",
	};
	for(var rep in reps){
		cates = cates.replace(new RegExp(rep, "gi"), reps[rep]);
	}
	var list = cates.replace(/tiểu thuyết|loại hình|truyện/gi, "").split(/[;,\/\|\-]/g).map(s => s.trim()).filter(s => s);
	var tags = [];
	list.forEach(cat => {
		if(cat.match(/ [a-zđ].+ [A-ZĐ]/)){
			var noDelis = [];
			var s = "";
			for(var i = 0; i < cat.length; i++){
				if(cat[i].match(/[A-Z]/)){
					if(s && s.match(/ ./)) {
						noDelis.push(s.trim());
						s = "";
					}
					s += cat[i];
				}else{
					s += cat[i];
				}
			}
			if(s) {
				noDelis.push(s.trim());
			}
			tags = tags.concat(noDelis)
		}else{
			tags.push(cat);
		}
	});
	return tags.filter(t => t);
}

function consumeEvent(fun, self){
	// event listener that invoke only once
	var newFun = fun.bind(self);
	return function(e){
		newFun(e);
		newFun = function(){};
	}
}

ui.scriptmanager.load("https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onAppCaptchaReady&render=explicit");
function onAppCaptchaReady(){
	window.captchaReady = true;
}
function runCaptcha(purpose, cb){
	var wgId = "0x4AAAAAABbXTEjsj3isHkfm";
	var element = document.createElement("div");
	element.style.display = "none";
	element.id = "captcha_" + purpose;
	document.body.appendChild(element);
	var captcha = turnstile.render(element.id, {
		sitekey: wgId,
		action: purpose,
		theme: "light",
		callback: function(token) {
			app.net.post("/index.php?ajax=verifycaptcha", app.serialize({
				token: token,
				purpose: purpose,
				provider: "cloudflare"
			})).then(function(rs){
				if(rs == "success"){
					cb(true);
				}else{
					cb(false);
				}
			});
			turnstile.remove(captcha);
			element.remove();
		}
	});
}

function parseQueryString(queryString) {
  if (!queryString) return {};

  // Remove leading "?" if present
  if (queryString.startsWith('?')) {
    queryString = queryString.slice(1);
  }

  return queryString
    .split('&')
    .map(param => param.split('='))
    .reduce((acc, [key, value]) => {
      key = decodeURIComponent(key);
      value = value !== undefined ? decodeURIComponent(value) : '';

      // Handle duplicate keys by converting to array
      if (acc.hasOwnProperty(key)) {
        if (Array.isArray(acc[key])) {
          acc[key].push(value);
        } else {
          acc[key] = [acc[key], value];
        }
      } else {
        acc[key] = value;
      }

      return acc;
    }, {});
}
