/*
 * EPUB.js + HarmonyOS WebView bridge.
 *
 * ArkTS -> JS:
 *   loadBook(url, target), prevPage(), nextPage(), goTo(cfi), goToHref(href),
 *   applyStyle(style), clearSelection(), pollEvent()
 *
 * JS -> ArkTS:
 *   eventQueue via pollEvent()
 */
(function () {
  'use strict';

  var book = null;
  var rendition = null;
  var eventQueue = [];
  var currentStyle = {};
  var currentBookUrl = '';
  var zoneActions = [4, 2, 3, 2, 0, 1, 2, 1, 1];
  var lastHandledTapAt = 0;
  var ACTION_NONE = -1;
  var ACTION_MENU = 0;
  var ACTION_NEXT_PAGE = 1;
  var ACTION_PREV_PAGE = 2;
  var BOOK_FONT_FAMILY = '__book__';
  var PAGE_GAP = 0;
  var livePageFrame = 0;
  var lastLivePageKey = '';

  function emit(type, data) {
    eventQueue.push({ type: type, data: data || {}, time: Date.now() });
    if (eventQueue.length > 80) {
      eventQueue.splice(0, eventQueue.length - 80);
    }
  }

  function errorMessage(err) {
    return err && err.message ? err.message : String(err);
  }

  window.onerror = function (message, source, line, column, error) {
    emit('error', {
      message: error ? errorMessage(error) : String(message || 'JavaScript error'),
      source: source || '',
      line: line || 0,
      column: column || 0
    });
    return false;
  };

  window.onunhandledrejection = function (event) {
    emit('debug', { message: 'unhandled rejection: ' + errorMessage(event && event.reason ? event.reason : 'unknown') });
  };

  function qs(name) {
    var params = new URLSearchParams(window.location.search || '');
    return params.get(name) || '';
  }

  function loading(show, text) {
    var el = document.getElementById('loading');
    if (!el) return;
    el.style.display = show ? 'block' : 'none';
    if (text) el.textContent = text;
  }

  function parseStyle(style) {
    if (!style) return {};
    if (typeof style === 'object') return style;
    try {
      return JSON.parse(style);
    } catch (e) {
      emit('debug', { message: 'style parse failed: ' + errorMessage(e) });
      return {};
    }
  }

  function parseActions(actions) {
    var parsed = actions;
    if (typeof actions === 'string') {
      try {
        parsed = JSON.parse(actions || '[]');
      } catch (e) {
        emit('debug', { message: 'actions parse failed: ' + errorMessage(e) });
        parsed = [];
      }
    }
    if (!Array.isArray(parsed) || parsed.length !== 9) {
      return [4, 2, 3, 2, 0, 1, 2, 1, 1];
    }
    var result = [];
    for (var i = 0; i < 9; i++) {
      var action = Number(parsed[i]);
      result.push(Number.isFinite(action) ? action : -1);
    }
    return result;
  }

  function safePercent(location) {
    try {
      if (book && book.locations && location && location.start && location.start.cfi) {
        var p = book.locations.percentageFromCfi(location.start.cfi);
        return Number.isFinite(p) ? p : 0;
      }
    } catch (e) {}
    return 0;
  }

  function hrefFromLocation(location) {
    try {
      if (!book || !book.spine || !location || !location.start) return '';
      var section = book.spine.get(location.start.index);
      return section && section.href ? section.href : '';
    } catch (e) {
      return '';
    }
  }

  // TOC 章节映射：把 spine index 映射为目录 chapter index，
  // 避免图片等独立 spine 项导致章节名显示错误
  var tocChapterMap = [];

  function buildTocChapterMap() {
    tocChapterMap = [];
    if (!book || !book.navigation || !book.spine) return;
    var flat = [];
    function walk(items) {
      if (!items) return;
      for (var i = 0; i < items.length; i++) {
        flat.push(items[i]);
        if (items[i].subitems && items[i].subitems.length) walk(items[i].subitems);
      }
    }
    walk(book.navigation.toc || []);
    for (var i = 0; i < flat.length; i++) {
      var item = flat[i];
      var href = (item.href || '').split('#')[0];
      if (!href) continue;
      var spineIndex = -1;
      try {
        var section = book.spine.get(href);
        if (section && typeof section.index === 'number') spineIndex = section.index;
      } catch (e) {}
      if (spineIndex < 0) {
        try {
          for (var j = 0; j < book.spine.length; j++) {
            var s = book.spine.get(j);
            if (s && s.href && s.href.split('#')[0] === href) {
              spineIndex = j;
              break;
            }
          }
        } catch (e2) {}
      }
      if (spineIndex >= 0) {
        tocChapterMap.push({ spineIndex: spineIndex, chapterIndex: i, href: href });
      }
    }
    tocChapterMap.sort(function (a, b) { return a.spineIndex - b.spineIndex; });
  }

  function chapterIndexFromSpineIndex(spineIndex) {
    if (tocChapterMap.length === 0) return spineIndex;
    var result = 0;
    for (var i = 0; i < tocChapterMap.length; i++) {
      if (tocChapterMap[i].spineIndex <= spineIndex) {
        result = tocChapterMap[i].chapterIndex;
      } else {
        break;
      }
    }
    return result;
  }

  function cssValue(value, fallback) {
    return value === undefined || value === null || value === '' ? fallback : value;
  }

  function cssString(value) {
    return "'" + String(value || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
  }

  function cssUrl(value) {
    return String(value || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'");
  }

  function cssFontFamily(value) {
    var family = String(cssValue(value, 'HarmonyOS Sans'));
    if (family === 'serif' || family === 'monospace' || family === 'sans-serif') {
      return family;
    }
    return cssString(family) + ', sans-serif';
  }

  function fontFaceCss() {
    if (currentStyle && currentStyle.fontFamily === BOOK_FONT_FAMILY) return '';
    var faces = currentStyle && Array.isArray(currentStyle.fontFaces) ? currentStyle.fontFaces : [];
    var css = '';
    for (var i = 0; i < faces.length; i++) {
      var face = faces[i] || {};
      if (!face.familyName || !face.url) continue;
      css += '@font-face{font-family:' + cssString(face.familyName) + ';src:url(\'' + cssUrl(face.url) + '\');font-display:swap;}';
    }
    return css;
  }

  function applyRootStyle() {
    var v = currentStyleValues();
    var bg = v.bg;
    document.documentElement.style.backgroundColor = bg;
    document.body.style.backgroundColor = bg;
    var frame = document.getElementById('reader-frame');
    if (frame) {
      frame.style.backgroundColor = bg;
      frame.style.paddingLeft = v.pl + 'px';
      frame.style.paddingRight = v.pr + 'px';
      frame.style.boxSizing = 'border-box';
    }
    var viewer = document.getElementById('viewer');
    if (viewer) {
      viewer.style.backgroundColor = bg;
      viewer.style.paddingLeft = '0px';
      viewer.style.paddingRight = '0px';
      viewer.style.boxSizing = 'border-box';
      viewer.style.width = '100%';
      viewer.style.height = '100%';
    }
  }

  function currentStyleValues() {
    var bg = cssValue(currentStyle.backgroundColor, '#F5F0E8');
    var color = cssValue(currentStyle.color, '#333333');
    var fontSize = Number(cssValue(currentStyle.fontSize, 18));
    var family = cssValue(currentStyle.fontFamily, BOOK_FONT_FAMILY);
    var useBookFont = family === BOOK_FONT_FAMILY;
    var familyCss = useBookFont ? '' : cssFontFamily(family);
    var weight = cssValue(currentStyle.fontWeight, '400');
    var lineHeight = Number(cssValue(currentStyle.lineHeight, 1.6));
    var letterSpacing = Number(cssValue(currentStyle.letterSpacing, 0));
    var paraSpacing = Number(cssValue(currentStyle.paragraphSpacing, 10));
    var indent = Number(cssValue(currentStyle.indentSize, 2));
    var pt = Number(cssValue(currentStyle.paddingTop, 24));
    var pb = Number(cssValue(currentStyle.paddingBottom, 24));
    var pl = Number(cssValue(currentStyle.paddingLeft, 20));
    var pr = Number(cssValue(currentStyle.paddingRight, 20));
    var textAlign = cssValue(currentStyle.textAlign, 'justify');
    var flowMode = cssValue(currentStyle.flowMode, 'paginated');
    return {
      bg: bg,
      color: color,
      fontSize: fontSize,
      family: family,
      familyCss: familyCss,
      useBookFont: useBookFont,
      weight: weight,
      lineHeight: lineHeight,
      letterSpacing: letterSpacing,
      paraSpacing: paraSpacing,
      indent: indent,
      pt: pt,
      pb: pb,
      pl: pl,
      pr: pr,
      textAlign: textAlign,
      flowMode: flowMode
    };
  }

  function currentChineseMode() {
    var mode = cssValue(currentStyle.chineseMode, 'original');
    return mode === 'simplified' || mode === 'traditional' ? mode : 'original';
  }

  function applyChineseConversion(doc) {
    if (!doc || !doc.body) return;
    try {
      if (!window.LegadoChineseConverter || !window.LegadoChineseConverter.convertDocument) return;
      window.LegadoChineseConverter.convertDocument(doc, currentChineseMode());
    } catch (e) {
      emit('debug', { message: 'chinese conversion failed: ' + errorMessage(e) });
    }
  }

  function currentThemeRules() {
    var v = currentStyleValues();
    var bodyRule = {
      'background': v.bg + ' !important',
      'color': v.color + ' !important',
      'font-size': v.fontSize + 'px !important',
      'font-weight': v.weight + ' !important',
      'line-height': String(v.lineHeight) + ' !important',
      'letter-spacing': v.letterSpacing + 'px !important',
      'text-align': v.textAlign + ' !important',
      'box-sizing': 'border-box !important',
      'padding': v.pt + 'px 0 ' + v.pb + 'px 0 !important'
    };
    var bodyAllRule = {
      'box-sizing': 'border-box !important',
      'font-weight': v.weight + ' !important',
      'letter-spacing': v.letterSpacing + 'px !important'
    };
    if (!v.useBookFont) {
      bodyRule['font-family'] = v.familyCss + ' !important';
      bodyAllRule['font-family'] = v.familyCss + ' !important';
    }

    return {
      'html': {
        'background': v.bg + ' !important',
        'color': v.color + ' !important'
      },
      'body': bodyRule,
      'body *': bodyAllRule,
      'p': {
        'margin-top': '0 !important',
        'margin-bottom': v.paraSpacing + 'px !important',
        'text-indent': v.indent + 'em',
        'font-weight': v.weight + ' !important',
        'letter-spacing': v.letterSpacing + 'px !important'
      },
      'img,svg': {
        'max-width': '100% !important',
        'max-height': v.flowMode === 'scrolled' ? 'none !important' : '85vh !important',
        'object-fit': 'contain !important',
        'page-break-inside': v.flowMode === 'scrolled' ? 'auto !important' : 'avoid !important',
        'break-inside': v.flowMode === 'scrolled' ? 'auto !important' : 'avoid !important'
      },
      'table': {
        'max-width': '100% !important'
      },
      'a': {
        'color': 'inherit !important'
      }
    };
  }

  function applyRenditionTheme() {
    if (!rendition || !rendition.themes) return;
    try {
      rendition.themes.register('legado-reader', currentThemeRules());
      rendition.themes.select('legado-reader');
    } catch (e) {
      emit('debug', { message: 'theme apply failed: ' + errorMessage(e) });
    }
  }

  function injectStyle(doc) {
    if (!doc || !doc.documentElement) return;
    var style = doc.getElementById('legado-reader-style');
    if (!style) {
      style = doc.createElement('style');
      style.id = 'legado-reader-style';
      (doc.head || doc.documentElement).appendChild(style);
    }

    var v = currentStyleValues();
    var bodyFontCss = v.useBookFont ? '' : 'font-family:' + v.familyCss + ' !important;';
    var bodyAllFontCss = v.useBookFont ? '' : 'font-family:' + v.familyCss + ' !important;';

    style.textContent =
      fontFaceCss() +
      'html,body{background:' + v.bg + ' !important;color:' + v.color + ' !important;}' +
      'body{' + bodyFontCss + 'font-size:' + v.fontSize + 'px !important;' +
      'font-weight:' + v.weight + ' !important;line-height:' + v.lineHeight + ' !important;' +
      'letter-spacing:' + v.letterSpacing + 'px !important;text-align:' + v.textAlign + ' !important;' +
      'box-sizing:border-box !important;padding:' + v.pt + 'px 0 ' + v.pb + 'px 0 !important;}' +
      'body *{' + bodyAllFontCss + 'box-sizing:border-box !important;font-weight:' + v.weight + ' !important;' +
      'letter-spacing:' + v.letterSpacing + 'px !important;}' +
      'p{margin-top:0 !important;margin-bottom:' + v.paraSpacing + 'px !important;text-indent:' + v.indent + 'em;' +
      'font-weight:' + v.weight + ' !important;letter-spacing:' + v.letterSpacing + 'px !important;}' +
      'img,svg{max-width:100% !important;max-height:' + (v.flowMode === 'scrolled' ? 'none' : '85vh') + ' !important;object-fit:contain !important;' +
      'page-break-inside:' + (v.flowMode === 'scrolled' ? 'auto' : 'avoid') + ' !important;break-inside:' + (v.flowMode === 'scrolled' ? 'auto' : 'avoid') + ' !important;}' +
      'table{max-width:100% !important;}a{color:inherit !important;}';

    doc.documentElement.style.backgroundColor = v.bg;
    if (doc.body) {
      doc.body.style.backgroundColor = v.bg;
      doc.body.style.color = v.color;
      if (v.useBookFont) {
        doc.body.style.removeProperty('font-family');
      } else {
        doc.body.style.fontFamily = v.familyCss;
      }
      doc.body.style.fontSize = v.fontSize + 'px';
      doc.body.style.fontWeight = v.weight;
      doc.body.style.lineHeight = String(v.lineHeight);
      doc.body.style.letterSpacing = v.letterSpacing + 'px';
      doc.body.style.boxSizing = 'border-box';
      doc.body.style.paddingLeft = '0px';
      doc.body.style.paddingRight = '0px';
    }
  }

  function hasSelection(doc) {
    try {
      var sel = doc && doc.getSelection ? doc.getSelection() : null;
      if (sel && String(sel.toString()).trim()) return true;
    } catch (e) {}
    return false;
  }

  function clearSelections() {
    try {
      if (window.getSelection) window.getSelection().removeAllRanges();
    } catch (e) {}
    try {
      if (rendition) {
        rendition.getContents().forEach(function (content) {
          try {
            if (content.document && content.document.getSelection) {
              content.document.getSelection().removeAllRanges();
            }
          } catch (e2) {}
        });
      }
    } catch (e3) {}
  }

  function isInteractiveTarget(target) {
    var el = target;
    while (el && el.nodeType === 1) {
      var name = String(el.tagName || '').toLowerCase();
      if (name === 'a' || name === 'button' || name === 'input' || name === 'textarea' || name === 'select') {
        return true;
      }
      el = el.parentElement;
    }
    return false;
  }

  function frameViewportSize() {
    try {
      var frame = document.getElementById('reader-frame');
      if (frame && frame.getBoundingClientRect) {
        var frameRect = frame.getBoundingClientRect();
        if (frameRect.width > 0 && frameRect.height > 0) {
          return { width: frameRect.width, height: frameRect.height, source: 'frame' };
        }
      }
    } catch (e) {}

    try {
      var view = window;
      var visualWidth = view.visualViewport ? view.visualViewport.width : 0;
      var visualHeight = view.visualViewport ? view.visualViewport.height : 0;
      var innerWidth = view.innerWidth || 0;
      var innerHeight = view.innerHeight || 0;
      var width = visualWidth || innerWidth || window.innerWidth || 0;
      var height = visualHeight || innerHeight || window.innerHeight || 0;
      if (width > 0 && height > 0) {
        return { width: width, height: height, source: 'viewport' };
      }
    } catch (e2) {}

    return { width: 0, height: 0, source: 'doc' };
  }

  function tapViewportWidth() {
    var frameSize = frameViewportSize();
    if (frameSize.width > 0) return frameSize.width;
    var visualWidth = window.visualViewport ? window.visualViewport.width : 0;
    var width = visualWidth || window.innerWidth || document.documentElement.clientWidth || 1;
    return width || 1;
  }

  function tapViewportHeight() {
    var frameSize = frameViewportSize();
    if (frameSize.height > 0) return frameSize.height;
    var visualHeight = window.visualViewport ? window.visualViewport.height : 0;
    var height = visualHeight || window.innerHeight || document.documentElement.clientHeight || 1;
    return height || 1;
  }

  function parentViewportPoint(x, y, doc) {
    if (!doc || doc === document || !doc.defaultView) {
      return { x: x, y: y };
    }
    try {
      var frame = doc.defaultView.frameElement;
      if (frame && frame.getBoundingClientRect) {
        var rect = frame.getBoundingClientRect();
        var localX = normalizeIframeAxis(x, rect.width || tapViewportWidth(), doc);
        var localY = clampPoint(y, rect.height || tapViewportHeight());
        return { x: rect.left + localX, y: rect.top + localY };
      }
    } catch (e) {}
    return { x: x, y: y };
  }

  function parseCssPx(value) {
    var parsed = parseFloat(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  function pagedColumnGap(doc) {
    if (!doc || !doc.defaultView) return 0;
    var candidates = [doc.body, doc.documentElement];
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      if (!el) continue;
      try {
        var style = doc.defaultView.getComputedStyle(el);
        var gap = parseCssPx(style.columnGap || style.webkitColumnGap);
        if (gap > 0) return gap;
      } catch (e) {}
    }
    return 0;
  }

  function normalizeIframeAxis(value, width, doc) {
    if (!Number.isFinite(value) || !Number.isFinite(width) || width <= 0) return value;
    if (value >= 0 && value <= width) return value;
    try {
      var view = doc && doc.defaultView;
      var offset = 0;
      if (view) {
        offset = view.visualViewport && Number.isFinite(view.visualViewport.pageLeft) ? view.visualViewport.pageLeft : 0;
        offset = offset || view.scrollX || view.pageXOffset || 0;
      }
      var candidate = value - offset;
      if (candidate >= 0 && candidate <= width) return candidate;
    } catch (e) {}

    var pitch = width + pagedColumnGap(doc);
    if (!Number.isFinite(pitch) || pitch <= 0) pitch = width;
    var normalized = value % pitch;
    if (normalized < 0) normalized += pitch;
    if (normalized > width) normalized = width;
    return normalized;
  }

  function clampPoint(value, size) {
    if (!Number.isFinite(value) || !Number.isFinite(size) || size <= 0) return value;
    if (value < 0) return 0;
    if (value > size) return size;
    return value;
  }

  function zoneFromPoint(x, y, doc) {
    var frameSize = frameViewportSize();
    var width = frameSize.width > 0 ? frameSize.width : tapViewportWidth();
    var height = frameSize.height > 0 ? frameSize.height : tapViewportHeight();
    var rawX = x;
    var rawY = y;
    var point = parentViewportPoint(x, y, doc);
    x = clampPoint(point.x, width);
    y = clampPoint(point.y, height);
    var col = x < width / 3 ? 0 : (x > width * 2 / 3 ? 2 : 1);
    var row = y < height / 3 ? 0 : (y > height * 2 / 3 ? 2 : 1);
    return {
      zone: row * 3 + col,
      x: x,
      y: y,
      rawX: rawX,
      rawY: rawY,
      width: width,
      height: height,
      source: frameSize.source
    };
  }

  function preventTapDefault(event) {
    if (!event) return;
    try { event.preventDefault(); } catch (e) {}
    try { event.stopPropagation(); } catch (e2) {}
    try { event.stopImmediatePropagation(); } catch (e3) {}
  }

  function finishTap(x, y, doc, event) {
    if (hasSelection(doc) || isInteractiveTarget(event && event.target)) return;

    var info = zoneFromPoint(x, y, doc);
    var action = Number(zoneActions[info.zone]);
    if (!Number.isFinite(action)) action = ACTION_NONE;

    preventTapDefault(event);

    if (action === ACTION_NEXT_PAGE) {
      window.nextPage();
    } else if (action === ACTION_PREV_PAGE) {
      window.prevPage();
    } else if (action === ACTION_MENU) {
      emit('menu', { zone: info.zone });
    } else if (action !== ACTION_NONE) {
      emit('tapAction', {
        zone: info.zone,
        action: action,
        x: Math.round(info.x),
        y: Math.round(info.y),
        rawX: Math.round(info.rawX),
        rawY: Math.round(info.rawY),
        width: Math.round(info.width),
        height: Math.round(info.height)
      });
    }

    lastHandledTapAt = Date.now();
  }

  /**
   * EPUB.js 的正文渲染在 iframe 中，滑动必须绑定到对应 contents.document。
   * 统一物理方向：右滑上一页，左滑下一页；斜向或短距离移动交还给滚动/选择。
   */
  function finishSwipe(start, touch, doc, event) {
    if (!start || !touch || hasSelection(doc)) return false;
    var dx = touch.clientX - start.x;
    var dy = touch.clientY - start.y;
    var absX = Math.abs(dx);
    var absY = Math.abs(dy);
    var duration = Date.now() - start.time;
    var viewport = frameViewportSize();
    var minDistance = Math.max(40, Number(viewport.width || 0) * 0.08);
    var isHorizontalSwipe = absX >= minDistance && absX > absY * 1.25 && duration <= 1200;
    if (!isHorizontalSwipe) return false;

    preventTapDefault(event);
    lastHandledTapAt = Date.now();
    if (dx > 0) {
      window.prevPage();
    } else {
      window.nextPage();
    }
    return true;
  }

  function bindTap(doc) {
    if (!doc || doc.__legadoTapBound) return;
    doc.__legadoTapBound = true;

    var touchStart = null;
    var linkTouchStart = null;
    doc.addEventListener('touchstart', function (event) {
      var link = event && event.target && event.target.closest && event.target.closest('a[href]');
      if (link && event.touches && event.touches.length === 1) {
        var linkTouch = event.touches[0];
        linkTouchStart = {
          link: link,
          x: linkTouch.clientX,
          y: linkTouch.clientY,
          time: Date.now()
        };
        touchStart = null;
        return;
      }
      linkTouchStart = null;
      if (isInteractiveTarget(event && event.target)) {
        touchStart = null;
        return;
      }
      try {
        event.stopPropagation();
      } catch (e) {}
      if (!event.touches || event.touches.length !== 1) {
        touchStart = null;
        return;
      }
      var touch = event.touches[0];
      touchStart = {
        x: touch.clientX,
        y: touch.clientY,
        time: Date.now()
      };
    }, { capture: true, passive: true });

    doc.addEventListener('touchmove', function (event) {
      if (linkTouchStart) {
        var linkTouch = event.touches && event.touches[0];
        if (!linkTouch || Math.abs(linkTouch.clientX - linkTouchStart.x) > 18 ||
            Math.abs(linkTouch.clientY - linkTouchStart.y) > 18) {
          linkTouchStart = null;
        }
        return;
      }
      if (!touchStart) return;
      var touch = event.touches && event.touches[0];
      if (!touch) return;
      var absX = Math.abs(touch.clientX - touchStart.x);
      var absY = Math.abs(touch.clientY - touchStart.y);
      if (absX > 12 && absX > absY) {
        preventTapDefault(event);
      }
    }, { capture: true, passive: false });

    doc.addEventListener('touchend', function (event) {
      if (linkTouchStart) {
        var linkStart = linkTouchStart;
        linkTouchStart = null;
        var linkEnd = event.changedTouches && event.changedTouches[0];
        if (linkEnd && Math.abs(linkEnd.clientX - linkStart.x) <= 18 &&
            Math.abs(linkEnd.clientY - linkStart.y) <= 18 &&
            Date.now() - linkStart.time <= 550) {
          try { event.preventDefault(); } catch (e) {}
          linkStart.link.click();
        }
        return;
      }
      if (!touchStart || !event.changedTouches || event.changedTouches.length < 1) return;
      if (isInteractiveTarget(event && event.target)) {
        touchStart = null;
        return;
      }
      var touch = event.changedTouches[0];
      var start = touchStart;
      var dx = Math.abs(touch.clientX - touchStart.x);
      var dy = Math.abs(touch.clientY - touchStart.y);
      var duration = Date.now() - touchStart.time;
      touchStart = null;
      if (finishSwipe(start, touch, doc, event)) return;
      if (dx > 18 || dy > 18 || duration > 550) return;
      finishTap(touch.clientX, touch.clientY, doc, event);
    }, { capture: true, passive: false });

    doc.addEventListener('touchcancel', function () {
      linkTouchStart = null;
      touchStart = null;
    }, { capture: true, passive: true });

    doc.addEventListener('click', function (event) {
      if (isInteractiveTarget(event && event.target)) return;
      if (Date.now() - lastHandledTapAt < 450) return;
      finishTap(event.clientX, event.clientY, doc, event);
    }, true);
  }

  function applyToContents(content) {
    if (!content || !content.document) return;
    injectStyle(content.document);
    applyChineseConversion(content.document);
    bindTap(content.document);
  }

  function applyToCurrentContentsSoon() {
    setTimeout(function () {
      try {
        if (!rendition) return;
        rendition.getContents().forEach(function (content) {
          applyToContents(content);
        });
      } catch (e) {}
    }, 120);
  }

  function resizeRenditionSoon() {
    if (!rendition) return;
    var run = function () {
      try {
        syncLayoutSettings();
        rendition.resize();
        syncLayoutSettings();
      } catch (e) {}
    };
    try {
      requestAnimationFrame(function () {
        run();
        setTimeout(run, 80);
      });
    } catch (e) {
      setTimeout(run, 0);
    }
  }

  function syncLayoutSettings() {
    if (!rendition) return;
    try {
      if (rendition.settings) {
        rendition.settings.gap = PAGE_GAP;
        rendition.settings.spread = 'none';
        rendition.settings.minSpreadWidth = 999999;
      }
    } catch (e) {}
    try {
      if (rendition.manager && rendition.manager.settings) {
        rendition.manager.settings.gap = PAGE_GAP;
        rendition.manager.settings.spread = 'none';
        rendition.manager.settings.minSpreadWidth = 999999;
      }
    } catch (e2) {}
    try {
      if (rendition.layout && rendition.layout.settings) {
        rendition.layout.settings.gap = PAGE_GAP;
        rendition.layout.settings.spread = 'none';
        rendition.layout.settings.minSpreadWidth = 999999;
      }
    } catch (e3) {}
  }

  function applyFlowLayout() {
    if (!rendition) return;
    var scrolled = cssValue(currentStyle.flowMode, 'paginated') === 'scrolled';
    syncLayoutSettings();
    try {
      if (rendition.spread) rendition.spread('none', 999999);
    } catch (e) {}
    try {
      if (rendition.flow) rendition.flow(scrolled ? 'scrolled-doc' : 'paginated');
    } catch (e2) {}
    syncLayoutSettings();
    try {
      if (rendition.manager && rendition.manager.updateLayout) rendition.manager.updateLayout();
    } catch (e3) {}
  }

  function setupContentHook() {
    if (!rendition || rendition.__legadoContentHookBound) return;
    rendition.__legadoContentHookBound = true;
    try {
      if (rendition.hooks && rendition.hooks.content) {
        rendition.hooks.content.register(function (contents) {
          applyToContents(contents);
        });
      }
    } catch (e) {
      emit('debug', { message: 'content hook failed: ' + errorMessage(e) });
    }
  }

  function setupRenditionEvents() {
    rendition.on('rendered', function (_section, contents) {
      try {
        if (contents && contents.document) {
          applyToContents(contents);
          var imgs = contents.document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            imgs[i].addEventListener('load', function () {
              try { rendition.resize(); } catch (e) {}
            });
          }
        }
      } catch (e2) {}
    });

    rendition.on('relocated', function (location) {
      if (!location) return;
      var start = location.start || {};
      var displayed = start.displayed || {};
      var spineIndex = typeof start.index === 'number' ? start.index : 0;
      var chapterIndex = chapterIndexFromSpineIndex(spineIndex);
      emit('location', {
        cfi: start.cfi || '',
        href: hrefFromLocation(location),
        chapterIndex: chapterIndex,
        page: displayed.page || 0,
        totalPages: displayed.total || 0,
        percentage: safePercent(location)
      });
    });

    var manager = rendition.manager;
    if (manager && manager.on && !manager.__legadoLivePageBound) {
      manager.__legadoLivePageBound = true;
      manager.on('scroll', function () {
        if (cssValue(currentStyle.flowMode, 'paginated') !== 'scrolled' || livePageFrame) return;
        livePageFrame = requestAnimationFrame(function () {
          livePageFrame = 0;
          var container = manager.container;
          var height = Number(container && container.clientHeight || 0);
          var scrollHeight = Number(container && container.scrollHeight || 0);
          if (height <= 0 || scrollHeight <= 0) return;
          var total = Math.max(1, Math.ceil(scrollHeight / height));
          var top = Number(container.scrollTop || 0);
          var page = Math.max(1, Math.min(total, Math.floor((top + height / 2) / height) + 1));
          var key = page + '/' + total;
          if (key !== lastLivePageKey) {
            lastLivePageKey = key;
            emit('page', { page: page, totalPages: total });
          }
        });
      });
    }
  }

  function emitBookInfo() {
    book.ready.then(function () {
      buildTocChapterMap();
      var meta = (book.package && book.package.metadata) || {};
      emit('metadata', {
        title: meta.title || '',
        author: meta.creator || ''
      });

      var toc = book.navigation && book.navigation.toc ? book.navigation.toc : [];
      var flat = [];
      function flatten(items, level) {
        if (!items) return;
        for (var i = 0; i < items.length; i++) {
          flat.push({ label: items[i].label || '', href: items[i].href || '', level: level || 0 });
          if (items[i].subitems && items[i].subitems.length) flatten(items[i].subitems, (level || 0) + 1);
        }
      }
      flatten(toc, 0);
      emit('toc', flat);
    }).catch(function (err) {
      emit('debug', { message: 'book info failed: ' + errorMessage(err) });
    });
  }

  function displayBook(target) {
    var displayTarget = target || undefined;
    var promise = rendition.display(displayTarget);
    return Promise.resolve(promise).catch(function (err) {
      if (!displayTarget) throw err;
      emit('debug', { message: 'display target failed, fallback to first spine: ' + errorMessage(err) });
      return rendition.display();
    });
  }

  window.loadBook = function (bookUrl, target) {
    loading(true, '加载中...');
    try {
      emit('debug', { message: 'loadBook ' + bookUrl + ' target=' + (target || '') });
      currentBookUrl = bookUrl;
      if (book) {
        try { book.destroy(); } catch (e) {}
      }
      book = ePub(bookUrl);
      rendition = book.renderTo('viewer', {
        width: '100%',
        height: '100%',
        manager: 'default',
        spread: 'none',
        minSpreadWidth: 999999,
        evenSpreads: false,
        gap: PAGE_GAP,
        flow: cssValue(currentStyle.flowMode, 'paginated') === 'scrolled' ? 'scrolled-doc' : 'paginated'
      });
      applyFlowLayout();
      applyRenditionTheme();
      setupContentHook();
      setupRenditionEvents();
      window.applyStyle(currentStyle);
      emitBookInfo();

      displayBook(target).then(function () {
        loading(false);
        emit('ready', {});
      }).catch(function (err) {
        loading(false);
        emit('error', { message: errorMessage(err) });
      });
    } catch (err2) {
      loading(false);
      emit('error', { message: errorMessage(err2) });
    }
  };

  function alignScrollToLine_(container, direction) {
    var v = currentStyleValues();
    var lineHeight = Number(v.fontSize) * Number(v.lineHeight);
    if (!lineHeight || lineHeight <= 0) return;
    var scrollTop = Number(container.scrollTop || 0);
    var remainder = scrollTop % lineHeight;
    if (Math.abs(remainder) < 1) return;
    // 向下翻页对齐到下一行，向上翻页对齐到上一行
    if (direction > 0) {
      container.scrollTop = scrollTop + (lineHeight - remainder);
    } else {
      container.scrollTop = scrollTop - remainder;
    }
  }

  function scrollCurrentBy_(direction) {
    if (!rendition || !rendition.manager || !rendition.manager.container) return false;
    var container = rendition.manager.container;
    var scrollTop = Number(container.scrollTop || 0);
    var scrollHeight = Number(container.scrollHeight || 0);
    var clientHeight = Number(container.clientHeight || 0);
    if (scrollHeight <= 0 || clientHeight <= 0) return false;
    var v = currentStyleValues();
    var lineHeight = Number(v.fontSize) * Number(v.lineHeight);
    if (lineHeight <= 0) lineHeight = 24;
    // 滚动距离 = 一屏 - 一行，让上一页的最后一行在下一页完整显示（重叠一行）
    var distance = Math.max(120, clientHeight - lineHeight);
    var target = direction > 0 ? scrollTop + distance : scrollTop - distance;
    if (direction > 0 && scrollTop + clientHeight >= scrollHeight - 4) {
      return true; // 已到底部，需要翻章
    }
    if (direction < 0 && scrollTop <= 4) {
      return true; // 已到顶部，需要翻章
    }
    container.scrollTop = target;
    alignScrollToLine_(container, direction);
    return false;
  }

  window.nextPage = function () {
    clearSelections();
    if (!rendition) return;
    if (cssValue(currentStyle.flowMode, 'paginated') === 'scrolled') {
      var needNextChapter = scrollCurrentBy_(1);
      if (!needNextChapter) return;
    }
    var result = rendition.next();
    Promise.resolve(result).then(function () {
      applyToCurrentContentsSoon();
    }).catch(function (err) {
      emit('debug', { message: 'nextPage failed: ' + errorMessage(err) });
    });
  };

  window.prevPage = function () {
    clearSelections();
    if (!rendition) return;
    if (cssValue(currentStyle.flowMode, 'paginated') === 'scrolled') {
      var needPrevChapter = scrollCurrentBy_(-1);
      if (!needPrevChapter) return;
    }
    var result = rendition.prev();
    Promise.resolve(result).then(function () {
      applyToCurrentContentsSoon();
    }).catch(function (err) {
      emit('debug', { message: 'prevPage failed: ' + errorMessage(err) });
    });
  };

  window.goTo = function (cfi) {
    if (rendition && cfi) rendition.display(cfi);
  };

  window.goToHref = function (href) {
    if (rendition && href) rendition.display(href);
  };

  window.applyStyle = function (style) {
    currentStyle = parseStyle(style);
    applyRootStyle();
    applyFlowLayout();
    applyRenditionTheme();
    if (rendition) {
      try {
        rendition.getContents().forEach(function (content) {
          applyToContents(content);
        });
      } catch (e) {}
      resizeRenditionSoon();
    }
  };

  window.setZoneActions = function (actions) {
    zoneActions = parseActions(actions);
  };

  window.setTheme = function (style) {
    window.applyStyle(style);
  };

  window.setFont = function (style) {
    var cfg = parseStyle(style);
    window.applyStyle(Object.assign({}, currentStyle, cfg));
  };

  window.clearSelection = function () {
    clearSelections();
  };

  window.pollEvent = function () {
    if (!eventQueue.length) return 'null';
    return JSON.stringify(eventQueue.shift());
  };

  window.pollEvents = function () {
    if (!eventQueue.length) return 'null';
    var events = eventQueue.splice(0, eventQueue.length);
    return JSON.stringify(events);
  };

  document.addEventListener('DOMContentLoaded', function () {
    window.applyStyle(parseStyle(qs('style')));
    window.setZoneActions(qs('actions'));
    bindTap(document);

    var bookUrl = qs('book');
    if (bookUrl) {
      window.loadBook(bookUrl, qs('target'));
    }
  });
})();
