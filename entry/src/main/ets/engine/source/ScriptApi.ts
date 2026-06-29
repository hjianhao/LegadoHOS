/**
 * JS Polyfill API 层
 *
 * 注入到 QuickJS 引擎中的 JavaScript polyfill，
 * 提供与 Legado Rhino 环境兼容的 API。
 *
 * 这些 polyfill 在引擎创建时自动注入，使得现有书源脚本
 * 无需任何修改即可运行。
 */

/**
 * 获取所有 polyfill 脚本的拼接字符串
 * 在引擎初始化时注入到全局作用域
 */
export function getPolyfillScript(): string {
  return `
// ============================================================
// Legado 兼容层 Polyfills
// 提供与 Rhino 环境一致的 API
// ============================================================

// --- javaString 兼容 ---
(function() {
  if (typeof javaString === 'undefined') {
    globalThis.javaString = function(s) {
      if (s === null || s === undefined) return '';
      return String(s);
    };
  }
})();

// --- javaArrayList 兼容 ---
(function() {
  if (typeof javaArrayList === 'undefined') {
    globalThis.javaArrayList = function() {
      var arr = [];
      for (var i = 0; i < arguments.length; i++) {
        if (Array.isArray(arguments[i])) {
          arr = arr.concat(arguments[i]);
        } else {
          arr.push(arguments[i]);
        }
      }
      return arr;
    };
  }
})();

// --- java 命名空间兼容 ---
(function() {
  if (typeof java === 'undefined') {
    globalThis.java = {
      net: {
        URL: globalThis.URL
      },
      text: {
        SimpleDateFormat: function(pattern) {
          return {
            format: function(date) {
              var d = new Date(date);
              var map = {
                'yyyy': d.getFullYear(),
                'MM': ('0' + (d.getMonth() + 1)).slice(-2),
                'dd': ('0' + d.getDate()).slice(-2),
                'HH': ('0' + d.getHours()).slice(-2),
                'mm': ('0' + d.getMinutes()).slice(-2),
                'ss': ('0' + d.getSeconds()).slice(-2)
              };
              return pattern.replace(/yyyy|MM|dd|HH|mm|ss/g, function(m) { return map[m]; });
            }
          };
        }
      }
    };
  }
})();

// --- BASE64 兼容（如果底层未注入，兜底实现） ---
(function() {
  if (typeof Base64 === 'undefined') {
    globalThis.Base64 = {
      encode: function(str) {
        try {
          return btoa(unescape(encodeURIComponent(str)));
        } catch(e) {
          return btoa(str);
        }
      },
      decode: function(str) {
        try {
          return decodeURIComponent(escape(atob(str)));
        } catch(e) {
          return atob(str);
        }
      }
    };
  }
})();

// --- 结果对象辅助 ---
(function() {
  if (typeof _resultPolyfill === 'undefined') {
    globalThis._resultPolyfill = function(obj, baseUrl) {
      if (obj && typeof obj === 'object') {
        if (Array.isArray(obj)) {
          obj.forEach(function(item) {
            if (item && typeof item === 'object' && !item.baseUrl) {
              Object.defineProperty(item, 'baseUrl', {
                value: baseUrl, writable: true, configurable: true
              });
            }
          });
        } else if (!obj.baseUrl) {
          Object.defineProperty(obj, 'baseUrl', {
            value: baseUrl, writable: true, configurable: true
          });
        }
      }
      return obj;
    };
  }
})();

// --- String 增强（兼容 Legado 常用操作） ---
(function() {
  // 移除 BOM
  if (!String.prototype.trimBOM) {
    String.prototype.trimBOM = function() {
      return this.charCodeAt(0) === 0xFEFF ? this.slice(1) : this;
    };
  }
  // 判断是否包含
  if (!String.prototype.contains) {
    String.prototype.contains = function(s) {
      return this.indexOf(s) !== -1;
    };
  }
})();


// --- java.hexDecodeToString 兼容 ---
(function() {
  var _j = typeof java !== "undefined" ? java : globalThis.java;
  if (_j && !_j.hexDecodeToString) {
    _j.hexDecodeToString = function(hex) {
      if (!hex || hex.length === 0) return "";
      var result = "";
      for (var i = 0; i < hex.length; i += 2) {
        var code = parseInt(hex.substring(i, i + 2), 16);
        if (!isNaN(code)) result += String.fromCharCode(code);
      }
      return result;
    };
  }
})();

console.log('[Polyfill] Legado compatibility layer loaded');

  `;
}

/**
 * 检查书源是否需要脚本执行（有 script 字段），还是只需要规则解析
 */
export function hasSourceScript(source: { script?: string }): boolean {
  return !!source.script && source.script.trim().length > 0;
}

/**
 * 构建包装脚本——将源规则转换为可执行 JS
 * 用于无 script 字段的规则式书源
 *
 * 注意：所有函数返回 JS 对象而非 JSON 字符串，
 * 因为 C++ NAPI 桥会自动执行 JSON.stringify(result)。
 * 避免双重序列化。
 */
export function buildRuleExecutorScript(
  ruleSearchUrl: string,
  ruleSearchList: string,
  ruleSearchName: string,
  ruleSearchAuthor: string,
  ruleSearchCover: string,
  ruleSearchNoteUrl: string,
  ruleBookInfoInit: string,
  ruleBookInfoName: string,
  ruleBookInfoAuthor: string,
  ruleBookInfoCover: string,
  ruleTocUrl: string,
  ruleToc: string,
  ruleBookContentUrl: string,
  ruleBookContent: string,
): string {
  const su = escapeJsString(ruleSearchUrl);
  const sl = escapeJsString(ruleSearchList);
  const sn = escapeJsString(ruleSearchName);
  const sa = escapeJsString(ruleSearchAuthor);
  const sc = escapeJsString(ruleSearchCover);
  const snu = escapeJsString(ruleSearchNoteUrl);
  const bi = escapeJsString(ruleBookInfoInit);
  const bn = escapeJsString(ruleBookInfoName);
  const ba = escapeJsString(ruleBookInfoAuthor);
  const bc = escapeJsString(ruleBookInfoCover);
  const tu = escapeJsString(ruleTocUrl);
  const tc = escapeJsString(ruleToc);
  const cu = escapeJsString(ruleBookContentUrl);
  const ct = escapeJsString(ruleBookContent);

  // Helper: ${key} in generated JS using concat to avoid template literal conflicts
  const kq = "'$' + '{key}'";
  const pq = "'$' + '{page}'";

  return `// 规则式书源自动生成的包装脚本
function search(key, page) {
  var url = '${su}'
    .replace(/\\{\\{(.*?)\\}\\}/g, function(_, code) {
      try { return eval(code); } catch(e) { return ''; }
    })
    .replace(${kq}, encodeURIComponent(key))
    .replace(${pq}, page);
  var resp = http.get(url);
  var body = resp.body.text();
  return { url: url, html: body,
    rules: {
      list: '${sl}',
      name: '${sn}',
      author: '${sa}',
      cover: '${sc}',
      noteUrl: '${snu}'
    }
  };
}

function getBookInfo(url) {
  var resp = http.get(url);
  var body = resp.body.text();
  return { url: url, html: body,
    rules: {
      init: '${bi}',
      name: '${bn}',
      author: '${ba}',
      cover: '${bc}'
    }
  };
}

function getToc(url) {
  var resp = http.get(url);
  var body = resp.body.text();
  return { url: url, html: body,
    rules: {
      toc: '${tc}',
      tocUrl: '${tu}'
    }
  };
}

function getContent(url) {
  var resp = http.get(url);
  var body = resp.body.text();
  return { url: url, html: body,
    rules: {
      content: '${ct}',
      contentUrl: '${cu}'
    }
  };
}

  `;
}

/**
 * 构建包装脚本（无 http.get，接收预取 HTML）
 * 用于规则式书源，在 ArkTS 侧完成 HTTP 请求后传入 HTML
 */
export function buildRuleExecutorScriptWithHtml(
  ruleSearchList: string,
  ruleSearchName: string,
  ruleSearchAuthor: string,
  ruleSearchCover: string,
  ruleSearchNoteUrl: string,
  ruleToc: string,
  ruleTocTitle: string,
  ruleTocUrlItem: string,
  ruleBookContent: string,
): string {
  const sl = escapeJsString(ruleSearchList);
  const sn = escapeJsString(ruleSearchName);
  const sa = escapeJsString(ruleSearchAuthor);
  const sc = escapeJsString(ruleSearchCover);
  const snu = escapeJsString(ruleSearchNoteUrl);
  const tc = escapeJsString(ruleToc);
  const tt = escapeJsString(ruleTocTitle);
  const tui = escapeJsString(ruleTocUrlItem);
  const ct = escapeJsString(ruleBookContent);

  return `// 规则式书源包装脚本（无 HTTP 版，数据由 ArkTS 传入）
function searchWithHtml(key, page, html) {
  return { html: html,
    rules: {
      list: '${sl}',
      name: '${sn}',
      author: '${sa}',
      cover: '${sc}',
      noteUrl: '${snu}'
    }
  };
}

function getInfoWithHtml(url, html) {
  return { html: html, rules: {} };
}

function getTocWithHtml(url, html) {
  return { html: html,
    rules: {
      toc: '${tc}',
      tocTitle: '${tt}',
      tocUrlItem: '${tui}'
    }
  };
}

function getContentWithHtml(url, html) {
  return { html: html,
    rules: {
      content: '${ct}'
    }
  };
}

  `;
}

function escapeJsString(str: string): string {
  if (!str) return '';
  return str
    .replace(/\\\\/g, '\\\\\\\\')
    .replace(/'/g, "\\\\'")
    .replace(/\\n/g, '\\\\n')
    .replace(/\\r/g, '\\\\r')
    .replace(/\\t/g, '\\\\t');
}
