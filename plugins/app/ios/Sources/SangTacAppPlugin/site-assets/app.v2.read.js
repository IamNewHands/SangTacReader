function ChineseDragBar(cNode,baseNode,options = {}){
    this.baseNode = baseNode || document.createElement("div");
    this.baseNode.classList.add("chinesedragbar");
    this.hanvietShow = document.createElement("div");
    this.baseNode.appendChild(this.hanvietShow);
    var tmpDiv = document.createElement("div");
    this.baseNode.appendChild(tmpDiv);
    this.leftCnShow = document.createElement("div");
    this.leftCnShow.classList.add("leftcnshow");
    this.rightCnShow = document.createElement("div");
    this.rightCnShow.classList.add("rightcnshow");
    this.currentCnShow = document.createElement("div");
    this.currentCnShow.classList.add("currentcnshow");
    tmpDiv.appendChild(this.leftCnShow);
    tmpDiv.appendChild(this.currentCnShow);
    tmpDiv.appendChild(this.rightCnShow);
    this.pointerLeft = document.createElement("div");
    this.pointerLeft.classList.add("pointer");
    this.pointerRight = document.createElement("div");
    this.pointerRight.className = "pointer active";
    tmpDiv.insertBefore(this.pointerLeft, this.currentCnShow);
    tmpDiv.insertBefore(this.pointerRight, this.rightCnShow);
    this.cn = cNode ? cNode.gT() : "";
    var leftNodeList = [];
    var rightNodeList = [];
    var rightTotalLen = 0;
    var maxLen = 10;
    this.pointer = "right";
    this.pointerChangeTimer = null;
    this.allowHighlight = true;
    this.showAllChar = false;
    this.showPointer = true;
    if(options.showAllChar){
        this.showAllChar = true;
    }
    if(options.showPointer === false){
        this.showPointer = true;
    }
    if(options.allowHighlight === false){
        this.allowHighlight = false;
    }
    function getLeftCn(n, l){
        leftNodeList = [];
        if(!l){l = 8;}
        var cn = "";
        n = n.pE();
        while(n && l > 0 && n.tagName == "I"){
            cn = n.gT() + cn;
            leftNodeList.unshift(n);
            n = n.pE();
            l--;
        }
        leftTotalLen = cn.length;
        return cn;
    }
    function getRightCn(n, l){
        rightNodeList = [];
        if(!l){l = 8;}
        var cn = "";
        n = n.nE();
        while(n && l > 0&& n.tagName == "I"){
            cn += n.gT();
            rightNodeList.push(n);
            n = n.nE();
            l--;
        }
        rightTotalLen = cn.length;
        return cn;
    }
    this.leftCn =cNode ? getLeftCn(cNode, maxLen) : "";
    this.rightCn =cNode ? getRightCn(cNode, maxLen) : "";
    this.display = function(){
        // display only 3 chars on each side
        this.leftCnShow.textContent = this.showAllChar ? this.leftCn : this.leftCn.substring(this.leftCn.length - 3);
        this.rightCnShow.textContent = this.showAllChar ? this.rightCn : this.rightCn.substr(0, 3);
        this.currentCnShow.textContent = this.cn;
        if(this.allowHighlight){
            try{
				this.highlightLeft(this.leftCn.length);
            	this.highlightRight(this.rightCn.length);
				this.showHanviet();
			}catch(e){}
        }
        this.onupdate(this.cn);
    }
    this.showHanviet = function(){
        if(app.reader.tempCurrentWindow){
            var hv = app.reader.tempCurrentWindow.convertohanviets(this.cn);
            this.hanvietShow.textContent = hv;
        }
    }
    this.highlightLeft = function(offset){
        var l = 0;
        for(var i=0; i<leftNodeList.length; i++){
            var n = leftNodeList[i];
            l += n.cn.length;
            if( l > offset){
                //n.highlight();
                //console.log("unhigh left", n.id);
                n.style.color = "red";
            }else{
                //console.log("unhigh left", n.id);
                n.style.color = "inherit";
            }
        }
    }
    this.highlightRight = function(offset){
        var l = 0;
        offset = rightTotalLen - offset;
        for(var i=0; i<rightNodeList.length; i++){
            var n = rightNodeList[i];
            if(offset > l){
                //n.highlight();
                //console.log("highlight right", n.id);
                n.style.color = "red";
            }else{
                //console.log("unhigh right", n.id);
                n.style.color = "inherit";
            }
            l += n.cn.length;
        }
    }
    this.unhighlight = function(){
        for(var i=0; i<leftNodeList.length; i++){
            var n = leftNodeList[i];
            n.style.color = "inherit";
        }
        for(var i=0; i<rightNodeList.length; i++){
            var n = rightNodeList[i];
            n.style.color = "inherit";
        }
    }
    this.leftAdd1 = function(){
        // remove last char from left and prepend to center
        if(this.leftCn.length > 0){
            this.cn = this.leftCn[this.leftCn.length - 1] + this.cn;
            this.leftCn = this.leftCn.substr(0, this.leftCn.length - 1);
            this.display();
        }
    }
    this.rightAdd1 = function(){
        // remove first char from right and append to center
        if(this.rightCn.length > 0){
            this.cn = this.cn + this.rightCn[0];
            this.rightCn = this.rightCn.substr(1);
            this.display();
        }
    }
    this.leftRemove1 = function(){
        // remove first char from center and prepend to left
        if(this.cn.length > 1){
            this.leftCn += this.cn[0];
            this.cn = this.cn.substr(1);
            this.display();
        }
    }
    this.rightRemove1 = function(){
        // remove last char from center and append to right
        if(this.cn.length > 1){
            this.rightCn = this.cn[this.cn.length - 1] + this.rightCn;
            this.cn = this.cn.substr(0, this.cn.length - 1);
            this.display();
        }
    }
    this.onupdate = function(cn){}
    this.switch = function(newNode){
        this.cn = newNode.gT();
        this.leftCn = getLeftCn(newNode, maxLen);
        this.rightCn = getRightCn(newNode, maxLen);
        this.display();
    }
    this.increment = function(){
        if(this.pointer == "right"){
            this.rightAdd1();
        }else{
            this.leftRemove1();
        }
        if(this.hidingTimer){
            clearTimeout(this.hidingTimer);
            this.hidingTimer = null;
        }
        this.modifySinceLastShow = true;
    }
    this.decrement = function(){
        if(this.pointer == "right"){
            this.rightRemove1();
        }else{
            this.leftAdd1();
        }
        if(this.hidingTimer){
            clearTimeout(this.hidingTimer);
            this.hidingTimer = null;
        }
        this.modifySinceLastShow = true;
    }
    this.display();
    this.isDisplay = false;
    this.setPointer = function(direction){
        if(this.pointer != direction){
            this.pointer = direction;
            if(direction == "left"){
                this.pointerLeft.className = "pointer active";
                this.pointerRight.className = "pointer";
            }else{
                this.pointerLeft.className = "pointer";
                this.pointerRight.className = "pointer active";
            }
        }
    }
    this.show = function(){
        if(!this.isDisplay){
            this.baseNode.style.top = this.yPos + "px";//(y + w.scrollY) + "px";
            this.baseNode.style.display = "block";
            this.isDisplay = true;
            this.modifySinceLastShow = false;
            this.setPointer("right");
            this.pointerChangeTimer = setTimeout((function(){
                if(!this.modifySinceLastShow){
                    this.setPointer("left");
                }
            }).bind(this), 700);
        }
    }
    this.hidingTimer = null;
    this.hide = function(){
        //this.baseNode.style.display = "none";
        //this.isDisplay = false;
        this.hidingTimer = setTimeout(function(){
            this.baseNode.style.display = "none";
            this.isDisplay = false;
        }.bind(this), 300);
        
    }
    return this;
}

ui.scriptmanager.load("/asset/app.v2.chapterdisplay.js", function(){}, !isCachedFrontend);
var events = {
    "view_contextmenu":{
        "click": function(e){e.stopPropagation();},
    },
    set: function(node, type){
        if(events[type]){
            for(var i in events[type]){
                node.addEventListener(i, events[type][i]);
            }
        }
    }
};
// reader
(function(app){
    
    var events = {
        "view_contextmenu":{
            "click": function(e){e.stopPropagation();},
        },
        set: function(node, type){
            if(events[type]){
                for(var i in events[type]){
                    node.addEventListener(i, events[type][i]);
                }
            }
        }
    }
	
	app.reader = app.reader || {};
    app.reader.encryptedHosts = ["sangtac", "dich"];
	app.reader.display = null;
	app.reader.bottommenu = null;
	app.reader.editnamepreview = null;
	app.reader.ttssetting = null;
	app.reader.drawer = null;
    app.reader.chapterDisplay = null;
	app.reader.init = function(h,i,c){
		this.clean();
		this.display = g("chapterview");
		var p = this.display;
		this.host = h;
		this.id = i;
		this.startid = c;
		this.bottommenu = p.q(".coption");
		this.editnamepreview = p.q(".editnamepreview");
		this.ttssetting = p.q(".ttssetting");
		this.drawer = p.q(".drawer");
		this.clistDrawerKey = "";
		window.failedIn5Times = 0;
		this.drawer.addEventListener("click",function(e){
			e.stopPropagation();
			if(e.target == this){
				this.classList.remove("open");
			}
		});
		this.drawer.addEventListener("transitionend",function(e){
			if(!this.classList.contains('open'))app.reader.hideDrawer();
		});
		app.tts.init();
		app.reader.previewer.backgroundImageId = "";
		p.q(".btncomment").addEventListener("click",function(){
			app.fun.showComment(app.reader.bookinfo.host,app.reader.bookinfo.id);
		});
		p.q(".btnnextchap").addEventListener("click",function(){
			app.reader.nextChapter();
		});
		p.q(".btnprevchap").addEventListener("click",function(){
			app.reader.prevChapter();
		});
		p.q(".btnspeak").addEventListener("click",function(){
			app.reader.showTtsSetting();
		});
		p.q(".btnsetting").addEventListener("click",function(){
			app.reader.showStyleSetting();
		});
		p.q(".btnaddname").addEventListener("click",function(){
			app.editor.openAddname();
		});
		p.q(".rbtn").addEventListener("click", function(){
			var tb = p.q(".titlebar");
			app.context.showMenu(app.context.menu.readchapter, null, {
				clientX: document.body.scrollWidth - 5,
				clientY: tb.scrollHeight + 5
			});
		});
		p.q(".bottombar").addEventListener("click",function(e){e.stopPropagation();});
		p.q(".coption").addEventListener("click",function(e){e.stopPropagation();});
		p.q(".titlebar").addEventListener("click",function(e){e.stopPropagation();});
		p.addEventListener("click",function(e){
			e.stopPropagation();
			app.reader.checkMenuTap(e.clientX,e.clientY);
		});
		p.width = document.body.scrollWidth;
		p.height = document.body.scrollHeight;
        clearInterval(window.readerWatchInterval);
		window.readerWatchInterval = setInterval(function(){
			q(".currenttime").forEach(e => {
				e.textContent = currentTime();
			});
            try{
                app.reader.getDisplay().getCurrentWindow().q(".currenttime").forEach(e => {
                    e.textContent = currentTime();
                });
            } catch(e){
                clearInterval(window.readerWatchInterval);
            }
		},60000);
		this.loadStyle();
		q(".clistcontainer").forEach(e => {e.innerHTML = "";e.firstload=true;});
		if(app.offlineBook.isBookExist(h,i)){
			this.offlineBook = app.offlineBook.getExistedBook({
				host: h,
				id: i
			});
		}
        this.allowLoadStart = true;
		if(this.chapterDisplay != null){
			this.chapterDisplay.destroy();
		}
        this.chapterDisplay = this.loadChapterDisplay(this.display.q(".chapterdisplay"));
		this.display.q(".expphraser").addEventListener("click",function(){
			app.editor.expandPhraseRight();
		});
		this.display.q(".expphrasel").addEventListener("click",function(){
			app.editor.expandPhraseLeft();
		});
		this.display.q(".hidemenubtn").addEventListener("click",function(){
			app.reader.toggleMenu();
		});
		this.display.q(".copytext").addEventListener("click",function(){
			var text = app.reader.display.q(".chi").textContent.trim();
			ui.copy(text);
		});
		this.display.q(".googletrans").addEventListener("click",function(){
			var text = app.reader.display.q(".chi").textContent.trim();
			app.browser.open("https://translate.google.com/?sl=auto&tl=vi&text="+encodeURIComponent(text));
		});
		this.display.q(".googlesearch").addEventListener("click",function(){
			var text = app.reader.display.q(".chi").textContent.trim();
			app.browser.open("https://www.google.com/search?q="+encodeURIComponent(text));
		});
		this.display.q(".line1 .chapterprogress").addEventListener("input",function(){
			app.reader.getDisplay().gotoProgress(this.value);
		});
		this.display.q(".btnnamemenu").addEventListener("click",function(){
			app.namemanager.showManager(app.reader.bookinfo || app.reader.book);
		});
		this.display.q(".btnnamemenu2").addEventListener("click",function(){
			app.namemanager.showManager(app.reader.bookinfo || app.reader.book);
		});
		this.display.q(".btnrunname").addEventListener("click",function(){
			app.reader.runNameForAll();
		});
		this.display.q(".btntoc").addEventListener('click', function(){
			app.reader.showDrawer("toc");
		});
		app.namemanager.resetContext();
		app.reader.behaviour.chapter_name_fixed_place.apply();
	}
	app.reader.initSurf = function(bookurl,chapurl){
		this.init("surf",bookurl , chapurl);
	}
    app.reader.loadChapterDisplay = function(root, noRender = false){
        var displayType = app.config.reader.display_type;
        if(displayType == "auto" || !displayType){
            displayType = "default";
        }
		if(typeof ChapterDisplayTypeRegistry == "undefined"){
			setTimeout(()=>{
				Capacitor.Plugins.App.exitApp();
			}, 5000);
		}
        var clazz = ChapterDisplayTypeRegistry[displayType];
        var display = new clazz(root);
        if(!noRender){
            display.render();
        }
        return display;
    }
    app.reader.getDisplay = function(){
        return this.chapterDisplay;
    }
    app.reader.changeDisplay = function(){
        var currentDisplay = this.getDisplay();
        var root = currentDisplay.root;
        var newDisplay = this.loadChapterDisplay(root, true);
        if(newDisplay.absorb && newDisplay.absorb(currentDisplay)){
            this.chapterDisplay = newDisplay;
        } else {
            this.startid = this.getPCN().current.cid;
            currentDisplay.destroy();
            this.allowLoadStart = true;
            this.chapterDisplay = newDisplay;
            this.previewer.backgroundImageId = "";
            setTimeout(function(){
                newDisplay.render();
                app.reader.behaviour.chapter_name_fixed_place.apply();
            }, 100);
        }
    }
	app.reader.loadStart =  function(){
		if(!this.allowLoadStart){
			return;
		}
		this.getDisplay().loadStart();
		this.allowLoadStart = false;
	}
	app.reader.behaviour = {
		way_to_choose_node: {
			"click": function(e){
				if(e.target.tagName == "I"){
					app.reader.showEditName(this,e.target);
					app.reader.setContextMenu(this.g("contextmenu"),e.target,this);
				}else
				app.reader.checkMenuTap(e.clientX,e.clientY);
				if(!isFullscreen()){
					app.reader.fullscreen();
				}
			},
			"dblclick": function(e){
				if(e.target.tagName !== "I"){
					app.reader.checkMenuTap(e.clientX,e.clientY);
					return;
				}
				if(this.clickTime && (new Date().getTime() - this.clickTime < 200)){
					if(e.target.tagName == "I"){
						app.reader.showEditName(this,e.target);
						app.reader.setContextMenu(this.g("contextmenu"),e.target,this);
					}
				}else{
					setTimeout((function(){
						if(this.clickTime && (new Date().getTime() - this.clickTime > 200)){
							app.reader.checkMenuTap(e.clientX,e.clientY);
						}
					}).bind(this), 250);
				}
				this.clickTime = new Date().getTime();
			},
			"none": function(e){},
			"triggermenu": function(e){
				app.reader.checkMenuTap(e.clientX,e.clientY);
			},
			"hold": function(e){
				if(!this.touchStartTarget){
					return;
				}
				if(this.touchStartTarget.tagName == "I"){
					app.reader.showEditName(this,this.touchStartTarget);
					app.reader.setContextMenu(this.g("contextmenu"),this.touchStartTarget,this);
				}
			},
            rebindEvent: function(){
                app.reader.getDisplay().behaviour.way_to_choose_node.rebindEvent();
            }
		},
        chapter_name_fixed_place: {
            apply: function(){
                app.reader.getDisplay().behaviour.chapter_name_fixed_place.apply();
            }
        },
		italic_talk_sentence: {
			apply: function(){
				app.reader.style.set("talkItalic",app.config.reader.italic_talk_sentence ? "italic" : "normal");
			}
		},
        prepend_chapter_name: {
            apply: function(){
                app.reader.getDisplay().behaviour.prepend_chapter_name.apply();
            }
        },
	};
	app.reader.leftTap = function(){
		this.getDisplay().leftTapAction();
	}
	app.reader.rightTap = function(){
		this.getDisplay().rightTapAction();
	}
	app.reader.getKey = async function(h,i){
		var cachekey = `${h}-${i}`;
		if(this.cachekey == cachekey){
			return;
		}else{
			await this.loadKeyFromServer(h,i);
			this.cachekey = cachekey;
		}
	}
	app.reader.preloadTimer = null;
	
	app.reader.nextChapter = function(isTTS){
		this.getDisplay().goNextChapter(isTTS);
	}
	app.reader.prevChapter = function(){
		this.getDisplay().goPrevChapter();
	}
	app.reader.getPCN = function(){
		return this.getDisplay().getPCN();
	}
	app.reader.loadKeyFromServer = async function(h,i){
		if(window.Capacitor && window.Capacitor.Plugins.Http){
			var context = window.Capacitor.Plugins.Http;
			var toEvaluate = await context.get({
				url: fullUrl(app.net.networkManager.bestDomain() + "/io/grantcontext/context?hostid="+h+"&bookid="+i),
				headers: {
					Cookie: document.cookie.toString() + "; mac_tt=true;",
					"User-Agent": navigator.userAgent,
					"x-stv-transport": "app",
					"x-requested-with": "com.sangtacviet.mobilereader",
				},
				ipv6: false,
			});
			app.net.evalCookie(toEvaluate.headers);
			this.chapterkey = eval(toEvaluate.data);
		}
	}
	app.reader.setNotLoading = function(f){
        this.getDisplay().setNotLoading(f);
    }
	app.reader.getContent2 = async function(h,i,c,rl){
		if(window.Capacitor && window.Capacitor.Plugins.Http){
			var context = window.Capacitor.Plugins.Http;
			var headers = {
				Cookie: document.cookie.toString() + "; mac_tt=true;",
				"User-Agent": navigator.userAgent,
				"x-stv-transport": "app",
				"x-requested-with": "com.sangtacviet.mobilereader",
			};
			var url = fullUrl(app.net.networkManager.bestDomain() + `/?sajax=readchapter&h=${h}&bookid=${i}&c=${c}&key=${this.chapterkey}`);
			if(rl){
				url += "&rescan=true";
			}
			console.log(url);
			var retry = 0;
			while(retry < 2){
				try{
					var r = await context.get({
						url: url,
						headers: headers,
						ipv6: false,
					});
					var j = r.data.replace(/^\uFEFF/, '');
					if(j[0] != '{'){
						j = j.substring(j.indexOf('{'));
					}
					try{
						var json = JSON.parse(j);
						return json;
					}catch(ej){
						//app.debug.report(ej + ":JSON:" + encodeURIComponent(j));
					}
				}catch(e){
					await app.net.networkManager.checkDomains();
					retry++;
					e.message += " (retry: " + retry + ", url: " + url + ")";
					url = fullUrl(app.net.networkManager.bestDomain() + `/?sajax=readchapter&h=${h}&bookid=${i}&c=${c}&key=${this.chapterkey}`);
					if(rl){
						url += "&rescan=true";
					}
					console.log("Retrying to get content: " + url);
					app.debug.report(e);
				}
			}
			return null;
		}
	}
	app.reader.getContent = async function(h,i,c,rl){
		if(this.offlineBook && !rl){
			var cdata = await this.offlineBook.getChapterOrNull(c);
			if(cdata){
				return JSON.parse(cdata);
			}
		}
		this.setTransMode();
		await this.getKey(h,i);
		var ht = await this.getContent2(h,i,c,rl);
		if(ht){
			return ht;
		}
		var url = `/?sajax=readchapter&h=${h}&bookid=${i}&c=${c}&key=${this.chapterkey}`;
		if(rl){
			url += "&rescan=true";
		}
		try{
			var cdata = await app.net.get(url);
			if (cdata.code + "" == "7") {
				throw new Error("Device not supported");
			}
			return cdata;
		}catch(e){
			return {
				code: "1",
				info: "Kết nối tới máy chủ thất bại, hãy thử kiểm tra kết nối mạng.",
			}
		}
	}
	
    app.reader.runNameForAll = function(){
		try {
            this.getDisplay().runName();
		} catch (error) {}
        try{
			app.comicReader.runName();
		}catch(e){}
    }
	app.reader.changeChapter = function(cid){
		this.getDisplay().changeCurrentChapter(cid);
	}
	app.reader.reloadCurrentChapter = async function(rl){
		this.getDisplay().reloadCurrentChapter(rl);
	}
	app.reader.reloadAllChapter = async function(){
		this.getDisplay().reloadAllChapter();
	}
	app.reader.convertBr2P = function(str){
		str = str.replace(/<p>(.*?)<\/p>/gi,"$1<br><br>");
		str = str.replace(/<br\s*\/?>/gi,"</p><p>");
		// append and prepend <p> tag
		str = "<p>" + str + "</p>";
		// remove empty <p> tag
		str = str.replace(/<p>[\s\t\r\n]*<\/p>/g,"");
		return str;
	}
    app.reader.stripTags = function(text, exclude = []){
        for(var i = 0; i < exclude.length; i++){
            text = text.replace(new RegExp("<(/?" + exclude[i] + "[^>]*?)>", "g"), `__$1__`);
        }
        text = text.replace(/<\/?[^>]+(>|$)/g, "");
        for(var i = 0; i < exclude.length; i++){
            text = text.replace(new RegExp(`__(.*?)__`, "g"), `<$1>`);
        }
        return text;
    }
	app.reader.preprocess = function(bookhost,str){
		str = this.stripTags(str, ["p","br","i","span", "image"]);
		//str=str.replace(/<p[^>]*>/g, '<br>').replace(/<\/p>/g, '<br>');
		if(bookhost=="sangtac"||bookhost=="dich"){
			str=str.replace(/<[^i\/]/g,"&gt;").replace(/[\n]+/g,"<br><br>");
			str=str.replace(/ ([,\.!\?:”]+)/g,"$1");
			str = this.convertBr2P(str);
			if(bookhost == "sangtac") return str;
		}
		//str=str.replace(/<\/p>\r\n<p>/g,"<br><br>");
		if(app.language != "vi"){
			str=str.replace(/\n/g,"<br>");
			str = this.convertBr2P(str);
			return str;
		}
		if(getCookie("transmode") && getCookie("transmode") == "tfms"){
			str=str.replace(/\n/g,"<br>");
			str = this.convertBr2P(str);
			return str;
		}
		str=str.replace(/đạo ?<\/i>:/g,"nói</i>:");
		str=str.replace(/&nbsp;&nbsp;&nbsp;&nbsp;/g,"<br>");
		str=str.replace(/\n/g,"<br>");
		str=str.replace(/(\w) \./g,"$1.");
		str=str.replace(/((\w\.{1}[ \t])|(\w[!?]+(”|】)?))/g,"$1<br><br>");
		str=str.replace(/<br( ?\/)?>/ig,"<br><br>");
		str=str.replace(/(<br>(|\n|\t|\r| )*)+/g,"<br><br>");
		str=str.replace(/([\w>])“/g,"$1 “");
		str=str.replace(/(\w)<\/i><br>“/g,"$1</i>.<br>");
		str=str.replace(/ ”/g,"”");
		if(bookhost == "uukanshu"){
			str=str.replace(/<div class="ad_content">.*?<\/div>/g,"");
		}
		if(bookhost ==  "ciweimao" ){
			str=str.replace(/<span>.*?<\/span>/g,"");
			str=str.replace(/<img src="(.*?)".*?>/g,"<img src=\"https://comic.sangtacvietcdn.xyz/ciweimaobadnetworkimage.php?url=$1\">");
		}
		if(bookhost=="fanqie"){
			str = str.replace(/<\/?article>/g,"");
			str = str.replace(/_i_/g,"~");
		}
		str=str.replace(/<a href=.*?<\/a>/g,"");
		str=str.replace(/<br><br>([\)” 】!?]+)(<br>|$)/g,"$1$2");
		str=str.replace(/ ([,’]) /g,"$1 ");
		str=str.replace(/ ‘ /g," ‘");
		str=str.replace("<a&nbsp;href=\"http:", "");
		if(bookhost == "faloo"){
			str=str.replace(/<br>/g,"<br>\n");
			str=str.replace(/<br>\n([^“][^\n“]*?)”<br>/g,"<br>“$1”<br>");
			str=str.replace(/<br>\n/g,"<br>");
		}
		str=str.replace(/<br><br>(<br>)+/g,"<br><br>");
		str=str.replace(/ ([,\.!\?”]+)/g,"$1");
		if(bookhost == 'fanqie'){
			str = str.replace(/src=".*?"/g,function(m){return m.replace(/<br>/g,"").replace("http:","https:");});
		}
		//str=str.replace(/<br ?\/?>/ig, "");
		str = this.convertBr2P(str);
		return str.replace("\ufffe","");
	}
	app.reader.handlingException = function(x,f){
		var exc = {
			"12": function(x,f){
				app.fun.showLogin();
			},
			"13": function(x,f){
				app.fun.showLogin();
			},
			"15": function(x,f){
				app.fun.openBrowser(x.url);
			},
			"18": function(x,f){
				app.fun.openBrowser(x.url);
			},
			"19": function(x,f){
				app.fun.openBrowser(x.url);
			},
			"7": function(x,f){
				app.reader.showAlert(x.err || x.info || "Thiết bị không phù hợp hoặc phiên bản ứng dụng đã lỗi thời", f);
			},
			"21": function(x,f){
				runCaptcha("read", function(result){
					if(result){
						app.reader.reloadCurrentChapter(true);
					}else{
						app.reader.showAlert("Khởi động lại ứng dụng để tự động cập nhật", f);
					}
				});
			},
			"10001": function(x,f){
				var pair = app.reader.cachekey.split("-");
				app.reader.loadKeyFromServer(pair[0], pair[1]).then(()=>{
					app.reader.reloadAllChapter();
				});
			},
			"10002": function(x,f){
				if(window.failedIn5Times > 3){
					app.reader.showAlert(x.err || x.info || "Hệ thống đang bận, hãy thử lại sau", f);
				}else{
					window.failedIn5Times = window.failedIn5Times + 1 || 1;
					var pair = app.reader.cachekey.split("-");
					app.reader.loadKeyFromServer(pair[0], pair[1]).then(()=>{
						app.reader.reloadAllChapter();
					});
				}
			},
			"5": function(x,f){
				alert(x.info);
				app.goback();
			},
			"default": function(x,f){
				app.reader.showAlert(x.err || x.info || "Lỗi không xác định", f);
			}
		}
		if(exc["" + x.code]){
			exc["" + x.code](x,f);
		}else{
			exc["default"](x,f);
		}
        this.setNotLoading(f);
	}
	app.reader.showAlert = function(msg,view){
		this.getDisplay().showAlert(msg,view);
	}
	app.reader.getChapterNavigator = async function(h,i,c){
		return app.net.post("/io/novel/updateOldLink","host="+h+"&bookid="+i+"&chapterid="+c)
			.then(function(res){
				res=res.split("-");
                var ret = {
                    prev: 0,
                    next: 0
                }
				if(res[1]!="0"){
					ret.next = res[1];
				}
				if(res[0]!="0"){
					ret.prev = res[0];
				}
                return ret;
			}).catch(async function(e){
				console.log(e);
				var cl = await getChapterList(app.reader.host, app.reader.id);
				var currentChapter = cl.findIndex(function(x){return x.cid == c});
				var nextNode = cl[currentChapter+1];
				var prevNode = cl[currentChapter-1];
				var ret = {
                    prev: 0,
                    next: 0
                }
                if(nextNode){
                    ret.next = nextNode.cid;
                }
                if(prevNode){
                    ret.prev = prevNode.cid;
                }
                return ret;
			});
	}
	app.reader.updateHistory2 = function(){
		var c = this.getPCN().current;
		if(c.cid != app.history.get(this.host,this.id).chapter){
			app.history.update2(this.bookinfo,{
				title: (c.cdata || {}).chaptername || "Tên chương",
				id: c.cid
			});
		}
	}
	app.reader.updateHistory = function(h,i,c,cdata){
		if(h == "surf"){
			return;
		}
		if(!this.bookinfo || (this.bookinfo.id != i && this.bookinfo.host != h)){
			app.net.getCacheLater("/mobile/bookinfo.php?hid="+i+"&host="+h).then(function(d){
				app.history.update2(d.book,{
					title: cdata.chaptername,
					id: c
				});
				app.reader.bookinfo = d.book;
				app.namemanager.loadContext(d.book).then(function(){
					app.reader.runNameForAll();
				});
			});
		}else{
			app.history.update2(this.bookinfo,{
				title: cdata.chaptername,
				id: c
			});
		}
	}
	app.reader.checkMenuTap = function(x,y){
		this.menuTap[this.menuTapMode](x,y);
	}
	app.reader.menuTapMode = "centerlr";
	app.reader.menuTap = {
		"centerlr": function(x,y){
			var w = app.reader.display.width;
			var h = app.reader.display.height;
			if(app.reader.display.className.contain("showmenu")){
				app.reader.toggleMenu();
			} else if(x < Math.max(w * 1/3, 60)){
				app.reader.leftTap();
			} else if(x > Math.min(w * 2/3, w - 60)){
				app.reader.rightTap();
			} else {
				app.reader.toggleMenu();
			}
		},
	}
	app.reader.updateCnameAndProgress = function(){
		var progress = this.getDisplay().getChapterNameAndProgress();
        if(progress){
            this.display.q(".line2 .chaptername").textContent = progress.name;
            this.display.q(".line1 .chapterprogress").value = progress.progress;
        }
	}
	app.reader.showMenuOl = function(){
		app.platform.toggleStatusBar(true);
		this.updateCnameAndProgress();
	}
	app.reader.toggleMenu = function(){
		if(!this.display){
			this.display = g("chapterview");
		}
		this.display.classList.toggle("showmenu");
		if(!this.display.className.contain("showmenu")){
			if(this.bottommenu.innerHTML!=""){
				this.bottommenu.style.transform = "translateY(110%)";
				var btmntsend = function(){
					this.innerHTML = "";
					this.removeEventListener("transitionend",btmntsend);
					this.setAttribute("style","");
				};
				this.bottommenu.addEventListener("transitionend",btmntsend);
			}
            try{
                this.getDisplay().hideContextMenu();
			}catch(e){}
			try{
                this.getDisplay().unlockNameSelect();
			}catch(e){}
			app.platform.toggleStatusBar(false);
		}else{
			this.editnamepreview.style.display = "none";
            this.ttssetting.style.display = "none";
			app.reader.showMenuOl();
			this.display.q(".chapterinfo").style.display = "block";
		}
	}
	app.reader.showEditSuggest=function(arr){
		var container = this.display.q(".line2");
		container.innerHTML = "";
		for(var i=0;i<arr.length;i++){
			var btn = document.createElement("button");
			btn.className="sqrbtn borderright waves-effect waves-light";
			btn.textContent = arr[i].text;
			console.log(arr[i]);
			btn.addEventListener("click",function(){
				app.namemanager.append("$" + `${arr.base}=${this.textContent}`);
                app.reader.getDisplay().runName();
			});
			container.appendChild(btn);
		}
	}
	app.reader.showEditName = function(w,phrase){
		if(!this.display.className.contain("showmenu")){
			this.display.classList.add("showmenu");
			app.reader.showMenuOl();
		}
		this.display.q(".chapterinfo").style.display = "none";
		this.ttssetting.style.display = "none";
		var result = w.appSelectNode(phrase);
		if(result){
			this.editnamepreview.q(".chi").textContent = phrase.gT();
			this.editnamepreview.style.display = "block";
			app.editor.updateSuggest(w,phrase.gT(), phrase);
		}
	}
	app.reader.showTtsSetting = function(){
		if(!this.display.className.contain("showmenu")){
			this.display.classList.add("showmenu");
			app.reader.showMenuOl();
		}
		this.display.q(".chapterinfo").style.display = "none";
		this.editnamepreview.style.display = "none";
		this.ttssetting.style.display = "block";
	}
	app.reader.setTransMode = function(mode){
		if(!mode){
			mode = app.config.reader.transmode;
		}
		switch(mode){
			case "vp": {
				setCookie("transmode","name",100);
				break;
			}
			case "bing": {
				setCookie("transmode","tfms",100);
				break;
			}
			case "original": {
				setCookie("transmode","chinese",100);
				break;
			}
			case "english": {
				setCookie("foreignlang","gg_en",100);
				break;
			}
			default: {
				setCookie("transmode","name",100);
				break;
			}
		}
		if(mode != "english"){
			setCookie("foreignlang","vi",100);
		}
	}
	app.reader.style = {
		fontSize: "24px",
		fontFamily: "nunito",
		fontWeight: "normal",
		lineHeight: "1.8",
		textAlign: "justify",
		textIndent: "0px",
		textTransform: "none",
		letterSpacing: "0px",
		color: "#000",
		backgroundColor: "#eae4d3",
		padding: "0px 12px",
		wordSpacing: "0px",
		textShadow: "0px 0px 0px #000",
		textShadowColor: "#000",
		borderTop: "0px solid transparent",
		borderBottom: "0px solid transparent",
		paragraphSpace: "0px",
	};
	app.reader.posibleStyle = [ "fontSize",
								"lineHeight",
								"fontWeight",
								"backgroundColor",
								"color",
								"padding",
								"textAlign",
								"textIndent",
								"textShadow",
								"fontFamily",
								"letterSpacing",
								"wordSpacing",
								"paragraphSpace",
								"talkItalic",
								];
	app.reader.extPosibleStyle = ["backgroundImageId", "borderTop", "borderBottom"];
	app.reader.styleUi = st.create("");
	app.reader.styleCnameUi = st.create("");
	app.reader.styleCnameUi.use();
	app.reader.styleLayout = st.create("");
	app.reader.styleLayout.use();
	app.reader.style.set = function(name,value,noset,nosync){
		this[name] = value;
		var s = {};
		s[name] = value;
		if(app.reader.posibleStyle.indexOf(name) != -1 && !noset){
			app.storage.cache.setFile("reader.style."+name,value);
		}
		if(app.reader.extPosibleStyle.indexOf(name) != -1 && !noset){
			app.storage.cache.setFile("reader.style."+name,value);
		}
		if(!nosync)app.reader.applyStyle();
	}
	app.reader.loadStyle = async function(){
		for(var i = 0;i < app.reader.posibleStyle.length;i++){
			var name = app.reader.posibleStyle[i];
			var value = await app.storage.cache.getFile("reader.style."+name);
			if(value){
				this.style[name] = value;
			}
		}
		for(var i = 0;i < app.reader.extPosibleStyle.length;i++){
			var name = app.reader.extPosibleStyle[i];
			var value = await app.storage.cache.getFile("reader.style."+name);
			if(value){
				this.style[name] = value;
			}
		}
		this.applyStyle();
	}
	app.reader.applyStyle = function(){
		var s = {};
		var paras = {};
		var cnames = {};
		var talk = {};
		for(var i = 0;i < app.reader.posibleStyle.length;i++){
			var name = app.reader.posibleStyle[i];
			if(this.style[name]){
				s[name] = this.style[name];
				if(name == "backgroundColor" || name=="color"){
					cnames[name] = this.style[name];
				}
				if(name == "textIndent"){
					//paras["marginLeft"] = this.style[name];
					s["textIndent"] = "0px";
					paras["textIndent"] = this.style[name];
				}
				if(name == "paragraphSpace"){
					///paras["marginTop"] = 'calc(1em + ' +this.style[name]+')';
					paras["marginBlockStart"] = 'calc(1em + ' +this.style[name]+')';
					paras["marginBlockEnd"] = "0px";
				}
				if(name == "textShadow"){
					if(this.style[name].split(" ")[2] == "0px"){
						s["textShadow"] = "none";
					}
				}
				if(name == "talkItalic"){
					if(this.style[name] == "italic"){
						talk["fontStyle"] = "italic";
					}else{
						talk["fontStyle"] = "normal";
					}
				}
			}
		}
		if(this.style.backgroundImageId){
			if(app.reader.getDisplay().snap){
				s["backgroundColor"] = "transparent";
			}
			cnames["backgroundColor"] = "transparent";
			if(this.style.backgroundImageId != app.reader.previewer.backgroundImageId){
				app.reader.previewer.backgroundImageId = this.style.backgroundImageId;
				app.reader.styleCnameUi.set("#chapterview div[view=chaptercontainer]",{
					backgroundColor: "black",
				});
				(async function(){
					var img = await app.images.mani.getImgAsBlobUrl(app.reader.style.backgroundImageId);
					console.log("load image");
					if(img && img.toString().length > 5){
						app.reader.styleCnameUi.set("#chapterview div[view=chaptercontainer]",{
							backgroundImage: "url("+img+")",
						});
						var cl = app.images.mani.getDominateColor(await app.images.mani.loadImg(img));
						var bg = "rgb(" + ~~cl.r+","+ ~~cl.g+","+ ~~cl.b+")";
						app.reader.style.set("backgroundColor",bg,true);
                        app.reader.getDisplay().onBackgroundImageLoaded(img, bg);
					}else{
						var firstTheme = app.reader.style.themeSet.find(function(t){
							return t.backgroundColor;
						});
						app.reader.style.set("backgroundImageId", "",false,true);
						app.reader.style.set("backgroundColor",firstTheme.backgroundColor,false,true);
						app.reader.style.set("color",firstTheme.color,false);
					}
				})();
			}
		}else{
			app.reader.styleCnameUi.set("#chapterview div[view=chaptercontainer]",{
				backgroundImage: "none",
			});
		}
		app.reader.styleUi.set("body, #pageflipper p", s);
		if(paras.textIndent || paras.marginBlockStart){
			app.reader.styleUi.set("#maincontent > p, #pageflipper p, .contentcontainer p",paras);
		}
		if(talk.fontStyle){
			app.reader.styleUi.set(".talk, .talk + [id*=\"-\"]",talk);
		}
		app.reader.styleUi.set("#contextmenu",{ transform: `scale(${app.config.reader.context_menu_scale})`});
		var oldBackground =
			app.reader.styleCnameUi.collection["#chapterview"] &&
		 app.reader.styleCnameUi.collection["#chapterview"].css["--background"];
		if(oldBackground != this.style.backgroundColor){
			app.reader.styleCnameUi.set(".chaptertopinfo",cnames);
			app.reader.styleCnameUi.set("#chapterview",{
				"--background": this.style.backgroundColor,
				"--color": this.style.color,
				"--border-color": ui.color.getAlterColor(this.style.backgroundColor,0.2),
			});
			
			app.reader.styleLayout.set("#chapterview button",{
				"color": "inherit",
				"borderColor": "inherit",
				"padding": "0px 5px",
			});
			
			var optimalColor = ui.color.getPair(this.style.backgroundColor, 20, 0.98);
			app.reader.styleLayout.set("#chapterview .titlebar, #chapterview .bottombar, #chapterview .coption",{
				"color": optimalColor[1],
				"backgroundColor": optimalColor[0],
				"boxShadow": "0px 0px 4px "+optimalColor[0],
				"borderColor": optimalColor[1],
				//"transition": "all 0.2s",
			});
			app.reader.styleCnameUi.set(":root",{
				"--reader-background": this.style.backgroundColor,
				"--reader-color": optimalColor[1],
				"--reader-border-color": optimalColor[0],
			});
			app.reader.styleLayout.set("#chapterview .chapterprogress::-webkit-slider-thumb",{
				"backgroundColor": optimalColor[1],
			});
		}
		var stl = this.styleUi.textContent;
		q("iframe.content").forEach(f=>{
			var cd = f.contentDocument;
			var s = cd.querySelector("#readerstyle");
			if(s){
				s.textContent = stl
			}
			s = cd.querySelector("#localfont");
			if(s && !s.textContent){
				s.textContent = app.fontmanager.localCss.textContent;
			}
		});
        this.getDisplay().applyStyleChange(this.style);
	}
	app.reader.style.incFs = function(){
		var fs = parseInt(this.fontSize);
		fs += 1;
		this.set("fontSize",fs+"px");
	}
	app.reader.style.incFw = function(){
		var fw = fontweightToNumber(this.fontWeight);
		if(fw  < 900){
			fw += 100;
		}
		this.set("fontWeight",fw);
	}
	app.reader.style.decFs = function(){
		var fs = parseInt(this.fontSize);
		fs -= 1;
		if(fs < 12){
			fs = 12;
		}
		this.set("fontSize",fs+"px");
	}
	app.reader.style.decFw = function(){
		var fw = fontweightToNumber(this.fontWeight);
		if(fw  > 100){
			fw -= 100;
		}
		this.set("fontWeight",fw);
	}
	app.reader.style.incLh = function(){
		var lh = parseFloat(this.lineHeight);
		lh += 0.1;
		this.set("lineHeight",lh+"");
	}
	app.reader.style.decLh = function(){
		var lh = parseFloat(this.lineHeight);
		lh -= 0.1;
		if(lh < 1){
			lh = 1;
		}
		this.set("lineHeight",lh+"");
	}
	app.reader.style.incPadding = function(){
		var p = parseInt(this.padding.split(" ")[1]);
		p += 1;
		this.set("padding","0px " +p+"px");
	}
	app.reader.style.decPadding = function(){
		var p = parseInt(this.padding.split(" ")[1]);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("padding","0px " +p+"px");
	}
	app.reader.style.incIndent = function(){
		var p = parseInt(this.textIndent);
		p += 1;
		this.set("textIndent",p+"px");
	}
	app.reader.style.decIndent = function(){
		var p = parseInt(this.textIndent);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("textIndent",p+"px");
	}
	app.reader.style.incSdW = function(){
		var p = parseInt(this.textShadow.split(" ")[2]);
		p += 1;
		this.set("textShadow","0 0 "+p+"px " + this.textShadowColor);
	}
	app.reader.style.decSdW = function(){
		var p = parseInt(this.textShadow.split(" ")[2]);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("textShadow","0 0 "+p+"px " + this.textShadowColor);
	}
	app.reader.style.incBorderTop = function(){
		var p = parseInt(this.borderTop.split(" ")[0]);
		p += 1;
		this.set("borderTop",p+"px solid transparent");
	}
	app.reader.style.decBorderTop = function(){
		var p =  parseInt(this.borderTop.split(" ")[0]);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("borderTop",p+"px solid transparent");
	}
	app.reader.style.incBorderBottom = function(){
		var p = parseInt(this.borderBottom.split(" ")[0]);
		p += 1;
		this.set("borderBottom",p+"px solid transparent");
	}
	app.reader.style.decBorderBottom = function(){
		var p =  parseInt(this.borderBottom.split(" ")[0]);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("borderBottom",p+"px solid transparent");
	}
	app.reader.style.incParaSpace = function(){
		var p = parseInt(this.paragraphSpace);
		if(p.toString() == "NaN"){
			p = 0;
		}
		p += 1;
		this.set("paragraphSpace",p+"px");
	}
	app.reader.style.decParaSpace = function(){
		var p = parseInt(this.paragraphSpace);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("paragraphSpace",p+"px");
	}
	app.reader.style.incLtSpace = function(){
		var p = parseInt(this.letterSpacing);
		p += 1;
		this.set("letterSpacing",p+"px");
	}
	app.reader.style.decLtSpace = function(){
		var p = parseInt(this.letterSpacing);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("letterSpacing",p+"px");
	}
	app.reader.style.incWdSpace = function(){
		var p = parseInt(this.wordSpacing);
		p += 1;
		this.set("wordSpacing",p+"px");
	}
	app.reader.style.decWdSpace = function(){
		var p = parseInt(this.wordSpacing);
		p -= 1;
		if(p < 0){
			p = 0;
		}
		this.set("wordSpacing",p+"px");
	}
	app.reader.style.setFont = function(font){
		this.set("fontFamily",font);
	}
	app.reader.style.themeSet = [
		{backgroundColor: "#eae4d3",color: "#000"},
		{backgroundColor: "#eae4d3",color: "#333"},
		{backgroundColor: "#f5f5f5",color: "#000"},
		{backgroundColor: "#d0d0d0",color: "#000"},
		{backgroundColor: "#a3e6a2",color: "#000"},
		{backgroundColor: "#a7d4e8",color: "#000"},
		{backgroundColor: "#d7ffff",color: "#000"},
		{backgroundColor: "#8a8a88",color: "#eae4d3"},
		{backgroundColor: "#8a8a88",color: "#ececec"},
		{backgroundColor: "#464646",color: "#bdbdbd"},
		{backgroundColor: "#262626",color: "#dddddd"},
		{backgroundColor: "#ececec",color: "#333"},
	];
	onDbLoad.waitForLoad().then(async function(){
		var themeSets = await app.storage.cache.getFile("readthemeset") || "[]";
		themeSets = JSON.parse(themeSets);
		var a = themeSets.concat(app.reader.style.themeSet);
        var compare = function(a,b){
            if(Object.keys(a).length != Object.keys(b).length){
                return false;
            }
            for(var i in a){
                if(a[i] != b[i]){
                    return false;
                }
            }
        }
		//remove duplicate
        var newList = [];
        for(var i = 0;i < a.length;i++){
            var found = false;
            for(var j = 0;j < newList.length;j++){
                if(compare(a[i],newList[j])){
                    found = true;
                    break;
                }
            }
            if(!found){
                newList.push(a[i]);
            }
        }
        app.reader.style.themeSet = newList;
	});
	app.reader.saveThemeSet = function(){
		app.storage.cache.setFile("readthemeset",JSON.stringify(app.reader.style.themeSet));
	}
	app.reader.showStyleSetting = function(){
		this.bottommenu.innerHTML = "";
		var p = app.render("stylesetting",{});
		p.q(".decreasefontsize").addEventListener("click",function(){
			app.reader.style.decFs();
			p.q(".fontsizevalue").textContent = Math.floor(parseFloat(app.reader.style.fontSize));
		});
		p.q(".increasefontsize").addEventListener("click",function(){
			app.reader.style.incFs();
			p.q(".fontsizevalue").textContent = Math.floor(parseFloat(app.reader.style.fontSize));
		});
		p.q(".decreasefontweight").addEventListener("click",function(){
			app.reader.style.decFw();
			p.q(".fontweightvalue").textContent = fontweightToNumber(app.reader.style.fontWeight);
		});
		p.q(".increasefontweight").addEventListener("click",function(){
			app.reader.style.incFw();
			p.q(".fontweightvalue").textContent = fontweightToNumber(app.reader.style.fontWeight);
		});
		p.q(".increaselineheight").addEventListener("click",function(){
			app.reader.style.incLh();
			p.q(".lineheightvalue").textContent = Math.floor(
				parseFloat(app.reader.style.lineHeight) * 10
				) / 10;
		});
		p.q(".decreaselineheight").addEventListener("click",function(){
			app.reader.style.decLh();
			p.q(".lineheightvalue").textContent = Math.floor(
				parseFloat(app.reader.style.lineHeight) * 10
			) / 10;
		});
		p.q(".fontsizevalue").textContent = Math.floor(parseFloat(app.reader.style.fontSize));
		p.q(".fontweightvalue").textContent = fontweightToNumber(app.reader.style.fontWeight);
		p.q(".lineheightvalue").textContent = Math.floor(parseFloat(app.reader.style.lineHeight) * 10) / 10;
		p.q(".align button[al="+app.reader.style.textAlign+"]").classList.add("selected");
		p.qEvent(".align button","click",function(){
			app.reader.style.set("textAlign",this.getAttribute("al"));
			p.q(".align button.selected").classList.remove("selected");
			this.classList.add("selected");
		});
		p.q(".fontfamily text").textContent = app.reader.style.fontFamily;
		p.q(".fontfamily").addEventListener("click",function(){
			var menu = {
				type: "selected",
				item: [],
				selection: "app.reader.style.fontFamily"
			};
			var f = app.fontmanager.fonts;
			for(var i=0;i<f.length;i++){
				if(f[i].name.length < 1){
					continue;
				}
				var ucFirstName = f[i].name[0].toUpperCase();
				let val = f[i].name;
				menu.item.push({
					text: ucFirstName + f[i].name.substring(1),
					value: val,
					onclick: function(){
						p.q(".fontfamily text").textContent = val;
						app.reader.style.set("fontFamily",val);
					}
				});
			}
			app.context.showMenu(menu);
		});
		var cl = p.q(".colortheme");
		for(var i=0;i<this.style.themeSet.length;i++){
			let e = document.createElement("span");
			let th = this.style.themeSet[i];
			if(th.backgroundImage){
				if(app.images.mani.isDeleted(th.backgroundImage)){
					continue;
				}
				app.images.mani.getImg(th.backgroundImage).then((img)=>{
					e.style.backgroundImage = "url("+img+")";
				}).catch((err)=>{});
				e.setAttribute("resid",th.backgroundImage);
				e.style.color = th.color;
				e.textContent = "A";
				if(ui.color.isEqual(this.style.color,th.color)
					&& this.style.backgroundImage == th.backgroundImage){
					e.className = "selected";
				}
				e.setAttribute("rect", "true");
			}else{
				e.style.backgroundColor = th.backgroundColor;
				e.style.color = th.color;
				e.textContent = "A";
				if(ui.color.isEqual(this.style.color,th.color)
					&& ui.color.isEqual(this.style.backgroundColor,th.backgroundColor)){
					e.className = "selected";
				}
			}
			cl.appendChild(e);
			ui.hold(e, function(){
				app.reader.previewer.open(th);
			});
		}
		cl.addEventListener("click",async function(e){
			var sp = e.target;
			if(sp.tagName == "SPAN"){
				if(sp.getAttribute("rect")){
					//app.reader.style.set("backgroundColor","transparent",false,true);
					app.reader.style.set("backgroundImageId",sp.getAttribute("resid"),false,true);
					app.reader.style.set("color",sp.style.color);
					app.reader.previewer.backgroundImageId = "";
					q(".colortheme span").forEach(function(e){
						e.className = "";
					});
					sp.className = "selected";
				}
				else{
					app.reader.style.set("backgroundColor",sp.style.backgroundColor,false,true);
					app.reader.style.set("backgroundImageId","",false,true);
					app.reader.style.set("color",sp.style.color);
					app.reader.previewer.backgroundImageId = "";
					q(".colortheme span").forEach(function(e){
						e.className = "";
					});
					sp.className = "selected";
				}
			}
		});
		this.bottommenu.appendChild(p);
		p.addEventListener("click",function(e){
			if(e.target && e.target.tagName == "BUTTON"){
				app.platform.nativeclick();
			}
		});
		var hiddenspaceholder = p.q(".hiddensetting .holder");
		p.q(".expander").addEventListener("click",function(){
			var isExpanded = this.className.contain("expanded");
			if(isExpanded){
				this.classList.remove("expanded");
				hiddenspaceholder.style.height = "0px";
			}else{
				this.classList.add("expanded");
				hiddenspaceholder.style.height = hiddenspaceholder.nextElementSibling.scrollHeight + "px";
			}
		});

		// extended setting

		p.q(".shadowcolorpreview").style.backgroundColor = this.style.shadowColor;
		p.q(".shadowcolorpreview").addEventListener("click",function(){
			app.context.showColorPicker(this.style.backgroundColor,function(color){
				app.reader.style.set("shadowColor",color);
				p.q(".shadowcolorpreview").style.backgroundColor = color;
			});
		});

		p.q(".setcustomcolor").addEventListener("click",function(){
			app.reader.previewer.open();
		});
	}
	app.reader.fullscreen = function(){
		app.platform.toFullscreen();
		setTimeout(function(){
			if(app.reader.scroller){
				app.reader.setSnapPoint();
			}
		},1000);
	}
	app.reader.clean = function(){
		this.display = null;
		this.bookinfo = null;
		this.nextid = null;
		this.previd = null;
		this.bottommenu = null;
	}
	app.reader.defaultRStyle = `i{text-decoration:none; font-style:normal;}body{margin:0;}
		#contextmenu{transform-origin:top left;position:absolute;z-index:1000;top: -100px;opacity:0;transition:opacity 0.2s;}
		#contextmenu.active{opacity:1;}img{max-width:100%;}#contextmenu i{font-size: 1.5em;}`;
	
	app.reader.contextMenu = {
		"novel":{
			"copy":{
                "condition": function(e){
                    return false;
                },
				"text": "Sao chép",
				"action": function(e){}
			},
			"search":{
				"condition": function(e){
					return app.config.reader.ctx_search_btn;
				},
				"text": "<i class='far fa-search'></i>",
				"action": function(e){
                    app.topPage().q(".googlesearch").click();
                }
			},
			"addname":{
				"condition": function(e){
					return app.config.reader.ctx_addname_btn;
				},
				"text": "<i class='far fa-plus'></i>",
				"action": function(e){
                    app.editor.openAddname();
                }
			},
			"copy":{
				"condition": function(e){
					return app.config.reader.ctx_copy_btn;
				},
				"text": "<i class='far fa-copy'></i>",
				"action": function(e){
                    
                }
			},
			"_e_touchstart":function(e){
                window.cx = e.touches[0].clientX;
                window.cy = e.touches[0].clientY;
                window.isCancel = false;
                window.isFirstTouch = true;
                // 50ms cooldown
                window.isModify = true;
                setTimeout(function(){
                    window.isModify = true;
                },50);
                setTimeout(function(){
                    if(!window.isCancel){
                        var w = app.reader.tempCurrentWindow;
                        var d = w.chinesedragbar;
                        d.show();
                    }
                }, 500);
            },
			"_e_touchend":function(e){
                window.isCancel = true;
                window.isFirstTouch = false;
                window.isModify = false;
                var w = app.reader.tempCurrentWindow;
                var d = w.chinesedragbar;
                d.hide();
            },
			"_e_touchmove":function(e){
                if(window.isFirstTouch){
                    // if y changed more than x
                    if(Math.abs(e.touches[0].clientY - window.cy) > Math.abs(e.touches[0].clientX - window.cx)){
                        window.isCancel = true;
                    }
                    window.isFirstTouch = false;
                }
                if(!window.isCancel){
                    var x = e.touches[0].clientX;
                    var w = app.reader.tempCurrentWindow;
                    var d = w.chinesedragbar;
                    var y = e.touches[0].clientY;
                    d.show(y,w);
                    var offsetX = x - window.cx;
                    window.cx = x;
                    if(window.isModify){
                        var f = false;
                        if(offsetX > 2){
                            //d.rightAdd1();
                            d.increment();
                            window.isModify = false;
                            f = true;
                        }else if(offsetX < -2){
                            //d.rightRemove1();
                            d.decrement();
                            window.isModify = false;
                            f = true;
                        }
                        if(f){
                            setTimeout(function(){
                                window.isModify = true;
                            },150);
                        }
                    }
                }
            },
			"_onactivate": function(e,d,w){
                if(!app.reader.getDisplay().disableDragBar){
                    w.addEventListener("touchstart",this._e_touchstart);
                    w.addEventListener("touchend",this._e_touchend);
                    w.addEventListener("touchmove",this._e_touchmove);
                }
				if(d.tend){
					d.removeEventListener("transitionend",d.tend);
					d.tend = null;
				}
			},
			"_ondeactivate": function(e,d,w){
				d.classList.remove("active");
                if(!app.reader.getDisplay().disableDragBar){
                    w.removeEventListener("touchstart",this._e_touchstart);
                    w.removeEventListener("touchend",this._e_touchend);
                    w.removeEventListener("touchmove",this._e_touchmove);
                }
                var dragbar = w.chinesedragbar;
                dragbar.unhighlight();
				var tend = function(){
					d.style.top = "0px";
					d.removeEventListener("transitionend",tend);
					d.tend = null;
				};
				d.tend = tend;
				d.addEventListener("transitionend",tend);
			}
		}
	}
	app.reader.setContextMenu = function(d,node,w){
		var c = node.getClientRects ? node.getClientRects()[0] : node.getBoundingClientRect();
		//d.style.left = c.left + "px";
		//d.style.top = c.top + w.scrollY + c.height + "px";
		var mode = "novel";
		var menu = this.contextMenu[mode];
		var html = "";
		for(var i in menu){
			if(menu[i].condition && !menu[i].condition(node) || i.startsWith("_")){
				continue;
			}
			html += `<div class="rctxitem" data-action="${i}">${menu[i].text}</div>`;
		}
		d.innerHTML = html;
		d.classList.add("active");
		var ctmnwidth = d.clientWidth * parseFloat(app.config.reader.context_menu_scale);
		requestAnimationFrame(function(){
			d.style.transform = `scale(${app.config.reader.context_menu_scale})`;
			d.style.top = c.top + w.scrollY + c.height + "px";
			if(c.left + ctmnwidth > w.innerWidth){
				d.style.left = c.left + c.width - ctmnwidth + "px";
			}else{
				d.style.left = c.left + "px";
			}
		});
		if(!d.eventAttached){
			d.eventAttached = true;
			d.addEventListener("click",e=>{
				var action = e.target.dataset.action || e.target.parentNode.dataset.action;
				if(!action){
					return;
				}
				menu[action].action(node);
			});
			d.hide = function(){
				if(menu._ondeactivate){
					menu._ondeactivate(node,this,w);
				}
			}
		}
		if(menu._onactivate){
			menu._onactivate(node,d,w);
		}
        var dragbar = w.chinesedragbar;
        dragbar.ctxMenu = d;
        dragbar.switch(node);
        dragbar.yPos = c.top + w.scrollY - 70;
        this.tempCurrentWindow = w;
	}

	// previewer 
	app.reader.previewer = {
		backgroundHolder: st.create().use(),
		setBase64: function(base64){
			this.backgroundHolder.set(".readthemesetpreview",{backgroundImage:`url(${base64})`});
		},
		rollback: function(target){
			$.extend(this.activeTheme,this.rollbackObj);
		},
	};
	app.reader.previewer.open = function(theme){
		var p = app.pushPage("pagethemesetpreview");
		var isAdd = false;
		if(!theme){
			theme = {
				backgroundColor: "#ffffff",
				backgroundImage: null,
				color: "#000000",
			}
			isAdd = true;
		}
		this.rollbackObj = $.extend({},theme);
		this.activeTheme = theme;
		setBackgroundOrImage(p, theme);
		var toolbox = p.q(".toolbox");
		//var left = p.q(".left");
		//var right = p.q(".right");
		var top = p.q(".top");
		var bottom = p.q(".bottom");
		var middle = p.q(".middle");
		var center = p.q(".center");
		var isTouch = true;
		var d = ui.resize(top,middle, "vertical", isTouch);
		d.appendChild(app.render("resizer-ver"));
		d = ui.resize(middle,bottom, "vertical", isTouch);
		d.appendChild(app.render("resizer-ver"));

		//events
		p.q(".backgroundcolor").addEventListener("click",async function(){
			var rs = await app.context.colorPicker(theme?theme.backgroundColor:"#ffffff", function(c){
				p.style.backgroundColor = c;
			});
			if(rs === false){
				setBackgroundOrImage(p, theme);
			}else{
				theme.backgroundColor = rs;
				theme.backgroundImage = null;
				setBackgroundOrImage(p, theme);
			}
		});
		p.q(".textcolor").addEventListener("click",async function(){
			var rs = await app.context.colorPicker(theme?theme.color:"#000000", function(c){
				p.style.color = c;
			});
			if(rs === false){
				p.style.color = theme.color;
			}else{
				theme.color = rs;
				p.style.color = rs;
			}
		});
		p.q(".backgroundimage").addEventListener("click",async function(){
			openImageFilePicker(true).then(async (imgRef)=>{
				var imgFile = await imgRef[0].getFile();
				var base64 = await img2Base64(imgFile);
				theme.backgroundImage = base64;
				theme.backgroundColor = null;
				setBackgroundOrImage(p, theme);
			});
		});
		var ctitle = p.q(".chapterinfo");
		p.q(".nametop").addEventListener("click",function(){
			ctitle.parentElement.insertBefore(ctitle,ctitle.parentElement.firstChild);
		});
		p.q(".namebot").addEventListener("click",function(){
			ctitle.parentElement.appendChild(ctitle);
		});
		p.q(".notop").addEventListener("click",function(){top.style.height = 0;});
		p.q(".nobot").addEventListener("click",function(){bottom.style.height = 0;});
		p.q(".addtop").addEventListener("click",function(){top.style.height = (parseInt(top.style.height)||0) + 10;});
		p.q(".addbot").addEventListener("click",function(){bottom.style.height = (parseInt(bottom.style.height)||0) + 10;});
		p.q(".addpadding").addEventListener("click",function(){
			var p = parseInt(center.style.paddingLeft) || 0;
			center.style.paddingLeft = (p + 2) + "px";
			center.style.paddingRight = (p + 2) + "px";
		});
		p.q(".decpadding").addEventListener("click",function(){
			var p = parseInt(center.style.paddingLeft) || 0;
			if(p > 0){
				center.style.paddingLeft = (p - 2) + "px";
				center.style.paddingRight = (p - 2) + "px";
			}
		});
		p.q(".save").addEventListener("click",function(){
			app.reader.previewer.save(theme,isAdd);
			app.goback();
		});
	}
	app.reader.previewer.save = async function(th,isAdd){
		if(th.backgroundImage){
			var imgId = th.backgroundImage;
			if(!app.images.mani.isRescId(th.backgroundImage)){
				imgId = await app.images.mani.saveImg(th.backgroundImage);
			}
			th.backgroundImage = imgId;
			this.backgroundImageId = imgId;
			app.reader.style.set("backgroundImageId", th.backgroundImage, false, true);
		}else{
			app.reader.style.set("backgroundColor", th.backgroundColor, false, true);
		}
		app.reader.style.set("color", th.color);
		
		if(isAdd){
			app.reader.style.themeSet.unshift(th);
			app.reader.saveThemeSet();
		}else{
			app.reader.saveThemeSet();
		}
	}
	async function setBackgroundOrImage(ele, theme){
		if(!theme){
			theme = {
				backgroundColor: "#ffffff",
				backgroundImage: "",
				color: "#000000"
			};
		}
		if(theme.backgroundImage){
			ele.style.backgroundImage = `url(${await app.images.mani.getImg(theme.backgroundImage)})`;
			ele.style.backgroundSize = /* stretch */ "100% 100%";
		}else{
			ele.style.backgroundImage = "";
			ele.style.backgroundColor = theme.backgroundColor;
		}
		ele.style.color = theme.color;
	}

	app.reader.autoscroller = {
		speed: 2,
		isBreak: false,
		isScrolling: false,
        lastTimestamp: 0,
		start: function(){
            var displayType = app.config.reader.display_type;
            if(["auto", "slide", "continuos"].indexOf(displayType) == -1){
                app.toast(app.text.autoscroll_not_supported);
                return;
            }
			this.isBreak = false;
			this.isScrolling = true;
			var pcn = app.reader.getPCN();
			this.current = pcn.current;
			this.cwd = app.reader.getDisplay().getCurrentWindow();
			this.scrollPos = this.cwd.scrollY;
            this.lastTimestamp = 0;
			requestAnimationFrame(this.scroll);
		},
		scroll: function(timestamp){
			var pcn = app.reader.getPCN();
			if(pcn.current != app.reader.autoscroller.current){
				app.reader.autoscroller.stop();
				return;
			}
            if(app.reader.autoscroller.lastTimestamp == 0){
                app.reader.autoscroller.lastTimestamp = timestamp;
            }
            var delta = timestamp - app.reader.autoscroller.lastTimestamp;
            if(delta < 1000 / 60){
                requestAnimationFrame(app.reader.autoscroller.scroll);
                return;
            }
            app.reader.autoscroller.lastTimestamp = timestamp;
			var scrollPos = app.reader.autoscroller.cwd.scrollY;
			if(scrollPos != app.reader.autoscroller.scrollPos){
				app.reader.autoscroller.scrollPos = scrollPos;
			}
			app.reader.autoscroller.cwd.scrollBy(0, app.reader.autoscroller.speed);
			if(!app.reader.autoscroller.isBreak){
				requestAnimationFrame(app.reader.autoscroller.scroll);
			}
		},
		incSpeed: function(){
			this.speed++;
		},
		decSpeed: function(){
			this.speed--;
			if(this.speed < 1){
				this.speed = 1;
			}
		},
		stop: function(){
			this.isBreak = true;
			this.isScrolling = false;
		}
	}
	app.reader.autoScroll = function(){
		if(app.reader.autoscroller.isScrolling){
			app.reader.autoscroller.stop();
		}else
		app.reader.autoscroller.start();
	}
	app.reader.loadDrawerChapter = async function(){
		if(app.reader.drawer.q(".clistcontainer").children.length == 0)
		return await getchapterlist(this.host,this.id, false, app.reader.drawer.q(".clistcontainer"), 90, false);
	}
	app.reader.showDrawer = async function(){
		app.reader.drawer.style.display = "block";
		await waitFrame();
		app.reader.drawer.classList.add("open");
		if(app.reader.drawer.q(".clistcontainer").children.length == 0){
			this.loadDrawerChapter();
			app.reader.drawer.q(".chapterlist").addEventListener("click",async function(e){
				var t = e.target;
				if(t.hasAttribute("cid")){
					var cid = t.getAttribute("cid");
					app.reader.getDisplay().changeCurrentChapter(cid);
					app.reader.drawer.classList.remove("open");
					await waitFrame();
					app.reader.updateCnameAndProgress();
				}
			});
			var clist = app.reader.drawer.q(".chapterlist");
			app.reader.drawer.q(".clistsearch").addEventListener("keyup",function(e){
				ui.filterSel(this, clist, ".clistpart > div");
			});
			app.reader.drawer.q(".rbtn").addEventListener("click",function(){
				app.reader.drawer.classList.remove("open");
			});
		}else{
			var currentCid = app.reader.getPCN().current.cid;
			setTimeout(function(){
				var currentLastRead = app.reader.drawer.q(".chaplastreaded");
				if(currentLastRead && currentLastRead.getAttribute("cid") != currentCid){
					currentLastRead.classList.remove("chaplastreaded");
					var c = app.reader.drawer.q(`.chapterlist [cid="${currentCid}"]`);
					if(c){
						c.classList.add("chaplastreaded");
						var p = app.reader.drawer.q(".clistcontainer");
						p.scrollTop = c.offsetTop - 70;
					}
				}
			}, 700);
		}
	};
	app.reader.hideDrawer = function(){
		app.reader.drawer.style.display = "none";
	}
	app.reader.openSetting = function(){
		var p = app.pushPage("pagereadersetting");
        var touchActionMenu = {
            type: "select",
            item: this.getDisplay().behaviour.tap_actions.description.map(x=>{return {text: x.name, value: x.value}}),
        }
        var tapLeftBtn = p.q(".tapactionleft");
		var tapRightBtn = p.q(".tapactionright");
		var findCurrentTapAction = function(v){
			var found = app.reader.getDisplay().behaviour.tap_actions.description.find(x=>x.value == v);
			if(found){
				return found.name;
			}
			return "Không phù hợp";
		}
		tapLeftBtn.textContent = findCurrentTapAction(app.config.reader.left_tap_action);
		tapRightBtn.textContent = findCurrentTapAction(app.config.reader.right_tap_action);
        tapLeftBtn.addEventListener("click",function(){
            app.context.showMenu($.extend({},touchActionMenu,{
                selection: "app.config.reader.left_tap_action",
                onchange: function(v){
                    tapLeftBtn.textContent = v.text;
                },
            }));
        });
        tapRightBtn.addEventListener("click",function(){
            app.context.showMenu($.extend({},touchActionMenu,{
                selection: "app.config.reader.right_tap_action",
                onchange: function(v){
                    tapRightBtn.textContent = v.text;
                },
            }));
        });
        var selectDisplayType = p.q(".displaytype");

	}
})(app);

// editor
(async function(app){
	app.editor = {};
	await onDbLoad.waitForLoad();
	var defaultSetting = {
		"allowchiname":true,
		"peoplefilter":true,
		"factionfilter":true,
		"allowtaptoedit":true,
		"allowanalyzerupdate":true,
		"allownamev3":true,
		"directedit":true,
		"skillfilter":true,
		"scopefilter":true,
		"englishfilter":true,
		"skilluppercase":true,
		"highlight":false,
		"disablemeanstrategy":false,
		"onlyonename":false,
		"enabletestln":false,
		"allowwordconnector":false,
		"allowphraseshiftor":false,
		"disabledefaultname":false,
		"enablesuffix":true,
	}
	app.editor._setting = JSON.parse((await app.storage.cache.getFile("editor.setting")) || `{}`);
	app.editor._setting = $.extend(defaultSetting, app.editor._setting);
	
	app.editor.setting = {};
	for(let i in app.editor._setting){
		app.editor.setting.__defineGetter__(i, function(){
			return app.editor._setting[i];
		});
		app.editor.setting.__defineSetter__(i, function(v){
			app.editor._setting[i] = v == "true" ? true : v == "false" ? false : v;
			app.storage.cache.setFile("editor.setting",JSON.stringify(app.editor._setting));
		});
	}
	app.editor.setting.set = function(name,value){
		this[name] = value;
		app.storage.cache.setFile("editor.setting",JSON.stringify(this));
	}
	app.editor.context = null;
	app.editor.updateSuggest = function(w,t,p){
		var suggest = w.getEditSuggest(t, p);
		suggest.onUpdate = function(){
			if(suggest == app.editor.context){
				this.sort((a,b)=>b.priority-a.priority);
				app.reader.showEditSuggest(this);
			}
		}
		app.editor.context = suggest;
		suggest.onUpdate();
		
	}
	app.editor.expandPhraseLeft = function(){
		var w = app.reader.getDisplay().getCurrentWindow();
		w.appExpandLeft();
		var s = w.getSelectedNodeChinese();
		app.reader.display.q(".chi").textContent = s;
		this.updateSuggest(w,s);
	}
	app.editor.expandPhraseRight = function(){
		var w = app.reader.getDisplay().getCurrentWindow();
		w.appExpandRight();
		var s = w.getSelectedNodeChinese();
		app.reader.display.q(".chi").textContent = s;
		this.updateSuggest(w,s);
	}
    app.editor.popupAddname = {
        title: "",
        body: `
            <div class="row-cn flex">
                <button class="linc"><i class="fas fa-chevron-left"></i></button>
                <button class="ldec"><i class="fas fa-chevron-right"></i></button>
                <div class="chinese">
                    <span class="chileft"></span><span class="chicenter"></span><span class="chiright"></span>
                </div>
                <button class="rdec"><i class="fas fa-chevron-left"></i></button>
                <button class="rinc"><i class="fas fa-chevron-right"></i></button>
            </div>
            <div class="row-hv flex">
                <div class="label">Hán<br>Việt</div>
                <div class="hv-block block">
                    <div class="hanviet" contenteditable=true>Hán Việt</div>
                    <div class="flex hv-case-sel">
						<span style="padding:3px">Hoa:</span>
                        <button class="case-hv" val="0">0</button>
                        <button class="case-hv" val="1">1</button>
                        <button class="case-hv" val="2">2</button>
                        <button class="case-hv" val="3">3</button>
                        <button class="case-hv" val="all">Tất cả</button>
                    </div>
                </div>
            </div>
            <div class="row-sug flex">
                <div class="label">Gợi<br>Ý</div>
                <div class="sg-block block"></div>
            </div>
            <div class="row-last flex">
                <div class="label">Kết<br>Quả</div>
                <div class="lst-block block" contenteditable=true></div>
                <div class="clearbtn"><i class="fal fa-times"></i></div>
            </div>
            <div class="row-save flex mb-3">
                <div class="label" style="line-height:2;">Lưu</div>
                <div class="block flex" style="border:none;padding: 0;gap:5px">
                    <div class="flex w-50" style="gap: 5px">
                        <button class="toname selected">Name</button>
                        <button class="tovp">VP</button></div>
                    <div class="flex w-50" style="gap: 5px">
                        <button class="saveall">Chung</button>
                        <button class="savetobook" hidden>Web</button>
                    </div>
                </div>
            </div>
        `,
        button: `
            <button action=cancel class="addnamecancel w-50">Hủy</button>
            <button action=save class="addnamesave w-50">Thêm name</button>
        `,
        action: {
            save: async function(p){
                var isSaveAsName = p.q(".toname").classList.contains("selected");
				var name = p.q(".lst-block").textContent.trim();
				var baseText = p.q(".chicenter").textContent;
				if(name == ""){
					var isRemove = await app.context.yesno(`Bạn có muốn xóa từ "${baseText}" này không?`);
					if(!isRemove){
						return;
					}
				}
                var pack = `${isSaveAsName?"$":"#"}${baseText}=${name}`;
                var isglobal = p.q(".saveall").classList.contains("selected");
                var isSaveToWeb = p.q(".savetobook").classList.contains("selected");
                if(isglobal){
                    await app.namemanager.appendGlobal(pack);
                    console.log("add global", pack);
					app.reader.runNameForAll();
                }else{
                    app.namemanager.append(pack);
					setTimeout(()=>{
						app.reader.runNameForAll();
					},500);
                }
                if(isSaveToWeb){
                    //todo
                };
                this.cancel(p);
                //app.reader.runNameForAll();
            },
            cancel: function(p){
                p.parentElement.hide();
            }
        }
    }
    app.editor.getSuggestTimer = null;
    function titleCaseNWords(str, n) {
        var splitStr = str.toLowerCase().split(' ');
        for (var i = 0; i < splitStr.length; i++) {
            if(i<n){
                splitStr[i] = splitStr[i].charAt(0).toUpperCase() + splitStr[i].substring(1);     
            }
        }
        return splitStr.join(' '); 
    }
    app.editor.openAddname = function(t, left, center, right){
        var popupTemplate = $.extend({},this.popupAddname);
        var ct = this.context;
        popupTemplate.data = {};
        var p = app.context.showPopup(popupTemplate);
        p.classList.add("popupaddname");
        p.q(".chicenter").textContent = ct.base;
        var bar = smallChineseBar(p.q(".chinese"), left, center, right);
        var w = t || app.reader.tempCurrentWindow;
        p.q(".ldec").addEventListener("click",function(){ bar.leftDec(); });
        p.q(".linc").addEventListener("click",function(){ bar.leftInc(); });
        p.q(".rdec").addEventListener("click",function(){ bar.rightDec(); });
        p.q(".rinc").addEventListener("click",function(){ bar.rightInc(); });
        var hv = p.q(".hanviet");
        var rs = p.q(".lst-block");
        hv.textContent = w.convertohanviets(ct.base);
        var sgBlock = p.q(".sg-block");
        this.updateSuggestAddname(w,sgBlock,ct.base);
        bar.onUpdate = function(t){
            hv.textContent = w.convertohanviets(t);
            clearTimeout(app.editor.getSuggestTimer);
            app.editor.getSuggestTimer = setTimeout(function(){
                app.editor.updateSuggestAddname(w,sgBlock,t);
            },500);
        }
        sgBlock.addEventListener("click",function(e){
            var t = e.target.textContent;
            rs.textContent = t;
			if(app.config.reader.save_on_case_click.toString() == "true"){
				p.q(".addnamesave").click();
				return;
			}
			if(this.clickTime && (new Date().getTime() - this.clickTime < 300)){
				p.q(".addnamesave").click();
				return;
			}
			this.clickTime = new Date().getTime();
        });
        p.q(".toname").addEventListener("click",function(){
            this.classList.add("selected");
            p.q(".tovp").classList.remove("selected");
        });
        p.q(".tovp").addEventListener("click",function(){
            this.classList.add("selected");
            p.q(".toname").classList.remove("selected");
        });
        p.q(".saveall").addEventListener("click",function(){
            this.classList.toggle("selected");
        });
        p.q(".savetobook").addEventListener("click",function(){
            this.classList.toggle("selected");
        });
        p.q(".clearbtn").addEventListener("click",function(){
            rs.textContent = "";
        });
        p.qq(".case-hv").forEach(function(e){
            var v = e.getAttribute("val");
            if(v == "all") v = 999;
            e.addEventListener("click",function(){
                hv.textContent = titleCaseNWords(hv.textContent.toLowerCase(),v);
                rs.textContent = hv.textContent;
				if(app.config.reader.save_on_case_click.toString() == "true"){
					p.q(".addnamesave").click();
					return;
				}
				if(this.clickTime && (new Date().getTime() - this.clickTime < 300)){
					p.q(".addnamesave").click();
					return;
				}
				this.clickTime = new Date().getTime();
            });
        });
		rs.addEventListener("keyup", function(e){
			if(e.keyCode == 13){
				p.q(".addnamesave").click();
			}
		});
		hv.addEventListener("keyup", function(e){
			rs.textContent = hv.textContent;
			if(e.keyCode == 13){
				p.q(".addnamesave").click();
			}
		});
		hv.addEventListener("focus", function(e){
			rs.textContent = hv.textContent;
		});
    };
    var smallChineseBar = function(n, lt, ct, rt){
        var l = n.q(".chileft");
        var c = n.q(".chicenter");
        var r = n.q(".chiright");
        n.rightInc = function(){
            if(r.textContent){
                c.textContent += r.textContent[0];
                r.textContent = r.textContent.substr(1);
                this.onUpdate(c.textContent);
            }
        }
        n.rightDec = function(){
            if(c.textContent.length > 1){
                r.textContent = c.textContent[c.textContent.length-1] + r.textContent;
                c.textContent = c.textContent.substr(0,c.textContent.length-1);
                this.onUpdate(c.textContent);
            }
        }
        n.leftInc = function(){
            if(l.textContent){
                c.textContent = l.textContent[l.textContent.length-1] + c.textContent;
                l.textContent = l.textContent.substr(0,l.textContent.length-1);
                this.onUpdate(c.textContent);
            }
        }
        n.leftDec = function(){
            if(c.textContent.length > 1){
                l.textContent += c.textContent[0];
                c.textContent = c.textContent.substr(1);
                this.onUpdate(c.textContent);
            }
        }
        n.getText = function(){
            return c.textContent;
        }
        var w = app.reader.tempCurrentWindow;
		if(!ct && w && w.chinesedragbar){
			var dragbar = w.chinesedragbar;
			l.textContent = dragbar.leftCn;
			r.textContent = dragbar.rightCn;
		}else{
			l.textContent = lt || "";
			r.textContent = rt || "";
		}
        return n;
    }
    app.editor.showEditSuggerAddname = function(bl,sg){
        bl.innerHTML = "";
        for(var i=0;i<sg.length;i++){
            var b = document.createElement("button");
            b.textContent = sg[i].text;
            b.classList.add("suggest");
            b.setAttribute("tag",sg[i].tag +":");
            bl.appendChild(b);
        }
    }
    app.editor.updateSuggestAddname =  function(w,bl,t){
        bl.text = t;
        var sg = w.getEditSuggest(t,null,true);
        sg.onUpdate = function(){
            if(bl.text == t)app.editor.showEditSuggerAddname(bl,this);
        }
    }
})(app);

//app.tts
(async function(app){
	await onDbLoad.waitForLoad();
	app.tts = {
		voiceId: 0,
	};
	ui.scriptmanager.load("/stv.tts.js?v=7", function(){}, !isCachedFrontend);

	function Sentence(view, nodes, senid){
		this.nodes = nodes;
		this.text = nodes.toText ? nodes.toText() : view.speaker.senToText(senid);
		this.isPlaying = false;
		this.retryCount = 0;
		function formatText(t){
			t = t.replace(/%/g, " phần trăm ");
			t = t.replace(/\//g, " trên ");
			t = t.replace(/\.(\d)/g, " chấm $1");
			t = t.replace(/debuff?/gi, " đì búp ");
			t = t.replace(/buff?/gi, " búp ");
			return t;
		}
		this.text = formatText(this.text);
		this.hasText = function(){
			return this.text.match(/\w/);
		}
		this.play = function(){
			if(!view){
				return;
			}
			if(this.audioItem){
				this.isPaused = false;
				this.playAndWait();
				return true;
			}else{
				this.prefetch();
				this.onaudioloaded = function(){
					this.play();
				};
			}
		};
		this.playAndWait = async function(){
			ttsEngine.play(this.audioItem);
			this.onstart();
			if(this.waitObject){
				this.waitObject.stillWaiting = false;
			}
			var wo = this.waitObject = ttsEngine.waitSingle();
			await this.waitObject.promise;
			if(!this.isPaused && wo.stillWaiting){
				console.log("after");
				this.after();
			}
		}
		this.continue = function(){
			this.isPaused = false;
			this.playAndWait();
		};
		this.pause = function(){
			this.isPaused = true;
			ttsEngine.audio.pause();
			if(this.waitObject){
				this.waitObject.stillWaiting = false;
			}
		};
		this.after = function(){};
		this.onstart = function(){};
		this.onerror = function(e){
			console.log(e);
		};
		this.discardAudio = function(){
		}
		this.hasRequestedAudio = false;
		this.requestTimeout = null;
		this.prefetch = function(){
			if(this.hasRequestedAudio)return;
			ttsEngine.requestAudioInstant(this.text, {}, this.senid).then(
				(function(item){
					if(item == null){
						app.toast("Khởi tạo audio thất bại, hãy thử lại");
						this.hasRequestedAudio = false;
						if(this.requestTimeout){
							clearTimeout(this.requestTimeout);
							this.requestTimeout = null;
						}
						var providerClass = ttsEngine.provider.constructor;
						this.onerror(`TTS request failed(Provider: ${providerClass ? providerClass.name : "Unknown"},
							sentence: ${this.text})`);
						return;
					}
					this.audioItem = item;
					this.onaudioloaded();
					if(this.requestTimeout){
						clearTimeout(this.requestTimeout);
						this.requestTimeout = null;
					}
				}).bind(this)
			);
			this.hasRequestedAudio = true;
			this.requestTimeout = setTimeout((function(){
				this.requestTimeout = null;
				this.hasRequestedAudio = false;
				this.retryCount++;
				if(this.retryCount > 3){
					var providerClass = ttsEngine.provider.constructor;
					this.onerror(`TTS request timeout(Provider: ${providerClass ? providerClass.name : "Unknown"}, 
						retry: ${this.retryCount},
						sentence: ${this.text})`);
					this.retryCount = 0;
					this.clearPrefetch();
				}else{
					this.prefetch();
				}
			}).bind(this), 5000);
		};
		this.onaudioloaded = function(){};
		this.audioItem = null;
		this.highlight = function(cl){
			if(this.nodes.highlightOn){
				this.nodes.highlightOn(cl);
			} else {
				this.view.speaker.highlightOn(this.senid, cl);
				try{
					$(this.view.document.documentElement).animate({
						scrollTop: $(this.nodes.find(e=>e.id)).offset().top - 230
					}, 200);
				}catch(e){}
			}
		};
		this.unhighlight = function(){
			if(this.nodes.highlightOff){
				this.nodes.highlightOff();
			} else {
				this.view.speaker.highlightOff(this.senid);
			}
		};
		this.clearPrefetch = function(){
			if(this.audioItem){
				this.audioItem.blob = null;
				this.audioItem = null;
				this.hasRequestedAudio = false;
				if(this.requestTimeout){
					clearTimeout(this.requestTimeout);
					this.requestTimeout = null;
				}
				this.retryCount = 0;
			}
		};
		this.view = view;
		this.senid = senid;
		return this;
	}
	function getSentences(addEvent){
		var wd = app.reader.getDisplay().getCurrentWindow();
		if(!wd.speaker){
			app.toast("Không tìm thấy nội dung để đọc, có thể do phát sinh lỗi");
			return null;
		}
		var list = [];
		if(app.reader.getDisplay().tokenizeSentence){
			list = app.reader.getDisplay().tokenizeSentence();
		}else{
			wd.speaker.parseSen();
			list = wd.speaker.sentences;
		}
		var result = [];
		for(var i=0;i<list.length;i++){
			var nodes = list[i];
			var sen = new Sentence(wd, nodes, i);
			if(sen.hasText()){
				result.push(sen);
				addEvent && addEvent(sen);
			}
		}
		return result;
	}
	var player = {
		sentences: [],
		_currentId: 0,
		get currentId(){
			return this._currentId;
		},
		set currentId(id){
			this._currentId = id;
			this.updateUi();
		},
		currentSen: null,
		isPlaying: false,
		audioNode: null,
		highlightColor: "red",
		currentChapterId: 0,
		isViewChanged: function(){
			return app.reader.getPCN().current.cid != this.currentChapterId;
		},
		checkAlive: function(){
			try{
				return app.reader.getDisplay().getCurrentWindow().speaker;
			}catch(e){
				return false;
			}
		},
		generateSentences: function(reset = true){
			var ref = this;
			this.sentences = getSentences(function(sen){
				sen.after = function(){
					if(ref.checkAlive()){
						ref.moveNext();
						console.log("movenext after");
					}
					
				};
				sen.onstart = function(){
					ref.startTimer();
					console.log("onstart prefetchnext");
					ref.tryPrefetchNext();
				};
				sen.onerror = function(e){
					ref.pause();
					app.context.info("TTS error: " + e);
				};
			});
			if(reset){
				this.currentId = 0;
			}
			this.currentChapterId = app.reader.getPCN().current.cid;
		},
		clearPrefetch: function(){
			this.sentences.forEach(function(sen){
				sen.clearPrefetch();
			});
		},
		stop: function(){
			this.currentId = 0;
			this.pause();
			this.currentSen = null;
		},
		reset: function(){
			this.stop();
			this.sentences = [];
		},
		init: function(){
			this.audioNode = ttsEngine.audio;
			//this.highlightColor =  ui.color.getAlterColor(app.reader.style.color, 20);
		},
		tryUnhighlight: function(){
			try{
				this.currentSen.unhighlight();
			}catch(e){
				console.log(e);
			}
		},
		play: function(){
			//if(this.isPlaying)return;
			if(this.currentId >= this.sentences.length){
				//this.stop();
				this.lastPlayChapterId = this.currentChapterId;
				app.reader.nextChapter(true);
				setTimeout((function(){
					if(this.lastPlayChapterId == this.currentChapterId){
						this.pause(); // unable to play next chapter
					}
					this.lastPlayChapterId = null;
				}).bind(this), 5000);
				return;
			}
            if(this.isPlaying == false){
				this.isPlaying = true;
                app.tts.startForeground(); // start tts service
            }
			var sen = this.sentences[this.currentId];
			this.currentSen = sen;
			if(!sen){
				this.stop();
				return;
			}
			sen.highlight(this.highlightColor);
			sen.play();
		},
		moveNext: function(){
			if(this.currentId >= this.sentences.length){
				this.stop();
				return;
			}
			if(this.currentSen){
				this.tryUnhighlight();
			}
			this.currentId++;
			this.play();
		},
		movePrev: function(){
			if(this.currentId > 0){
				this.currentId--;
			}
			if(this.currentSen){
				this.tryUnhighlight();
			}
			this.play();
		},
		jumpNext: function(){
			this.pause();
			this.moveNext();
		},
		jumpPrev: function(){
			this.pause();
			this.movePrev();
		},
		pause: function(isUserEvent){
			this.isPlaying = false;
            app.tts.stopForeground(); // pause tts service
			if(this.currentSen){
				this.currentSen.pause();
			}
			this.updateUi();
			if(isUserEvent)
				this.resetTimer();
		},
		tryPrefetchNext: function(){
			if(this.currentId + 1 < this.sentences.length){
				this.sentences[this.currentId + 1].prefetch();
			}
		},
		updateUi: function(){
			if(app.tts.mediaSession.isRunning){
				app.tts.mediaSession.update();
			}
			if(this.uiComponent.playBtn == null){
				return;
			}
			if(this.sentences){
				if(this.playTimer){
					var minuteFromStart = Math.floor(
						Date.now() - this.startTime
					) / 1000 / 60;
					this.uiComponent.status.textContent = (this.currentId + 1) + "/" + this.sentences.length
						+" "+minuteFromStart.toFixed(1)+"/"+this.maxPlayTime+"p";
				}else{
					this.uiComponent.status.textContent = (this.currentId + 1) + "/" + this.sentences.length;
				}
				if(this.uiComponent.slider.max != this.sentences.length){
					this.uiComponent.slider.max = this.sentences.length;
				}
			}else{
				this.uiComponent.status.textContent = "0/0";
			}
			if(this.isPlaying){
				this.uiComponent.playBtn.setAttribute("playing", "true");
			}else if(this.uiComponent.playBtn.hasAttribute("playing")){
				this.uiComponent.playBtn.removeAttribute("playing");
			}
			this.uiComponent.slider.value = this.currentId + 1;
		},
		uiComponent: {
			playBtn: null,
			slider: null,
			status: null,
			jumpNextBtn: null,
			jumpPrevBtn: null,
			init: function(player){
				var p = app.reader.ttssetting;
				this.playBtn = p.q(".playbtn");
				this.slider = p.q("#ttsslider");
				this.status = p.q(".ttsstatus");
				this.jumpNextBtn = p.q(".jumpnext");
				this.jumpPrevBtn = p.q(".jumpprev");
				this.playBtn.addEventListener("click", function(){
					if(player.isPlaying){
						player.pause(true);
					}else{
						app.tts.start();
					}
					player.updateUi();
				});
				this.slider.addEventListener("input", function(){
					player.currentId = this.value - 1;
					player.pause();
					player.play();
				});
				this.jumpNextBtn.addEventListener("click", function(){
					player.jumpNext();
				});
				this.jumpPrevBtn.addEventListener("click", function(){
					player.jumpPrev();
				});
				this.playBtn.className = "playbtn";
				
			},
		},
		maxPlayTime: 0, // minutes
		startTime: 0,
		playTimer: null,
		askSetTimer: async function(){
			var lastSet = parseInt(app.config.reader.last_tts_maxtime);
			var maxTime = await app.context.prompt("Nhập thời gian tối đa đọc (phút)","", lastSet);
			if(maxTime == null){
				return;
			}
			maxTime = parseInt(maxTime);
			if(isNaN(maxTime) || maxTime < 0){
				app.context.info("Thời gian không hợp lệ");
				return;
			}
			app.config.reader.last_tts_maxtime = maxTime;
			this.maxPlayTime = maxTime;
			if(this.playTimer){
				clearTimeout(this.playTimer);
				this.playTimer = null;
			}
		},
		startTimer: function(){
			if(this.maxPlayTime > 0 && !this.playTimer){
				this.startTime = Date.now();
				this.playTimer = setTimeout(function(){
					app.tts.player.pause();
					app.context.info("Đã dừng đọc sau " + app.tts.maxPlayTime + " phút");
				}, this.maxPlayTime * 60 * 1000);
			}
		},
		resetTimer: function(){
			if(this.playTimer){
				clearTimeout(this.playTimer);
				this.playTimer = null;
				this.updateUi();
			}
		},
	}
	app.tts.init = function(){
		player.uiComponent.init(player);
	}
	app.tts.wait = async function(){
		return new Promise((resolve,reject)=>{
			ttsEngine.onEnd = function(){
				resolve();
			}
		});
	}
	app.tts.currentSenId = 0;
	app.tts.currentSenLen = 0;
	app.tts.requestPause = false;
	app.tts.currentChapter = null;
	app.tts.playQueue = async function(){
		if(this.requestPause){
			this.requestPause = false;
			return;
		}
		var audioItem = await ttsEngine.getFirstItem();
		if(audioItem){
			ttsEngine.play(audioItem);
			this.isPlaying = true;
			try{
				if(audioItem.itemid){
					this.currentChapter.highlightOn(audioItem.itemid);
					if(this.previousHighlight){
						this.currentChapter.highlightOff(this.previousHighlight);
					}
					this.previousHighlight = audioItem.itemid;
					if(g("ttsslider")){
						g("ttsslider").value = audioItem.itemid;
					}
				}
			}catch(e){
				console.log(e);
			}
		}
	}
	
	app.tts.start = function(){
		player.init();
		this.applyPlaybackSetting();
		if(player.isViewChanged()){
			player.reset();
			player.generateSentences();
		}
		if(player.sentences && player.sentences.length > 0)
			player.play();
	}
	app.tts.changeChapter = function(){
		if(player.isPlaying){
			this.start();
		}
	}
	app.tts.player = player;
	app.tts.mediaSession = {
		isRunning: false,
		lastUpdateTime: 0,
		getCurrentState: function(){
			if(!app.reader.bookinfo){
				return {
					playState: false,
					title: "",
					progress: 0,
					icon: null,
					novel: null,
				}
			}
			var prog = app.reader.getDisplay().getChapterNameAndProgress();
			if(!prog){
				return {
					playState: false,
					title: "",
					progress: 0,
					icon: app.reader.bookinfo.thumb,
					novel: app.reader.bookinfo.tname,
				}
			}
			return {
				playState: app.tts.player.isPlaying,
				title: prog.name,
				progress: Math.floor(prog.progress / 10),
				icon: app.reader.bookinfo.thumb,
				novel: app.reader.bookinfo.tname,
			}
		},
		update: function(force = false){
			if(TTS.updateMediaSession){
				var time = new Date().getTime();
				if(!force && this.isRunning){
					if(time - this.lastUpdateTime < this.updateThreshold){
						return;
					}
				}
				this.lastUpdateTime = time;
				TTS.updateMediaSession(this.getCurrentState());
				this.isRunning = true;
			}
		},
		stopTimeout: null,
		updateThreshold: 5000,
		stop: function(){
			if(this.stopTimeout){
				clearTimeout(this.stopTimeout);
				this.stopTimeout = null;
			}
			if(TTS.updateMediaSession){
				var state = this.getCurrentState();
				state.playState = false;
				TTS.updateMediaSession(state);
				this.isRunning = false;
				this.stopTimeout = setTimeout(()=>{
					if(!app.tts.mediaSession.isRunning){
						TTS.stopMediaSession();
					}
				}, 6000); // wait 60s before really stop
			}
		},
	};
	app.tts.foregroundServiceLock = null;
    app.tts.startForeground = function(){
		this.mediaSession.update(true);
		window.Capacitor && window.Capacitor.nativePromise("Http", "startForeground", {});
		var res = null;
		this.foregroundServiceLock = new Promise((resolve, reject)=>{
			res = resolve;
		});
		setTimeout(()=>{
			if(this.foregroundServiceLock){
				res();
				this.foregroundServiceLock = null;
			}
		}, 10000); // Prevent app crash when stop too fast
    }
    app.tts.stopForeground = async function(){
		if(player.isPlaying){
			return; // do not stop foreground service when player is playing
		}
		if(this.foregroundServiceLock){
			await this.foregroundServiceLock;
			if(player.isPlaying){
				return; // do not stop foreground service when player is playing
			}
			this.stopForeground(); // call again to check for new lock
			return;
		}
        window.Capacitor && window.Capacitor.nativePromise("Http", "stopForeground", {});
		this.mediaSession.stop();
    }
	
	app.tts.engineList = function(){
		if(app.platform.isAndroid){
			return [
				{ name: "Android TextToSpeech", value: "google" },
				{ name: "Bing TTS", value: "bing" },
				{ name: "Zalo AI", value: "zalo" },
				{ name: "FPT AI", value: "fpt" },
				{ name: "Viettelgroup TextToSpeech", value: "viettel" },
				{ name: "Sáng Tác Việt", value: "stv" },
			]
		}
		if(app.platform.isWeb){
			return [
				{ name: "Bing TTS", value: "bing" },
				{ name: "Zalo AI", value: "zalo" },
				{ name: "FPT AI", value: "fpt" },
				{ name: "Viettelgroup TextToSpeech", value: "viettel" },
				{ name: "Sáng Tác Việt", value: "stv" },
			]
		}
		if(app.platform.isIOS){
			return [
				{ name: "Bing TTS", value: "bing" },
				{ name: "Zalo AI", value: "zalo" },
				{ name: "FPT AI", value: "fpt" },
				{ name: "Viettelgroup TextToSpeech", value: "viettel" },
				{ name: "Sáng Tác Việt", value: "stv" },
			]
		}
	}
	app.tts.getEngineDefaultConfig = function(){
		var e = this.engineList();
		var best = e[0];
		return `{"provider":"${best.value}","rate":1.5,"${best.value}":{}}`;
	}
	app.tts.setting = JSON.parse(await app.storage.cache.getFile("tts.setting") || app.tts.getEngineDefaultConfig());
	app.tts.setting.set = function(name,value){
		if(!this[this.provider]){
			this[this.provider] = {};
		}
		this[this.provider][name] = value;
		app.storage.cache.setFile("tts.setting",JSON.stringify(this));
	}
	app.tts.setting.setPlayback = function(name,value){
		if(!this["playback"]){
			this["playback"] = {};
		}
		this["playback"][name] = value;
		app.storage.cache.setFile("tts.setting",JSON.stringify(this));
	}
	app.tts.openSetting = function(){
		if(this.isPlaying || player.isPlaying){
			player.pause();
		}
		var p = app.pushPage("ttssetting",{});
		var propListContainer = p.q(".propListContainer");
		this.loadProviderOption(propListContainer);
		this.loadAudioPlaybackOption(p.q(".playbackContainer"));
		p.q(".selectable").addEventListener("change",function(){
			app.tts.setting.provider = this.value;
			app.tts.setting.set("provider",this.value);
			app.tts.loadProviderOption(propListContainer);
			console.log(this.value);
			app.tts.player.clearPrefetch();
		});
		p.q(".selectable").value = this.setting.provider;
		this.applyPlaybackSetting();
		p.q(".webeqContainer").appendChild(ttsEngine.webeq.render());
		var eqSetting = this.setting.webeq;
		if(eqSetting){

		}
		p.q(".webeqContainer").qq("[type=range]").forEach(function(e){
			e.addEventListener("touchstart", function(ev){
				ev.stopPropagation();
			},{passive:false});
			e.addEventListener("touchmove", function(ev){
				ev.stopPropagation();
			},{passive:false});
		});
	}
	app.tts.loadProviderOption = function(container){
		if(!window.ttsEngine){
			app.toast("Chuyển văn bản thành giọng nói không khả dụng trên thiết bị này");
			return;
		}
		ttsEngine.createProvider(this.setting.provider,{});
		container.innerHTML = "";
		var props = ttsEngine.provider.props;
		var oldSet = this.setting[this.setting.provider];
		if(!oldSet){
			oldSet = {};
		}
        var voicesSelect = null;
		for(var name in props){
			var prop = props[name];
			if(prop.type == "float"){
				var v = Math.round((oldSet[name] || prop.default) * 100);
				console.log(v);
				let e = app.render("ttspropnumber",{ desc: prop.description, value: v / 100});
				e.q(".islider").setAttribute("name",name);
				e.q(".islider").setAttribute("min",prop.min * 100);
				e.q(".islider").setAttribute("max",prop.max * 100);
				e.q(".islider").oninput = function(){
					var v = this.value / 100;
					var name = this.getAttribute("name");
					app.tts.setting.set(name,v);
					e.q(".value").textContent = this.value / 100;
				}
				e.q(".islider").value = v ;
				container.appendChild(e);
			}
			if(prop.type == "number"){
				var v = oldSet[name] || prop.default;
				let e = app.render("ttspropnumber",{ desc: prop.description, value: v });
				e.q(".islider").setAttribute("name",name);
				e.q(".islider").setAttribute("min",prop.min);
				e.q(".islider").setAttribute("max",prop.max);
				e.q(".islider").oninput = function(){
					var v = this.value;
					var name = this.getAttribute("name");
					app.tts.setting.set(name,v);
					e.q(".value").textContent = this.value;
				}
				e.q(".islider").value = v;
				container.appendChild(e);
			}
			if(prop.type == "select"){
				var v = oldSet[name];
				let e = app.render("ttspropselect",{ desc: prop.description});
				e.q(".select").setAttribute("name",name);
                var loadVoices = async function(e){
					var currentValue = app.tts.setting[app.tts.setting.provider].voice;
					var sel = e.q(".select");
                    sel.innerHTML = "";
					console.log("Current voice", currentValue);
                    var voices = await ttsEngine.provider.getVoices();
					console.log(voices);
					var isSelected = false;
                    for(var i = 0; i < voices.length; i++){
                        var voice = voices[i];
                        var o = document.createElement("option");
                        o.value = voice.value;
                        o.textContent = voice.name + ` (${voice.value})`;
                        o.selected = voice.value == currentValue;
						if(voice.value == currentValue){
							isSelected = true;
						}
                        sel.appendChild(o);
                    }
                    sel.value = currentValue;
					if(!isSelected){
						ttsEngine.provider.options.voice = voices[0].value;
						sel.value = voices[0].value;
						app.tts.setting.set("voice",voices[0].value);
					}
                }
				e.q(".select").onchange = function(){
					var v = this.value;
					var name = this.getAttribute("name");
					app.tts.setting.set(name,v);
					app.tts.player.clearPrefetch();
                    if(name == "engine"){
						ttsEngine.provider.options.engine = v;
						ttsEngine.provider.initEngine = v;
						TTS.setEngine && TTS.setEngine(v);
                        if(voicesSelect){
                            setTimeout(()=>{
								loadVoices(voicesSelect)
							}, 500);
                        }
                    }
				}
				container.appendChild(e);
                if(name == "voice"){
                    loadVoices(e);
                    voicesSelect = e;
                }
				if(name == "engine"){
                    (async function(val){
                        var engines = await ttsEngine.provider.getEngines();
                        for(var i = 0; i < engines.length; i++){
                            var engine = engines[i];
                            var o = document.createElement("option");
                            o.value = engine.name;
                            o.textContent = engine.label + ` (${engine.name})`;
                            o.selected = engine.value == val;
                            e.q(".select").appendChild(o);
                        }
                        e.q(".select").value = val;
						if(val != ttsEngine.provider.options.initEngine){
							ttsEngine.provider.options.initEngine = val;
							ttsEngine.provider.initEngine = val;
							TTS.setEngine && TTS.setEngine(val);
							setTimeout(()=>{
								loadVoices(voicesSelect)
							}, 500);
						}
                    })(v);
                }
			}
			if(prop.type == "string"){
				var v = oldSet[name] || prop.default;
				let e = app.render("ttspropstring",{ desc: prop.description });
				e.q(".value").setAttribute("name",name);
				e.q(".value").onchange = function(){
					var v = this.value;
					var name = this.getAttribute("name");
					app.tts.setting.set(name,v);
				}
				e.q(".value").value = v;
				container.appendChild(e);
			}
		}
	}
	app.tts.loadAudioPlaybackOption = function(container){
		container.innerHTML = "";
		var props = ttsEngine.playbackProps;
		var oldSet = this.setting.playback;
		if(!oldSet){
			oldSet = {};
		}
		for(var name in props){
			var prop = props[name];
			if(prop.type == "float"){
				var v = Math.round((oldSet[name] || prop.default) * 100);
				console.log(v);
				let e = app.render("ttspropnumber",{ desc: prop.description, value: v/ 100 });
				e.q(".islider").setAttribute("name",name);
				e.q(".islider").setAttribute("min",prop.min * 100);
				e.q(".islider").setAttribute("max",prop.max * 100);
				e.q(".islider").oninput = function(){
					var v = this.value / 100;
					var name = this.getAttribute("name");
					app.tts.setting.setPlayback(name,v);
					e.q(".value").textContent = this.value / 100;
				}
				e.q(".islider").value = v ;
				container.appendChild(e);
			}
		}
	}
	
	app.tts.applyPlaybackSetting = function(){
		ttsEngine.playbackSetting = this.setting.playback || ttsEngine.playbackSetting;
		if(ttsEngine.audio){
			if(!this.setting.playback){
				this.setting.playback = ttsEngine.playbackSetting;
			}
			if(this.setting.playback.rate){
				ttsEngine.audio.playbackRate = this.setting.playback.rate;
			}
			if(this.setting.playback.volume){
				ttsEngine.audio.volume = this.setting.playback.volume;
			}
		}
		if(!ttsEngine.provider || !ttsEngine.audio){
			ttsEngine.init(this.setting.provider, this.setting[this.setting.provider]|| {});
		}
		else{
			$.extend(ttsEngine.provider.options,this.setting[this.setting.provider ]|| {});
		}
	}
	app.tts.test = function(){
		var text = "Xin chào, đây là chuyển văn bản thành giọng nói";
		this.applyPlaybackSetting();
		ttsEngine.clearQueue();
		ttsEngine.requestAudio(text, {});
		ttsEngine.onFirstLoad(function(){
			app.tts.playQueue();
		});
	}
})(app);


//app.offlineBook
(async function(app){
	await onDbLoad.waitForLoad();
	app.offlineBook = {
		store: new app.objectStore("offlineBook"),
		init: function(){
			this.store.load().then(function(){
				if(!app.offlineBook.store.data){
					app.offlineBook.store.data = [];
				}
			});
		},
		isBookExist: function(host,id){
			return this.store.data.find(function(e){
				return e.host == host && e.id == id;
			});
		},
		getDownloadBooks: async function(from,to){
			var list = this.store.data.slice(from,to);
			if(!list.length){
				return [];
			}
			return await populateBookInfo(list);
		},
		sort: function(){
			this.store.data.sort(function(a,b){
				return b.lastDownload - a.lastDownload;
			});
			this.store.save();
		},
		getBook: function(obj){
			return OfflineBook.fromBaseObject(obj);
		},
		getNewBook: async function(obj){
			// check if exist
			var h = obj.host;
			var i = obj.id;
			var exist = this.store.data.find(function(e){
				return e.id == i && e.host == h;
			});
			var bookInfo = await app.net.getCacheLater("/mobile/bookinfo.php?hid="+i+"&host="+h);
			if(!bookInfo){
				return;
			}
			bookInfo = bookInfo.book;
			var book = exist ? this.getSingleton(h,i,bookInfo,exist) : this.getSingleton(h,i,bookInfo,null);
			if(!exist){
				book.save();
				this.store.save();
			}
			return book;
		},
		getExistedBook: function(obj){
			var h = obj.host;
			var i = obj.id;
			var exist = this.store.data.find(function(e){
				return e.id == i && e.host == h;
			});
			if(!exist){
				return;
			}
			return this.getSingleton(h,i,null,exist);
		},
		offlineBookSingletons: {},
		getSingleton: function(host,id, bookInfo, baseObj){
			var key = host+"_"+id;
			if(!this.offlineBookSingletons[key]){
				this.offlineBookSingletons[key] = new OfflineBook(bookInfo, baseObj);
			}
			return this.offlineBookSingletons[key];
		},
	};
	app.offlineBook.init();
	async function populateBookInfo(listOfBook){
		await onDbLoad.waitForLoad();
		var asyncList = [];
		for(var i = 0;i<listOfBook.length; i++){
			var b = listOfBook[i];
			var url = "/mobile/bookinfo.php?hid="+b.id+"&host="+b.host;
			asyncList.push(app.storage.cache.get(url));
		}
		var l = (await Promise.all(asyncList)).filter(e=>e).map(function(e){
			return JSON.parse(e).book;
		});
		for(var i = 0; i<l.length; i++){
			var old = listOfBook.find(function(e){
				return e.id == l[i].id && e.host == l[i].host;
			});
			if(old){
				$.extend(l[i], old);
			}
		}
		return l;
	}
	class OfflineBook{
		constructor(bookInfo, baseObject){
			if(baseObject){
				this.baseObject = baseObject;
				this.chapterStoreKey = this.baseObject.chapterStoreKey;
				this.chapterPreKey = this.baseObject.chapterPreKey;
				this.isWithBaseObject = true;
			}else{
				this.baseObject = {};
				this.baseObject.host = bookInfo.host;
				this.baseObject.id = bookInfo.id;
				this.baseObject.key = "offlineBook_" + bookInfo.host + "_" + bookInfo.id;
				this.baseObject.totalDownloaded = 0;
				this.baseObject.chapterStoreKey = "offlineBook_" + bookInfo.host + "_" + bookInfo.id + "_chapters";
				this.chapterStoreKey = this.baseObject.chapterStoreKey;
				this.baseObject.firstTime = Date.now();
				this.baseObject.chapterPreKey = "offlineBook_" + bookInfo.host + "_" + bookInfo.id + "_";
				this.chapterPreKey = this.baseObject.chapterPreKey;
				this.baseObject.lastDownload = Date.now();
			}
		}
		static fromBaseObject(obj){
			var book = new OfflineBook(null,obj);
			return book;
		}
		async save(){
			if(this.isWithBaseObject){
				await app.offlineBook.store.save();
			}
			else{
				await app.offlineBook.store.prepend(this.baseObject);
				this.isWithBaseObject = true;
				await app.offlineBook.store.save();
			}
		}
		async delete(){
			await app.offlineBook.store.remove(this);
		}
		async getChapterDownloaded(){
			var book = this;
			if(book.chapters){
				return book.chapters;
			}
			var chapters = await app.storage.cache.getFile(book.baseObject.chapterStoreKey);
			if(!chapters){
				chapters = book.chapters = [];
				await app.storage.cache.setFile(book.baseObject.chapterStoreKey, JSON.stringify(chapters));
			}else{
				book.chapters = JSON.parse(chapters);
			}
			return book.chapters;
		}
		async getChapterDownloadedWithOldBug(){
			var book = this;
			var chapters = await app.storage.cache.getFile(book.baseObject.chapterStoreKey);
			var list = [];
			if(chapters){
				list = JSON.parse(chapters);
			}
			var chaptersBugged = await app.storage.cache.getFile("undefined"); // an old bug that cause chapter ids to be stored in undefined key
			if(chaptersBugged){
				var l2 = JSON.parse(chaptersBugged);
				if(l2 && l2.push){
					l2 = l2.filter(function(e){
						return parseInt(e) > 10000;
					});
					list = list.concat(l2);
				}
			}
			return list;
		}
		async addDownloadedChapter(chapter){
			var book = this;
			var chapters = await book.getChapterDownloaded();
			chapters.push(chapter);
			this.baseObject.totalDownloaded = chapters.length;
			await app.storage.cache.setFile(book.baseObject.chapterStoreKey, JSON.stringify(chapters));
		}
		async deleteChapter(chapter){
			var book = this;
			var key = book.baseObject.chapterPreKey + chapter;
			await app.storage.cache.deleteFile(key);
			var chapters = await book.getChapterDownloaded();
			var index = chapters.indexOf(chapter);
			if(index >= 0){
				chapters.splice(index,1);
				await app.storage.cache.setFile(book.baseObject.chapterStoreKey, JSON.stringify(chapters));
			}
		}
		async deleteAll(){
			var book = this;
			var chapters = await book.getChapterDownloaded();
			for(var i = 0; i < chapters.length; i++){
				await book.deleteChapter(chapters[i]);
			}
		}
		async getChapter(chapter){
			var book = this;
			var key = book.baseObject.chapterPreKey + chapter;
			var data = await app.storage.cache.getFile(key);
			return data;
		}
		async getChapterOrNull(chapter){
			var book = this;
			// check if exist
			var chapters = await book.getChapterDownloaded();
			if(chapters.indexOf(chapter) < 0){
				if(parseInt(chapter) > 10000){
					var oldBug = await app.storage.cache.getFile("undefined" + chapter);
					if(oldBug){
						return oldBug;
					}
				}
				return null;
			}
			return await book.getChapter(chapter);
		}
		async downloadChapter(chapterid, content){
			var book = this;
			var chapters = await book.getChapterDownloaded();
			if(chapters.indexOf(chapterid) >= 0){
				return;
			}
			var key = book.baseObject.chapterPreKey + chapterid;
			await app.storage.cache.setFile(key, content);
			await book.addDownloadedChapter(chapterid);
		}
		async updateOldContent(chapterid, content){
			var book = this;
			var chapters = await book.getChapterDownloaded();
			if(chapters.indexOf(chapterid) < 0){
				return;
			}
			var key = book.baseObject.chapterPreKey + chapterid;
			await app.storage.cache.setFile(key, content);
		}
		async insertOrUpdateChapter(chapterid, content){
			var book = this;
			var chapters = await book.getChapterDownloaded();
			if(chapters.indexOf(chapterid) >= 0){
				await book.updateOldContent(chapterid, content);
			}
			else{
				await book.downloadChapter(chapterid, content);
			}
			this.save();
		}
	}
	app.bookDownloaderList = [];
	app.bookDownloaderList.onUpdate = async function(n){
		if(n || g("download-manager")){
			var dlmngr = n || g("download-manager");
			for(var i=0;i<this.length;i++){
				var n = await this[i].render();
				// check if already exist
				if(n.parentElement == dlmngr || n.parentNode == dlmngr){
					continue;
				}
				dlmngr.appendChild(n);
			}
			var tt = dlmngr.parentElement.q(".total");
			if(tt){
				tt.textContent = this.length;
			}
		}
	}
	function filterDownloadingChapters(h,i,arr){
		for(var i = 0; i < arr.length; i++){
			var item = arr[i];
			for(var j = 0; j < app.bookDownloaderList.length; j++){
				if(app.bookDownloaderList[j].host != h || app.bookDownloaderList[j].id != i){
					continue;
				}
				var downloadingClist = app.bookDownloaderList[j].chaptersOrginal;
				if(downloadingClist.indexOf(item) >= 0){
					arr.splice(i,1);
					i--;
				}
			}
		}
		return arr;
	}
	class DownloadManager{
		// host = "";
		// id = "";
		// chapters = [];
		// chaptersOrginal = [];
		// context = null;
		// book = null;
		// total = 0;
		// isPaused = false;
		// downloaded = 0;
		constructor(host, id, chapters, book){
			this.host = host;
			this.id = id;
			this.chapters = filterDownloadingChapters(host,id,chapters);
			this.context = Capacitor.Plugins.Http;
			this.book = book;
			this.total = chapters.length;
			this.chaptersOrginal = [].concat(chapters);
			this.downloaded = 0;
			this.isPaused = false;
			app.bookDownloaderList.push(this);
			app.bookDownloaderList.onUpdate();
		}
		pause(){
			this.isPaused = true;
			this.setStatus("Đã dừng");
		}
		async start(){
			this.isPaused = false;
			this.setStatus("Đang tải...");
			var maxParralel = 3;
			var downloadList = [];
			for(var i=0;i<this.chapters.length;i++){
				let chapter = this.chapters[i];
				downloadList.push(async function(){
					await this.downloadChapter(chapter);
					this.downloaded++;
					this.onProgress();
					this.chapters.splice(this.chapters.indexOf(chapter),1);
					console.log(this.downloaded + "/" + this.total);
				}.bind(this));
			}
			var isBreak = false;
			while(downloadList.length > 0){
				var list = downloadList.splice(0, maxParralel).map(
					async function(f){
						try{
							await f();
						}catch(e){
							console.log(e);
							app.context.info(e.message);
							isBreak = true;
						}
					});
				await Promise.all(list);
				if(isBreak || this.isPaused){
					break;
				}
				await sleepFor(3000);
			}
			if(this.total == this.downloaded){
				this.setStatus("Hoàn thành");
				this.book.save();
			}
			if(this.status && this.status.textContent == "Đang tải..."){
				this.setStatus("Đã dừng");
			}
			this.onProgress();
			if(isBreak){
				this.isPaused = true;
			}
		}
		async downloadChapter(chapter, retry = 0){
			var url = STV_SERVER + `/index.php?sajax=readchapter&h=${this.host}&bookid=${this.id}&c=${chapter}&download=true&key=stvmobilereader`;
			try{
				var headers = {
					Cookie: document.cookie.toString() + "; mac_tt=true;",
					"User-Agent": navigator.userAgent,
					"x-stv-transport": "app",
					"x-requested-with": "com.sangtacviet.mobilereader",
				};
				var response = await this.context.get({
					url: url,
					headers: headers,
					ipv6: false,
				});
			}catch(e){
				if(retry < 3){
					await this.downloadChapter(chapter, retry + 1);
				}else{
					this.setStatus("Lỗi: Lỗi mạng");
					throw e;
				}
				return;
			}
			try{
				// remove BOM
				response.data = response.data.replace(/^\uFEFF/, '');
				var json = JSON.parse(response.data);
			}catch(e){
				if(retry < 3){
					await sleepFor(200);
					await this.downloadChapter(chapter, retry + 1);
					return;
				}else{
					this.setStatus("Lỗi: Không thể đọc dữ liệu");
					throw new Error("Không thể đọc dữ liệu");
				}
			}
			if(json.code == "0"){
				await this.book.insertOrUpdateChapter(chapter, response.data);
			}else{
				if(json.code == "13"){
					if(retry < 3){
						await sleepFor(300);
						await this.downloadChapter(chapter, retry + 1);
						return;
					}
				}
				throw new Error(json.err || json.info);
			}
		}
		getContextDownloading(){
			var ref = this;
			return {
				type: "tap",
				item: [
					{text: "Ngừng tải", onclick: function(){
						ref.pause();
					}}
				]
			}
		}
		getContextFailed(){
			var ref = this;
			return {
				type: "tap",
				item: [
					{text: "Thử lại", onclick: function(){
						ref.start();
					}},
				]
			}
		}
		async render(){
			if(this.node){
				return this.node;
			}
			var bi = (await populateBookInfo([{id: this.id, host: this.host}]))[0];
			console.log(bi);
			var n = app.render("bookdownloadjob", bi);
			var percent = this.downloaded / this.total * 100;
			var inner = n.q(".pgbarinner");
			inner.style.width = percent + "%";
			this.node = n;
			this.progress = inner;
			this.status = n.q(".status");
			this.numstatus = n.q(".numstatus");
			this.numstatus.textContent = this.downloaded + "/" + this.total;
			this.setStatus("Đang tải...");
			this.node.addEventListener("click", function(){
				app.fun.openBookWithData(0,bi);
			});
			ui.hold(this.node, (function(){
				if(this.downloaded < this.total)
				app.context.showMenu(this.isPaused ? this.getContextFailed() : this.getContextDownloading());
			}).bind(this));
			this.node.model = this;
			return n;
		}
		onProgress(){
			if(this.node){
				var percent = this.downloaded / this.total * 100;
				this.progress.style.width = percent + "%";
				this.numstatus.textContent = this.downloaded + "/" + this.total;
			}
		}
		createMock(){
			var n = app.render("bookdownloadjob", {title: "Tiêu đề sách"});
			var percent = this.downloaded / this.total * 100;
			var inner = n.q(".pgbarinner");
			inner.style.width = percent + "%";
			this.node = n;
			this.progress = inner;
			this.status = n.q(".status");
			this.numstatus = n.q(".numstatus");
			this.numstatus.textContent = this.downloaded + "/" + this.total;
			return n;
		}
		setStatus(status){
			if(this.status){
				this.status.textContent = status;
			}
		}
	}
	app.BookDownloadManager = DownloadManager;
})(app);

(function(app){
	app.comicReader = {
		pageUrl: "",
		nextPage: "",
		prevPage: "",
		browser: null,
		render: function(imgs, v){
			v.innerHTML = "";
			imgs = app.comicReader.imageLoader(imgs);
			for(var i = 0; i < imgs.length; i++){
				v.appendChild(imgs[i]);
			}
		},
		translator: {
			canvas: null,
			context: null,
			plugin: null,
			translateText: async function(text){
				return text; // TODO
			},
			translateImage: async function(imgs){
				if(!this.canvas){
					this.canvas = document.createElement("canvas");
					this.context = this.canvas.getContext("2d");
					this.plugin = Capacitor.Plugins.MlKit;
				}
				this.canvas.width = imgs[0].naturalWidth;
				// sum height
				var height = 0;
				for(var i = 0; i < imgs.length; i++){
					height += imgs[i].naturalHeight;
				}
				this.canvas.height = height;
				var y = 0;
				for(var i = 0; i < imgs.length; i++){
					this.context.drawImage(imgs[i], 0, y);
					y += imgs[i].naturalHeight;
				}
				var data = this.canvas.toDataURL("image/jpeg", 1).substr(23);
				var result = await this.plugin.mlKitOcr({
					lang: "zh",
					data: data
				});
				var blocks = result.result;
				var l = Object.keys(blocks).length;
				var blocks2 = [];
				for(var i=0;i<l;i++){
					let bl = this.constructBlock(blocks[i+""]);
					if(bl){
						blocks2.push(bl);
					}
				}
				var textToTrans = blocks2.map(b=>b.text).join("-//-");
				var translated = await translateWithQt(textToTrans);
				var translatedArr = translated.split("-//-");
				for(var i=0;i<blocks2.length;i++){
					blocks2[i].text = translatedArr[i];
				}
				return blocks2;
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
				//this.scaleRectDownToView(rect);
				//rect.y += this.activatedOffsetY - 105;
				return {
					text,
					top: rect.y,
					left: rect.x,
					width: rect.w,
					height: rect.h
				}
			},
			cornerPointsToRect: function(points){
				var x = Math.min(points[0].x, points[1].x, points[2].x, points[3].x);
				var y = Math.min(points[0].y, points[1].y, points[2].y, points[3].y);
				var w = Math.max(points[0].x, points[1].x, points[2].x, points[3].x) - x;
				var h = Math.max(points[0].y, points[1].y, points[2].y, points[3].y) - y;
				return {x,y,w,h};
			}
		},
	};
	app.comicReader.findProvider = function(url){
		var host = app.comicReader.getHost(url);
		var provider = getComicProvider(host);
		if(provider){
			return provider;
		}
		return null;
	}
	app.comicReader.getHost = function(url){
		var host = url.match(/:\/\/(.[^/]+)/);
		if(host){
			return host[1].replace("www.", "");
		}
		return null;
	}
	app.comicReader.init = async function(url){
		var provider = app.comicReader.findProvider(url);
		if(provider){
			var p = app.pushPage("readcomic",{});
			var v = p.q(".chapterimgview");
			provider.getImages(url).then(imgs=>{
				app.comicReader.render(imgs, v);
			});
			app.comicReader.initEvents(p);
		}else{
			return;
		}
	}
	app.comicReader.initRemote = async function(url, chapters, bookinfo){
		var p = app.pushPage("readcomic",{});
		app.comicReader.page = this.display = p;
		var v = p.q(".chapterimgview");
		var iframe = document.createElement("iframe");
		this.currentComicInfo = bookinfo;
		//iframe.src = this.getTranslatorUrl(url);
		this.changeChapterUrl(url, iframe);
		iframe.setAttribute("style", "width:100%;height:100%;border:none;");
		v.appendChild(iframe);
		var w = null;
		iframe.onload = function(){
			w = iframe.contentWindow;
			app.comicReader.initEventForFrame(w);
		};
		this.currentChapterList = chapters;
		this.currentChapterName = chapters.find(e=>e.url == url).name;
		app.comicReader.initEvent(p);
		app.namemanager.loadContext({
			name: bookinfo.name.trim(),
			author: "comic"
		}).then(function(){
		//	app.comicReader.runName();
		});
	};
	app.comicReader.imageLoader = function(imgs){
		var ls = [];
		var init = 0;
		for(var i = 0; i < imgs.length; i++){
			var img = imgs[i];
			let e = new Image();
			if(img.loadFunc){
				(function(im,ele,showOnload){
					im.loadFunc().then(function(blobUrl){
						ele.invokeShow = function(){
							ele.src = blobUrl;
							ele.invokeShow = null;
						};
						ele.loaded = true;
						if(showOnload){
							ele.invokeShow();
						}
					})
				})(img,e,init < 10);
			}else if(img.substring){
				(function(im,ele,showOnload){
					app.images.download(im).then(function(blob){
						var blobUrl = URL.createObjectURL(blob);
						console.log(blobUrl)
						ele.invokeShow = function(){
							ele.src = blobUrl;
							ele.invokeShow = null;
						};
						ele.loaded = true;
						if(showOnload){
							ele.invokeShow();
						}
					});
				})(img,e,init < 10);
			}
			init++;
			ls.push(e);
		}
		return ls;
	};
	app.comicReader.makeBlock = function(text, top, left, width, height){
		var block = document.createElement("div");
		block.className = "comic-block";
		block.style.top = top + "px";
		block.style.left = left + "px";
		block.style.width = width + "px";
		block.style.height = height + "px";
		block.innerText = text;
		return block;
	}
	app.comicReader.renderTranslatedBlock = async function(view, initOffset, width, imgs){
		console.log(imgs);
		console.log(width);
		console.log(initOffset);
		var scaleRatio = width / imgs[0].naturalWidth;
		var blocks = await app.comicReader.translator.translateImage(imgs);
		var blocks2 = blocks.map(b=>{
			b.top = b.top * scaleRatio + initOffset;
			b.left = b.left * scaleRatio;
			b.width = b.width * scaleRatio;
			b.height = b.height * scaleRatio;
			return b;
		});
		var blocks3 = blocks2.map(b=>{
			return app.comicReader.makeBlock(b.text, b.top, b.left, b.width, b.height);
		});
		blocks3.forEach(b=>{
			view.appendChild(b);
		});
	}
	app.comicReader.initEvents = function(p){
		var v = p.q(".chapterimgview");
		v.height = window.innerHeight;
		v.width = window.innerWidth;
		v.transThreshhold = 0;
		v.lazyThreshold = v.height*2;
		v.currentOffset = 0;
		var suiteHeightForTrans = v.height;
		v.addEventListener("scroll", function(e){
			var t = v.scrollTop;
			var bottom = t + v.lazyThreshold;
			var imgs = v.getElementsByTagName("img");
			for(var i = 0; i < imgs.length; i++){
				var img = imgs[i];
				if(img.offsetTop < bottom && img.loaded){
					img.invokeShow && img.invokeShow();
				}
			}
			// check if passed threshhold
			if(t + v.height > v.transThreshhold){
				// perform translate
				// get list of images from currentOffset to suiteHeightForTrans
				var ls = [];
				var fromTop = 0;
				var heightCounted = 0;
				var translateAble = true;
				var transOffset = v.currentOffset;
				for(var i = 0; i < imgs.length; i++){
					var img = imgs[i];
					if(fromTop < v.currentOffset){
						fromTop += img.height;
						continue;
					}
					if(heightCounted < suiteHeightForTrans){
						if(!img.loaded){
							translateAble = false;
							break;
						}
						if(img.invokeShow){
							img.invokeShow();
						}
						ls.push(img);
						heightCounted += img.height;
						if(heightCounted > suiteHeightForTrans){
							// set currentOffset to img.offsetTop
							v.currentOffset = fromTop + heightCounted;
							break;
						}
					}
				}
				if(translateAble){
					app.comicReader.renderTranslatedBlock(v, transOffset, v.width, ls);
					v.transThreshhold += suiteHeightForTrans;
				}
			}
		});
	};
	app.comicReader.initEvent = function(p){
		p.q(".chapterprogress").oninput = function(){
			var per = this.value / 1000;
			var w = app.comicReader.currentWindow;
			if(!w){
				return;
			}
			var h = w.document.body.scrollHeight;
			var y = h * per;
			requestAnimationFrame(function(){
				w.scrollTo(0, y);
			});
		};
		p.q(".chaptername").textContent = app.comicReader.currentChapterName;
		this.bottommenu = p.q(".coption");
		this.editnamepreview = p.q(".editnamepreview");
		this.ttssetting = p.q(".ttssetting");
		this.drawer = p.q(".drawer");
		p.q(".btnnextchap").addEventListener("click",function(){
			app.comicReader.nextChapter();
		});
		p.q(".btnprevchap").addEventListener("click",function(){
			app.comicReader.prevChapter();
		});
		p.q(".btnspeak").addEventListener("click",function(){
			//app.tts.openPlayer();
			app.comicReader.showTtsSetting();
		});
		p.q(".btnaddname").addEventListener("click",function(){
			app.editor.openAddname(
				app.comicReader.currentWindow,
				app.editor.context.left,
				app.editor.context.base,
				app.editor.context.right,
			);
		});
		p.q(".rbtn").addEventListener("click", function(){
			var tb = p.q(".titlebar");
			app.context.showMenu(app.context.menu.readcomic, null, {
				clientX: document.body.scrollWidth - 5,
				clientY: tb.scrollHeight + 5
			});
		});
		p.q(".bottombar").addEventListener("click",function(e){e.stopPropagation();});
		p.q(".titlebar").addEventListener("click",function(e){e.stopPropagation();});
		this.page.q(".btntoc").addEventListener('click', function(){
			app.comicReader.showDrawer("toc");
		});
		this.drawer.addEventListener("click",function(e){
			e.stopPropagation();
			if(e.target == this){
				this.classList.remove("open");
			}
		});
		this.page.q(".expphraser").addEventListener("click",function(){
			app.comicReader.gotoNextTextBlock();
		});
		this.page.q(".expphrasel").addEventListener("click",function(){
			app.comicReader.gotoPrevTextBlock();
		});
		this.page.q(".hidemenubtn").addEventListener("click",function(){
			app.reader.toggleMenu();
		});
		this.display.q(".btnnamemenu").addEventListener("click",function(){
			app.namemanager.showManager({
				tname: app.comicReader.currentComicInfo.name,
				name: app.comicReader.currentComicInfo.name,
				author: "comic"
			});
		});
		this.display.q(".btnnamemenu2").addEventListener("click",function(){
			app.namemanager.showManager({
				tname: app.comicReader.currentComicInfo.name.trim(),
				name: app.comicReader.currentComicInfo.name.trim(),
				author: "comic"
			});
		});
		if(app.reader.styleCnameUi){
			var style = app.reader.styleCnameUi;
			var o = {
				"--reader-color":"white",
				"--reader-border-color":"#515151fa",
				"--reader-background":"#272727"
			};
			style.set(":root", o)
		}
		else{
			app.reader.styleCnameUi = ui.style.create(`:root{
				--reader-color:white;
				--reader-border-color:#515151fa;
				--reader-background:#272727;
			}`);
			app.reader.styleCnameUi.use();
		}
		app.reader.fullscreen();
	}
	app.comicReader.showTtsSetting = function(){
		if(!this.display.className.contain("showmenu")){
			this.display.classList.add("showmenu");
			app.comicReader.showMenuOl();
		}
		this.display.q(".chapterinfo").style.display = "none";
		this.editnamepreview.style.display = "none";
		this.ttssetting.style.display = "block";
	}
	app.comicReader.getCurrentChapterUrl = function(){
		var iframe = this.page.q("iframe");
		var url = iframe.src.split("?")[1];
		return decodeURIComponent(url.split("=")[1].split("&")[0]);
	}
	app.comicReader.getCurrentChapterName = function(){
		var url = this.getCurrentChapterUrl();
		return this.currentChapterList.find(e=>e.url == url).name;
	}
	app.comicReader.getTranslatorUrl = function(url){
		var transmode = app.config.comicReader.transmode;
		var comicLang = "zh";
		if(this.currentComicInfo.transModeHint && this.currentComicInfo.transModeHint.trim() == "perpage"){
			transmode = "perpage";
		}
		if(this.currentComicInfo.languageHint){
			comicLang = this.currentComicInfo.languageHint;
		}
		return `${STV_SERVER}/comictranslator.php?url=${encodeURIComponent(url)}&transmode=${transmode}&langhint=${comicLang}`;
	}
	app.comicReader.setTransMode = function(mode){
		app.config.comicReader.transmode = mode;
		var frame = this.page.q("iframe");
		frame.src = this.getTranslatorUrl(this.getCurrentChapterUrl());

	}
	app.comicReader.updateCnameAndProgress = function(){
		this.display.q(".line2 .chaptername").textContent = this.getCurrentChapterName();
		var w = this.currentWindow;
		if(!w){
			return;
		}
		var h = w.document.body.scrollHeight;
		var t = w.scrollY;
		var perc = t / h;
		this.display.q(".chapterprogress").value = perc * 1000;
	}
	app.comicReader.initEventForFrame = function(w){
		this.currentWindow = w;
		var findTop = function(e, clazz){
			if(e.classList.contains(clazz)){
				return e;
			}
			if(e.parentElement){
				return findTop(e.parentElement, clazz);
			}
			return null;
		}
		w.addEventListener("scroll", function(e){
			setTimeoutOnce("comicReaderScroll", function(){
				var h = w.document.body.scrollHeight;
				var t = w.scrollY;
				var perc = t / h;
				app.comicReader.page.q(".chapterprogress").value = perc * 1000;
			}, 100);
		});
		w.addEventListener("click", function(e){
			var t = e.target;
			var noFunction = true;
			if(findTop(t, "comic-block")){
				noFunction = false;
				app.comicReader.openEditBlock(findTop(t, "comic-block"), e);
			}
			if(noFunction){
				app.comicReader.toggleMenu();
			}
		});
		w.onReadEnd = function(){
			if(app.comicReader.hasNextChapter()){
				w.translator.setEndButtonText("Đọc chương kế", function(){
					app.comicReader.nextChapter();
				});
			}
		};
		w.__defineGetter__("nameContext", function(){
			var rows = app.namemanager.namedata.concat(app.namemanager.nameglobal);
			var names = {};
			for(var row of rows){
				if(row[0] == "$"){
					var pair = row.substring(1).split("=");
					names[pair[0].trim()] = pair[1].trim();
				}
			}
			return names;
		});
	}
	app.comicReader.toggleMenu = function(){
		this.display = app.comicReader.page;
		if(!this.display){
			this.display = g("chapterview");
		}
		this.display.classList.toggle("showmenu");
		if(!this.display.className.contain("showmenu")){
			app.platform.toggleStatusBar(false);
			if(this.selectedTextBlock){
				this.selectedTextBlock.style.border = "";
				this.selectedTextBlock.classList.remove("selected");
			}
		}else{
			this.editnamepreview.style.display = "none";
            this.ttssetting.style.display = "none";
			app.comicReader.showMenuOl();
			this.display.q(".chapterinfo").style.display = "block";
		}
	}
	app.comicReader.showMenuOl = function(){
		app.platform.toggleStatusBar(true);
		this.updateCnameAndProgress();
	}
	app.comicReader.currentProviderHost = "www.baozimh.com";
	app.comicReader.currentProviderName = "BaoziManhua";
	app.comicReader.currentSearchKeyword = "";
	app.comicReader.renderComicBrowser = async function(p,host){
		var body = p.q(".body");
		body.innerHTML = `<tab style="height:var(--olvh100subtop)">
				<tabbar></tabbar>
				<tabpointer style="height: 3px;overflow-x:hidden;">
					<ntab>
						<tabpointermark style="top:0px"><span></span></tabpointermark>
					</ntab>
				</tabpointer>
				<div>
					<tabdiv></tabdiv>
				</div>
			</tab>`;
		var tab = p.q("tab");
		var tabdiv = p.q("tabdiv");
		var tabbar = p.q("tabbar");
		var provider  = getComicProvider(host);
		if(!provider){
			app.toast("Không tìm thấy trang web hỗ trợ");
			return;
		}
		
		var categorys = await provider.getTabs();
		for (let i = 0; i < categorys.length; i++) {
			let ti = document.createElement("tabitem");
			ti.innerHTML = categorys[i].name;
			let tv = document.createElement("tabview");
			tabbar.appendChild(ti);
			tabdiv.appendChild(tv);
			let ct = document.createElement("div");
			tv.appendChild(ct);
			ct.className = "grid-min-240-max-300";
			var preloader = app.createPreloader("Đang tải...");
			ct.appendChild(preloader);
			let url = categorys[i].url;
			tv.onfirstload = function() {
				if(url == "search" && !tv.q(".search")){
					var d = document.createElement("div");
					var search = document.createElement("input");
					search.className = "search w-100";
					search.placeholder = "Tìm kiếm bằng ngôn ngữ của trang";
					search.addEventListener("keyup", function(e){
						setTimeoutOnce("searchComic", function(){
							var v = e.target.value;
							app.comicReader.currentSearchKeyword = v;
							tv.reload();
						}, 500)
					});
					d.setAttribute("style", "padding: 8px;top:0px;position:sticky;background:var(--background);z-index:100;");
					d.appendChild(search);
					tv.insertBefore(d, ct);
				}
				provider.getComicList(url).then(function(d){
					app.removePreloader(ct);
					for(let j = 0; j < d.length; j++){
						var e = app.render("booksquare",{
							tname: d[j].name,
							thumb: d[j].thumb,
						});
						e.data = d[j];
						ct.appendChild(e);
						e.addEventListener("click", function() {
							app.fun.openComicByUrl(d[j].url);
						});
						
					}
					var page = 2;
					var loadNext = null;
					var createInf = function(){
						var inf = app.createInf(loadNext);
						ct.appendChild(inf);
					}
					loadNext = function(){
						provider.getComicList(url, page).then(function(d){
							app.removePreloader(ct);
							if(d.length == 0){
								return;
							}
							for(let j = 0; j < d.length; j++){
								var e = app.render("booksquare",{
									tname: d[j].name,
									thumb: d[j].thumb,
								});
								e.data = d[j];
								ct.appendChild(e);
								e.addEventListener("click", function() {
									app.fun.openComicByUrl(d[j].url);
								});
							}
							page++;
							createInf();
						});
					}
					createInf();
				});
			}
			tv.reload = function(){
				ct.innerHTML = "";
				tv.onfirstload();
			}
		}
		ui.smtab(tab, true);
		tabbar.children[0].click();
	}
	app.comicReader.reloadCurrentBrowserTab = function(){
		var tab = this.display.q("tab");
		var tv = tab.currentTabNode();
		tv.reload();
	}
	app.comicReader.changeChapterUrl = function(url, frame){
		var iframe = this.page.q("iframe") || frame;
		iframe.src = this.getTranslatorUrl(url);
		this.history.update(url);
		setTimeout(function(){
			app.comicReader.updateCnameAndProgress();
		}, 100);
	}
	app.comicReader.loadDrawerChapter = async function(){
		var drawer = this.drawer.q(".clistcontainer");
		var chapters = this.currentChapterList;
		var currentCid = this.getCurrentChapterUrl();
		var currentRow = null;
		for(var i = 0; i < chapters.length; i++){
			var e = document.createElement("div");
			e.textContent = chapters[i].name;
			e.className = "chapterrow";
			e.setAttribute("clink", chapters[i].url);
			if(chapters[i].url == currentCid){
				e.classList.add("chaplastreaded");
				currentRow = e;
			}
			drawer.appendChild(e);
		}
		drawer.scrollTop = currentRow.offsetTop - 100;
	}
	app.comicReader.showDrawer = async function(){
		app.comicReader.drawer.style.display = "block";
		await waitFrame();
		app.comicReader.drawer.classList.add("open");
		if(app.comicReader.drawer.q(".clistcontainer").children.length == 0){
			this.loadDrawerChapter();
			app.comicReader.drawer.q(".chapterlist").addEventListener("click",async function(e){
				var t = e.target;
				if(t.hasAttribute("clink")){
					var clink = t.getAttribute("clink");
					var current = app.comicReader.getCurrentChapterUrl();
					if(current == clink){
						return;
					}
					app.comicReader.changeChapterUrl(clink);
					app.comicReader.toggleMenu();
					app.comicReader.drawer.classList.remove("open");
				}
			});
			var clist = app.comicReader.drawer.q(".chapterlist");
			app.comicReader.drawer.q(".clistsearch").addEventListener("keyup",function(e){
				ui.filterSel(this, clist, "div");
			});
			app.comicReader.drawer.q(".rbtn").addEventListener("click",function(){
				app.comicReader.drawer.classList.remove("open");
			});
		}else{
			var currentCid = app.comicReader.getCurrentChapterUrl();
			setTimeout(function(){
				var currentLastRead = app.comicReader.drawer.q(".chaplastreaded");
				if(currentLastRead && currentLastRead.getAttribute("clink") != currentCid){
					currentLastRead.classList.remove("chaplastreaded");
					app.comicReader.drawer.q(`.chapterlist [clink="${currentCid}"]`).classList.add("chaplastreaded");
					// set scroll
					var c = app.comicReader.drawer.q(`.chapterlist [clink="${currentCid}"]`);
					var p = app.comicReader.drawer.q(".clistcontainer");
					p.scrollTop = c.offsetTop - 100;
				}else if(!currentLastRead){
					var c = app.comicReader.drawer.q(`.chapterlist [clink="${currentCid}"]`);
					c.classList.add("chaplastreaded");
					// set scroll
					var p = app.comicReader.drawer.q(".clistcontainer");
					p.scrollTop = c.offsetTop - 100;
				}
			}, 200);
		}
	};
	app.comicReader.hideDrawer = function(){
		app.comicReader.drawer.style.display = "none";
	}
	app.comicReader.nextChapter = function(){
		var current = this.getCurrentChapterUrl();
		var index = this.currentChapterList.findIndex(e=>e.url == current);
		if(index < this.currentChapterList.length - 1){
			this.changeChapterUrl(this.currentChapterList[index + 1].url);
		}
	}
	app.comicReader.prevChapter = function(){
		var current = this.getCurrentChapterUrl();
		var index = this.currentChapterList.findIndex(e=>e.url == current);
		if(index > 0){
			this.changeChapterUrl(this.currentChapterList[index - 1].url);
		}
	}
	app.comicReader.hasNextChapter = function(){
		var current = this.getCurrentChapterUrl();
		var index = this.currentChapterList.findIndex(e=>e.url == current);
		return index < this.currentChapterList.length - 1;
	}
	app.comicReader.openEditBlock = function(block, ev){
		this.editnamepreview.style.display = "block";
		var target = ev && ev.target;
		var text = block.block.text.substring(0, 15);
		var lt = "", rt = "";
		if(target && target.tagName == "I"){
			text = target.getAttribute("t");
			lt = block.block.text.substring(0, block.block.text.indexOf(text));
			rt = block.block.text.substring(block.block.text.indexOf(text) + text.length);
		}
		this.editnamepreview.q(".chi").textContent = text;
		var lastBlock = this.selectedTextBlock;
		this.selectedTextBlock = block;
		block.style.border = "2px solid purple";
		block.classList.add("selected");
		app.editor.context = {
			base: text,
			left: lt,
			right: rt,
		};
		if(lastBlock && lastBlock != block){
			lastBlock.style.border = "";
			lastBlock.classList.remove("selected");
		}
		if(!this.display.className.contain("showmenu")){
			this.display.classList.add("showmenu");
			app.platform.toggleStatusBar(false);
			this.display.q(".chapterinfo").style.display = "none";
			this.ttssetting.style.display = "none";
		}
	}
	app.comicReader.getTextBlockList = function(){
		var w = this.currentWindow;
		var blocks = w.document.getElementsByClassName("imgblock");
		var l= Array.from(blocks).sort((a,b)=>{return parseInt(a.getAttribute("ord") - parseInt(b.getAttribute("ord")))}).map(e=>e.querySelectorAll(".comic-block"));
		var l2 = [];
		for(var i = 0; i < l.length; i++){
			l2 = l2.concat(Array.from(l[i]));
		}
		return l2;
	}
	app.comicReader.gotoNextTextBlock = function(){
		var blocks = this.getTextBlockList();
		var w = this.currentWindow;
		var i = blocks.indexOf(this.selectedTextBlock);
		while(i < blocks.length - 1){
			var nextBlock = blocks[i+1];
			if(nextBlock.block.text == this.selectedTextBlock.block.text){
				i++;
				continue;
			}
			blocks[i+1].scrollIntoView({behavior: "smooth"});
			blocks[i+1].click();
			break;
		}
	}
	app.comicReader.gotoPrevTextBlock = function(){
		var blocks = this.getTextBlockList();
		var w = this.currentWindow;
		var i = blocks.indexOf(this.selectedTextBlock);
		while(i > 0){
			var prevBlock = blocks[i-1];
			if(prevBlock.block.text == this.selectedTextBlock.block.text){
				i--;
				continue;
			}
			blocks[i-1].scrollIntoView({behavior: "smooth"});
			blocks[i-1].click();
			break;
		}
	}
	app.comicReader.openSetting = function(){
		var p = app.pushPage("pagecomicsetting");
	}
	app.comicReader.history = {
		data: null,
		update: async function(chapUrl, comicInfo){
			await this.checkIsLoaded();
			chapUrl = chapUrl || app.comicReader.getCurrentChapterUrl();
			comicInfo = comicInfo || app.comicReader.currentComicInfo;
			var comicUrl = comicInfo.url;
			// if(comicInfo.lastRead == chapUrl){
			// 	return;
			// }else{
			// 	comicInfo.lastRead == chapUrl;
			// 	comicInfo.lastReadTime = new Date().getTime();
			// }
			if(comicUrl in this.data){
				comicInfo = this.data[comicUrl];
				if(comicInfo.lastRead != chapUrl){
					comicInfo.lastRead = chapUrl;
					comicInfo.lastReadTime = new Date().getTime();
				}else{return;}
				return this.save();
			}else{
				var clone = Object.assign({}, comicInfo);
				delete clone.chapters;
				clone.lastRead = chapUrl;
				clone.lastReadTime = new Date().getTime();
				this.data[comicUrl] = clone;
				return this.save();
			}
		},
		save: function(){
			app.storage.cache.setFile("clientComicHistory", JSON.stringify(this.data));
		},
		load: async function(){
			var d = await app.storage.cache.getFile("clientComicHistory");
			if(!d){
				this.data = {};
			}else{
				this.data = JSON.parse(d);
			}
		},
		checkIsLoaded: async function(){
			if(!this.data){
				await this.load();
			}
		},
		getLastReadChapter: async function(url){
			await this.checkIsLoaded();
			if(url in this.data){
				return this.data[url].lastRead;
			}
			return null;
		},
		getLastReadList: async function(page = 0){
			await this.checkIsLoaded();
			page = page - 1;
			if(page < 0){page = 0;}
			return Object.values(this.data).sort((a,b)=>{return (b.lastReadTime||0) - (a.lastReadTime||0)}).slice(page * 20, (page + 1) * 20);
		}
	};
	app.comicReader.getReadHistory = async function(page = 0){
		return app.comicReader.history.getLastReadList(page);
	}
	app.comicReader.addHistoryAsFirstChapter = function(comicInfo){
		var firstChap = comicInfo.chapters[0].url;
		app.comicReader.history.update(firstChap, comicInfo);
	}
	app.comicReader.runName = function(){
		var w = this.currentWindow;
		w.translator && w.translator.onNameUpdate();
	}
})(app);