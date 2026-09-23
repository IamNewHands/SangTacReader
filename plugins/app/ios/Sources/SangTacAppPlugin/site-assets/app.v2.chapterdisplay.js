function _defineProperty(e, r, t) {
    return (
        (r = _toPropertyKey(r)) in e
            ? Object.defineProperty(e, r, {
                  value: t,
                  enumerable: !0,
                  configurable: !0,
                  writable: !0,
              })
            : (e[r] = t),
        e
    );
}
function _toPropertyKey(t) {
    var i = _toPrimitive(t, "string");
    return "symbol" == typeof i ? i : i + "";
}
function _toPrimitive(t, r) {
    if ("object" != typeof t || !t) return t;
    var e = t[Symbol.toPrimitive];
    if (void 0 !== e) {
        var i = e.call(t, r || "default");
        if ("object" != typeof i) return i;
        throw new TypeError("@@toPrimitive must return a primitive value.");
    }
    return ("string" === r ? String : Number)(t);
}
const preloaderAnimation = `
      .rotate{
          animation: rota 1s infinite linear;
          transform-origin: center;
      }
  
      @keyframes rota {
      0% {
          transform: rotateY(0deg) skewY(0deg);
      }
      25% {
          transform: rotateY(45deg) skewY(-22deg);
      }
      50% {
          transform: rotateY(90deg) skewY(-30deg);
      }
      75% {
          transform: rotateY(135deg) skewY(-22deg);
      }
      100% {
          transform: rotateY(180deg) skew(0deg);
      }
      }
      .svgl path:nth-child(1){
      animation-delay: 0ms;
      }
      .svgl path:nth-child(2){
      animation-delay: 150ms;
      }
  
      .svgl path:nth-child(3){
      animation-delay: 300ms;
      }
  
      .svgl path:nth-child(4){
      animation-delay: 450ms;
      }
      .preloader, .waitpreloader{
          padding: 8px;
          text-align: center;
      }`;
class ChapterDisplay {
    constructor(root) {
        this.root = root;
    }
    render() {}
    applyStyleChange() {} // apply style change to the chapter display
    getPCN() {} // get the previous, current and next chapter
    getCurrentChapter() {} // get the current chapter
    goNextChapter() {} // go to the next chapter
    goPrevChapter() {} // go to the previous chapter
    getRoot() {} // get the root element of the chapter display
    rightTapAction() {} // action when right tap
    leftTapAction() {} // action when left tap
    reloadCurrentChapter() {} // reload the current chapter
    reloadAllChapter() {} // reload all chapter
    changeCurrentChapter() {} // change the current chapter
    showAlert() {} // show alert
    getChapterNameAndProgress() {} // get the chapter name and progress
    gotoProgress() {} // go to a specific position
    runName() {} // run name engine
    hideContextMenu() {} // hide context menu
    unlockNameSelect() {} // unlock name select
    getCurrentWindow() {} // get the current window
    destroy() {
        if (this.root) {
            this.root.firstChild.remove();
        }
        for (var k in this) {
            delete this[k];
        }
    }
    onBackgroundImageLoaded(url) {
        this.useBackgroundImage = true;
        this.backgroundImage = url;
    } // on background image loaded
}
class SlideChapterDisplay extends ChapterDisplay {
    constructor(root) {
        super(root);
        _defineProperty(this, "scroller", void 0);
        _defineProperty(this, "prevId", void 0);
        _defineProperty(this, "prevContainer", void 0);
        _defineProperty(this, "prevFrame", void 0);
        _defineProperty(this, "currentId", void 0);
        _defineProperty(this, "currentContainer", void 0);
        _defineProperty(this, "currentFrame", void 0);
        _defineProperty(this, "nextId", void 0);
        _defineProperty(this, "nextContainer", void 0);
        _defineProperty(this, "nextFrame", void 0);
        _defineProperty(this, "offsetCenter", void 0);
        _defineProperty(this, "currentOffset", -100.0);
        _defineProperty(this, "lockNavBtn", void 0);
        _defineProperty(
            this,
            "baseSrcDoc",
            `<head>
          <script src="${app.net.networkManagerXHR.bestDomain()}/stv.ui.js"></script>
          <style id="readerstyle"></style>
          <style id="localfont"></style>
          <link rel="stylesheet" href="{webfont}">
          <link rel="stylesheet" href="/asset/all.min.css">
          <style id="uistyle">
              .rctx > div {
                  padding: 10px;
                  line-height: 1;
                  font-size: 12px;
                  border-right: 1px solid #80808080;
              }
              .rctx {
                  display: flex;
                  border-radius: 15px;
                  background: inherit;
                  border: 1px solid #80808080;
              }
              .rctx > div:last-child {
                  border-right: none;
              }
              .chinesedragbar{
                  position: absolute;
                  background: #00000080;
                  color: white;
                  padding: 6px;
                  border-radius: 15px;
                  font-size: 14px;
                  display: none;
                  line-height: 1.5;
                  max-width: 100%;
                  z-index: 10001;
              }
              .chinesedragbar > div{
                  display: flex;
                  text-align: center;
              }
              .chinesedragbar > div > div{
                  display: inline-block;
                  vertical-align: top;
                  white-space: nowrap;
              }
              .chinesedragbar .leftcnshow, .chinesedragbar .rightcnshow{
                  color: #a1a1a1;
              }
              .chinesedragbar .pointer{
                  width: 2px;
              }
              .chinesedragbar .pointer.active{
                  background: white;
              }
              #contextmenu:not(.active){
                  pointer-events: none;
              }
              #chaptername{
                  text-align: center;
              }
              #maincontent{
                  max-width: 100vw;
                  min-height: 100%;
              }
          </style>
          <script src="${app.net.networkManagerXHR.bestDomain()}/qtOnline.js?v=35"></script>
          <script type="id" id="hiddenid">0;0;0</script>
          </head><body>
              <div class="rctx" id="contextmenu"></div>
              <div id="topofpage" style="color:transparent;text-shadow:none;height:50px;">topage</div>
              <div id="maincontent"></div>
              <div style="color:transparent;text-shadow:none;height:50px;" id="botofpage">bottom</div>
              <div id="dragbar"></div>
              
          </body>`
        );
        // interact behavior
        _defineProperty(this, "behaviour", {
            way_to_choose_node: {
                bindEvent: function (cw) {
                    var method = app.config.reader.way_to_choose_node;
                    var baseBehaviour = app.reader.behaviour.way_to_choose_node;
                    if (!baseBehaviour[method]) {
                        method = "click";
                    }
                    switch (method) {
                        case "click": {
                            cw.way_to_choose_node = baseBehaviour[method].bind(cw);
                            cw.document.body.addEventListener("click", cw.way_to_choose_node);
                            break;
                        }
                        case "dblclick": {
                            cw.way_to_choose_node = baseBehaviour[method].bind(cw);
                            cw.document.body.addEventListener("click", cw.way_to_choose_node);
                            break;
                        }
                        case "hold": {
                            ui.hold(cw.document.body, baseBehaviour[method].bind(cw));
                            cw.document.body.addEventListener("click", baseBehaviour["triggermenu"]);
                            break;
                        }
                        case "none": {
                            cw.document.body.addEventListener("click", baseBehaviour["triggermenu"]);
                            return;
                        }
                    }
                },
                rebindEvent: function () {
                    var pcn = app.reader.getPCN();
                    var l = [pcn.prev, pcn.current, pcn.next];
                    for (var i = 0; i < l.length; i++) {
                        var cw = l[i].q(".content").contentWindow;
                        cw.document.body.removeEventListener("click", cw.way_to_choose_node);
                        cw.document.body.removeEventListener("dblclick", cw.way_to_choose_node);
                        cw.document.body.removeEventListener(
                            "click",
                            app.reader.behaviour.way_to_choose_node["triggermenu"]
                        );
                        cw.document.body.unhold && cw.document.body.unhold();
                        this.bindEvent(cw);
                    }
                },
            },
            chapter_name_fixed_place: {
                apply: function () {
                    var cs = app.reader.getDisplay().getRoot().qq(".chaptertopinfo");
                    switch (app.config.reader.chapter_name_fixed_place) {
                        case "top": {
                            cs.forEach((e) => {
                                e.style.display = "flex";
                                e.parentElement.insertBefore(e, e.parentElement.firstChild);
                            });
                            break;
                        }
                        case "bottom": {
                            cs.forEach((e) => {
                                e.style.display = "flex";
                                e.parentElement.appendChild(e);
                            });
                            break;
                        }
                        case "none": {
                            cs.forEach((e) => {
                                e.style.display = "none";
                            });
                            break;
                        }
                    }
                },
            },
            prepend_chapter_name: {
                apply: function () {
                    var pcn = app.reader.getPCN();
                    var l = [pcn.prev, pcn.current, pcn.next];
                    var has = app.config.reader.prepend_chapter_name;
                    if (has) {
                        l.forEach((e) => {
                            var cw = e.q(".content").contentWindow;
                            var name = e.q(".chaptername");
                            var inner = cw.g("chaptername");
                            if (!inner) {
                                inner = cw.document.createElement("div");
                                inner.id = "chaptername";
                                inner.textContent = name.textContent;
                                cw.document.body.insertBefore(inner, cw.g("maincontent"));
                            } else if (inner.textContent != name.textContent) {
                                inner.textContent = name.textContent;
                            }
                        });
                    } else {
                        l.forEach((e) => {
                            var cw = e.q(".content").contentWindow;
                            var inner = cw.g("chaptername");
                            if (inner) {
                                inner.remove();
                            }
                        });
                    }
                },
            },
            tap_actions: {
                description: [
                    {
                        value: "none",
                        name: app.text.none,
                    },
                    {
                        value: "scroll_down",
                        name: app.text.slide_down, //"Cuộn xuống",
                    },
                    {
                        value: "scroll_up",
                        name: app.text.slide_up,
                    },
                    {
                        value: "open_menu",
                        name: app.text.open_menu,
                    },
                ],
                scroll_down: function (cw, view) {
                    var offset = 250;
                    cw.scrollBy({
                        top: offset,
                        behavior: "smooth",
                    });
                },
                scroll_up: function (cw, view) {
                    var offset = 250;
                    cw.scrollBy({
                        top: -offset,
                        behavior: "smooth",
                    });
                },
                open_menu: function (cw, view) {
                    app.reader.toggleMenu();
                },
                none: function (cw, view) {},
            },
        });
    }
    render() {
        var v = (this.scroller = app.render("chapterDisplay-slide", {}));
        var c1 = (this.prevContainer = this.getSingleContainer(0));
        var c2 = (this.currentContainer = this.getSingleContainer(1));
        var c3 = (this.nextContainer = this.getSingleContainer(2));
        c1.style.transform = "translateY(0vh)";
        c2.style.transform = "translateY(100vh)";
        c3.style.transform = "translateY(200vh)";
        v.appendChild(c1);
        v.appendChild(c2);
        v.appendChild(c3);
        if (this.root.q(".chapterscroller")) {
            this.root.q(".chapterscroller").remove();
        }
        this.root.appendChild(v);
        this.resetPosition();
    }
    getSingleContainer(num) {
        var e = app.render("chaptercontainer", {});
        e.q(".chaptername").textContent = app.text.loading;
        e.q(".currenttime").textContent = currentTime();
        var view = e.q(".content");
        var w = window;
        var isEncrypted = app.reader.encryptedHosts.indexOf(this.host) >= 0;
        var srcdoc = this.baseSrcDoc.replace("{webfont}", app.fontmanager.getFontUrl(isEncrypted));
        var self = this;
        view.onload = function () {
            var cd = this.contentDocument;
            var cw = this.contentWindow;
            self.behaviour.way_to_choose_node.bindEvent(cw);
            cw.onblur = function () {
                w.preventExit = true;
                console.log(w.preventExit);
            };
            var s = document.createElement("style");
            s.textContent = app.reader.defaultRStyle;
            cd.head.appendChild(s);
            cw.hanvietdic = w.hanvietdic;
            cw.store = app.storage;
            cw.getCookie = w.getCookie;
            cw.container = e;
            cw.thispage = "chapter";
            cw.namew = {
                value: "",
                valueglobal: "",
            };
            Object.defineProperty(cw.namew, "value", {
                set: function (v) {
                    app.namemanager.updateNameData(v);
                },
                get: function () {
                    return app.namemanager.namedatacache || app.namemanager.namedata.join("\n");
                },
            });
            Object.defineProperty(cw.namew, "valueglobal", {
                set: function (v) {
                    app.namemanager.updateNameData(v);
                },
                get: function () {
                    return app.namemanager.namedatacacheglobal || app.namemanager.nameglobal.join("\n");
                },
            });
            cw.saveNS = function () {
                app.namemanager.saveData();
            };
            cw.excute = cw.excuteApp;
            cw.setting = app.editor.setting;
            cw.pr = function () {};
            cw.dragdownAble = false;
            cw.dragupAble = false;
            cw.touchStartTarget = null;
            if (num == 1) {
                app.reader.loadStart();
            }
            var tmove = function (e) {
                var o = (e.touches[0].clientY - cw.startPos) / cw.sh;
                cw.currentY = e.touches[0].clientY;
                if (cw.initDrag) {
                    var ox = e.touches[0].clientX - cw.startPosX;
                    if (Math.abs(ox) > Math.abs(e.touches[0].clientY - cw.startPos)) {
                        cw.initDrag = false;
                        cw.removeEventListener("touchmove", tmove);
                        console.log("cancel drag");
                        return;
                    }
                    if (cw.dragdown) {
                        if (o > 0 || !cw.dragdownAble) {
                            cw.dragdown = false;
                        } else {
                            cw.draggingdown = true;
                        }
                        console.log(cw.draggingdown);
                    }
                    if (cw.dragup) {
                        if (o < 0 || !cw.dragupAble) {
                            cw.dragup = false;
                        } else {
                            cw.draggingup = true;
                        }
                        console.log(cw.draggingup);
                    }
                }
                if ((cw.dragdown && cw.draggingdown) || (cw.dragup && cw.draggingup)) {
                    self.transform(o);
                }
                cw.initDrag = false;
            };
            cw.addEventListener("touchstart", function (e) {
                this.touchStartTarget = e.target;
                if ((cw.isAtTop && isWindowTop(cw)) || (cw.isAtBottom && isWindowBottom(cw))) {
                    cw.startPos = e.touches[0].clientY;
                    cw.startPosX = e.touches[0].clientX;
                    cw.initDrag = true;
                    console.log("init drag");
                    cw.sh = document.body.scrollHeight;
                    cw.addEventListener("touchmove", tmove, {
                        passive: false,
                    });
                } else {
                    cw.removeEventListener("touchmove", tmove);
                }
            });
            cw.addEventListener("touchend", function (e) {
                cw.removeEventListener("touchmove", tmove);
                if (cw.draggingdown) {
                    if (cw.currentY < cw.startPos) {
                        self.snap("down");
                    } else {
                        self.snap();
                    }
                } else if (cw.draggingup) {
                    if (cw.currentY > cw.startPos) {
                        self.snap("up");
                    } else {
                        self.snap();
                    }
                } else {
                    self.snap();
                }
                cw.draggingdown = false;
                cw.draggingup = false;
                if (cw.isAtBottom) {
                    cw.dragdown = true;
                }
                if (cw.isAtTop) {
                    cw.dragup = true;
                }
            });
            cw.addEventListener("touchcancel", function (e) {
                cw.removeEventListener("touchmove", tmove);
                cw.draggingdown = false;
                cw.draggingup = false;
                if (cw.isAtBottom) {
                    cw.dragdown = true;
                }
                if (cw.isAtTop) {
                    cw.dragup = true;
                }
            });
            var topofpage = cd.getElementById("topofpage");
            topofpage.onVisible = function () {
                cw.dragup = true;
                cw.isAtTop = true;
            };
            topofpage.onHidden = function () {
                if (!cw.draggingup) cw.dragup = false;
                cw.isAtTop = false;
            };
            var botofpage = cd.getElementById("botofpage");
            botofpage.onVisible = function () {
                cw.isAtBottom = true;
                cw.dragdown = true;
            };
            botofpage.onHidden = function () {
                if (!cw.draggingdown) cw.dragdown = false;
                cw.isAtBottom = false;
            };
            observer.observe(topofpage);
            observer.observe(botofpage);
            app.reader.applyStyle();
            events.set(cd.getElementById("contextmenu"), "view_contextmenu");
            cw.chinesedragbar = new ChineseDragBar(null, cd.getElementById("dragbar"));
            cw.chinesedragbar.onupdate = function (c) {
                app.reader.display.q(".chi").textContent = c;
                app.editor.updateSuggest(cw, c);
            };
        };
        e.setAttribute("num", num);
        e.style.order = num + 1;
        view.srcdoc = srcdoc;
        return e;
    }
    snap(direction, fast, instant, noAnimation) {
        var h = 100.0;
        var o = -h;
        var self = this;
        if (this.offsetCenter == null) {
            this.offsetCenter = o;
        } else {
            o = this.offsetCenter;
        }
        if (direction == "down") {
            o = this.offsetCenter - h;
        }
        if (direction == "up") {
            o = this.offsetCenter + h;
        }
        var duration = 0.35;
        if (fast) {
            duration = instant || 0.12;
        }
        if (this.currentOffset == o) {
            return;
        }
        this.lockNavBtn = true;
        var onFinish = function (fixedPos = true) {
            self.currentOffset = o;
            self.offsetCenter = o;
            var vh = o;
            if (!fixedPos) {
                var y = self.scroller.animator ? self.scroller.animator.y : o + "px";
            }
            self.scroller.style.transform = "translateY(" + vh + "vh)";
            self.scroller.internal = {
                translateY: vh,
            };
            self.recycle(direction, vh);
            self.lockNavBtn = false;
            app.reader.updateHistory2();
            app.reader.updateCnameAndProgress();
            self.scroller.animator = null;
            app.tts.changeChapter();
        };
        if (noAnimation && document.hidden) {
            self.scroller.style.transform = "translateY(" + o + "vh)";
            console.log("instant to " + o + "vh");
            onFinish(false);
            return;
        }
        self.scroller.animator = gsap.fromTo(
            self.scroller,
            {
                transform: "translate3d(0," + self.currentOffset + "vh,0)",
            },
            {
                duration: duration,
                transform: "translate3d(0," + o + "vh,0)",
                onComplete: onFinish,
            }
        );
    }
    recycle(dir) {
        var current;
        if (dir == "down") {
            var maxOffset = -999999999,
                maxOffsetChild,
                minOffset = 999999999,
                minOffsetChild;
            for (var i = 0; i < this.scroller.children.length; i++) {
                var child = this.scroller.children[i];
                var interalTransform = child.internal ? child.internal.transform : child.style.transform;
                var o = getPxFromTranslate(interalTransform);
                if (o > maxOffset) {
                    maxOffset = o;
                    maxOffsetChild = this.scroller.children[i];
                }
                if (o < minOffset) {
                    minOffset = o;
                    minOffsetChild = this.scroller.children[i];
                }
            }
            minOffsetChild.style.transform = "translateY(" + (maxOffset + 100) + "vh)";
            minOffsetChild.internal = {
                transform: "translateY(" + (maxOffset + 100) + "vh)",
            };
            current = maxOffsetChild;
            this.ensurePreload(null, current, minOffsetChild);
            this.currentContainer = current;
            this.nextContainer = minOffsetChild;
            this.prevContainer = Array.from(this.scroller.children).filter((e) => e != current && e != minOffsetChild)[0];
            this.resetPosition();
        }
        if (dir == "up") {
            var maxOffset = -999999999,
                maxOffsetChild,
                minOffset = 999999999,
                minOffsetChild;
            for (var i = 0; i < this.scroller.children.length; i++) {
                var interalTransform = this.scroller.children[i].internal
                    ? this.scroller.children[i].internal.transform
                    : this.scroller.children[i].style.transform;
                var o = getPxFromTranslate(interalTransform);
                if (o > maxOffset) {
                    maxOffset = o;
                    maxOffsetChild = this.scroller.children[i];
                }
                if (o < minOffset) {
                    minOffset = o;
                    minOffsetChild = this.scroller.children[i];
                }
            }
            maxOffsetChild.style.transform = "translateY(" + (minOffset - 100) + "vh)";
            maxOffsetChild.internal = {
                transform: "translateY(" + (minOffset - 100) + "vh)",
            };
            current = minOffsetChild;
            this.ensurePreload(maxOffsetChild, current, null);
            this.currentContainer = current;
            this.prevContainer = maxOffsetChild;
            this.nextContainer = Array.from(this.scroller.children).filter((e) => e != current && e != maxOffsetChild)[0];
            this.resetPosition();
        }
    }
    transform(offset) {
        var p = this.scroller;
        if (p.animator) {
            p.animator.kill();
            p.animator = null;
        }
        var o = this.currentOffset;
        p.style.transform = "translateY(" + (o + offset * 100) + "vh)";
        this.currentOffset = o + offset * 100;
    }
    resetPosition() {
        this.currentFrame = this.currentContainer.q(".content");
        this.prevFrame = this.prevContainer.q(".content");
        this.nextFrame = this.nextContainer.q(".content");
        this.currentId = this.currentContainer.cid;
        this.prevId = this.prevContainer.cid;
        this.nextId = this.nextContainer.cid;
    }
    getRoot() {
        return this.scroller;
    }
    getPCN() {
        return {
            prev: this.prevContainer,
            current: this.currentContainer,
            next: this.nextContainer,
        };
    }
    setContent(target, content, chaptername) {
        var container =
            target == "prev" ? this.prevContainer : target == "next" ? this.nextContainer : this.currentContainer;
        container.q(".chaptername").textContent = chaptername;
        var frame = container.q(".content");
        var innerWindow = frame.contentWindow;
        innerWindow.q("#maincontent").innerHTML = content;
        try {
            innerWindow.applyNodeList();
            innerWindow.excuteApp();
        } catch (e) {
            console.log(e);
        }
        this.behaviour.prepend_chapter_name.apply();
        if (target == "prev") {
            innerWindow.scrollTo(0, 999999);
        } else {
            innerWindow.scrollTo(0, 0);
        }
    }
    setContent2(text, cdata, view, isToTop) {
        view.cdata = cdata;
        view.q(".chaptername").textContent = cdata.chaptername;
        var cw = view.q(".content").contentWindow;
        cw.g("maincontent").innerHTML = text;
        try {
            cw.applyNodeList();
            cw.excuteApp();
        } catch (e) {}
        this.behaviour.prepend_chapter_name.apply();
        if (isToTop) {
            cw.scrollTo(0, 0);
        } else {
            cw.scrollTo(0, 999999);
        }
    }
    ensurePreload(prev, current, next) {
        var self = this;
        if (!current) {
            var pcn = app.reader.getPCN();
            prev = pcn.prev;
            current = pcn.current;
            next = pcn.next;
        }
        var cw = current.q(".content").contentWindow;
        if (!cw) {
            setTimeout(function () {
                self.ensurePreload(prev, current, next);
            }, 100);
            return;
        }
        if (current.previd == "0") {
            current.previd = false;
        }
        if (current.nextid == "0") {
            current.nextid = false;
        }
        if (prev) {
            console.log(`previd: ${prev.cid}, prev cid: ${current.previd}`);
            if (prev.cid != current.previd && current.previd && current.previd != "0") {
                console.log("preload prev");
                this.preload(app.reader.host, app.reader.id, current.previd, prev, false);
                cw.dragupAble = true;
            }
            prev.q(".content").contentWindow.scrollTo(0, 9999999);
        }
        if (current.previd) {
            cw.dragupAble = true;
        } else {
            cw.dragupAble = false;
            console.log(current.previd);
        }
        if (next) {
            console.log("checking next");
            console.log(`nextid: ${next.cid}, nexid: ${current.nextid}`);
            if (next.cid != current.nextid && current.nextid && current.nextid != "0") {
                console.log("preload next");
                this.preload(app.reader.host, app.reader.id, current.nextid, next, true);
            }
        }
        if (current.nextid) {
            cw.dragdownAble = true;
        } else {
            cw.dragdownAble = false;
            console.log(current.nextid);
        }
    }
    scrollToCenter() {
        var p = this.scroller;
        p.style.scrollBehavior = "auto";
        p.style.scrollSnapType = "unset";
        p.scrollTop = document.body.scrollHeight;
        p.style.scrollBehavior = "smooth";
        p.style.scrollSnapType = "y mandatory";
    }
    loadStart() {
        this.scrollToCenter();
        this.preload(app.reader.host, app.reader.id, app.reader.startid, this.currentContainer, true, false, true);
    }
    async preload(h, i, c, view, isToTop, rl, start) {
        if (c == "0" || !c) {
            return;
        }
        view.cid = c;
        this.setLoading(view);
        var cdata = await app.reader.getContent(h, i, c, rl);
        this.setNotLoading(view);
        if (cdata.code == "0") {
            window.failedIn5Times = 0;
            var text = app.reader.preprocess(h, cdata.data);
            this.setContent2(text, cdata, view, isToTop);
            await this.assignNavigator(h, i, c, cdata, view);
            if (start) {
                app.reader.updateHistory(h, i, c, cdata);
                this.ensurePreload(this.prevContainer, this.currentContainer, this.nextContainer);
            }
        } else {
            app.reader.handlingException(cdata, view);
        }
    }
    async assignNavigator(h, i, c, x, frame) {
        var forceget = ["trxc", "bxwxorg", "faloo", "biquge", "fanqie"];
        if (forceget.indexOf(h) > -1) {
            x.next = 0;
            x.prev = 0;
        }
        var nextid = x.next;
        var previd = x.prev;
        frame.previd = previd;
        frame.nextid = nextid;
        frame.cid = c;
        if (h == "surf") {
            return;
        }
        if (frame.previd == 0 || frame.nextid == 0) {
            var nani = await app.reader.getChapterNavigator(h, i, c); // {next, prev}
            if (parseInt(nani.next) != 0) {
                frame.nextid = nani.next;
            }
            if (parseInt(nani.prev) != 0) {
                frame.previd = nani.prev;
            }
            this.ensurePreload();
        }
    }
    setLoading(container) {
        var pl = app.createPreloader("Đang tải nội dung...", true);
        pl.classList.add("chapterpreloader");
        container.appendChild(pl);
    }
    setNotLoading(container) {
        container.qq(".waitpreloader").forEach((e) => e.remove());
    }
    rightTapAction() {
        var cw = this.currentFrame.contentWindow;
        var view = this.currentFrame;
        var method = app.config.reader.right_tap_action;
        if (!this.behaviour.tap_actions[method]) {
            method = "none";
        }
        this.behaviour.tap_actions[method](cw, view);
    }
    leftTapAction() {
        var cw = this.currentFrame.contentWindow;
        var view = this.currentFrame;
        var method = app.config.reader.left_tap_action;
        if (!this.behaviour.tap_actions[method]) {
            method = "none";
        }
        this.behaviour.tap_actions[method](cw, view);
    }

    // user method
    goNextChapter(isTTS) {
        if (this.lockNavBtn) {
            return;
        }
        if (this.currentFrame.contentWindow.dragdownAble) {
            this.snap("down", true, false, isTTS);
        }
    }
    goPrevChapter(isTTS) {
        if (this.lockNavBtn) {
            return;
        }
        if (this.currentFrame.contentWindow.dragupAble) {
            this.prevFrame.contentWindow.scrollTo(0, 0);
            this.snap("up", true, false, isTTS);
        }
    }
    showAlert(msg, view) {
        var mct = view.q(".content").contentWindow.g("maincontent");
        var preloader = view.q(".chapterpreloader");
        if (preloader) {
            preloader.remove();
        }
        mct.innerHTML = `
              <div class="erroralert" style="width:100%;height:100%;min-height:calc(100vh - 100px);position:relative;">
              <div style="position: absolute;width:80%;left: 50%;top: 50%;transform: translate(-50%, -50%);
              text-align: center;font-size: 20px;">
                  <div>${msg}</div>
                  <div class="btn" style="display: inline-block;border-radius: 8px;border-color: white;border-width: 2px;
                  border-style: solid;padding: 6px 12px;margin: 20px;">Tải lại</div>
              </div></div>
          `;
        var btn = mct.querySelector(".btn");
        btn.addEventListener("click", function () {
            window.failedIn5Times = 0;
            app.reader.reloadCurrentChapter();
            event.stopPropagation();
            app.platform.nativeclick();
        });
    }
    removeAlert(view) {
        var ele = view.q(".content").contentWindow.q(".erroralert")[0];
        if (ele) {
            ele.remove();
        }
    }
    async reloadCurrentChapter(rl) {
        var view = this.currentContainer;
        if (view.cid != "0" && view.cid) {
            this.removeAlert(view);
            this.preload(app.reader.host, app.reader.id, view.cid, view, true, rl).then(() => {
                var pcn = app.reader.getPCN();
                this.ensurePreload(pcn.prev, pcn.current, pcn.next);
            });
        }
    }
    async reloadAllChapter() {
        var self = this;
        this.preload(app.reader.host, app.reader.id, this.currentContainer.cid, this.currentContainer, true);
        if (this.nextContainer && this.nextContainer.cid != "0") {
            var cid = this.nextContainer.cid;
            var container = this.nextContainer;
            setTimeout(function () {
                self.preload(app.reader.host, app.reader.id, cid, container, true);
            }, 3000);
        }
        if (this.prevContainer && this.prevContainer.cid != "0") {
            var cid = this.prevContainer.cid;
            var container = this.prevContainer;
            setTimeout(function () {
                self.preload(app.reader.host, app.reader.id, cid, container, false);
            }, 6000);
        }
    }
    async changeCurrentChapter(targetId) {
        var view = this.currentContainer;
        if (targetId != "0" && targetId) {
            view.cid = targetId;
            this.removeAlert(view);
            this.preload(app.reader.host, app.reader.id, targetId, view, true).then(() => {
                var pcn = app.reader.getPCN();
                this.ensurePreload(pcn.prev, pcn.current, pcn.next);
                app.reader.updateCnameAndProgress();
            });
        }
    }
    getChapterNameAndProgress() {
        if (this.currentContainer && this.currentContainer.cdata) {
            var name = this.currentContainer.cdata.chaptername;
            var cw = this.currentFrame.contentWindow;
            var h = cw.document.body.scrollHeight;
            var y = cw.scrollY;
            var p = y / (h - cw.innerHeight);
            return {
                name: name,
                progress: p * 1000, // 0 - 1000
            };
        }
    }
    applyStyleChange(stl) {
        var oldBorderTop =
            app.reader.styleCnameUi.collection["#chapterview iframe.content"] &&
            app.reader.styleCnameUi.collection["#chapterview iframe.content"].css["border-top"];
        var oldBorderBottom =
            app.reader.styleCnameUi.collection["#chapterview iframe.content"] &&
            app.reader.styleCnameUi.collection["#chapterview iframe.content"].css["border-bottom"];
        if (oldBorderTop != stl.borderTop || oldBorderBottom != stl.borderBottom) {
            app.reader.styleCnameUi.set("#chapterview iframe.content", {
                borderTop: stl.borderTop,
                borderBottom: stl.borderBottom,
            });
        }
    }
    gotoProgress(p) {
        var w = this.currentFrame.contentWindow;
        var h = w.document.body.scrollHeight;
        w.scrollTo(0, (h - w.innerHeight) * (p / 1000));
    }
    runName() {
        for (var i = 0; i < this.scroller.children.length; i++) {
            var cw = this.scroller.children[i].q(".content").contentWindow;
            cw.excuteApp();
        }
    }
    hideContextMenu() {
        this.getCurrentWindow().g("contextmenu").hide();
    }
    unlockNameSelect() {
        this.getCurrentWindow().unlock();
    }
    getCurrentWindow() {
        return this.currentFrame.contentWindow;
    }
}
class PageClipChapter {
    constructor() {
        this.cid = "0";
        this.nextid = "0";
        this.previd = "0";
        this.cdata = null;
        this.pages = [];
        this.pageElements = [];
        this.baseHTML = "";
    }
    firstPage() {
        return this.pageElements[0];
    }
    lastPage() {
        return this.pageElements[this.pageElements.length - 1];
    }
    getAjacentPage(page) {
        var index = this.pages.indexOf(page);
        if (index == -1) {
            return null;
        }
        return {
            prev: this.pages[index - 1],
            next: this.pages[index + 1],
        };
    }
    resetValue() {
        this.nextid = "0";
        this.previd = "0";
        this.baseHTML = "";
        this.cdata = null;
    }
    setPages(pages) {
        this.pages = pages;
        var eles = [];
        for (var i = 0; i < pages.length; i++) {
            var page = pages[i];
            var oldElement = this.pageElements[i];
            if (oldElement) {
                this.resetPageHtml(oldElement);
                for (var j = 0; j < page.length; j++) {
                    oldElement.appendChild(page[j]);
                }
                eles.push(oldElement);
            } else {
                var newPage = this.createPage();
                for (var j = 0; j < page.length; j++) {
                    newPage.appendChild(page[j]);
                }
                eles.push(newPage);
            }
        }
        this.pageElements = eles;
    }
    splitPage(contentDiv, wheight) {
        var pageHeight = wheight || window.innerHeight;
        console.log("ph:" + pageHeight);
        var computedStyle = window.getComputedStyle(contentDiv);
        var marginBlockStart = 0;
        var pElement = contentDiv.querySelector("p");
        if (pElement) {
            var computedStyleP = window.getComputedStyle(pElement);
            marginBlockStart = parseInt(computedStyleP.marginBlockStart || computedStyleP.marginTop || 0);
        }
        var lineHeight = parseInt(computedStyle.lineHeight);
        var estimateNumOfLine = function (para, oH) {
            if (!para || para.tagName != "P") {
                return 0;
            }
            var num = Math.round(oH / lineHeight);
            return num;
        };
        var findBestNumOfLine = function (totalLine, heightLeft) {
            var num = 0;
            heightLeft -= marginBlockStart;
            for (var i = 1; i <= totalLine; i++) {
                if (i * lineHeight > heightLeft) {
                    num = i - 1;
                    break;
                }
            }
            return num;
        };
        var copyCnForName = function (base, clone) {
            var is1 = base.qq("i");
            var is2 = clone.qq("i");
            if (is1.length != is2.length) {
                return;
            }
            for (var i = 0; i < is1.length; i++) {
                is2[i].cn = is1[i].cn;
            }
        };
        var pages = [];
        var page = [];
        var currentConsumedPageHeight = 0;
        for (var i = 0; i < contentDiv.children.length; i++) {
            var para = contentDiv.children[i];
            var oH = para.offsetHeight;
            var consumedHeight = oH + (oH > 0 ? marginBlockStart : 0);
            if (currentConsumedPageHeight + consumedHeight > pageHeight) {
                var heightLeft = pageHeight - currentConsumedPageHeight;
                var totalLine = estimateNumOfLine(para, oH);
                var bestNumOfLine = findBestNumOfLine(totalLine, heightLeft);
                if (bestNumOfLine > 0) {
                    var clippedPara = para.cloneNode(true);
                    copyCnForName(para, clippedPara);
                    var clipHeight = bestNumOfLine * lineHeight;
                    clippedPara.style.height = clipHeight + "px";
                    clippedPara.style.overflow = "hidden";
                    page.push(clippedPara);
                    pages.push(page);
                    page = [];
                    var remainingPara = para.cloneNode(true);
                    copyCnForName(para, remainingPara);
                    var div = document.createElement("div");
                    var remainingHeight = oH - clipHeight;
                    remainingPara.style.marginTop = -clipHeight + "px";
                    div.style.height = remainingHeight + "px";
                    div.style.overflow = "hidden";
                    div.style.marginTop = marginBlockStart + "px";
                    div.appendChild(remainingPara);
                    page.push(div);
                    currentConsumedPageHeight = remainingHeight + marginBlockStart;
                } else {
                    pages.push(page);
                    page = [];
                    page.push(para);
                    currentConsumedPageHeight = consumedHeight;
                }
            } else {
                currentConsumedPageHeight += consumedHeight;
                //console.log("currentConsumedPageHeight:" + currentConsumedPageHeight, "consumedHeight:" + consumedHeight, "text:" + para.textContent);
                page.push(para);
            }
        }
        if (page.length > 0) {
            pages.push(page);
        }
        return pages;
    }
    getPrependChapterNameHTML() {
        var has = app.config.reader.prepend_chapter_name;
        if (has && this.cdata) {
            var name = this.cdata.chaptername;
            if (!name) {
                return "";
            }
            return `<p class="chaptername">${name}</p>`;
        }
        return "";
    }
    createPage() {
        var page = document.createElement("div");
        page.className = "page";
        var cname = "";
        var ctime = currentTime();
        if (this.cdata) {
            cname = this.cdata.chaptername;
        }
        switch (app.config.reader.chapter_name_fixed_place) {
            case "top": {
                page.innerHTML = `<div class="chaptertopinfo" style="top: 0">
                      <div class="chapternamefixed" style="flex: 1;">${cname}</div>
                      <div class="currenttime">${ctime}</div>
                  </div>`;
                break;
            }
            case "bottom": {
                page.innerHTML = `<div class="chaptertopinfo" style="bottom: 0">
                      <div class="chapternamefixed" style="flex: 1;">${cname}</div>
                      <div class="currenttime">${ctime}</div>
                  </div>`;
                break;
            }
        }
        return page;
    }
    resetPageHtml(p) {
        var cname = "";
        if (this.cdata) {
            cname = this.cdata.chaptername;
        }
        var ctime = currentTime();
        switch (app.config.reader.chapter_name_fixed_place) {
            case "top": {
                p.innerHTML = `<div class="chaptertopinfo" style="top: 0">
                      <div class="chapternamefixed" style="flex: 1;">${cname}</div>
                      <div class="currenttime">${ctime}</div>
                  </div>`;
                break;
            }
            case "bottom": {
                p.innerHTML = `<div class="chaptertopinfo" style="bottom: 0">
                      <div class="chapternamefixed" style="flex: 1;">${cname}</div>
                      <div class="currenttime">${ctime}</div>
                  </div>`;
                break;
            }
            case "none": {
                p.innerHTML = "";
                break;
            }
            default: {
                p.innerHTML = "";
                break;
            }
        }
    }
    reOrganizePages(renderer, noHtmlChange, wheight) {
        if (!noHtmlChange) {
            if (!this.cdata) {
                return;
            }
            renderer.innerHTML = this.getPrependChapterNameHTML() + this.baseHTML;
            try {
                app.reader.getDisplay().getCurrentWindow().applyNodeList();
                app.reader.getDisplay().getCurrentWindow().excuteApp();
            } catch (e) {
                console.log(e);
            }
        }
        this.pages = this.splitPage(renderer, wheight);
        for (var i = 0; i < this.pages.length; i++) {
            var page = this.pages[i];
            var oldElement = this.pageElements[i];
            if (oldElement) {
                this.resetPageHtml(oldElement);
                for (var j = 0; j < page.length; j++) {
                    oldElement.appendChild(page[j]);
                }
            } else {
                var newPage = this.createPage();
                for (var j = 0; j < page.length; j++) {
                    newPage.appendChild(page[j]);
                }
                this.pageElements.push(newPage);
            }
        }
        if (this.pages.length < this.pageElements.length) {
            for (var i = this.pages.length; i < this.pageElements.length; i++) {
                this.pageElements[i].remove();
            }
            this.pageElements = this.pageElements.slice(0, this.pages.length);
        }
    }
    remove() {
        this.pageElements.forEach((e) => e.remove());
        this.pages = [];
        this.pageElements = [];
    }
}
class PageFlipChapterDisplay extends ChapterDisplay {
    constructor(root) {
        super(root);
        _defineProperty(this, "innerWindow", void 0);
        _defineProperty(this, "disableDragBar", true);
        _defineProperty(this, "lockNavBtn", false);
        _defineProperty(this, "currentChapter", new PageClipChapter());
        _defineProperty(this, "prevChapter", new PageClipChapter());
        _defineProperty(this, "nextChapter", new PageClipChapter());
        _defineProperty(this, "currentFrame", void 0);
        _defineProperty(this, "currentPageId", 0);
        _defineProperty(this, "screenWidth", window.innerWidth);
        _defineProperty(this, "flipper", void 0);
        _defineProperty(
            this,
            "baseSrcDoc",
            `<head>
          <script src="${app.net.networkManagerXHR.bestDomain()}/stv.ui.js"></script>
          <style id="readerstyle"></style>
          <style id="localfont"></style>
          <link rel="stylesheet" href="{webfont}">
          <link rel="stylesheet" href="/asset/all.min.css">
          <style id="uistyle">
              ${preloaderAnimation}
              .chapterpreloader1 {
                  width: 100%;
                  height: 100%;
              }
              .currenttime {
                  padding-right: 20px;
              }
              .chapterpreloader{
                  position: absolute;
                  top: 50%;
                  left: 50%;
                  transform: translate(-50%, -50%);
              }
              .rctx > div {
                  padding: 10px;
                  line-height: 1;
                  font-size: 12px;
                  border-right: 1px solid #80808080;
              }
              .rctx {
                  display: flex;
                  border-radius: 15px;
                  background: inherit;
                  border: 1px solid #80808080;
              }
              .rctx > div:last-child {
                  border-right: none;
              }
              .chinesedragbar{
                  position: absolute;
                  background: #00000080;
                  color: white;
                  padding: 6px;
                  border-radius: 15px;
                  font-size: 14px;
                  display: none;
                  line-height: 1.5;
                  max-width: 100%;
                  z-index: 10001;
              }
              .chinesedragbar > div{
                  display: flex;
                  text-align: center;
              }
              .chinesedragbar > div > div{
                  display: inline-block;
                  vertical-align: top;
                  white-space: nowrap;
              }
              .chinesedragbar .leftcnshow, .chinesedragbar .rightcnshow{
                  color: #a1a1a1;
              }
              .chinesedragbar .pointer{
                  width: 2px;
              }
              .chinesedragbar .pointer.active{
                  background: white;
              }
              #contextmenu:not(.active){
                  pointer-events: none;
              }
              .chaptername{
                  text-align: center !important;
              }
              #maincontent{
                  max-width: 100vw;
                  min-height: 100vh;
                  position: absolute;
                  top: 0;
                  left: 0;
                  z-index: -1; 
                  visibility: hidden;
              }
              .singlechapter{
                  max-width: 100vw;
                  min-height: 101vh;
              }
              .chaptertopinfo {
                  font-size: 10px;
                  height: 14px;
                  padding: 0px 6px;
                  background-color: inherit;
                  display: flex;
                  position: absolute;
                  width: 100%;
                  left: 0;
              }
              .pageparent {
                  position: absolute;
                  top: 0;
                  left: 0;
                  width: 100vw;
                  height: 100vh;
                  box-sizing: border-box;
              }
              .page {
                  width: 100%;
                  height: 100%;
                  overflow: hidden;
                  box-sizing: border-box;
                  position: relative;
              }
              #pageflipper {
                  position: absolute;
                  top: 0;
                  left: 0;
                  width: 100vw;
                  height: 100vh;
                  overflow: hidden;
              }
              body {
                  margin: 0;
                  padding: 0;
                  overflow: hidden;
              }
              #backpaper {
                  position: absolute;
                  top: 0;
                  left: 0;
                  width: 100vw;
                  height: 100vh;
                  box-sizing: border-box;
                  touch-action: none;
                  pointer-events: none;
              }
              .backpaper {
                  width: 100%;
                  height: 100%;
              }
              #pageflipper p {
                background: none !important;
              }
          </style>
          <script src="${app.net.networkManagerXHR.bestDomain()}/qtOnline.js?v=35"></script>
          <script type="id" id="hiddenid">0;0;0</script>
          </head><body>
              <div class="rctx" id="contextmenu"></div>
              <div id="pageflipper">
                  <div class="pageparent"></div>
              </div>
              <div id="backpaper"></div>
              <div id="dragbar"></div>
              <div id="maincontent"></div>
          </body>`
        );
        _defineProperty(this, "exstyle", st.create(""));
        _defineProperty(this, "cachedStyle", {});
        _defineProperty(this, "pendingReorganize", false);
        _defineProperty(this, "behaviour", {
            way_to_choose_node: {
                bindEvent: function (cw) {
                    var method = app.config.reader.way_to_choose_node;
                    var baseBehaviour = app.reader.behaviour.way_to_choose_node;
                    if (!baseBehaviour[method]) {
                        method = "click";
                    }
                    switch (method) {
                        case "click": {
                            cw.way_to_choose_node = baseBehaviour[method].bind(cw);
                            cw.document.body.addEventListener("click", cw.way_to_choose_node);
                            break;
                        }
                        case "dblclick": {
                            cw.way_to_choose_node = baseBehaviour[method].bind(cw);
                            cw.document.body.addEventListener("click", cw.way_to_choose_node);
                            break;
                        }
                        case "hold": {
                            ui.hold(cw.document.body, baseBehaviour[method].bind(cw));
                            cw.document.body.addEventListener("click", baseBehaviour["triggermenu"]);
                            break;
                        }
                        case "none": {
                            cw.document.body.addEventListener("click", baseBehaviour["triggermenu"]);
                            return;
                        }
                    }
                },
                rebindEvent: function () {
                    var d = app.reader.getDisplay();
                    var cw = d.innerWindow;
                    cw.document.body.removeEventListener("click", cw.way_to_choose_node);
                    cw.document.body.removeEventListener("dblclick", cw.way_to_choose_node);
                    cw.document.body.removeEventListener("click", app.reader.behaviour.way_to_choose_node["triggermenu"]);
                    cw.document.body.unhold && cw.document.body.unhold();
                    this.bindEvent(cw);
                },
            },
            chapter_name_fixed_place: {
                apply: function () {},
            },
            prepend_chapter_name: {
                apply: function () {
                    app.reader.getDisplay().runName();
                },
            },
            tap_actions: {
                description: [
                    {
                        value: "none",
                        name: app.text.none, //"Không",
                    },
                    {
                        value: "go_right",
                        name: app.text.slide_right, //"Trang sau",
                    },
                    {
                        value: "go_left",
                        name: app.text.slide_left, //"Trang trước",
                    },
                    {
                        value: "open_menu",
                        name: app.text.open_menu, //"Mở menu",
                    },
                ],
                go_right: function (cw, view) {
                    app.reader.getDisplay().jumpToNextPage();
                },
                go_left: function (cw, view) {
                    app.reader.getDisplay().jumpToPrevPage();
                },
                open_menu: function (cw, view) {
                    app.reader.toggleMenu();
                },
                none: function (cw, view) {},
            },
        });
        _defineProperty(this, "animator", {
            touchInitX: 0,
            isFirstTouch: false,
            touchInitTime: 0,
            isDragging: false,
            dragElement: null,
            elemInitX: 0,
            dragRangeMax: 0,
            dragRangeMin: 0,
            screenWidth: window.innerWidth,
            direction: null,
            initDrag: function (element, dir) {
                if (!element) {
                    this.dragElement = null;
                    this.isDragging = false;
                    return;
                }
                if (dir == "next" && !element.previousElementSibling) {
                    this.dragElement = null;
                    this.isDragging = false;
                    return;
                }
                this.dragElement = element;
                this.dragElement.style.transition = "none";
                this.isDragging = true;
                this.elemInitX = element.getBoundingClientRect().left;
                this.dragRangeMin = -this.screenWidth;
                this.direction = dir;
            },
            drag: function (x) {
                if (this.isDragging) {
                    var dx = x - this.touchInitX;
                    var newx = this.elemInitX + dx;
                    if (newx > 0) {
                        newx = 0;
                    } else if (newx < this.dragRangeMin) {
                        newx = this.dragRangeMin;
                    }
                    this.dragElement.style.transform = `translate3d(${newx}px, 0, 0)`;
                }
            },
        });
    }
    render() {
        var v = app.render("chapterDisplay-pageflip", {});
        var c = this.getMainContainer();
        v.appendChild(c);
        if (this.root.q(".chapterscroller")) {
            this.root.q(".chapterscroller").remove();
        }
        this.root.appendChild(v);
    }
    getMainContainer() {
        var e = document.createElement("iframe");
        e.className = "chaptercontentflip content";
        var view = e;
        var w = window;
        var isEncrypted = app.reader.encryptedHosts.indexOf(this.host) >= 0;
        var srcdoc = this.baseSrcDoc.replace("{webfont}", app.fontmanager.getFontUrl(isEncrypted));
        var self = this;
        view.onload = function () {
            var cd = this.contentDocument;
            var cw = this.contentWindow;
            self.innerWindow = cw;
            self.behaviour.way_to_choose_node.bindEvent(cw);
            cw.onblur = function () {
                w.preventExit = true;
                console.log(w.preventExit);
            };
            var s = document.createElement("style");
            s.textContent = app.reader.defaultRStyle;
            cd.head.appendChild(s);
            cw.hanvietdic = w.hanvietdic;
            cw.store = app.storage;
            cw.getCookie = w.getCookie;
            cw.container = e;
            cw.thispage = "chapter";
            cw.namew = {
                value: "",
                valueglobal: "",
            };
            cw.disableAnalyzer = true;
            Object.defineProperty(cw.namew, "value", {
                set: function (v) {
                    app.namemanager.updateNameData(v);
                },
                get: function () {
                    return app.namemanager.namedatacache || app.namemanager.namedata.join("\n");
                },
            });
            Object.defineProperty(cw.namew, "valueglobal", {
                set: function (v) {
                    app.namemanager.updateNameData(v);
                },
                get: function () {
                    return app.namemanager.namedatacacheglobal || app.namemanager.nameglobal.join("\n");
                },
            });
            app.reader.loadStart();
            cw.saveNS = function () {
                app.namemanager.saveData();
            };
            cw.excute = cw.excuteApp;
            cw.setting = app.editor.setting;
            cw.pr = function () {};
            app.reader.applyStyle();
            events.set(cd.getElementById("contextmenu"), "view_contextmenu");
            cw.chinesedragbar = new ChineseDragBar(null, cd.getElementById("dragbar"));
            cw.chinesedragbar.onupdate = function (c) {
                app.reader.display.q(".chi").textContent = c;
                app.editor.updateSuggest(cw, c);
            };
            cw.addEventListener(
                "touchstart",
                (cw.ts = function (e) {
                    self.onTouchStart(e);
                })
            );
            cw.addEventListener(
                "touchmove",
                (cw.tm = function (e) {
                    self.onTouchMove(e);
                })
            );
            cw.addEventListener(
                "touchend",
                (cw.te = function (e) {
                    self.onTouchEnd(e);
                })
            );
            cw.addEventListener(
                "touchcancel",
                (cw.tc = function (e) {
                    self.onTouchEnd(e);
                })
            );
            cw.onXhrComplete = function (e) {
                if (e > 0) {
                    clearTimeout(cw.xhrTimeout);
                    cw.xhrTimeout = setTimeout(function () {
                        self.runName();
                    }, 100);
                }
            };
        };
        view.srcdoc = srcdoc;
        return e;
    }
    setContent(text, cdata, view) {
        view.cdata = cdata;
        var hiddenRenderer = this.innerWindow.g("maincontent");
        view.baseHTML = text;
        view.reOrganizePages(hiddenRenderer, false, this.getDisplayHeight());
    }
    ensurePreload(prev, current, next) {
        var self = this;
        if (!current) {
            current = this.currentChapter;
            prev = this.prevChapter;
            next = this.nextChapter;
        }
        if (this.currentFrame && this.currentFrame.page) {
            this.pushPageToScreen(this.currentFrame.page);
        }
        if (prev) {
            console.log(`previd: ${prev.cid}, prev cid: ${current.previd}`);
            if (prev.cid != current.previd && current.previd && current.previd != "0") {
                console.log("preload prev");
                this.preload(app.reader.host, app.reader.id, current.previd, prev);
                current.dragupAble = true;
            } else if (current.previd == "0") {
                prev.remove();
            }
        }
        if (current.previd) {
            current.dragupAble = true;
        } else {
            current.dragupAble = false;
        }
        if (next) {
            console.log("checking next");
            console.log(`nextid: ${next.cid}, nexid: ${current.nextid}`);
            if (next.cid != current.nextid && current.nextid && current.nextid != "0") {
                console.log("preload next");
                this.noNextChap = false;
                this.preload(app.reader.host, app.reader.id, current.nextid, next);
            } else if (current.nextid == "0") {
                next.remove();
                this.noNextChap = true;
            }
        }
        if (current.nextid) {
            current.dragdownAble = true;
        } else {
            current.dragdownAble = false;
            console.log(current.nextid);
        }
        this.pushPageToScreen(this.currentFrame.page);
    }
    loadStart() {
        this.currentFrame = this.innerWindow.q(".pageparent")[0];
        this.flipper = this.innerWindow.q("#pageflipper")[0];
        this.preload(app.reader.host, app.reader.id, app.reader.startid, this.currentChapter, false, true);
    }

    // RENDERER
    getDisplayHeight() {
        var paddingTop = parseInt(this.cachedStyle.borderTop || 0),
            paddingBottom = parseInt(this.cachedStyle.borderBottom || 0);
        return (
            this.innerWindow.q(".pageparent")[0].offsetHeight - paddingTop - paddingBottom - 20 // give some space at bottom
        );
    }
    pushPageToScreen(page) {
        if (!page) {
            return;
        }
        var pages = [
            ...this.prevChapter.pageElements,
            ...this.currentChapter.pageElements,
            ...this.nextChapter.pageElements,
        ];
        var index = pages.indexOf(page);
        if (index == -1) {
            return;
        }
        this.currentPageId = this.currentChapter.pageElements.indexOf(page);
        var prevFrame = this.currentFrame.nextElementSibling;
        var toAddNext = false;
        var toAddPrev = false;
        if (!prevFrame && index > 0) {
            prevFrame = this.createFrame();
            prevFrame.style.transform = `translate3d(-${this.screenWidth}px, 0, 0)`;
            prevFrame.appendChild(pages[index - 1]);
            prevFrame.page = pages[index - 1];
            toAddPrev = prevFrame;
        } else if (prevFrame && prevFrame.page != pages[index - 1] && index > 0) {
            prevFrame.page = pages[index - 1];
            prevFrame.innerHTML = "";
            prevFrame.appendChild(pages[index - 1]);
        } else if (prevFrame && index == 0) {
            prevFrame.remove();
        }
        var nextFrame = this.currentFrame.previousElementSibling;
        if (!nextFrame && index < pages.length - 1) {
            nextFrame = this.createFrame();
            nextFrame.style.transform = `translate3d(0px, 0, 0)`;
            nextFrame.appendChild(pages[index + 1]);
            nextFrame.page = pages[index + 1];
            toAddNext = nextFrame;
        } else if (nextFrame && nextFrame.page != pages[index + 1] && index < pages.length - 1) {
            nextFrame.page = pages[index + 1];
            nextFrame.innerHTML = "";
            nextFrame.appendChild(pages[index + 1]);
        } else if (nextFrame && index == pages.length - 1) {
            nextFrame.remove();
        }
        if (toAddNext) {
            this.flipper.insertBefore(toAddNext, this.currentFrame);
        }
        if (toAddPrev) {
            this.flipper.appendChild(toAddPrev);
        }
        this.invokePreloaderOnScreen();
        this.recycle();
    }
    recycle() {
        var index = Array.from(this.flipper.children).indexOf(this.currentFrame);
        while (index > 1) {
            this.flipper.children[0].remove();
            index--;
        }
        while (this.flipper.children.length > 3) {
            this.flipper.children[this.flipper.children.length - 1].remove();
        }
        app.reader.updateCnameAndProgress();
    }
    invokePreloaderOnScreen() {
        if (this.currentFrame && this.currentFrame.querySelector(".chapterpreloader")) {
            this.currentFrame.querySelector(".chapterpreloader").onEnterScreen &&
                this.currentFrame.querySelector(".chapterpreloader").onEnterScreen();
        }
    }
    jumpToPage(page) {
        if (
            !page ||
            (this.prevChapter.pageElements.indexOf(page) < 0 &&
                this.currentChapter.pageElements.indexOf(page) < 0 &&
                this.nextChapter.pageElements.indexOf(page) < 0)
        ) {
            return;
        }
        if (this.currentFrame && this.currentFrame.page == page) {
            if (this.currentFrame.page == this.currentFrame.firstChild) {
                this.invokePreloaderOnScreen();
                return;
            }
        }
        this.currentFrame.style.transform = "translate3d(0, 0, 0)";
        this.currentFrame.page = page;
        this.currentFrame.innerHTML = "";
        this.currentFrame.appendChild(page);
        this.pushPageToScreen(page);
    }
    createFrame() {
        var e = document.createElement("div");
        e.className = "pageparent";
        return e;
    }
    async preload(h, i, c, view, rl, start) {
        if (c == "0" || !c) {
            return;
        }
        view.cid = c;
        this.setLoading(view);
        if (start) {
            this.jumpToPage(view.firstPage());
            this.currentFrame.innerHTML = view.firstPage().outerHTML; // fix a weird bug
        }
        var cdata = await app.reader.getContent(h, i, c, rl);
        if (cdata.code == "0") {
            window.failedIn5Times = 0;
            var text = app.reader.preprocess(h, cdata.data);
            this.setContent(text, cdata, view);
            this.setNotLoading(view);
            if (start) {
                this.jumpToPage(view.firstPage());
            }
            await this.assignNavigator(h, i, c, cdata, view);
            if (start) {
                app.reader.updateHistory(h, i, c, cdata);
                this.ensurePreload(this.prevChapter, this.currentChapter, this.nextChapter);
            }
            if (view == this.currentChapter) {
                app.reader.updateCnameAndProgress();
            }
        } else {
            this.setNotLoading(view);
            app.reader.handlingException(cdata, view);
        }
    }
    async assignNavigator(h, i, c, x, chapterObj) {
        var forceget = ["trxc", "bxwxorg", "faloo", "biquge", "fanqie"];
        if (forceget.indexOf(h) > -1) {
            x.next = 0;
            x.prev = 0;
        }
        var nextid = x.next;
        var previd = x.prev;
        chapterObj.previd = previd;
        chapterObj.nextid = nextid;
        chapterObj.cid = c;
        if (h == "surf") {
            return;
        }
        if (chapterObj.previd == 0 || chapterObj.nextid == 0) {
            var nani = await app.reader.getChapterNavigator(h, i, c);
            if (parseInt(nani.next) != 0) {
                chapterObj.nextid = nani.next;
                this.noNextChap = false;
            } else {
                this.noNextChap = true;
            }
            if (parseInt(nani.prev) != 0) {
                chapterObj.previd = nani.prev;
            }
            this.ensurePreload();
        }
    }
    setLoading(chapter) {
        var pl = app.render("preloader", {
            msg: app.text.loading_content,
            icon: "",
        });
        pl.classList.add("chapterpreloader");
        pl.onEnterScreen = function () {
            pl.q(".icon").innerHTML = _gif_book;
        };
        var d = document.createElement("div");
        d.appendChild(pl);
        d.className = "waitpreloader1";
        chapter.setPages([[d]]);
        if (chapter == this.currentChapter) {
            this.jumpToPage(chapter.firstPage());
        }
    }
    setNotLoading(chapter) {
        chapter.setPages(chapter.pages.filter((e) => e.find((f) => f.classList.contains("waitpreloader1")) == null));
        if (chapter == this.currentChapter) {
            if (this.currentPageId > this.currentChapter.pages.length) {
                this.jumpToPage(chapter.lastPage());
            }
        }
    }
    getPCN() {
        return {
            prev: this.prevChapter,
            current: this.currentChapter,
            next: this.nextChapter,
        };
    }
    getCurrentChapter() {
        return this.currentChapter;
    }
    goNextChapter(isTTS) {
        if (this.lockNavBtn) {
            return;
        }
        if (this.nextChapter && this.nextChapter.cid != "0" && this.nextChapter.cid) {
            this.prevChapter = this.currentChapter;
            this.currentChapter = this.nextChapter;
            this.nextChapter = new PageClipChapter();
            this.jumpToPage(this.currentChapter.firstPage());
            app.reader.updateHistory2();
            this.ensurePreload();
            if (isTTS) {
                app.tts.changeChapter();
            }
        }
    }
    goPrevChapter() {
        if (this.lockNavBtn) {
            return;
        }
        if (this.prevChapter && this.prevChapter.cid != "0" && this.prevChapter.cid) {
            this.nextChapter = this.currentChapter;
            this.currentChapter = this.prevChapter;
            this.prevChapter = new PageClipChapter();
            this.jumpToPage(this.currentChapter.firstPage());
            app.reader.updateHistory2();
            this.ensurePreload();
        }
    }
    getRoot() {
        return this.root;
    }
    rightTapAction() {
        var view = this.currentChapter;
        var method = app.config.reader.right_tap_action;
        if (!this.behaviour.tap_actions[method]) {
            method = "none";
        }
        this.behaviour.tap_actions[method](this.innerWindow, view);
    }
    leftTapAction() {
        var view = this.currentChapter;
        var method = app.config.reader.left_tap_action;
        if (!this.behaviour.tap_actions[method]) {
            method = "none";
        }
        this.behaviour.tap_actions[method](this.innerWindow, view);
    }
    reloadCurrentChapter(rl) {
        this.removeAlert(this.currentChapter);
        this.currentChapter.resetValue();
        this.preload(app.reader.host, app.reader.id, this.currentChapter.cid, this.currentChapter, rl, true);
    }
    reloadAllChapter() {
        this.currentChapter.resetValue();
        this.prevChapter.resetValue();
        this.nextChapter.resetValue();
        this.preload(app.reader.host, app.reader.id, this.currentChapter.cid, this.currentChapter);
        setTimeout(() => {
            this.preload(app.reader.host, app.reader.id, this.nextChapter.cid, this.nextChapter);
        }, 3000);
        setTimeout(() => {
            this.preload(app.reader.host, app.reader.id, this.prevChapter.cid, this.prevChapter);
        }, 6000);
    }
    changeCurrentChapter(targetId) {
        this.removeAlert(this.currentChapter);
        this.currentChapter.resetValue();
        this.preload(app.reader.host, app.reader.id, targetId, this.currentChapter, false, true);
    }
    showAlert(msg, chapter) {
        var mct = document.createElement("div");
        mct.innerHTML = `
              <div class="erroralert" style="width:100%;height:100%;min-height:calc(100vh - 100px);position:relative;">
              <div style="position: absolute;width:80%;left: 50%;top: 50%;transform: translate(-50%, -50%);
              text-align: center;font-size: 20px;">
                  <div>${msg}</div>
                  <div class="btn" style="display: inline-block;border-radius: 8px;border-color: white;border-width: 2px;
                  border-style: solid;padding: 6px 12px;margin: 20px;">Tải lại</div>
              </div></div>
          `;
        mct.className = "erroralert1";
        var btn = mct.querySelector(".btn");
        btn.addEventListener("click", function (e) {
            window.failedIn5Times = 0;
            app.reader.reloadCurrentChapter();
            e.stopPropagation();
            app.platform.nativeclick();
        });
        chapter.setPages([[mct]]);
        if (chapter == this.currentChapter) {
            this.jumpToPage(chapter.firstPage());
        }
    }
    removeAlert(chapter) {
        chapter.setPages(chapter.pages.filter((e) => e.find((f) => f.classList.contains("erroralert1")) == null));
        if (chapter == this.currentChapter) {
            if (this.currentPageId > this.currentChapter.pages.length) {
                this.jumpToPage(chapter.lastPage());
            }
        }
    }
    getChapterNameAndProgress() {
        if (this.currentChapter.cdata) {
            return {
                name: this.currentChapter.cdata.chaptername,
                progress: (this.currentPageId / (this.currentChapter.pages.length - 1)) * 1000,
            };
        }
        return {
            name: "",
            progress: 0,
        };
    }
    gotoProgress(p) {
        var page = Math.round((p / 1000) * (this.currentChapter.pageElements.length - 1));
        this.jumpToPage(this.currentChapter.pageElements[page]);
    }
    onBackgroundImageLoaded(url, bg) {
        this.exstyle.set(".page", {
            backgroundImage: `url(${url})`,
            backgroundSize: "100vw 100vh",
            backgroundColor: bg,
        });
        this.useBackgroundImage = true;
        this.backgroundImage = url;
    }
    applyStyleChange(stl, reOrganize = true) {
        if (!this.innerWindow) {
            return;
        }
        var innerExStyle = this.innerWindow.g("exstyle");
        if (!innerExStyle) {
            this.innerWindow.document.head.appendChild(this.exstyle);
            this.exstyle.id = "exstyle";
        }
        if (stl.padding != this.cachedStyle.padding) {
            this.exstyle.set("#maincontent", {
                padding: "0",
            });
            this.exstyle.set("#maincontent p", {
                padding: stl.padding,
            });
            this.cachedStyle.padding = stl.padding;
        }
        if (stl.backgroundColor && stl.backgroundColor != this.cachedStyle.backgroundColor) {
            if (stl.backgroundImageId && this.useBackgroundImage) {
                this.exstyle.set(".page", {
                    backgroundImage: `url(${this.backgroundImage})`,
                    backgroundColor: stl.backgroundColor,
                    backgroundSize: "100% 100%",
                });
                this.exstyle.set(".chaptertopinfo", {
                    backgroundColor: "transparent",
                });
            } else if (stl.backgroundImageId && !this.useBackgroundImage) {
                this.exstyle.set(".page", {
                    backgroundImage: "none",
                    backgroundColor: stl.backgroundColor,
                });
            } else {
                this.exstyle.set(".page", {
                    backgroundColor: stl.backgroundColor,
                });
            }
            this.cachedStyle.backgroundColor = stl.backgroundColor;
        }
        if (stl.borderTop != this.cachedStyle.borderTop || stl.borderBottom != this.cachedStyle.borderBottom) {
            this.exstyle.set(".pageparent", {
                paddingTop: parseInt(stl.borderTop) + "px",
                paddingBottom: parseInt(stl.borderBottom) + "px",
            });
            this.cachedStyle.borderTop = stl.borderTop;
            this.cachedStyle.borderBottom = stl.borderBottom;
        }
        if (reOrganize) {
            var wheight = this.getDisplayHeight();
            var renderer = this.innerWindow.g("maincontent");
            this.currentChapter.reOrganizePages(renderer, false, wheight);
            if (app.tts.player.isPlaying) {
                app.tts.player.generateSentences(false);
                app.tts.player.play();
            }
            clearTimeout(this.pendingReorganize);
            this.pendingReorganize = setTimeout(
                (() => {
                    this.nextChapter.reOrganizePages(renderer, false, wheight);
                    this.prevChapter.reOrganizePages(renderer, false, wheight);
                }).bind(this),
                1000
            ); // wait for 1s before reorganize next and prev chapter
            if (this.currentPageId >= this.currentChapter.pages.length && this.currentChapter.pages.length > 0) {
                this.jumpToPage(this.currentChapter.lastPage());
            }
        }
    }
    runName() {
        if (this.animator.dragElement) {
            return;
        }
        var wheight = this.getDisplayHeight();
        var renderer = this.innerWindow.g("maincontent");
        this.currentChapter.reOrganizePages(renderer, false, wheight);
        if (app.tts.player.isPlaying) {
            app.tts.player.generateSentences(false);
            app.tts.player.play();
        }
        this.nextChapter.reOrganizePages(renderer, false, wheight);
        this.prevChapter.reOrganizePages(renderer, false, wheight);
        if (this.currentPageId >= this.currentChapter.pages.length) {
            this.jumpToPage(this.currentChapter.lastPage());
        }
    }
    hideContextMenu() {
        this.innerWindow.g("contextmenu").hide();
    }
    unlockNameSelect() {
        this.innerWindow.unlock();
    }
    getCurrentWindow() {
        return this.innerWindow;
    }
    onTouchStart(e) {
        this.animator.touchInitX = e.touches[0].clientX;
        this.animator.isFirstTouch = true;
        this.animator.touchInitTime = Date.now();
    }
    onTouchMove(e) {
        var x = e.touches[0].clientX;
        if (this.animator.isFirstTouch) {
            var dx = x - this.animator.touchInitX;
            if (dx > 0) {
                this.animator.initDrag(this.currentFrame.nextElementSibling, "prev");
            } else if (dx < 0) {
                this.animator.initDrag(this.currentFrame, "next");
            }
            this.animator.isFirstTouch = false;
        }
        if (this.animator.isDragging) {
            this.animator.drag(x);
        }
    }
    onTouchEnd(e) {
        if (this.animator.isDragging) {
            if (this.animator.direction == "prev") {
                var dx = e.changedTouches[0].clientX - this.animator.touchInitX;
                if (dx > 10 && Date.now() - this.animator.touchInitTime < 200) {
                    this.jumpToPrevPage();
                } else if (dx > this.screenWidth / 3) {
                    this.jumpToPrevPage();
                } else {
                    this.animator.dragElement.style.transition = "transform 0.3s";
                    this.animator.dragElement.style.transform = `translate3d(-100%, 0, 0)`;
                }
            }
            if (this.animator.direction == "next") {
                var dx = e.changedTouches[0].clientX - this.animator.touchInitX;
                if (dx < -10 && Date.now() - this.animator.touchInitTime < 200) {
                    this.jumpToNextPage();
                } else if (dx < -this.screenWidth / 3) {
                    this.jumpToNextPage();
                } else {
                    this.animator.dragElement.style.transition = "transform 0.3s";
                    this.animator.dragElement.style.transform = `translate3d(0px, 0, 0)`;
                }
            }
            this.animator.isDragging = false;
            this.animator.dragElement = null;
        }
    }
    onTouchCancel(e) {
        if (this.animator.isDragging) {
            if (this.animator.direction == "prev") {
                this.animator.dragElement.style.transition = "transform 0.3s";
                this.animator.dragElement.style.transform = `translate3d(-100%, 0, 0)`;
            } else if (this.animator.direction == "next") {
                this.animator.dragElement.style.transition = "transform 0.3s";
                this.animator.dragElement.style.transform = `translate3d(0, 0, 0)`;
            }
            this.animator.isDragging = false;
            this.animator.dragElement = null;
        }
    }
    jumpToNextPage() {
        var nextFrame = this.currentFrame.previousElementSibling;
        if (nextFrame) {
            this.currentFrame.style.transition = "transform 0.3s";
            this.currentFrame.style.transform = `translate3d(-100%, 0, 0)`;
            this.currentFrame = nextFrame;
            if (this.nextChapter.pageElements.indexOf(nextFrame.page) == 0) {
                this.prevChapter = this.currentChapter;
                this.currentChapter = this.nextChapter;
                this.nextChapter = new PageClipChapter();
                this.ensurePreload();
                app.reader.updateHistory2();
            }
            this.pushPageToScreen(nextFrame.page);
        }
    }
    jumpToPrevPage() {
        var prevFrame = this.currentFrame.nextElementSibling;
        if (prevFrame) {
            prevFrame.style.transition = "transform 0.3s";
            prevFrame.style.transform = `translate3d(0, 0, 0)`;
            this.currentFrame = prevFrame;
            var idxPrev = this.prevChapter.pageElements.indexOf(prevFrame.page);
            if (idxPrev == this.prevChapter.pageElements.length - 1 && idxPrev >= 0) {
                this.nextChapter = this.currentChapter;
                this.currentChapter = this.prevChapter;
                this.prevChapter = new PageClipChapter();
                this.ensurePreload();
                app.reader.updateHistory2();
            }
            this.pushPageToScreen(prevFrame.page);
        }
    }
    absorb(oldDisplay) {
        if (!(oldDisplay instanceof PageFlipChapterDisplay)) {
            return;
        }
        // copy all properties from oldDisplay to this
        var exclude = ["animator", "baseSrcDoc", "behaviour"];
        for (var key in oldDisplay) {
            if (exclude.indexOf(key) == -1) {
                this[key] = oldDisplay[key];
            }
        }
        this.innerWindow.removeEventListener("touchstart", this.innerWindow.ts);
        this.innerWindow.removeEventListener("touchmove", this.innerWindow.tm);
        this.innerWindow.removeEventListener("touchend", this.innerWindow.te);
        this.innerWindow.removeEventListener("touchcancel", this.innerWindow.tc);
        this.innerWindow.addEventListener("touchstart", (this.innerWindow.ts = this.onTouchStart.bind(this)));
        this.innerWindow.addEventListener("touchmove", (this.innerWindow.tm = this.onTouchMove.bind(this)));
        this.innerWindow.addEventListener("touchend", (this.innerWindow.te = this.onTouchEnd.bind(this)));
        this.innerWindow.addEventListener("touchcancel", (this.innerWindow.tc = this.onTouchCancel.bind(this)));
        app.reader.applyStyle();
        return this;
    }
    tokenizeSentence() {
        var findFullSentence = function (startNode) {
            var sen = [];
            var allSens = [];
            while (startNode != null) {
                var tagName = startNode.tagName,
                    nodeType = startNode.nodeType;
                if (tagName == "I" && startNode.id[0] != "e") {
                    sen.push(startNode);
                } else if (nodeType == 3 || tagName == "I") {
                    if (startNode.textContent.includes("“")) {
                        if (sen.length > 0) {
                            allSens.push(sen);
                            sen = [];
                        }
                        sen.push(startNode);
                    } else if (startNode.textContent.includes("”")) {
                        sen.push(startNode);
                        allSens.push(sen);
                        sen = [];
                    } else if (startNode.textContent.includes(",")) {
                        sen.push(startNode);
                    } else if (startNode.textContent.includes(".")) {
                        sen.push(startNode);
                        allSens.push(sen);
                        sen = [];
                    } else {
                        sen.push(startNode);
                    }
                }
                startNode = startNode.nextSibling;
                if (startNode == null) {
                    allSens.push(sen);
                    sen = [];
                }
            }
            return allSens;
        };
        var allSens = [];
        var self = this;
        var viRgx = this.getCurrentWindow().speaker.viRgx;
        for (var i = 0; i < this.currentChapter.pageElements.length; i++) {
            let page = this.currentChapter.pageElements[i];
            var childs = page.children;
            for (var j = 0; j < childs.length; j++) {
                if (childs[j].tagName == "P") {
                    if (childs[j].querySelector("i") != null) {
                        var startNode = childs[j].querySelector("i");
                        var sens = findFullSentence(startNode);
                        for (var k = 0; k < sens.length; k++) {
                            var sen = sens[k];
                            sen.highlightOn = function () {
                                for (var l = 0; l < this.length; l++) {
                                    var e = this[l];
                                    if (e.tagName == "I") {
                                        e.style.color = "red";
                                    }
                                }
                                self.jumpToPage(page);
                            };
                            sen.highlightOff = function () {
                                for (var l = 0; l < this.length; l++) {
                                    var e = this[l];
                                    if (e.tagName == "I") {
                                        e.style.color = "";
                                    }
                                }
                            };
                            sen.toText = function () {
                                var text = "";
                                for (var i = 0; i < this.length; i++) {
                                    if (this[i].tagName == "I") {
                                        if (this[i].gT().length > 0 || this[i].textContent.match(viRgx)) {
                                            text += " " + this[i].textContent;
                                        }
                                    } else {
                                        text += " " + this[i].textContent;
                                    }
                                }
                                return text;
                            };
                            allSens.push(sen);
                        }
                    }
                }
            }
        }
        return allSens;
    }
}
class SimulatedPageFlipChapterDisplay extends PageFlipChapterDisplay {
    constructor(root) {
        super(root);
        _defineProperty(this, "animator", {
            touchInitX: 0,
            touchInitY: 0,
            touchCX: 0,
            touchCY: 0,
            isFirstTouch: false,
            touchInitTime: 0,
            isDragging: false,
            dragElement: null,
            dragElementBound: null,
            screenWidth: window.innerWidth,
            screenHeight: window.innerHeight,
            direction: null,
            edgeTop: null,
            edgeBottom: null,
            animatingLock: false,
            frameFinish: true,
            animationTime: 300,
            // ms
            composePolygon: function (p1, p2) {
                if (p1.y > 0) {
                    return `polygon(0 0, ${this.screenWidth}px 0, ${p1.x}px ${p1.y}px, ${p2.x}px ${p2.y}px, 0 ${this.screenHeight}px)`;
                }
                if (p2.y < this.screenHeight) {
                    return `polygon(0 0, ${p1.x}px ${p1.y}px, ${p2.x}px ${p2.y}px, ${this.screenWidth}px ${this.screenHeight}px, 0 ${this.screenHeight}px)`;
                }
                return `polygon(0 0, ${p1.x - 1}px ${p1.y}px, ${p1.x}px ${p1.y}px, ${p2.x}px ${p2.y}px, 0 ${
                    this.screenHeight
                }px)`;
            },
            computeSymmetricPoint: function (p, p1, p2) {
                let A = p2.y - p1.y;
                let B = p1.x - p2.x;
                let C = p2.x * p1.y - p1.x * p2.y;
                let D = (A * p.x + B * p.y + C) / (A * A + B * B);
                let qx = p.x - 2 * A * D;
                let qy = p.y - 2 * B * D;
                return {
                    x: qx,
                    y: qy,
                };
            },
            composeSymmetricPolygon: function (p1, p2) {
                if (p1.y > 0) {
                    var pSym = this.computeSymmetricPoint(
                        {
                            x: this.screenWidth,
                            y: this.screenHeight,
                        },
                        p1,
                        p2
                    );
                    return `polygon(${p1.x}px ${p1.y}px, ${pSym.x}px ${pSym.y}px, ${p2.x}px ${p2.y}px)`; // triangle
                }
                if (p2.y < this.screenHeight) {
                    var pSym = this.computeSymmetricPoint(
                        {
                            x: this.screenWidth,
                            y: 0,
                        },
                        p1,
                        p2
                    );
                    return `polygon(${p1.x}px ${p1.y}px, ${pSym.x}px ${pSym.y}px, ${p2.x}px ${p2.y}px)`; // triangle
                }
                var pSym1 = this.computeSymmetricPoint(
                    {
                        x: this.screenWidth,
                        y: 0,
                    },
                    p1,
                    p2
                );
                var pSym2 = this.computeSymmetricPoint(
                    {
                        x: this.screenWidth,
                        y: this.screenHeight,
                    },
                    p1,
                    p2
                );
                return `polygon(${p1.x}px ${p1.y}px, ${pSym1.x}px ${pSym1.y}px, ${pSym2.x}px ${pSym2.y}px, ${p2.x}px ${p2.y}px)`; // quadrilateral
            },
            initDrag: function (element, dir) {
                if (!element || this.animatingLock) {
                    this.dragElement = null;
                    this.isDragging = false;
                    return;
                }
                if (dir == "next" && !element.previousElementSibling) {
                    this.dragElement = null;
                    this.isDragging = false;
                    return;
                }
                this.dragElement = element;
                this.isDragging = true;
                this.direction = dir;
                this.screenHeight = window.innerHeight;
                this.screenWidth = window.innerWidth;
                this.dragElementBound = this.dragElement.getBoundingClientRect();
                if (dir == "prev") {
                    this.dragElement.style.transition = "none";
                    this.dragElement.style.transform = `translate3d(0, 0, 0)`;
                    this.clipP1 = {
                        x: 2,
                        y: 0,
                    };
                    this.clipP2 = {
                        x: 2,
                        y: this.screenHeight,
                    };
                    this.dragElement.style.clipPath = this.composePolygon(this.clipP1, this.clipP2);
                } else if (dir == "next") {
                    this.dragElement.style.transition = "none";
                    this.clipP1 = {
                        x: this.screenWidth,
                        y: 0,
                    };
                    this.clipP2 = {
                        x: this.screenWidth,
                        y: this.screenHeight,
                    };
                    this.dragElement.style.clipPath = this.composePolygon(this.clipP1, this.clipP2);
                }
            },
            createBackPaper: function (paper, dir) {
                var cv = new SimulatedBackPaperCanvas(this.screenWidth, this.screenHeight);
                if (!paper.querySelector("img")) {
                    // use hardware acceleration
                    cv.loadPaper(paper, () => {
                        if (dir == "prev") {
                            paper.style.transform = `translate3d(-${this.screenWidth}px, 0, 0)`;
                        }
                    });
                }
                var display = app.reader.getDisplay();
                cv.setPaperColor(display.cachedStyle.backgroundColor);
                display.innerWindow.g("backpaper").appendChild(cv.canvas);
                return cv;
            },
            moveDragPoint: function (dx, dy) {
                var c1 = this.clipP1,
                    c2 = this.clipP2;
                var clamp = function (val, min, max) {
                    return Math.min(Math.max(val, min), max);
                };
                if (this.direction == "prev") {
                    if (c1.y > 0) {
                        c1.y += dx + dy;
                        if (c1.y > this.screenHeight - 20) {
                            c1.y = this.screenHeight - 20;
                        }
                        if (c1.y < 0) {
                            var reMain = c1.y;
                            c1.y = 0;
                            c1.x -= reMain;
                            c1.x = clamp(c1.x, 2, this.screenWidth);
                        }
                    } else {
                        c1.x += dx + dy;
                        if (c1.x < 2) {
                            c1.x = 2;
                        }
                        if (c1.x > this.screenWidth) {
                            var reMain = c1.x - this.screenWidth;
                            c1.x = this.screenWidth;
                            c1.y += reMain;
                            c1.y = clamp(c1.y, 0, this.screenHeight - 20);
                        }
                    }
                    if (c2.y < this.screenHeight) {
                        c2.y += dx - dy;
                        if (c2.y < 20) {
                            c2.y = 20;
                        }
                        if (c2.y > this.screenHeight) {
                            var reMain = c2.y - this.screenHeight;
                            c2.y = this.screenHeight;
                            c2.x -= reMain;
                            c2.x = clamp(c2.x, 2, this.screenWidth);
                        }
                    } else {
                        c2.x += dx - dy;
                        if (c2.x < 2) {
                            c2.x = 2;
                        }
                        if (c2.x > this.screenWidth) {
                            var reMain = c2.x - this.screenWidth;
                            c2.x = this.screenWidth;
                            c2.y -= reMain;
                            c2.y = clamp(c2.y, 20, this.screenHeight);
                        }
                    }
                } else {
                    if (c1.y > 0) {
                        c1.y += dx - dy;
                        if (c1.y > this.screenHeight - 20) {
                            c1.y = this.screenHeight - 20;
                        }
                        if (c1.y < 0) {
                            var reMain = c1.y;
                            c1.y = 0;
                            c1.x -= reMain;
                            c1.x = clamp(c1.x, 2, this.screenWidth);
                        }
                    } else {
                        c1.x += dx - dy;
                        if (c1.x < 2) {
                            c1.x = 2;
                        }
                        if (c1.x > this.screenWidth) {
                            var reMain = c1.x - this.screenWidth;
                            c1.x = this.screenWidth;
                            c1.y += reMain;
                            c1.y = clamp(c1.y, 0, this.screenHeight - 20);
                        }
                    }
                    if (c2.y < this.screenHeight) {
                        c2.y += dx + dy;
                        if (c2.y < 20) {
                            c2.y = 20;
                        }
                        if (c2.y > this.screenHeight) {
                            var reMain = c2.y - this.screenHeight;
                            c2.y = this.screenHeight;
                            c2.x -= reMain;
                            c2.x = clamp(c2.x, 2, this.screenWidth);
                        }
                    } else {
                        c2.x += dx + dy;
                        if (c2.x < 2) {
                            c2.x = 2;
                        }
                        if (c2.x > this.screenWidth) {
                            var reMain = c2.x - this.screenWidth;
                            c2.x = this.screenWidth;
                            c2.y -= reMain;
                            c2.y = clamp(c2.y, 20, this.screenHeight);
                        }
                    }
                }
                if (c1.y > 0 && c2.y < this.screenHeight) {
                    c1.y = 0;
                    c2.y = this.screenHeight;
                }
            },
            drag: function (x, y) {
                if (!this.backPaper) {
                    this.backPaper = this.createBackPaper(this.dragElement, this.direction);
                }
                var self = this;
                var dragX = x - this.touchCX;
                var dragY = y - this.touchCY;
                this.touchCX = x;
                this.touchCY = y;
                this.moveDragPoint(dragX, dragY);
                self.dragElement.clipP1 = self.clipP1;
                self.dragElement.clipP2 = self.clipP2;
                if (this.frameFinish) {
                    requestAnimationFrame(() => {
                        try {
                            self.backPaper.draw(self.clipP1, self.clipP2);
                            if (!self.backPaper.paper) {
                                self.dragElement.style.clipPath = self.composePolygon(self.clipP1, self.clipP2);
                            }
                        } catch (e) {}
                        self.frameFinish = true;
                    });
                }
            },
            removeBackPaper: function (t) {
                if (this.backPaper) {
                    if (t) {
                        this.backPaper.remove();
                    }
                    this.backPaper = null;
                }
            },
            getEdgeTop: function () {
                return {
                    x: this.screenWidth,
                    y: 0,
                };
            },
            getEdgeBottom: function () {
                return {
                    x: this.screenWidth,
                    y: this.screenHeight,
                };
            },
            getAnimationTimeFloat: function () {
                return Math.round((this.animationTime / 1000) * 100) / 100;
            },
            animatePageIn: function (element) {
                var currentClipPath = element.style.clipPath;
                this.animatingLock = true;
                if (currentClipPath == "none" || currentClipPath == "") {
                    var backPaper = this.createBackPaper(element);
                    element.style.transform = "translate3d(0, 0, 0)";
                    var initP1 = {
                            x: 2,
                            y: 0,
                        },
                        initP2 = {
                            x: 2,
                            y: this.screenHeight,
                        },
                        endP1 = {
                            x: this.screenWidth,
                            y: 0,
                        },
                        endP2 = {
                            x: this.screenWidth,
                            y: this.screenHeight,
                        };
                    backPaper.runAnimation(initP1, initP2, endP1, endP2, element, this, this.animationTime);
                } else {
                    var backPaper = this.backPaper || this.createBackPaper(element);
                    var clipP1 = element.clipP1;
                    var clipP2 = element.clipP2;
                    var end1 = {
                            x: this.screenWidth,
                            y: 0,
                        },
                        end2 = {
                            x: this.screenWidth,
                            y: this.screenHeight,
                        };
                    if (clipP1) {
                        end1.y = clipP1.y;
                    }
                    if (clipP2) {
                        end2.y = clipP2.y;
                    }
                    backPaper.runAnimationTo(end1, end2, element, this, this.animationTime);
                }
            },
            animatePageOut: function (element) {
                this.animatingLock = true;
                var self = this;
                var currentClipPath = element.style.clipPath;
                if (currentClipPath == "none" || currentClipPath == "") {
                    var backPaper = this.createBackPaper(element);
                    var initP1 = {
                            x: this.screenWidth,
                            y: 0,
                        },
                        initP2 = {
                            x: this.screenWidth,
                            y: this.screenHeight,
                        },
                        endP1 = {
                            x: 2,
                            y: 0,
                        },
                        endP2 = {
                            x: 2,
                            y: this.screenHeight,
                        };
                    backPaper.runAnimation(initP1, initP2, endP1, endP2, element, this, this.animationTime);
                } else {
                    var backPaper = this.backPaper || this.createBackPaper(element);
                    var end1 = {
                            x: 2,
                            y: 0,
                        },
                        end2 = {
                            x: 2,
                            y: this.screenHeight,
                        };
                    backPaper.runAnimationTo(end1, end2, element, this, this.animationTime);
                }
            },
        });
        _defineProperty(this, "sfx", {
            audio: null,
            play: function () {
                if (!app.config.reader.page_flip_sound) return;
                if (!this.audio) {
                    this.audio = new Audio(`${app.net.networkManagerXHR.bestDomain()}/page-flip.mp3`);
                }
                this.audio.currentTime = 0;
                this.audio.play();
            },
        });
    }
    onTouchStart(e) {
        this.animator.touchInitX = e.touches[0].clientX;
        this.animator.touchInitY = e.touches[0].clientY;
        this.animator.isFirstTouch = true;
        this.animator.touchInitTime = Date.now();
    }
    onTouchMove(e) {
        var x = e.touches[0].clientX;
        var y = e.touches[0].clientY;
        if (this.animator.isFirstTouch) {
            var dx = x - this.animator.touchInitX;
            if (dx > 0) {
                this.animator.initDrag(this.currentFrame.nextElementSibling, "prev");
            } else if (dx < 0) {
                this.animator.initDrag(this.currentFrame, "next");
            }
            this.animator.isFirstTouch = false;
            this.animator.touchCX = x;
            this.animator.touchCY = y;
        }
        if (this.animator.isDragging) {
            this.animator.drag(x, y);
        }
    }
    onTouchEnd(e) {
        if (this.animator.isDragging) {
            if (this.animator.direction == "prev") {
                var dx = e.changedTouches[0].clientX - this.animator.touchInitX;
                if (dx > 10 && Date.now() - this.animator.touchInitTime < 200) {
                    this.jumpToPrevPage();
                } else if (dx > this.screenWidth / 3) {
                    this.jumpToPrevPage();
                } else {
                    this.animator.animatePageOut(this.animator.dragElement); // restore
                }
            }
            if (this.animator.direction == "next") {
                var dx = e.changedTouches[0].clientX - this.animator.touchInitX;
                if (dx < -10 && Date.now() - this.animator.touchInitTime < 200) {
                    this.jumpToNextPage();
                } else if (dx < -this.screenWidth / 3) {
                    this.jumpToNextPage();
                } else {
                    this.animator.animatePageIn(this.animator.dragElement); // restore
                }
            }
            this.animator.isDragging = false;
            this.animator.dragElement = null;
            this.animator.removeBackPaper();
        }
    }
    onTouchCancel(e) {
        if (this.animator.isDragging) {
            if (this.animator.direction == "prev") {
                this.animator.animatePageOut(this.animator.dragElement);
            } else if (this.animator.direction == "next") {
                this.animator.animatePageIn(this.animator.dragElement);
            }
            this.animator.isDragging = false;
            this.animator.dragElement = null;
        }
        this.animator.removeBackPaper(true);
    }
    jumpToNextPage() {
        var nextFrame = this.currentFrame.previousElementSibling;
        if (nextFrame) {
            this.animator.animatePageOut(this.currentFrame);
            this.currentFrame = nextFrame;
            if (this.nextChapter.pageElements.indexOf(nextFrame.page) == 0) {
                this.prevChapter = this.currentChapter;
                this.currentChapter = this.nextChapter;
                this.nextChapter = new PageClipChapter();
                this.ensurePreload();
                app.reader.updateHistory2();
            }
            this.pushPageToScreen(nextFrame.page);
            this.sfx.play();
        }
    }
    jumpToPrevPage() {
        var prevFrame = this.currentFrame.nextElementSibling;
        if (prevFrame) {
            this.animator.animatePageIn(prevFrame);
            this.currentFrame = prevFrame;
            var idxPrev = this.prevChapter.pageElements.indexOf(prevFrame.page);
            if (idxPrev == this.prevChapter.pageElements.length - 1 && idxPrev >= 0) {
                this.nextChapter = this.currentChapter;
                this.currentChapter = this.prevChapter;
                this.prevChapter = new PageClipChapter();
                this.ensurePreload();
                app.reader.updateHistory2();
            }
            this.pushPageToScreen(prevFrame.page);
            this.sfx.play();
        }
    }
    applyStyleChange(stl, reOrganize = true) {
        if (!this.innerWindow) {
            return;
        }
        super.applyStyleChange(stl, reOrganize);
        if (stl.backgroundColor) {
            var c = stl.backgroundColor;
            if (c.indexOf("rgb") > -1) {
                c = ui.color.rgbStringToHex(c);
            }
            this.exstyle.set(".backpaper", {
                background: `linear-gradient(270deg, ${ui.color.darker(c, 20)}, ${stl.backgroundColor})`,
            });
        }
    }
}
class SimulatedBackPaperCanvas {
    constructor(w, h) {
        _defineProperty(this, "liftHeight", 30);
        _defineProperty(this, "dLift", Math.PI * 15);
        _defineProperty(this, "paperColor", "#f0f0f0");
        _defineProperty(this, "paperGradient1", "#f0f0f0");
        _defineProperty(this, "paperGradient2", "#e0e0e0");
        _defineProperty(this, "paper", null);
        _defineProperty(this, "animationCTime", 0);
        this.canvas = document.createElement("canvas");
        this.canvas.width = w;
        this.canvas.height = h;
        this.ctx = this.canvas.getContext("2d");
    }
    loadPaper(element, onLoad) {
        return;
        var self = this;
        requestAnimationFrame(() => {
            html2canvas(element, {
                scale: devicePixelRatio,
                foreignObjectRendering: true, // precise rendering
            }).then(
                ((canvas) => {
                    this.paper = canvas;
                    console.log("Paper loaded", canvas);
                    onLoad && onLoad();
                }).bind(self)
            );
        });
    }
    setPaperColor(color) {
        if (color.indexOf("rgb") > -1) {
            color = ui.color.rgbStringToHex(color);
        }
        this.paperColor = color;
        this.paperGradient1 = ui.color.darker(color, 10);
        this.paperGradient2 = ui.color.darker(color, 30);
    }
    remove() {
        this.canvas.remove();
    }
    getEdgeTop() {
        return {
            x: this.canvas.width,
            y: 0,
        };
    }
    getEdgeBottom() {
        return {
            x: this.canvas.width,
            y: this.canvas.height,
        };
    }
    getEdgeLeftTop() {
        return {
            x: 0,
            y: 0,
        };
    }
    getEdgeLeftBottom() {
        return {
            x: 0,
            y: this.canvas.height,
        };
    }
    getMaxLiftHeight(x) {
        return Math.min(this.liftHeight, this.canvas.width - x);
    }
    computeSymmetricPoint(p, p1, p2) {
        let A = p2.y - p1.y;
        let B = p1.x - p2.x;
        let C = p2.x * p1.y - p1.x * p2.y;
        let D = (A * p.x + B * p.y + C) / (A * A + B * B);
        let qx = p.x - 2 * A * D;
        let qy = p.y - 2 * B * D;
        return {
            x: qx,
            y: qy,
        };
    }
    interpolate(p1, p2, t) {
        return {
            x: p1.x + (p2.x - p1.x) * t,
            y: p1.y + (p2.y - p1.y) * t,
        };
    }
    center(p1, p2) {
        return {
            x: (p1.x + p2.x) / 2,
            y: (p1.y + p2.y) / 2,
        };
    }
    findPerpendicularFoot(A, B, C) {
        let x_a = A.x,
            y_a = A.y;
        let x_b = B.x,
            y_b = B.y;
        let x_c = C.x,
            y_c = C.y;
        let dx = x_c - x_b;
        let dy = y_c - y_b;
        let d = dx * dx + dy * dy;
        if (d === 0) {
            return null;
        }
        let t = ((x_a - x_b) * dx + (y_a - y_b) * dy) / d;
        let x_h = x_b + t * dx;
        let y_h = y_b + t * dy;
        return {
            x: x_h,
            y: y_h,
        };
    }
    distance(p1, p2) {
        return Math.sqrt((p1.x - p2.x) ** 2 + (p1.y - p2.y) ** 2);
    }
    computePathStep(p1, p2) {
        var gradientStart = null;
        var gradientEnd = null;
        var points = [];
        if (p1.y > 0) {
            var sym = this.computeSymmetricPoint(this.getEdgeBottom(), p1, p2);
            points.push(sym);
            points.push(p1);
            points.push(p2);
            gradientStart = sym;
            gradientEnd = this.findPerpendicularFoot(sym, p1, p2);
        } else if (p2.y < this.canvas.height) {
            var sym = this.computeSymmetricPoint(this.getEdgeTop(), p1, p2);
            points.push(sym);
            points.push(p1);
            points.push(p2);
            gradientStart = sym;
            gradientEnd = this.findPerpendicularFoot(sym, p1, p2);
        } else {
            var sym1 = this.computeSymmetricPoint(this.getEdgeTop(), p1, p2);
            var sym2 = this.computeSymmetricPoint(this.getEdgeBottom(), p1, p2);
            points.push(sym1);
            points.push(p1);
            points.push(p2);
            points.push(sym2);
            gradientStart = this.distance(sym1, p1) < this.distance(sym2, p2) ? sym2 : sym1;
            gradientEnd = this.findPerpendicularFoot(gradientStart, p1, p2);
        }
        return {
            line: points,
            start: gradientStart,
            end: gradientEnd,
        };
    }
    makeGradient(start, end) {
        var gradient = this.ctx.createLinearGradient(start.x, start.y, end.x, end.y);
        gradient.addColorStop(0, this.paperColor);
        gradient.addColorStop(0.8, this.paperGradient1);
        gradient.addColorStop(1, this.paperGradient2);
        return gradient;
    }
    drawBoxShadow(line, expand = 10) {
        this.ctx.beginPath();
        this.ctx.moveTo(line[0].x, line[0].y);
        for (var i = 1; i < line.length; i++) {
            this.ctx.lineTo(line[i].x, line[i].y);
        }
        this.ctx.closePath();
        this.ctx.shadowColor = "black";
        this.ctx.shadowBlur = expand;
        this.ctx.shadowOffsetX = 0;
        this.ctx.shadowOffsetY = 0;
        this.ctx.strokeStyle = "transparent";
        this.ctx.stroke();
    }
    clipPolygon(line) {
        this.ctx.beginPath();
        this.ctx.moveTo(line[0].x, line[0].y);
        for (var i = 1; i < line.length; i++) {
            this.ctx.lineTo(line[i].x, line[i].y);
        }
        this.ctx.closePath();
    }
    drawPaper(p1, p2) {
        if (this.paper) {
            this.ctx.save();
            var clips = [
                {
                    x: 0,
                    y: 0,
                },
            ];
            if (p1.y > 0) {
                clips.push({
                    x: this.canvas.width,
                    y: 0,
                });
            }
            clips.push(p1);
            clips.push(p2);
            if (p2.y < this.canvas.height) {
                clips.push({
                    x: this.canvas.width,
                    y: this.canvas.height,
                });
            }
            clips.push({
                x: 0,
                y: this.canvas.height,
            });
            this.clipPolygon(clips);
            var realW = this.paper.width / devicePixelRatio - devicePixelRatio;
            var realH = this.paper.height / devicePixelRatio - devicePixelRatio;
            this.ctx.drawImage(this.paper, -devicePixelRatio, -devicePixelRatio, realW, realH);
            this.ctx.restore();
        }
    }
    draw(p1, p2) {
        this.currentP1 = p1;
        this.currentP2 = p2;
        this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
        this.drawPaper(p1, p2);
        this.ctx.save();
        var bg = this.computePathStep(p1, p2);
        this.drawBoxShadow(bg.line, 10);
        this.clipPolygon(bg.line);
        this.ctx.clip();
        this.ctx.fillStyle = this.makeGradient(bg.start, bg.end);
        this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
        this.ctx.restore();
    }
    runAnimation(initP1, initP2, endP1, endP2, elem, animator, time) {
        var self = this;
        var start = null;
        var step = function (timestamp) {
            if (!start) start = timestamp;
            var progress = timestamp - start;
            self.animationCTime = progress;
            var t = Math.min(progress / time, 1);
            var p1 = self.interpolate(initP1, endP1, t);
            var p2 = self.interpolate(initP2, endP2, t);
            self.draw(p1, p2);
            if (!self.paper) {
                elem.style.clipPath = animator.composePolygon(p1, p2);
            }
            if (progress < time) {
                requestAnimationFrame(step);
            } else {
                if (endP1.x < 3 || endP2.x < 3) {
                    elem.style.transform = "translate3d(-100%, 0, 0)";
                }
                elem.style.clipPath = "none";
                animator.animatingLock = false;
                self.remove();
            }
        };
        requestAnimationFrame(step);
    }
    runAnimationTo(endP1, endP2, elem, animator, time) {
        this.runAnimation(this.currentP1, this.currentP2, endP1, endP2, elem, animator, time);
    }
}
class FlashPageFlipChapterDisplay extends PageFlipChapterDisplay {
    constructor(root) {
        super(root);
        // NO animation
        _defineProperty(this, "animator", {
            touchInitX: 0,
            isFirstTouch: false,
            touchInitTime: 0,
            isDragging: false,
            dragElement: null,
            screenWidth: window.innerWidth,
            direction: null,
            initDrag: function (element, dir) {
                if (!element) {
                    this.dragElement = null;
                    this.isDragging = false;
                    return;
                }
                if (dir == "next" && !element.previousElementSibling) {
                    this.dragElement = null;
                    this.isDragging = false;
                    return;
                }
                this.dragElement = element;
                this.isDragging = true;
                this.direction = dir;
            },
        });
    }
    onTouchStart(e) {
        this.animator.touchInitX = e.touches[0].clientX;
        this.animator.isFirstTouch = true;
        this.animator.touchInitTime = Date.now();
    }
    onTouchMove(e) {
        var x = e.touches[0].clientX;
        if (this.animator.isFirstTouch) {
            var dx = x - this.animator.touchInitX;
            if (dx > 0) {
                this.animator.initDrag(this.currentFrame.nextElementSibling, "prev");
            } else if (dx < 0) {
                this.animator.initDrag(this.currentFrame, "next");
            }
            this.animator.isFirstTouch = false;
        }
    }
    onTouchEnd(e) {
        if (this.animator.isDragging) {
            if (this.animator.direction == "prev") {
                var dx = e.changedTouches[0].clientX - this.animator.touchInitX;
                if (dx > 10 && Date.now() - this.animator.touchInitTime < 200) {
                    this.jumpToPrevPage();
                } else if (dx > this.screenWidth / 3) {
                    this.jumpToPrevPage();
                }
            }
            if (this.animator.direction == "next") {
                var dx = e.changedTouches[0].clientX - this.animator.touchInitX;
                if (dx < -10 && Date.now() - this.animator.touchInitTime < 200) {
                    this.jumpToNextPage();
                } else if (dx < -this.screenWidth / 3) {
                    this.jumpToNextPage();
                }
            }
            this.animator.isDragging = false;
            this.animator.dragElement = null;
        }
    }
    onTouchCancel(e) {
        if (this.animator.isDragging) {
            if (this.animator.direction == "prev") {
                this.animator.dragElement.style.transform = `translate3d(-100%, 0, 0)`;
            } else if (this.animator.direction == "next") {
                this.animator.dragElement.style.transform = `translate3d(0, 0, 0)`;
            }
            this.animator.isDragging = false;
            this.animator.dragElement = null;
        }
    }
    jumpToNextPage() {
        var nextFrame = this.currentFrame.previousElementSibling;
        if (nextFrame) {
            this.currentFrame.style.transform = `translate3d(-100%, 0, 0)`;
            this.currentFrame = nextFrame;
            if (this.nextChapter.pageElements.indexOf(nextFrame.page) == 0) {
                this.prevChapter = this.currentChapter;
                this.currentChapter = this.nextChapter;
                this.nextChapter = new PageClipChapter();
                this.ensurePreload();
                app.reader.updateHistory2();
            }
            this.pushPageToScreen(nextFrame.page);
        }
    }
    jumpToPrevPage() {
        var prevFrame = this.currentFrame.nextElementSibling;
        if (prevFrame) {
            prevFrame.style.transform = `translate3d(0, 0, 0)`;
            this.currentFrame = prevFrame;
            var idxPrev = this.prevChapter.pageElements.indexOf(prevFrame.page);
            if (idxPrev == this.prevChapter.pageElements.length - 1 && idxPrev >= 0) {
                this.nextChapter = this.currentChapter;
                this.currentChapter = this.prevChapter;
                this.prevChapter = new PageClipChapter();
                this.ensurePreload();
                app.reader.updateHistory2();
            }
            this.pushPageToScreen(prevFrame.page);
        }
    }
}
class ContinuosChapterDisplay extends ChapterDisplay {
    constructor(root) {
        super(root);
        _defineProperty(this, "scroller", void 0);
        _defineProperty(this, "innerWindow", void 0);
        _defineProperty(this, "prevId", void 0);
        _defineProperty(this, "prevContainer", void 0);
        _defineProperty(this, "currentId", void 0);
        _defineProperty(this, "currentContainer", void 0);
        _defineProperty(this, "nextId", void 0);
        _defineProperty(this, "nextContainer", void 0);
        _defineProperty(this, "lockNavBtn", void 0);
        _defineProperty(
            this,
            "baseSrcDoc",
            `<head>
          <script src="${app.net.networkManagerXHR.bestDomain()}/stv.ui.js"></script>
          <style id="readerstyle"></style>
          <style id="localfont"></style>
          <link rel="stylesheet" href="{webfont}">
          <link rel="stylesheet" href="/asset/all.min.css">
          <style id="uistyle">
              ${preloaderAnimation}
              .rctx > div {
                  padding: 10px;
                  line-height: 1;
                  font-size: 12px;
                  border-right: 1px solid #80808080;
              }
              .rctx {
                  display: flex;
                  border-radius: 15px;
                  background: inherit;
                  border: 1px solid #80808080;
              }
              .rctx > div:last-child {
                  border-right: none;
              }
              .chinesedragbar{
                  position: absolute;
                  background: #00000080;
                  color: white;
                  padding: 6px;
                  border-radius: 15px;
                  font-size: 14px;
                  display: none;
                  line-height: 1.5;
                  max-width: 100%;
                  z-index: 10001;
              }
              .chinesedragbar > div{
                  display: flex;
                  text-align: center;
              }
              .chinesedragbar > div > div{
                  display: inline-block;
                  vertical-align: top;
                  white-space: nowrap;
              }
              .chinesedragbar .leftcnshow, .chinesedragbar .rightcnshow{
                  color: #a1a1a1;
              }
              .chinesedragbar .pointer{
                  width: 2px;
              }
              .chinesedragbar .pointer.active{
                  background: white;
              }
              #contextmenu:not(.active){
                  pointer-events: none;
              }
              .chaptername{
                  text-align: center;
                  margin-top: 20px;
              }
              #maincontent{
                  max-width: 100vw;
                  min-height: 100vh;
              }
              .singlechapter{
                  max-width: 100vw;
                  min-height: 101vh;
              }
              .chaptertopinfo {
                  font-size: 10px;
                  height: 14px;
                  padding: 0px 6px;
                  background-color: inherit;
                  display: flex;
                  position: fixed;
                  top: 0;
                  width: 100%;
                  left: 0;
              }
          </style>
          <script src="${app.net.networkManagerXHR.bestDomain()}/qtOnline.js?v=35"></script>
          <script type="id" id="hiddenid">0;0;0</script>
          </head><body>
              <div class="rctx" id="contextmenu"></div>
              <div class="chaptertopinfo">
                  <div class="chapternamefixed" style="flex: 1;"></div>
                  <div class="currenttime"></div>
              </div>
              <div id="mainscroller"></div>
              <div id="dragbar"></div>
          </body>`
        );
        _defineProperty(this, "prevChapOffset", 0);
        _defineProperty(this, "currentChapOffset", 0);
        _defineProperty(this, "currentChapOffsetEnd", 0);
        _defineProperty(this, "nextChapOffset", 0);
        _defineProperty(this, "nextChapPreloadThreshold", 0);
        _defineProperty(this, "offsetCache", []);
        _defineProperty(this, "windowHalfHeight", 0);
        // interact behavior
        _defineProperty(this, "behaviour", {
            way_to_choose_node: {
                bindEvent: function (cw) {
                    var method = app.config.reader.way_to_choose_node;
                    var baseBehaviour = app.reader.behaviour.way_to_choose_node;
                    if (!baseBehaviour[method]) {
                        method = "click";
                    }
                    switch (method) {
                        case "click": {
                            cw.way_to_choose_node = baseBehaviour[method].bind(cw);
                            cw.document.body.addEventListener("click", cw.way_to_choose_node);
                            break;
                        }
                        case "dblclick": {
                            cw.way_to_choose_node = baseBehaviour[method].bind(cw);
                            cw.document.body.addEventListener("click", cw.way_to_choose_node);
                            break;
                        }
                        case "hold": {
                            ui.hold(cw.document.body, baseBehaviour[method].bind(cw));
                            cw.document.body.addEventListener("click", baseBehaviour["triggermenu"]);
                            break;
                        }
                        case "none": {
                            cw.document.body.addEventListener("click", baseBehaviour["triggermenu"]);
                            return;
                        }
                    }
                },
                rebindEvent: function () {
                    var d = app.reader.getDisplay();
                    var cw = d.innerWindow;
                    cw.document.body.removeEventListener("click", cw.way_to_choose_node);
                    cw.document.body.removeEventListener("dblclick", cw.way_to_choose_node);
                    cw.document.body.removeEventListener("click", app.reader.behaviour.way_to_choose_node["triggermenu"]);
                    cw.document.body.unhold && cw.document.body.unhold();
                    this.bindEvent(cw);
                },
            },
            chapter_name_fixed_place: {
                apply: function () {
                    if (!app.reader.getDisplay().innerWindow) {
                        return;
                    }
                    var cs = app.reader.getDisplay().innerWindow.q(".chaptertopinfo")[0];
                    switch (app.config.reader.chapter_name_fixed_place) {
                        case "top": {
                            cs.style.top = "0";
                            cs.style.bottom = "unset";
                            break;
                        }
                        case "bottom": {
                            cs.style.top = "unset";
                            cs.style.bottom = "0";
                            break;
                        }
                        case "none": {
                            cs.style.display = "none";
                            break;
                        }
                    }
                },
            },
            prepend_chapter_name: {
                apply: function () {
                    var has = app.config.reader.prepend_chapter_name;
                    var cw = app.reader.getDisplay().innerWindow;
                    var scroller = app.reader.getDisplay().scroller;
                    if (has) {
                        for (var i = 0; i < scroller.children.length; i++) {
                            var e = scroller.children[i];
                            if (e.cdata) {
                                var name = e.q(".chaptername");
                                var cname = e.cdata.chaptername;
                                if (!name) {
                                    name = cw.document.createElement("div");
                                    name.className = "chaptername";
                                    name.textContent = cname;
                                    e.insertBefore(name, e.q(".contentcontainer"));
                                } else if (cname != name.textContent) {
                                    name.textContent = cname;
                                }
                            }
                        }
                    } else {
                        for (var i = 0; i < scroller.children.length; i++) {
                            var e = scroller.children[i];
                            var name = e.q(".chaptername");
                            if (name) {
                                name.remove();
                            }
                        }
                    }
                },
            },
            tap_actions: {
                description: [
                    {
                        value: "none",
                        name: app.text.none,
                    },
                    {
                        value: "scroll_down",
                        name: app.text.slide_down,
                    },
                    {
                        value: "scroll_up",
                        name: app.text.slide_up,
                    },
                    {
                        value: "open_menu",
                        name: app.text.open_menu,
                    },
                ],
                scroll_down: function (cw, view) {
                    var offset = 250;
                    cw.scrollBy({
                        top: offset,
                        behavior: "smooth",
                    });
                },
                scroll_up: function (cw, view) {
                    var offset = 250;
                    cw.scrollBy({
                        top: -offset,
                        behavior: "smooth",
                    });
                },
                open_menu: function (cw, view) {
                    app.reader.toggleMenu();
                },
                none: function (cw, view) {},
            },
        });
        _defineProperty(this, "exstyle", st.create(""));
    }
    render() {
        var v = app.render("chapterDisplay-continuos", {});
        var c = this.getMainContainer();
        v.appendChild(c);
        if (this.root.q(".chapterscroller")) {
            this.root.q(".chapterscroller").remove();
        }
        this.root.appendChild(v);
    }
    getMainContainer() {
        var e = document.createElement("iframe");
        e.className = "chaptercontentcontinous content";
        var view = e;
        var w = window;
        var isEncrypted = app.reader.encryptedHosts.indexOf(this.host) >= 0;
        var srcdoc = this.baseSrcDoc.replace("{webfont}", app.fontmanager.getFontUrl(isEncrypted));
        var self = this;
        view.onload = function () {
            var cd = this.contentDocument;
            var cw = this.contentWindow;
            self.innerWindow = cw;
            self.behaviour.way_to_choose_node.bindEvent(cw);
            cw.onblur = function () {
                w.preventExit = true;
                console.log(w.preventExit);
            };
            var s = document.createElement("style");
            s.textContent = app.reader.defaultRStyle;
            cd.head.appendChild(s);
            cw.hanvietdic = w.hanvietdic;
            cw.store = app.storage;
            cw.getCookie = w.getCookie;
            cw.container = e;
            cw.thispage = "chapter";
            cw.namew = {
                value: "",
                valueglobal: "",
            };
            Object.defineProperty(cw.namew, "value", {
                set: function (v) {
                    app.namemanager.updateNameData(v);
                },
                get: function () {
                    return app.namemanager.namedatacache || app.namemanager.namedata.join("\n");
                },
            });
            Object.defineProperty(cw.namew, "valueglobal", {
                set: function (v) {
                    app.namemanager.updateNameData(v);
                },
                get: function () {
                    return app.namemanager.namedatacacheglobal || app.namemanager.nameglobal.join("\n");
                },
            });
            self.scroller = cw.g("mainscroller");
            self.resetPosition();
            app.reader.loadStart();
            cw.saveNS = function () {
                app.namemanager.saveData();
            };
            cw.excute = cw.excuteApp;
            cw.setting = app.editor.setting;
            cw.pr = function () {};
            app.reader.applyStyle();
            events.set(cd.getElementById("contextmenu"), "view_contextmenu");
            cw.chinesedragbar = new ChineseDragBar(null, cd.getElementById("dragbar"));
            cw.chinesedragbar.onupdate = function (c) {
                app.reader.display.q(".chi").textContent = c;
                app.editor.updateSuggest(cw, c);
            };
            cw.addEventListener("scroll", function (e) {
                self.onScroll(e);
            });
            app.reader.behaviour.chapter_name_fixed_place.apply();
        };
        view.srcdoc = srcdoc;
        return e;
    }
    getSingleContainer() {
        var e = app.render("continuos-chapter", {});
        return e;
    }
    resetPosition() {
        if (this.scroller.children.length < 3) {
            this.prevContainer = this.scroller.appendChild(this.getSingleContainer());
            this.currentContainer = this.scroller.appendChild(this.getSingleContainer());
            this.nextContainer = this.scroller.appendChild(this.getSingleContainer());
        } else {
            this.prevContainer = this.scroller.children[0];
            this.currentContainer = this.scroller.children[1];
            this.nextContainer = this.scroller.children[2];
            this.reCacheOffset();
        }
    }
    reCacheOffset() {
        this.offsetCache = [];
        for (var i = 0; i < this.scroller.children.length; i++) {
            this.offsetCache.push({
                offset: this.scroller.children[i].offsetTop,
                height: this.scroller.children[i].offsetHeight,
            });
        }
        this.currentContainer = this.getCurrentChapter();
        this.nextChapPreloadThreshold = this.offsetCache[this.offsetCache.length - 1].offset - window.innerHeight; // preload next chap when it's 1 screen away
    }
    getPCN() {
        return {
            prev: this.prevContainer,
            current: this.getCurrentChapter(),
            next: this.nextContainer,
        };
    }
    getCurrentChapter(y) {
        if (this.windowHalfHeight == 0) {
            this.windowHalfHeight = this.innerWindow.innerHeight / 2;
        }
        var y = y + this.windowHalfHeight || this.innerWindow.pageYOffset + this.windowHalfHeight;
        if (this.offsetCache.length == 0) {
            this.reCacheOffset();
        }
        for (var i = 0; i < this.offsetCache.length; i++) {
            var c = this.offsetCache[i];
            if (c.offset <= y && c.offset + c.height >= y) {
                if (this.currentContainer != this.scroller.children[i]) {
                    this.updateFixedChapterName(this.scroller.children[i]);
                }
                this.currentContainer = this.scroller.children[i];
                return this.scroller.children[i];
            }
        }
        return this.currentContainer;
    }
    updateFixedChapterName(c) {
        if (c && c.cdata) {
            var name = c.cdata.chaptername;
            var fixed = this.innerWindow.q(".chapternamefixed")[0];
            if (fixed) {
                var oldName = fixed.textContent;
                if (oldName != name) {
                    fixed.textContent = name;
                    this.innerWindow.contentcontainer = c.q(".contentcontainer").id;
                    this.recycle(c);
                    app.reader.updateHistory2();
                }
            }
        }
    }
    recycle(v) {
        var c = this.scroller.children;
        var viewIndex = Array.from(c).indexOf(v);
        var removed = 0;
        while (viewIndex > 1) {
            var first = c[0];
            first.remove();
            viewIndex--;
            removed++;
        }
        while (c.length > 3) {
            var last = c[c.length - 1];
            last.remove();
            removed++;
        }
        if (removed > 0) {
            this.reCacheOffset();
        }
    }
    setContent(text, cdata, view) {
        view.cdata = cdata;
        view.q(".contentcontainer").innerHTML = text;
        view.q(".contentcontainer").id = "cid-" + view.cid;
        try {
            this.innerWindow.contentcontainer = "cid-" + view.cid;
            this.innerWindow.applyNodeList();
            this.innerWindow.excuteApp();
        } catch (e) {}
        this.behaviour.prepend_chapter_name.apply();
    }
    ensurePreload(prev, current, next) {
        var self = this;
        if (!current) {
            current = this.getCurrentChapter();
            prev = current.previousElementSibling;
            next = current.nextElementSibling;
        }
        if (prev) {
            console.log(`previd: ${prev.cid}, prev cid: ${current.previd}`);
            if (prev.cid != current.previd && current.previd && current.previd != "0") {
                console.log("preload prev");
                this.preload(app.reader.host, app.reader.id, current.previd, prev);
                current.dragupAble = true;
            } else if (current.previd == "0") {
                prev.remove();
            }
        }
        if (current.previd) {
            current.dragupAble = true;
        } else {
            current.dragupAble = false;
        }
        if (next) {
            console.log("checking next");
            console.log(`nextid: ${next.cid}, nexid: ${current.nextid}`);
            if (next.cid != current.nextid && current.nextid && current.nextid != "0") {
                console.log("preload next");
                this.noNextChap = false;
                this.preload(app.reader.host, app.reader.id, current.nextid, next);
            } else if (current.nextid == "0") {
                next.remove();
                this.noNextChap = true;
            }
        }
        if (current.nextid) {
            current.dragdownAble = true;
        } else {
            current.dragdownAble = false;
            console.log(current.nextid);
        }
    }
    scrollToCenter() {
        var p = this.innerWindow;
        var c = this.currentContainer;
        p.scrollTo(0, c.offsetTop);
    }
    loadStart() {
        this.scrollToCenter();
        this.preload(app.reader.host, app.reader.id, app.reader.startid, this.currentContainer, false, true);
    }
    async preload(h, i, c, view, rl, start) {
        if (c == "0" || !c) {
            return;
        }
        view.cid = c;
        this.setLoading(view);
        var cdata = await app.reader.getContent(h, i, c, rl);
        this.setNotLoading(view);
        if (cdata.code == "0") {
            window.failedIn5Times = 0;
            var text = app.reader.preprocess(h, cdata.data);
            this.setContent(text, cdata, view);
            this.reCacheOffset();
            if (start) {
                this.scrollToCenter();
            }
            await this.assignNavigator(h, i, c, cdata, view);
            if (start) {
                app.reader.updateHistory(h, i, c, cdata);
                this.updateFixedChapterName(view);
                this.ensurePreload(this.prevContainer, this.currentContainer, this.nextContainer);
            }
        } else {
            app.reader.handlingException(cdata, view);
            this.reCacheOffset();
        }
    }
    async assignNavigator(h, i, c, x, frame) {
        var forceget = ["trxc", "bxwxorg", "faloo", "biquge", "fanqie"];
        if (forceget.indexOf(h) > -1) {
            x.next = 0;
            x.prev = 0;
        }
        var nextid = x.next;
        var previd = x.prev;
        frame.previd = previd;
        frame.nextid = nextid;
        frame.cid = c;
        if (h == "surf") {
            return;
        }
        if (frame.previd == 0 || frame.nextid == 0) {
            var nani = await app.reader.getChapterNavigator(h, i, c);
            if (parseInt(nani.next) != 0) {
                frame.nextid = nani.next;
                this.noNextChap = false;
            } else {
                this.noNextChap = true;
            }
            if (parseInt(nani.prev) != 0) {
                frame.previd = nani.prev;
            }
            this.ensurePreload();
        }
    }
    setLoading(container) {
        var pl = app.createPreloader("Đang tải nội dung...", true);
        pl.classList.add("chapterpreloader");
        var d = document.createElement("div");
        d.setAttribute("style", "height: 300px; width: 100%; text-align: center;");
        d.appendChild(pl);
        d.className = "waitpreloader1";
        container.appendChild(d);
        this.reCacheOffset();
    }
    setNotLoading(container) {
        container.qq(".waitpreloader1").forEach((e) => e.remove());
        this.reCacheOffset();
    }
    rightTapAction() {
        var cw = this.currentContainer;
        var method = app.config.reader.right_tap_action;
        if (!this.behaviour.tap_actions[method]) {
            method = "none";
        }
        this.behaviour.tap_actions[method](this.innerWindow, cw);
    }
    leftTapAction() {
        var cw = this.currentContainer;
        var method = app.config.reader.left_tap_action;
        if (!this.behaviour.tap_actions[method]) {
            method = "none";
        }
        this.behaviour.tap_actions[method](this.innerWindow, cw);
    }
    onScroll(e) {
        var y = this.innerWindow.pageYOffset;
        if (y > this.nextChapPreloadThreshold) {
            if (!this.nextChapPreloading && !this.noNextChap) {
                var nextId = this.scroller.lastElementChild.nextid;
                if (nextId && nextId != "0") {
                    this.nextChapPreloading = true;
                    var n = this.scroller.appendChild(this.getSingleContainer());
                    n.cid = nextId;
                    var self = this;
                    this.preload(app.reader.host, app.reader.id, nextId, n).then(() => {
                        self.nextChapPreloading = false;
                    });
                }
            }
        }
        this.getCurrentChapter(y);
    }

    // user method
    goNextChapter(isTTS) {
        if (this.lockNavBtn) {
            return;
        }
        var current = this.getCurrentChapter();
        if (current.nextid && current.nextid != "0") {
            var p = this.innerWindow;
            var c = current.nextElementSibling;
            if (c) {
                p.scrollTo(0, c.offsetTop);
            } else {
                this.changeCurrentChapter(current.nextid);
            }
            app.reader.updateCnameAndProgress();
            this.updateFixedChapterName(this.getCurrentChapter());
            if (isTTS) {
                app.tts.changeChapter();
            }
        }
    }
    goPrevChapter() {
        if (this.lockNavBtn) {
            return;
        }
        var current = this.getCurrentChapter();
        if (current.previd && current.previd != "0") {
            var p = this.innerWindow;
            var c = current.previousElementSibling;
            if (c) {
                p.scrollTo(0, c.offsetTop);
            } else {
                this.changeCurrentChapter(current.previd);
            }
            app.reader.updateCnameAndProgress();
            this.updateFixedChapterName(this.getCurrentChapter());
        }
    }
    showAlert(msg, view) {
        var mct = view.q(".contentcontainer");
        var preloader = view.q(".chapterpreloader1");
        if (preloader) {
            preloader.remove();
        }
        mct.innerHTML = `
              <div class="erroralert" style="width:100%;height:100%;min-height:calc(100vh - 100px);position:relative;">
              <div style="position: absolute;width:80%;left: 50%;top: 50%;transform: translate(-50%, -50%);
              text-align: center;font-size: 20px;">
                  <div>${msg}</div>
                  <div class="btn" style="display: inline-block;border-radius: 8px;border-color: white;border-width: 2px;
                  border-style: solid;padding: 6px 12px;margin: 20px;">Tải lại</div>
              </div></div>
          `;
        var btn = mct.querySelector(".btn");
        btn.addEventListener("click", function (e) {
            window.failedIn5Times = 0;
            app.reader.reloadCurrentChapter();
            e.stopPropagation();
            app.platform.nativeclick();
        });
    }
    removeAlert(view) {
        var ele = view.q(".erroralert");
        if (ele) {
            ele.remove();
        }
    }
    getRoot() {
        return this.scroller;
    }
    reloadCurrentChapter(rl) {
        var view = this.getCurrentChapter();
        if (view.cid != "0" && view.cid) {
            this.removeAlert(view);
            this.preload(app.reader.host, app.reader.id, view.cid, view, rl).then(() => {
                this.ensurePreload();
                this.updateFixedChapterName(view);
                app.reader.updateCnameAndProgress();
                app.reader.updateHistory2();
            });
        }
    }
    reloadAllChapter() {
        for (var i = 0; i < this.scroller.children.length; i++) {
            setTimeout(
                (n) => {
                    this.preload(app.reader.host, app.reader.id, this.scroller.children[n].cid, this.scroller.children[n]);
                },
                i * 1000,
                i
            );
        }
    }
    changeCurrentChapter(targetId) {
        var view = this.getCurrentChapter();
        if (targetId != "0" && targetId) {
            view.cid = targetId;
            this.removeAlert(view);
            this.preload(app.reader.host, app.reader.id, targetId, view).then(() => {
                this.ensurePreload();
                app.reader.updateCnameAndProgress();
            });
        }
    }
    getChapterNameAndProgress() {
        var c = this.getCurrentChapter();
        if (c && c.cdata) {
            var name = c.cdata.chaptername;
            var y = this.innerWindow.pageYOffset - c.offsetTop;
            var h = c.offsetHeight;
            var p = y / (h - this.innerWindow.innerHeight);
            return {
                name: name,
                progress: p * 1000, // 0 - 1000
            };
        }
    }
    gotoProgress(p) {
        var c = this.getCurrentChapter();
        var h = c.offsetHeight;
        var y = (p / 1000) * (h - this.innerWindow.innerHeight);
        this.innerWindow.scrollTo(0, c.offsetTop + y);
    }
    runName() {
        for (var i = 0; i < this.scroller.children.length; i++) {
            var containerId = this.scroller.children[i].querySelector(".contentcontainer").id;
            this.innerWindow.contentcontainer = containerId;
            this.innerWindow.excuteApp();
        }
    }
    hideContextMenu() {
        this.innerWindow.g("contextmenu").hide();
    }
    unlockNameSelect() {
        this.innerWindow.unlock();
    }
    getCurrentWindow() {
        return this.innerWindow;
    }
    applyStyleChange(stl) {
        if (!this.innerWindow) {
            return;
        }
        var innerExStyle = this.innerWindow.g("exstyle");
        if (!innerExStyle) {
            this.innerWindow.document.head.appendChild(this.exstyle);
            this.exstyle.id = "exstyle";
        }
        var oldBorderTop =
            app.reader.styleCnameUi.collection["#chapterview iframe.content"] &&
            app.reader.styleCnameUi.collection["#chapterview iframe.content"].css["border-top"];
        var oldBorderBottom =
            app.reader.styleCnameUi.collection["#chapterview iframe.content"] &&
            app.reader.styleCnameUi.collection["#chapterview iframe.content"].css["border-bottom"];
        if (oldBorderTop != stl.borderTop || oldBorderBottom != stl.borderBottom) {
            app.reader.styleCnameUi.set("#chapterview iframe.content", {
                borderTop: stl.borderTop,
                borderBottom: stl.borderBottom,
            });
        }
        if (!stl.backgroundImageId && this.useBackgroundImage) {
            var bgImg = this.innerWindow.g("bgimg");
            if (bgImg) {
                bgImg.src = "";
                bgImg.style.display = "none";
            }
            this.useBackgroundImage = false;
            this.backgroundImage = null;
        }
        if (this.useBackgroundImage && this.backgroundImage) {
            var bgImg = this.innerWindow.g("bgimg");
            if (!bgImg) {
                this.onBackgroundImageLoaded(this.backgroundImage, null);
            }
        }
    }
    onBackgroundImageLoaded(url, bg) {
        if (!this.innerWindow) {
            this.useBackgroundImage = true;
            this.backgroundImage = url;
            return;
        }
        var bgImg = this.innerWindow.g("bgimg");
        if (!bgImg) {
            bgImg = this.innerWindow.document.createElement("img");
            bgImg.id = "bgimg";
            bgImg.style.display = "none";
            this.innerWindow.document.body.insertBefore(bgImg, this.innerWindow.document.body.firstChild);
        }
        bgImg.src = url;
        bgImg.style.display = "none";
        bgImg.onload = () => {
            bgImg.style.display = "block";
        };
        this.exstyle.set("#bgimg", {
            width: "100vw",
            height: "100vh",
            position: "fixed",
            zIndex: "-1",
            top: "0",
            left: "0",
            display: "none",
        });
        this.useBackgroundImage = true;
        this.backgroundImage = url;
    }
}
const ChapterDisplayTypeRegistry = {
    slide: SlideChapterDisplay,
    pageflip: PageFlipChapterDisplay,
    simulatedpageflip: SimulatedPageFlipChapterDisplay,
    flashpageflip: FlashPageFlipChapterDisplay,
    continuos: ContinuosChapterDisplay,
    default: SlideChapterDisplay,
};
