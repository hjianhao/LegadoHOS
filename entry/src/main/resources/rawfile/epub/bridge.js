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
  // 单页无 column-gap；双页用 gutter 作为两页中间的页缝。
  // 翻页对齐靠 alignToSpreadBoundary + 不覆盖左右 padding，而不是强制 gap=0。
  var PAGE_GAP = 0;
  var DEFAULT_DUAL_PAGE_GAP = 48;
  var livePageFrame = 0;
  var lastLivePageKey = '';
  var activeFlowMode = '';
  var activeSpreadMode = '';
  var activeLayoutGap = -1;

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
      // 左右边距作用在外层 frame，不写进 iframe body：
      // body 左右 padding 由 epub.js columns() 用于双页 column-gap，覆盖会破坏分栏对齐。
      // 单页 / 双页均尊重风格设置的 paddingLeft / paddingRight。
      frame.style.paddingLeft = Math.max(0, v.pl) + 'px';
      frame.style.paddingRight = Math.max(0, v.pr) + 'px';
      frame.style.paddingTop = '0px';
      frame.style.paddingBottom = '0px';
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
    var isDual = currentStyle.dualPage === true;
    var imgMaxH = isDual ? '40vh' : (v.flowMode === 'scrolled' ? 'none' : '85vh');
    // 只设上下 padding，左右留给 epub.js columns() 控制，避免破坏双页分栏对齐
    var bodyRule = {
      'background': v.bg + ' !important',
      'color': v.color + ' !important',
      'font-size': v.fontSize + 'px !important',
      'font-weight': v.weight + ' !important',
      'line-height': String(v.lineHeight) + ' !important',
      'letter-spacing': v.letterSpacing + 'px !important',
      'text-align': v.textAlign + ' !important',
      'box-sizing': 'border-box !important',
      'padding-top': v.pt + 'px !important',
      'padding-bottom': v.pb + 'px !important'
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
        'max-height': imgMaxH + ' !important',
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
	  var isDual = currentStyle.dualPage === true;
	  var bodyFontCss = v.useBookFont ? '' : 'font-family:' + v.familyCss + ' !important;';
	  var bodyAllFontCss = v.useBookFont ? '' : 'font-family:' + v.familyCss + ' !important;';
	  var imgMaxH = isDual ? '40vh' : (v.flowMode === 'scrolled' ? 'none' : '85vh');

	  // 上下 padding 用 !important；左右不写，保留 epub.js 的 column gap 半宽 padding
	  style.textContent =
	    fontFaceCss() +
	    'html,body{background:' + v.bg + ' !important;color:' + v.color + ' !important;}' +
	    'body{' + bodyFontCss + 'font-size:' + v.fontSize + 'px !important;' +
	    'font-weight:' + v.weight + ' !important;line-height:' + v.lineHeight + ' !important;' +
	    'letter-spacing:' + v.letterSpacing + 'px !important;text-align:' + v.textAlign + ' !important;' +
	    'box-sizing:border-box !important;padding-top:' + v.pt + 'px !important;padding-bottom:' + v.pb + 'px !important;}' +
	    'body *{' + bodyAllFontCss + 'box-sizing:border-box !important;font-weight:' + v.weight + ' !important;' +
	    'letter-spacing:' + v.letterSpacing + 'px !important;}' +
	    'p{margin-top:0 !important;margin-bottom:' + v.paraSpacing + 'px !important;text-indent:' + v.indent + 'em;' +
	    'font-weight:' + v.weight + ' !important;letter-spacing:' + v.letterSpacing + 'px !important;}' +
	    'img,svg{max-width:100% !important;max-height:' + imgMaxH + ' !important;object-fit:contain !important;' +
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
      // 不要清掉 paddingLeft/Right：epub.js columns() 依赖它们做双页列间距
      doc.body.style.paddingTop = v.pt + 'px';
      doc.body.style.paddingBottom = v.pb + 'px';
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

  function dualPageEnabled() {
    if (cssValue(currentStyle.flowMode, 'paginated') === 'scrolled') return false;
    return currentStyle.dualPage === true;
  }

  /** 双页中间页缝宽度（px），与原生 PageView dualPageGutter 默认 48 对齐 */
  function dualPageGap() {
    var g = Number(currentStyle.dualPageGutter);
    if (!Number.isFinite(g) || g < 0) g = DEFAULT_DUAL_PAGE_GAP;
    if (g > 120) g = 120;
    // 偶数更利于 epub.js 半 gap padding 对称
    return Math.round(g / 2) * 2;
  }

  function currentLayoutSettings() {
    var dual = dualPageEnabled();
    return {
      // always：用户显式开双页时强制两栏，不依赖 minSpreadWidth 阈值
      spread: dual ? 'always' : 'none',
      minSpreadWidth: dual ? 1 : 999999,
      gap: dual ? dualPageGap() : PAGE_GAP
    };
  }

  function resizeRenditionSoon() {
    if (!rendition) return;
    var run = function () {
      try {
        applySpreadLayout();
        rendition.resize();
        syncLayoutSettings();
        alignToSpreadBoundary();
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
    var layoutSettings = currentLayoutSettings();
    try {
      if (rendition.settings) {
        rendition.settings.gap = layoutSettings.gap;
        rendition.settings.spread = layoutSettings.spread;
        rendition.settings.minSpreadWidth = layoutSettings.minSpreadWidth;
      }
    } catch (e) {}
    try {
      if (rendition.manager && rendition.manager.settings) {
        rendition.manager.settings.gap = layoutSettings.gap;
        rendition.manager.settings.spread = layoutSettings.spread;
        rendition.manager.settings.minSpreadWidth = layoutSettings.minSpreadWidth;
      }
    } catch (e2) {}
    try {
      var liveLayout = (rendition.manager && rendition.manager.layout) || rendition.layout;
      if (liveLayout) {
        if (liveLayout.settings) {
          liveLayout.settings.gap = layoutSettings.gap;
          liveLayout.settings.spread = layoutSettings.spread;
          liveLayout.settings.minSpreadWidth = layoutSettings.minSpreadWidth;
        }
        // 直接驱动 Layout 内部 _spread / _minSpreadWidth
        if (typeof liveLayout.spread === 'function') {
          liveLayout.spread(layoutSettings.spread, layoutSettings.minSpreadWidth);
        }
      }
    } catch (e3) {}
  }

  function applySpreadLayout() {
    if (!rendition) return;
    var layoutSettings = currentLayoutSettings();
    var layoutChanged = activeSpreadMode !== layoutSettings.spread
      || activeLayoutGap !== layoutSettings.gap;
    syncLayoutSettings();
    try {
      if (rendition.spread) {
        rendition.spread(layoutSettings.spread, layoutSettings.minSpreadWidth);
      }
    } catch (e) {}
    activeSpreadMode = layoutSettings.spread;
    activeLayoutGap = layoutSettings.gap;
    if (layoutChanged) {
      try {
        if (rendition.manager && rendition.manager.updateLayout) {
          rendition.manager.updateLayout();
        }
      } catch (e2) {}
    }
  }

  /**
   * 将 scrollLeft 对齐到 delta 整数倍。
   * 双页下若 scroll 停在半栏位置，会看到「半页 | 整页 | 半页」。
   */
  function alignToSpreadBoundary() {
    if (!rendition || !dualPageEnabled()) return;
    try {
      var manager = rendition.manager;
      var container = manager && manager.container;
      var layout = manager && manager.layout;
      var delta = Number(layout && layout.delta || 0);
      var currentLeft = Number(container && container.scrollLeft || 0);
      if (!manager || !container || delta <= 0) return;
      var alignedLeft = Math.round(currentLeft / delta) * delta;
      if (Math.abs(alignedLeft - currentLeft) > 1) {
        if (typeof manager.scrollTo === 'function') {
          manager.scrollTo(alignedLeft, Number(container.scrollTop || 0), true);
        } else {
          container.scrollLeft = alignedLeft;
        }
      }
    } catch (e) {}
  }

  function applyFlowLayout() {
    if (!rendition) return;
    var scrolled = cssValue(currentStyle.flowMode, 'paginated') === 'scrolled';
    var flowMode = scrolled ? 'scrolled-doc' : 'paginated';
    if (activeFlowMode !== flowMode) {
      try {
        if (rendition.flow) rendition.flow(flowMode);
      } catch (e) {}
      activeFlowMode = flowMode;
    }
    applySpreadLayout();
    try {
      if (rendition.manager && rendition.manager.updateLayout) {
        rendition.manager.updateLayout();
      }
    } catch (e2) {}
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
      // 跳转 / 翻页后兜底对齐，避免停在半栏位置
      alignToSpreadBoundary();
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
    return Promise.resolve(promise).then(function () {
      // epub.js 的 spread 在首次 display 后可能未生效，强制刷新布局
      applyFlowLayout();
      syncLayoutSettings();
      try { rendition.resize(); } catch (e) {}
      alignToSpreadBoundary();
      return promise;
    }).catch(function (err) {
      if (!displayTarget) throw err;
      emit('debug', { message: 'display target failed, fallback to first spine: ' + errorMessage(err) });
      return rendition.display().then(function () {
        applyFlowLayout();
        try { rendition.resize(); } catch (e2) {}
        alignToSpreadBoundary();
      });
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
      activeFlowMode = '';
      activeSpreadMode = '';
      activeLayoutGap = -1;
      book = ePub(bookUrl);
      var layoutSettings = currentLayoutSettings();
      rendition = book.renderTo('viewer', {
        width: '100%',
        height: '100%',
        manager: 'default',
        spread: layoutSettings.spread,
        minSpreadWidth: layoutSettings.minSpreadWidth,
        evenSpreads: false,
        gap: layoutSettings.gap,
        flow: cssValue(currentStyle.flowMode, 'paginated') === 'scrolled' ? 'scrolled-doc' : 'paginated'
      });
      applyFlowLayout();
      applyRenditionTheme();
      setupContentHook();
      setupRenditionEvents();
      window.applyStyle(currentStyle);
      emitBookInfo();

      displayBook(target).then(function () {
        alignToSpreadBoundary();
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
    // epub.js spread 模式下 next() 已按 layout.delta（整屏=两栏）滚动，只需调用一次
    var result = rendition.next();
    Promise.resolve(result).then(function () {
      alignToSpreadBoundary();
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
      alignToSpreadBoundary();
      applyToCurrentContentsSoon();
    }).catch(function (err) {
      emit('debug', { message: 'prevPage failed: ' + errorMessage(err) });
    });
  };

  window.goTo = function (cfi) {
    if (rendition && cfi) rendition.display(cfi);
  };

  window.goToHref = function (href) {
    if (!rendition || !href) return;
    navigateInternalHref_(href);
  };

  /**
   * 在 (clientX, clientY) 处命中检测 a[href]。
   * 供 ArkTS 触摸层调用：命中则内部跳转并返回 "1"，否则返回 "0"。
   */
  window.hitTestLinkAt = function (clientX, clientY) {
    try {
      var x = Number(clientX);
      var y = Number(clientY);
      if (!Number.isFinite(x) || !Number.isFinite(y)) return '0';

      var href = findLinkHrefAt_(x, y);
      if (!href) return '0';

      if (/^(https?:|mailto:|tel:)/i.test(href)) {
        emit('externalLink', { href: href });
        return '1';
      }
      if (/^javascript:/i.test(href)) return '0';

      if (navigateInternalHref_(href)) return '1';
      return '0';
    } catch (e) {
      emit('debug', { message: 'hitTestLinkAt failed: ' + errorMessage(e) });
      return '0';
    }
  };

  function findLinkHrefAt_(clientX, clientY) {
    function linkFromElement(el) {
      while (el && el.nodeType === 1) {
        if (String(el.tagName || '').toLowerCase() === 'a') {
          var h = el.getAttribute('href');
          if (h) return h;
        }
        el = el.parentElement;
      }
      return '';
    }

    function searchDoc(doc, x, y) {
      if (!doc || !doc.elementFromPoint) return '';
      var el = null;
      try {
        el = doc.elementFromPoint(x, y);
      } catch (e) {
        return '';
      }
      if (!el) return '';
      var tag = String(el.tagName || '').toLowerCase();
      if (tag === 'iframe') {
        try {
          var rect = el.getBoundingClientRect();
          var idoc = el.contentDocument;
          if (idoc) {
            var nested = searchDoc(idoc, x - rect.left, y - rect.top);
            if (nested) return nested;
          }
        } catch (e2) {}
      }
      return linkFromElement(el);
    }

    var href = searchDoc(document, clientX, clientY);
    if (href) return href;

    try {
      var iframes = document.querySelectorAll('iframe');
      for (var i = 0; i < iframes.length; i++) {
        var fr = iframes[i];
        var r = fr.getBoundingClientRect();
        if (clientX < r.left || clientX > r.right || clientY < r.top || clientY > r.bottom) {
          continue;
        }
        try {
          var idoc = fr.contentDocument;
          if (!idoc) continue;
          href = searchDoc(idoc, clientX - r.left, clientY - r.top);
          if (href) return href;
        } catch (e3) {}
      }
    } catch (e4) {}

    return '';
  }

  /** 当前阅读章节在 spine 中的路径（含目录前缀，如 Text/part0151.xhtml） */
  function currentSectionHref_() {
    try {
      if (rendition && rendition.location && rendition.location.start && book && book.spine) {
        var section = book.spine.get(rendition.location.start.index);
        if (section && section.href) return section.href;
      }
    } catch (e) {}
    return '';
  }

  /**
   * 解析 EPUB 内链相对路径。
   * 例：当前 Text/part0151.xhtml，链接 part0151.xhtml#notef1
   * → Text/part0151.xhtml#notef1（否则 spine.get 报 No Section Found）
   */
  function resolveHrefForDisplay_(href) {
    if (!href) return href;
    if (/^(https?:|mailto:|tel:|epubcfi\()/i.test(href)) return href;

    var baseHref = currentSectionHref_();

    // section.resolve（epub.js 内置）
    try {
      if (book && book.spine && rendition && rendition.location && rendition.location.start) {
        var sec = book.spine.get(rendition.location.start.index);
        if (sec && typeof sec.resolve === 'function') {
          var resolvedBySection = sec.resolve(href);
          if (resolvedBySection) return resolvedBySection;
        }
      }
    } catch (e) {}

    // book.resolve
    try {
      if (book && typeof book.resolve === 'function') {
        var resolvedByBook = book.resolve(href, false);
        if (resolvedByBook) {
          // book.resolve 可能返回绝对 URL，取 path 部分
          var asPath = String(resolvedByBook);
          var pathMatch = asPath.match(/\/book\/(.+)$/) || asPath.match(/OEBPS\/(.+)$/i);
          if (pathMatch) return pathMatch[1] + (href.indexOf('#') >= 0 && pathMatch[1].indexOf('#') < 0
            ? href.slice(href.indexOf('#')) : '');
          if (asPath.indexOf('://') < 0) return asPath;
        }
      }
    } catch (e2) {}

    return resolveRelativePath_(baseHref, href);
  }

  function resolveRelativePath_(baseHref, href) {
    var hash = '';
    var path = String(href || '');
    var hi = path.indexOf('#');
    if (hi >= 0) {
      hash = path.slice(hi);
      path = path.slice(0, hi);
    }
    // 纯锚点
    if (!path) {
      return (baseHref || '').split('#')[0] + hash;
    }
    // 去掉开头 /
    if (path.charAt(0) === '/') path = path.slice(1);

    var baseDir = '';
    if (baseHref) {
      var clean = String(baseHref).split('#')[0];
      var slash = clean.lastIndexOf('/');
      baseDir = slash >= 0 ? clean.slice(0, slash + 1) : '';
    }

    var combined = baseDir + path;
    var parts = combined.split('/');
    var stack = [];
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (!p || p === '.') continue;
      if (p === '..') {
        if (stack.length) stack.pop();
        continue;
      }
      stack.push(p);
    }
    var resolved = stack.join('/') + hash;

    // 用 spine 校验 / 按文件名回退匹配
    if (book && book.spine) {
      var noHash = resolved.split('#')[0];
      try {
        if (book.spine.get(resolved) || book.spine.get(noHash)) return resolved;
      } catch (e3) {}
      var fileName = noHash.split('/').pop();
      if (fileName) {
        for (var j = 0; j < book.spine.length; j++) {
          try {
            var s = book.spine.get(j);
            if (!s || !s.href) continue;
            var sh = s.href.split('#')[0];
            var sn = sh.split('/').pop();
            if (sh === noHash || sh === fileName || sn === fileName ||
                sh.endsWith('/' + fileName)) {
              return sh + hash;
            }
          } catch (e4) {}
        }
      }
    }
    return resolved;
  }

  function navigateInternalHref_(href) {
    if (!rendition || !href) return false;
    try {
      var target = resolveHrefForDisplay_(href);
      emit('debug', { message: 'navigate link raw=' + href + ' resolved=' + target });

      // 优先校验 spine，避免 display 抛 No Section Found
      var pathOnly = String(target).split('#')[0];
      var sectionOk = false;
      if (book && book.spine) {
        try {
          sectionOk = !!(book.spine.get(pathOnly) || book.spine.get(target));
        } catch (e) {
          sectionOk = false;
        }
        if (!sectionOk) {
          // 再试一次按文件名匹配
          var retry = resolveRelativePath_(currentSectionHref_(), href);
          if (retry !== target) {
            target = retry;
            pathOnly = String(target).split('#')[0];
            try {
              sectionOk = !!(book.spine.get(pathOnly) || book.spine.get(target));
            } catch (e2) {}
          }
        }
      }

      if (!sectionOk && pathOnly) {
        emit('debug', { message: 'navigate href no spine section: ' + target });
        // 仍尝试 display，部分版本可接受 canonical
      }

      var result = rendition.display(target);
      Promise.resolve(result).then(function () {
        try { applyFlowLayout(); } catch (e3) {}
        alignToSpreadBoundary();
        applyToCurrentContentsSoon();
      }).catch(function (err) {
        emit('debug', { message: 'navigate href failed: ' + errorMessage(err) + ' href=' + target });
      });
      return true;
    } catch (e4) {
      emit('debug', { message: 'navigate href error: ' + errorMessage(e4) });
      return false;
    }
  }

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
