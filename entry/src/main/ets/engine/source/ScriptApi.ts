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

// --- BASE64 兼容（纯 JS 实现，不依赖 btoa/atob） ---
	(function() {
	  if (typeof Base64 === 'undefined') {
	    var _base64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
	    globalThis.Base64 = {
	      encode: function(str) {
	        // 先转 UTF-8 字节（encodeURIComponent + 还原），避免 charCodeAt & 0xff 截断中文
	        str = String(str);
	        var utf8 = '';
	        for (var i = 0; i < str.length; i++) {
	          var c = str.charCodeAt(i);
	          if (c < 0x80) {
	            utf8 += String.fromCharCode(c);
	          } else if (c < 0x800) {
	            utf8 += String.fromCharCode(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
	          } else if (c < 0xd800 || c >= 0xe000) {
	            utf8 += String.fromCharCode(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
	          } else {
	            // surrogate pair (code point > 0xffff)
	            i++;
	            var c2 = str.charCodeAt(i);
	            var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
	            utf8 += String.fromCharCode(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
	          }
	        }
	        var out = '';
	        var j = 0;
	        var len = utf8.length;
	        while (j < len) {
	          var b1 = utf8.charCodeAt(j++) & 0xff;
	          out += _base64Chars.charAt(b1 >> 2);
	          if (j === len) {
	            out += _base64Chars.charAt((b1 & 0x3) << 4);
	            out += '==';
	            break;
	          }
	          var b2 = utf8.charCodeAt(j++) & 0xff;
	          out += _base64Chars.charAt(((b1 & 0x3) << 4) | ((b2 & 0xf0) >> 4));
	          if (j === len) {
	            out += _base64Chars.charAt((b2 & 0xf) << 2);
	            out += '=';
	            break;
	          }
	          var b3 = utf8.charCodeAt(j++) & 0xff;
	          out += _base64Chars.charAt(((b2 & 0xf) << 2) | ((b3 & 0xc0) >> 6));
	          out += _base64Chars.charAt(b3 & 0x3f);
	        }
	        return out;
	      },
	      decode: function(str) {
	        str = String(str).replace(/[^A-Za-z0-9\+\/]/g, '');
	        // 先解码为 UTF-8 字节，再还原为 JS 字符串
	        var bytes = '';
	        var i = 0;
	        var len = str.length;
	        while (i < len) {
	          var idx1 = _base64Chars.indexOf(str.charAt(i++));
	          var idx2 = _base64Chars.indexOf(str.charAt(i++));
	          var idx3 = _base64Chars.indexOf(str.charAt(i++));
	          var idx4 = _base64Chars.indexOf(str.charAt(i++));
	          bytes += String.fromCharCode((idx1 << 2) | (idx2 >> 4));
	          if (idx3 !== 64) bytes += String.fromCharCode(((idx2 & 15) << 4) | (idx3 >> 2));
	          if (idx4 !== 64) bytes += String.fromCharCode(((idx3 & 3) << 6) | idx4);
	        }
	        // UTF-8 解码
	        var out = '';
	        var j = 0;
	        while (j < bytes.length) {
	          var b1 = bytes.charCodeAt(j++) & 0xff;
	          if (b1 < 0x80) {
	            out += String.fromCharCode(b1);
	          } else if ((b1 & 0xe0) === 0xc0) {
	            var b2 = bytes.charCodeAt(j++) & 0xff;
	            out += String.fromCharCode(((b1 & 0x1f) << 6) | (b2 & 0x3f));
	          } else if ((b1 & 0xf0) === 0xe0) {
	            var b2 = bytes.charCodeAt(j++) & 0xff;
	            var b3 = bytes.charCodeAt(j++) & 0xff;
	            out += String.fromCharCode(((b1 & 0x0f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f));
	          } else if ((b1 & 0xf8) === 0xf0) {
	            var b2 = bytes.charCodeAt(j++) & 0xff;
	            var b3 = bytes.charCodeAt(j++) & 0xff;
	            var b4 = bytes.charCodeAt(j++) & 0xff;
	            var cp = ((b1 & 0x07) << 18) | ((b2 & 0x3f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f);
	            cp -= 0x10000;
	            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
	          }
	        }
	        return out;
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

// --- java.base64Encode / java.base64Decode 兼容 ---
(function() {
  var _j = typeof java !== "undefined" ? java : globalThis.java;
  if (_j) {
    if (!_j.base64Encode) {
      _j.base64Encode = function(str) {
        return Base64.encode(String(str));
      };
    }
    if (!_j.base64Decode) {
      _j.base64Decode = function(str) {
        return Base64.decode(String(str));
      };
    }
    if (!_j.ajax) {
      _j.ajax = function(url) {
        // 返回空字符串，Worker 中会拦截并真正发请求
        console.log('[Polyfill] java.ajax called (will be intercepted): ' + String(url).substring(0, 80));
        return '';
      };
    }
    if (!_j.longToast) {
      _j.longToast = function(msg) {
        console.log('[java.longToast] ' + msg);
      };
    }
    if (!_j.toast) {
      _j.toast = function(msg) {
        console.log('[java.toast] ' + msg);
      };
    }
    if (!_j.startBrowser) {
      _j.startBrowser = function(url, title) {
        console.log('[java.startBrowser] ' + (title || '') + ': ' + url);
      };
    }
  }
})();

// --- getVariable / setVariable 兼容 ---
(function() {
  if (typeof getVariable === 'undefined') {
    var _variables = {};
    globalThis.getVariable = function(key) {
      return _variables[key];
    };
    globalThis.setVariable = function(key, value) {
      _variables[key] = value;
    };
  }
})();

// --- BaseUrl() 全局函数（返回书源 base URL，由 ArkTS 侧在执行前注入） ---
(function() {
  if (typeof BaseUrl === 'undefined') {
    globalThis.BaseUrl = function() {
      return typeof baseUrl !== 'undefined' ? baseUrl : '';
    };
  }
})();

// --- hosts 变量（聚合书源常用，默认空） ---
(function() {
  if (typeof hosts === 'undefined') {
    globalThis.hosts = '';
  }
})();

// --- checkEnv() 兼容（聚合书源用） ---
(function() {
  if (typeof checkEnv === 'undefined') {
    globalThis.checkEnv = function() {
      return '鸿蒙';
    };
  }
})();

// --- getFqToken / getToken 兼容（聚合书源番茄/晴天登录） ---
(function() {
  if (typeof getFqToken === 'undefined') {
    globalThis.getFqToken = function() { return ''; };
  }
  if (typeof getToken === 'undefined') {
    globalThis.getToken = function() { return ''; };
  }
})();

// --- createFilter / createText / createButton 兼容（聚合书源发现页） ---
(function() {
  if (typeof createFilter === 'undefined') {
    globalThis.createFilter = function(name, options, selected, key, width, label) {
      return { title: name, type: 'filter', options: options, selected: selected, key: key, width: width, label: label };
    };
  }
  if (typeof createText === 'undefined') {
    globalThis.createText = function(name, action, defaultValue, width, placeholder) {
      return { title: name, type: 'text', action: action, defaultValue: defaultValue, width: width, placeholder: placeholder };
    };
  }
  if (typeof createButton === 'undefined') {
    globalThis.createButton = function(name, action, width) {
      return { title: name, type: 'button', action: action, width: width };
    };
  }
})();

// --- getCloudSettings / renderVersionPage / getHtmlSettings 兼容 ---
(function() {
  if (typeof getCloudSettings === 'undefined') {
    globalThis.getCloudSettings = function(force) {
      console.log('[Polyfill] getCloudSettings called, force=' + force);
    };
  }
  if (typeof renderVersionPage === 'undefined') {
    globalThis.renderVersionPage = function() {
      console.log('[Polyfill] renderVersionPage called');
    };
  }
  if (typeof getHtmlSettings === 'undefined') {
    globalThis.getHtmlSettings = function() {
      console.log('[Polyfill] getHtmlSettings called');
    };
  }
  if (typeof exploreSearch === 'undefined') {
    globalThis.exploreSearch = function() {
      console.log('[Polyfill] exploreSearch called');
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
