function _defineProperty(e, r, t) {
    return (
      (r = _toPropertyKey(r)) in e
        ? Object.defineProperty(e, r, {
            value: t,
            enumerable: !0,
            configurable: !0,
            writable: !0
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
  class BookDisplay {
    constructor(loader, container) {
      _defineProperty(this, "books", []);
      _defineProperty(this, "container", null);
      _defineProperty(this, "rootElement", null);
      _defineProperty(this, "elements", []);
      _defineProperty(this, "maxConsume", 999999);
      _defineProperty(this, "baseBookElement", document.createElement("div"));
      _defineProperty(this, "getNewNode", function (book) {
        var clone = this.baseBookElement.cloneNode(true);
        app.assign(book, clone);
        clone.data = book;
        clone.classList.add("book-" + book.lid);
        return clone;
      });
      _defineProperty(
        this,
        "rendering",
        new Promise((rs) => {
          rs();
        })
      );
      this.loader = loader;
      this.container = container;
      this.render();
      ui.pullToRefresh(this.rootElement, this.container, app.text.pull2refresh);
      this.rootElement.onrefresh = ((onFinish) => {
        this.loader.reset().then((code) => {
          console.log("Refresh done", code);
          onFinish(code);
        });
      }).bind(this);
    }
    consume(books, container) {
      this.container = container;
      // if(this.books != null && this.books.length > 0){
      //     // start compare for old and new books
      //     var oldBooks = this.books;
      //     var newBooks = books;
      //     for(var i = 0; i < newBooks.length; i++){
      //         var oldPos = oldBooks.findIndex(e => e.lid == newBooks[i].lid);
      //         if(oldPos >= 0){
      //             // update position
      //             this.updateBookPosition(newBooks[i], oldPos, i);
      //         }else{
      //             // add new book
      //             this.addBook(newBooks[i], i);
      //         }
      //     }
      // }
      var oldCount = this.books.length;
      this.books = books.slice(0, this.maxConsume - this.books.length);
      var newCount = this.books.length;
      this.render(true);
      return newCount - oldCount; // return number of books consumed
    }
    bindEvent(node) {}
    render() {}
    updateBookPosition(book, oldPos, newPos) {}
    addBook(book, pos) {}
    markEnd() {}
    markError() {}
    markLoading() {}
    showMessage(message) {}
    childMoveOrInsertAt(parent, node, pos) {
      if (pos >= parent.children.length) {
        parent.appendChild(node);
      } else {
        parent.insertBefore(node, parent.children[pos]);
      }
    }
    clearChildren() {}
  }
  class BookGrid extends BookDisplay {
    constructor(...args) {
      super(...args);
    }
    render(isUpdate = false) {
      if (this.rootElement == null) {
        this.rootElement = document.createElement("div");
        this.rootElement.classList.add("book-grid");
        this.container.appendChild(this.rootElement);
        _defineProperty(this, "grid", app.render("book-grid", {}));
        _defineProperty(this, "indexer", {});
        this.rootElement.appendChild(this.grid);
      }
      isUpdate && this.callPlaceNode();
    }
    async callPlaceNode() {
      await this.rendering;
      var resolve = null;
      this.rendering = new Promise((rs) => {
        resolve = rs;
      });
      this.removePreloader();
      var newlyCreated = [];
      for (var i = 0; i < this.books.length; i++) {
        var n = this.placeNode(this.books[i], i);
        if (n) {
          newlyCreated.push(n);
        }
      }
      if (newlyCreated.length > 0) {
        applyFixedHeight(newlyCreated);
      }
      resolve();
    }
    async removePreloader() {
      var preloader = this.grid.querySelector(".preloader, .waitpreloader");
      if (preloader) {
        preloader.style.opacity = 0;
      }
      await this.rendering;
      // remove the preloader
      if (preloader) {
        preloader.remove();
      }
    }
    lockElementHeight(ele) {
      var h = ele.scrollHeight;
      ele.style.height = h + "px";
      ele.setAttribute("offset", ele.offsetTop);
      app.applySleepWake(ele, "none");
    }
    bindEvent(ele) {
      var data = ele.data;
      ele.addEventListener("click", function () {
        app.platform.nativeClick();
        app.fun.openBookWithData(data.lid, data);
      });
      ui.hold(ele, function () {
        app.context.current(1, ele);
      });
      ele.q("img").addEventListener("contextmenu", function (e) {
        e.preventDefault();
        e.stopPropagation();
        return false;
      });
    }
    placeNode(book, pos) {
      var node = null;
      var isNew = this.indexer[book.lid] == null;
      if (isNew) {
        node = this.getNewNode(book);
        this.bindEvent(node);
        this.childMoveOrInsertAt(this.grid, node, pos);
        this.indexer[book.lid] = node;
        this.lockElementHeight(node);
      }
      return isNew ? node : null;
    }
    markEnd() {
      if (this.loader.books.length > 0) {
        return; // dont show a message if there are any books
      }
      var noData = app.createNodata(
        app.text.nobookfound || "Không tìm thấy truyện nào...",
        false,
        // is small
        {
          text: app.text.reload,
          onclick: () => {
            this.loader.retry();
            noData.remove();
          }
        }
      );
      this.grid.appendChild(noData);
    }
    markError(msg) {
      var alreadyHaveBooks = this.loader.books.length > 0;
      var noData = app.createNodata(
        (app.text.loadbooklisterror || "Lỗi khi tải truyện...") + (msg ? `(${msg})` : ""),
        alreadyHaveBooks,
        // is small or full width
        {
          text: app.text.reload,
          onclick: () => {
            this.loader.retry();
            noData.remove();
          }
        }
      );
      if(!alreadyHaveBooks){
        noData.style.width = "80vw";
        noData.style.maxWidth = "500px";
        noData.style.transform = "translateX(-50%)";
        noData.style.left = "50%";
        noData.style.position = "absolute";
      }
      this.grid.appendChild(noData);
    }
    markLoading() {
      if (this.grid == null) {
        this.grid = this.rootElement.querySelector(".book-grid-parent");
      }
      var isHaveBooks = this.loader.books.length > 0;
      var preloader = app.createPreloader(
        app.text.loading || "Đang tải...",
        isHaveBooks,
        null,
        false,
      );
      this.grid.appendChild(preloader);
    }
    showMessage(message) {
      var noData = app.createNodata(
        message,
        false,
        // is small
        {
          text: app.text.reload,
          onclick: () => {
            this.loader.retry();
            noData.remove();
          }
        }
      );
      this.grid.appendChild(noData);
    }
    bindInfinityScroll() {
      var ref = this;
      setTimeout(async () => {
        await this.rendering;
        var inf = app.createInf(
          function () {
            this.loader.increasePage();
            inf.remove();
          }.bind(ref)
        );
        ref.grid.appendChild(inf);
      }, 500);
    }
    clearChildren() {
      this.grid.innerHTML = "";
      this.indexer = {};
    }
  }
  class BookGridNameOnly extends BookGrid {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-grid-name-only", {})
      );
    }
  }
  class BookGridNameAndAuthor extends BookGrid {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-grid-name-author", {})
      );
    }
  }
  class BookGridNameAndAuthorAndStat extends BookGrid {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-grid-name-author-stat", {})
      );
    }
  }
  class BookRow extends BookDisplay {
    constructor(...args) {
      super(...args);
    }
    render(isUpdate = false) {
      if (this.rootElement == null || this.row == null) {
        this.rootElement = document.createElement("div");
        this.rootElement.classList.add("book-row-container");
        this.container.appendChild(this.rootElement);
        _defineProperty(this, "row", app.render("book-list", {}));
        _defineProperty(this, "indexer", {});
        this.rootElement.appendChild(this.row);
      }
      isUpdate && this.callPlaceNode();
    }
    async callPlaceNode() {
      await this.rendering;
      var resolve = null;
      this.rendering = new Promise((rs) => {
        resolve = rs;
      });
      this.removePreloader();
      var newlyCreated = [];
      for (var i = 0; i < this.books.length; i++) {
        var n = this.placeNode(this.books[i], i);
        if (n) {
          newlyCreated.push(n);
        }
        // if(i % 3 == 0){
        //     if(newlyCreated.length > 0){
        //         applyFixedHeight(newlyCreated);
        //         newlyCreated = [];
        //     }
        // }
      }
      if (newlyCreated.length > 0) {
        applyFixedHeight(newlyCreated);
      }
      resolve();
    }
    placeNode(book, pos) {
      var node = null;
      var isNew = this.indexer[book.lid] == null;
      if (isNew) {
        node = this.getNewNode(book);
        this.bindEvent(node);
        this.childMoveOrInsertAt(this.row, node, pos);
        this.indexer[book.lid] = node;
      }
      return isNew ? node : null;
    }
    bindEvent(node) {}
    markEnd() {
      var isSmall = this.loader.books.length > 0;
      if (isSmall) {
        return;
      }
      var text = app.text.nobookfound || "Không tìm thấy truyện nào...";
      var noData = app.createNodata(
        text,
        isSmall,
        // is small
        {
          text: app.text.reload,
          onclick: () => {
            this.loader.retry();
            noData.remove();
          }
        }
      );
      this.row.appendChild(noData);
    }
    markError(msg) {
      var alreadyHaveBooks = this.loader.books.length > 0;
      var noData = app.createNodata(
        (app.text.loadbooklisterror || "Lỗi khi tải truyện...") + (msg ? `(${msg})` : ""),
        alreadyHaveBooks,
        // is small or full width
        {
          text: app.text.reload,
          onclick: () => {
            this.loader.retry();
            noData.remove();
          }
        }
      );
      this.row.appendChild(noData);
    }
    markLoading() {
      // if (this.row == null) {
      //   this.row = this.rootElement.querySelector(".book-list");
      // }
      var isHaveBooks = this.loader.books.length > 0;
      var preloader = app.createPreloader(
        app.text.loading || "Đang tải...",
        isHaveBooks,
        null,
        false,
      );
      this.row.appendChild(preloader);
      preloader.onVisible();
    }
    async removePreloader() {
      // set visible to false
      var preloader = this.row.querySelector(".preloader, .waitpreloader");
      if (preloader) {
        preloader.style.opacity = 0;
      }
      await this.rendering;
      // remove the preloader
      if (preloader) {
        preloader.remove();
      }
    }
    showMessage(message) {
      var noData = app.createNodata(
        message,
        false,
        // is small
        {
          text: app.text.reload,
          onclick: () => {
            this.loader.retry();
            noData.remove();
          }
        }
      );
      this.row.appendChild(noData);
    }
    bindInfinityScroll() {
      var ref = this;
      setTimeout(async () => {
        await this.rendering;
        var inf = app.createInf(
          function () {
            this.loader.increasePage();
            inf.remove();
          }.bind(ref)
        );
        ref.row.appendChild(inf);
      }, 500);
    }
    clearChildren() {
      this.row.innerHTML = "";
      this.indexer = {};
    }
  }
  class BookRowNameAndAuthor extends BookRow {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-row-name-author", {})
      );
    }
    bindEvent(ele) {
      var data = ele.data;
      ele.addEventListener("click", function () {
        app.platform.nativeClick();
        app.fun.openBookWithData(data.lid, data);
      });
      ui.hold(ele, function () {
        app.context.current(1, ele);
      });
      ele.q("img").addEventListener("contextmenu", function (e) {
        e.preventDefault();
        e.stopPropagation();
        return false;
      });
    }
  }
  class BookRowNameAndAuthorAndStat extends BookRow {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-row-name-author", {})
      );
    }
    bindEvent(ele) {
      var data = ele.data;
      var exInfo =
        `${data.viewweek} \uf06e`.padRight(" ", 8) +
        ` ${data.star} \uf005`.padRight(" ", 9) +
        `${data.liked} \uf164`.padRight(" ", 7) +
        `${data.subscribe} \uf09e`.padRight(" ", 6) +
        `${data.chaptercount} \uf1f9`;
      ele.q(".tags").textContent = exInfo;
      ele.addEventListener("click", function () {
        app.platform.nativeClick();
        app.fun.openBookWithData(data.lid, data);
      });
      ui.hold(ele, function () {
        app.context.current(1, ele);
      });
      ele.q("img").addEventListener("contextmenu", function (e) {
        e.preventDefault();
        e.stopPropagation();
        return false;
      });
    }
  }
  class BookRowExtended extends BookRow {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-row-extended", {})
      );
    }
    bindEvent(ele) {
      var data = ele.data;
      var exInfo =
        `\uf06e ${data.viewweek} ` +
        `\uf005 ${data.star} ` +
        `\uf164 ${data.liked} ` +
        `\uf09e ${data.subscribe} ` +
        `\uf1f9 ${data.chaptercount} `;
      ele.q(".etags").textContent = exInfo;
      ele.q(".tinfo").textContent = data.info;
      ele.q(".categories").textContent = "#" + [data.host, getBookStep(data.status)].concat(tryParseBookCate(data.category)).join(", #");
      ele.addEventListener("click", function () {
        app.platform.nativeClick();
        app.fun.openBookWithData(data.lid, data);
      });
      ui.hold(ele, function () {
        app.context.current(1, ele);
      });
      ele.q("img").addEventListener("contextmenu", function (e) {
        e.preventDefault();
        e.stopPropagation();
        return false;
      });
    }
  }
  class BookSlider extends BookDisplay {
    constructor(...args) {
      super(...args);
      _defineProperty(this, "slider", null);
      _defineProperty(this, "rowNum", 1);
      _defineProperty(this, "colNum", 3);
      _defineProperty(this, "maxConsume", 6);
    }
    async render() {
      if (this.rootElement == null) {
        this.rootElement = document.createElement("div");
        this.rootElement.classList.add("book-slider");
        this.container.appendChild(this.rootElement);
        this.slider = app.render("book-slider", {});
        this.rootElement.appendChild(this.slider);
      }
      await this.callPlaceNode();
    }
    async callPlaceNode() {
      for (var i = 0; i < this.books.length; i++) {
        this.placeNode(this.books[i], i);
        if (i % 3 == 0) {
          await waitFrame(); // smooth rendering
        }
      }
    }
    getSubNodeIndex(pos) {
      // get the column index, where ordered as up to down, then next column
      return Math.floor(pos / this.rowNum);
    }
    placeNode(book, pos) {
      var nodeId = "book-" + book.lid;
      var node = this.slider.querySelector("." + nodeId); // use class as id
      if (node == null) {
        node = this.getNewNode(book);
        this.bindEvent(node);
      }
      var subNode = this.slider.children[this.getSubNodeIndex(pos)];
      if (!subNode) {
        subNode = document.createElement("div");
        subNode.classList.add("book-slider-column");
        this.slider.appendChild(subNode);
      }
      var oldIndex = Array.from(subNode.children).indexOf(node);
      if (oldIndex != pos) {
        // prevent dom reflow
        this.childMoveOrInsertAt(subNode, node, Math.min(pos % this.rowNum));
      }
    }
  }
  class BookSliderNameOnly extends BookSlider {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-slider-name-only", {})
      );
    }
  }
  class BookSliderNameAndAuthor extends BookSlider {
    constructor(...args) {
      super(...args);
      _defineProperty(
        this,
        "baseBookElement",
        app.render("book-slider-name-author", {})
      );
    }
  }
  class BookTiktokSlideShow extends BookDisplay {
    constructor(...args) {
      super(...args);
      // tiktok like slide show that can swipe up and down
      _defineProperty(this, "slider", null);
    }
    render() {
      if (this.rootElement == null) {
        this.rootElement = document.createElement("div");
        this.rootElement.classList.add("book-tiktok");
        this.container.appendChild(this.rootElement);
        this.slider = app.render("book-tiktok", {});
        this.rootElement.appendChild(this.slider);
      }
      // not implement yet
    }
  }
  class BookListLoader {
    constructor(link, container, renderer) {
      _defineProperty(this, "pageParam", "p");
      _defineProperty(this, "page", 0);
      _defineProperty(this, "baseLink", "");
      _defineProperty(this, "container", null);
      _defineProperty(this, "renderer", null);
      _defineProperty(this, "books", []);
      _defineProperty(this, "showPagination", false);
      // Use endless scroll by default
      _defineProperty(this, "customLoader", null);
      _defineProperty(this, "extendedContextMenu", []);
      _defineProperty(this, "rendererLoaded", null);
      if (link != null) {
        this.setBaseLink(link);
      }
      if (container != null) {
        this.setContainer(container);
      }
      if (renderer != null) {
        this.setRenderer(renderer);
      }
      this.rendererLoaded = createPromise();
    }
    setBaseLink(link) {
      link = fullUrl(link);
      var url = new URL(link);
      var searchParams = url.searchParams;
      if (searchParams.has("page")) {
        this.page = searchParams.get("page");
        searchParams.delete("page");
        this.pageParam = "page";
      }
      if (searchParams.has("p")) {
        this.page = searchParams.get("p");
        searchParams.delete("p");
        this.pageParam = "p";
      }
      this.baseLink = app.net.networkManager.bestDomain() + url.pathname + "?" + searchParams.toString();
      return this;
    }
    setContainer(container) {
      this.container = container;
      this.container.style.position = "relative";
      this.container.style.overflowY = "scroll";
      this.container.style.overflowX = "hidden";
      this.container.style.display = "block";
      this.container.style.height = "100%";
      return this;
    }
    async setRenderer(renderer) {
      var resovle = null;
      await app.history.isLoaded();
      var rendererClass = {
        "row-1": BookRowNameAndAuthor,
        "row-2": BookRowNameAndAuthorAndStat,
        "row-3": BookRowExtended,
        "grid-0": BookGridNameOnly,
        "grid-1": BookGridNameAndAuthor,
        "grid-2": BookGridNameAndAuthorAndStat,
        "slider-0": BookSliderNameOnly,
        "slider-1": BookSliderNameAndAuthor,
        "tiktok-0": BookTiktokSlideShow
      };
      if (renderer.includes(",")) {
        var multiRenderer = renderer.split(",");
        this.renderer = [];
        for (var i = 0; i < multiRenderer.length; i++) {
          this.renderer.push(
            new rendererClass[multiRenderer[i]](this, this.container)
          );
        }
      } else {
        this.renderer = [new rendererClass[renderer](this, this.container)];
        console.log(this.renderer[0].row);
      }
      this.rendererLoaded.resolve();
      return this;
    }
    setCustomLoader(loader) {
      this.customLoader = loader;
      return this;
    }
    setExtendedContextMenu(menu) {
      this.extendedContextMenu = menu;
      return this;
    }
    autoPopulate() {
      if (this.container == null || this.renderer == null) {
        return;
      }
      var consumed = 0;
      for (var i = 0; i < this.renderer.length; i++) {
        consumed += this.renderer[i].consume(
          this.books.slice(consumed),
          this.container
        );
        if (consumed >= this.books.length) {
          break;
        }
      }
      if (this.showPagination == false) {
        this.bindInfinityScroll();
      }
    }
    increasePage() {
      this.page++;
      this.loader();
    }
    markEndOfList() {
      var last = this.renderer[this.renderer.length - 1];
      last.markEnd();
    }
    markLoadError(msg) {
      var last = this.renderer[this.renderer.length - 1];
      last.markError(msg);
    }
    markLoading() {
      var last = this.renderer[this.renderer.length - 1];
      last.markLoading();
    }
    showMessage(message) {
      var last = this.renderer[this.renderer.length - 1];
      last.showMessage(message);
    }
    bindInfinityScroll() {
      var last = this.renderer[this.renderer.length - 1];
      last.bindInfinityScroll();
    }
    clearAllPreloader() {
      this.container
        .querySelectorAll(".preloader, .waitpreloader")
        .forEach((e) => e.remove());
    }
    clearAllAlert() {
      this.container
        .querySelectorAll('[view="nodata"]')
        .forEach((e) => e.remove());
    }
    clearAllContent() {
      for (var i = 0; i < this.renderer.length; i++) {
        this.renderer[i].clearChildren();
      }
    }
    async loader(isReset = false) {
      var self = this;
      await this.rendererLoaded;
      var link = this.baseLink;
      var resultCode = false;
      if (link.indexOf("?") >= 0) {
        link += "&";
      } else {
        link += "?";
      }
      link += this.pageParam + "=" + this.page;
      var promise = null;
      if (this.customLoader != null) {
        promise = this.customLoader(link, this.page);
      } else {
        // promise = app.net.get(link);
        if (window.Capacitor && window.Capacitor.Plugins.Http) {
          var context = window.Capacitor.Plugins.Http;
          promise = new Promise((resolve, reject) => {
            var url = new URL(link);
            var origin = app.net.networkManager.bestDomain();
            link = origin + url.pathname + "?" + url.searchParams.toString();
            context.get({
              url: link,
              headers: {
                "x-stv-transport": "app",
                "x-requested-with": "com.sangtacviet.mobilereader",
                "User-Agent": navigator.userAgent,
                "Accept": "application/json, text/plain, */*",
                "Cookie": document.cookie,
              },
              ipv6: false
            })
              .then((rsp) => {
                if (rsp.status === 200) {
                  if (typeof rsp.data === "string" && rsp.data.startsWith("{")) {
                    rsp.data = JSON.parse(rsp.data);
                  }
                  resolve(rsp.data);
                } else {
                  reject(new Error("HTTP error: " + rsp.status));
                }
              })
              .catch((err) => {
                console.error("HTTP request failed", err);
                app.net.networkManager.checkDomains();
                reject(err);
              });
          });
        } else {
          var url = new URL(link);
          origin = location.origin; // use the current origin
          link = origin + url.pathname + "?" + url.searchParams.toString();
          promise = app.net.get(link);
        }
      }
      this.markLoading();
      await promise
        .then((rsp) => {
          console.log("Booklist loaded", rsp);
          if (isReset) {
            self.books = [];
            self.clearAllPreloader();
          }
          if (rsp.message || rsp.text) {
            resultCode = false;
            self.clearAllPreloader();
            if(isReset){
              self.clearAllContent();
            }
            var msg = (rsp.message || rsp.text || "").replace(/Permission denied/g, app.text.you_have_not_login);
            return self.markLoadError(msg);
          }
          var list = rsp.list;
          resultCode = true;
          if (!list || list.length == 0) {
            self.clearAllPreloader();
            if(isReset){
              self.clearAllContent();
            }
            return self.markEndOfList();
          }
          self.books = self.books.concat(list);
          if (isReset) {
            self.clearAllContent();
          }
          self.autoPopulate();
        })
        .catch((err) => {
          console.error(err);
          self.clearAllPreloader();
          if(isReset){
            self.clearAllContent();
          }
          self.markLoadError(err.message || err);
          app.debug.report({stack: JSON.stringify(err) + self.baseLink + " f2 test"});
        });
      console.log("Booklist loader done", resultCode);
      return resultCode;
    }
    async reset() {
      this.page = 0;
      return await this.loader(true);
    }
    retry() {
      this.clearAllAlert();
      this.loader();
    }
  }

window.BookListLoader = BookListLoader; // Fix a weird bug