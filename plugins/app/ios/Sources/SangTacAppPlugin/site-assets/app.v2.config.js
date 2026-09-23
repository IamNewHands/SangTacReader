(async function(app){
    // app behavior settings
    app.config = {};
    app.config.readerDefault = {
        "way_to_choose_node": "click",
        "show_title": true,
        "chapter_name_ontop": true,
        "show_chapter_name_fixed": true,
        "prepend_chapter_name": false,
        "allow_edit": true,
        "allow_drag_to_expand": true,
        "left_tap_action": "none",
        "right_tap_action": "none",
        "save_on_case_click": false,
        "last_tts_maxtime": 0,
        "transmode": "vp",
        "chapter_name_fixed_place": "top",
        "italic_talk_sentence": false,
        "context_menu_scale": 1,
        "ctx_addname_btn": true,
        "ctx_copy_btn": false,
        "ctx_search_btn": true,
        "display_type": "auto",
        "page_flip_sound": false,
    };
    app.config.comicReaderDefault = {
        "transmode": "perpair",
        "translang": "zh",
    };
    app.config.uxDefault = {
        text_brightness: "1",
        allow_image_preload: "true",
        notification_allow_on_chapter_update: "true",
        notification_allow_on_reply: "true",
        notification_allow_on_tag: "true",
        app_language: "vi",
        app_domain: "auto",
    };
    app.config.reader = {};
    app.config.comicReader = {};
    await onDbLoad.waitForLoad();
    var loadedReaderSetting = JSON.parse((await app.storage.cache.getFile("config.reader")) || "{}");
    var loadedComicReaderSetting = JSON.parse((await app.storage.cache.getFile("config.comicReader")) || "{}");
    var loadedUxSetting = JSON.parse((await app.storage.cache.getFile("config.ux")) || "{}");
    app.config._reader = $.extend({},app.config.readerDefault, loadedReaderSetting);
    app.config._ux = $.extend({},app.config.uxDefault, loadedUxSetting);
    app.config._comicReader = $.extend({},app.config.comicReaderDefault, loadedComicReaderSetting);
    app.config.ux = {};

    for(let key in app.config._reader){
        app.config.reader.__defineGetter__(key, function(){
            let v = app.config._reader[key];
            if(v == "false"){
                return false;
            }
            if(v == "true"){
                return true;
            }
            return v;
        });
        app.config.reader.__defineSetter__(key, function(value){
            app.config._reader[key] = value;
            app.config.saveReaderSetting();
        });
    }
    for(let key in app.config._ux){
        app.config.ux.__defineGetter__(key, function(){
            let v = app.config._ux[key];
            if(v == "false"){
                return false;
            }
            if(v == "true"){
                return true;
            }
            return v;
        });
        app.config.ux.__defineSetter__(key, function(value){
            app.config._ux[key] = value;
            //console.log("set ux", key, value);
           // printStackTrace();
            app.config.saveUxSetting();
        });
    }
    for(let key in app.config._comicReader){
        app.config.comicReader.__defineGetter__(key, function(){
            let v = app.config._comicReader[key];
            if(v == "false"){
                return false;
            }
            if(v == "true"){
                return true;
            }
            return v;
        });
        app.config.comicReader.__defineSetter__(key, function(value){
            app.config._comicReader[key] = value;
            app.config.saveComicReaderSetting();
        });
    }
    function saveSetting(type, obj){
        app.storage.cache.setFile("config."+type, JSON.stringify(obj));
    }
    app.config.saveReaderSetting = function(){
        saveSetting("reader", app.config._reader);
    }
    app.config.saveUxSetting = function(){
        saveSetting("ux", app.config._ux);
    }
    app.config.saveComicReaderSetting = function(){
        saveSetting("comicReader", app.config._comicReader);
    }

    // onloaded
    app.theme.generatorExcute(app.theme.css);
    
})(app);