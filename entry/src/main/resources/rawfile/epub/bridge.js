/**
 * EPUB.js + HarmonyOS WebView 桥接层
 *
 * 通信协议：
 *   ArkTS → JS: window.loadBook(path), prevPage(), nextPage(), goTo(cfi), setTheme(json), setFont(json)
 *   JS → ArkTS: window.__event 队列，ArkTS 通过 pollEvent() 读取
 */
(function () {
  'use strict';

  var book = null;
  var rendition = null;
  var currentCfi = null;
  var totalPages = 0;
  var eventQueue = [];

  /** 向 ArkTS 推送事件 */
  function emit(eventType, data) {
    eventQueue.push({ type: eventType, data: data || null, time: Date.now() });
  }

  // ==================== 公开 API（由 ArkTS 调用） ====================

  /** 加载 EPUB 文件 */
  window.loadBook = function (filePath) {
    document.getElementById('loading').style.display = 'block';
    if (book) { try { book.destroy(); } catch (e) {} }

    book = ePub(filePath);
    rendition = book.renderTo('viewer', {
      width: '100%',
      height: '100%',
      spread: 'none',
      flow: 'paginated',
      manager: 'continuous',
    });

    // 加载完成后获取目录并报告
    book.ready.then(function () {
      document.getElementById('loading').style.display = 'none';

      // 报告元数据
      var meta = book.package.metadata;
      emit('metadata', {
        title: meta.title || '',
        author: meta.creator || '',
      });

      // 提取目录
      var toc = book.navigation && book.navigation.toc ? book.navigation.toc : [];
      var flatToc = [];
      function flatten(items) {
        if (!items) return;
        for (var i = 0; i < items.length; i++) {
          flatToc.push({ label: items[i].label, href: items[i].href });
          if (items[i].subitems && items[i].subitems.length > 0) {
            flatten(items[i].subitems);
          }
        }
      }
      flatten(toc);
      emit('toc', flatToc);

      // 监听定位变化（翻页/跳转）
      rendition.on('relocated', function (location) {
        if (!location) return;
        currentCfi = location.start ? location.start.cfi : '';
        var startIndex = location.start ? location.start.index : 0;
        var endIndex = location.end ? location.end.index : 0;
        // 计算总页数
        var pageCount = 0;
        if (location.start && location.start.displayed) {
          pageCount = location.start.displayed.page;
        } else if (location.end && location.end.displayed) {
          pageCount = location.end.displayed.page;
        }
        totalPages = location.totalPages || pageCount || 0;
        emit('location', {
          cfi: currentCfi,
          chapterIndex: startIndex,
          page: pageCount,
          totalPages: totalPages,
        });
      });

      // 渲染首章
      rendition.display();

      emit('ready', {});
    });
  };

  /** 下一页 */
  window.nextPage = function () {
    if (rendition) rendition.next();
  };

  /** 上一页 */
  window.prevPage = function () {
    if (rendition) rendition.prev();
  };

  /** 跳转到指定 CFI */
  window.goTo = function (cfi) {
    if (rendition && cfi) rendition.display(cfi);
  };

  /** 跳转到目录项 */
  window.goToHref = function (href) {
    if (rendition && href) rendition.display(href);
  };

  /** 设置主题 */
  window.setTheme = function (json) {
    try {
      var cfg = typeof json === 'string' ? JSON.parse(json) : json;
      if (rendition && rendition.getContents) {
        rendition.getContents().forEach(function (content) {
          if (cfg.backgroundColor) content.document.body.style.backgroundColor = cfg.backgroundColor;
          if (cfg.color) content.document.body.style.color = cfg.color;
        });
      }
      if (cfg.backgroundColor) document.body.style.backgroundColor = cfg.backgroundColor;
    } catch (e) {}
  };

  /** 设置字体 */
  window.setFont = function (json) {
    try {
      var cfg = typeof json === 'string' ? JSON.parse(json) : json;
      if (rendition) {
        rendition.themes.register('custom', {
          body: {
            'font-family': cfg.fontFamily || "'PingFang SC', 'Noto Sans SC', serif",
            'font-size': (cfg.fontSize || 18) + 'px',
            'line-height': (cfg.lineHeight || 1.8),
            'text-align': cfg.textAlign || 'justify',
          }
        });
        rendition.themes.select('custom');
      }
    } catch (e) {}
  };

  /** 获取未读事件（ArkTS 轮询用） */
  window.pollEvent = function () {
    if (eventQueue.length === 0) return 'null';
    var evt = eventQueue.shift();
    return JSON.stringify(evt);
  };
})();
