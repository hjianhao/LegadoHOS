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
 * java.ajax 实现（Worker 线程内使用 NAPI http.get/post）
 * 独立函数，不影响主 polyfill 加载
 */
export function getAjaxPolyfill(): string {
  return `
(function() {
  var _j = typeof java !== "undefined" ? java : (globalThis.java || {});
  if (!_j.ajax || _j.ajax._isMock) {
    // 从 http.get/post 返回的响应对象中提取 body 文本
    // C++ 桥返回 {statusCode, body: {_text, text(), json()}, baseUrl, headers}
    // java.ajax() 应返回 body 字符串（与 Android Legado 一致）
    function extractBody(resp) {
      if (resp === null || resp === undefined) return "";
      if (typeof resp === 'string') return resp;
      if (typeof resp === 'object') {
        // 优先用 body._text（C++ 桥存储的原始响应体）
        if (resp.body && typeof resp.body === 'object') {
          if (resp.body._text !== undefined) return String(resp.body._text);
          if (typeof resp.body.text === 'function') {
            try { var t = resp.body.text(); if (t) return String(t); } catch(_) {}
          }
        }
        // 兼容：直接 toString
        try { return String(resp); } catch(_) { return ""; }
      }
      return String(resp);
    }
    // 书源 header 字段作为默认请求头（对齐 Android AnalyzeUrl 的 source.getHeaderMap）。
    // 单次调用 url,{headers:{...}} 中的同名头覆盖默认值。
    // 得奇 ajax2.php 会校验 User-Agent，缺了书源 UA 会返回 "不支持该客户端访问"。
    function __srcHeaders() {
      var h = {};
      try {
        if (typeof source !== 'undefined' && source && source.header) {
          var sh = typeof source.header === 'string' ? JSON.parse(source.header) : source.header;
          if (sh && typeof sh === 'object') {
            for (var k in sh) {
              if (Object.prototype.hasOwnProperty.call(sh, k)) h[k] = String(sh[k]);
            }
          }
        }
      } catch(_) {}
      return h;
    }
    _j.ajax = function(url) {
      var s = String(url);
      if (typeof http !== "undefined" && http.get) {
        var m = s.match(/^(https?:\\/\\/[^,]+),(\\{[\\s\\S]*\\})$/);
        var u = s, method = "GET", body = "", headers = __srcHeaders();
        if (m) {
          u = m[1];
          try {
            var o = JSON.parse(m[2]);
            if (o.method) method = o.method.toUpperCase();
            if (o.body !== undefined) body = String(o.body);
            // headers 必须透传（对齐 Android AnalyzeUrl），否则 X-Requested-With/
            // Referer 丢失会导致 ajax 接口拒绝请求（如得奇 ajax2.php）
            if (o.headers && typeof o.headers === 'object') {
              for (var hk in o.headers) {
                if (Object.prototype.hasOwnProperty.call(o.headers, hk)) headers[hk] = String(o.headers[hk]);
              }
            }
          } catch(_) {}
        }
        try {
          if (method === "POST") return extractBody(http.post(u, body, { headers: headers }));
          return extractBody(http.get(u, { headers: headers }));
        } catch(_e) {}
      }
      return "";
    };
    _j.ajax._isMock = false;

    // ---- StrResponse / Jsoup Response 兼容包装（java.post/connect/get 返回值） ----
    // Android: connect() → StrResponse（.body()/.url()/.code()/.headers().get(name)）
    //          get/post() → Jsoup Connection.Response（.body()/.statusCode()/.header(name)/.cookie(name)/.cookies()）
    // 这里合并两种接口表面到一个对象上
    function __wrapResp(resp, url) {
      var bodyText = extractBody(resp);
      var h = (resp && resp.headers) || {};
      var statusCode = (resp && resp.statusCode) || 0;
      function lookupRaw(name) {
        var n = String(name).toLowerCase();
        for (var k in h) {
          if (Object.prototype.hasOwnProperty.call(h, k) && String(k).toLowerCase() === n) return h[k];
        }
        return null;
      }
      function lookupStr(name) {
        var v = lookupRaw(name);
        if (v === null || v === undefined) return null;
        return Array.isArray(v) ? v.join(', ') : String(v);
      }
      function parseSetCookies() {
        var raw = lookupRaw('set-cookie');
        if (!raw) return [];
        var arr = Array.isArray(raw) ? raw : String(raw).split(/,(?=\\s*[^\\s;,=]+=)/);
        var out = [];
        for (var i = 0; i < arr.length; i++) {
          var seg = String(arr[i]).split(';')[0];
          var eq = seg.indexOf('=');
          if (eq > 0) out.push([seg.substring(0, eq).trim(), seg.substring(eq + 1).trim()]);
        }
        return out;
      }
      var headersFn = function(name) {
        if (name === undefined) return { get: headersFn.get, values: headersFn.values, raw: h };
        var v = lookupStr(name);
        return v === null ? '' : v;
      };
      headersFn.get = function(n) { return lookupStr(n); };
      headersFn.values = function(n) {
        var r = lookupRaw(n);
        return r === null || r === undefined ? [] : (Array.isArray(r) ? r.slice() : [String(r)]);
      };
      return {
        body: function() { return bodyText; },
        text: function() { return bodyText; },
        url: function() { return url; },
        code: function() { return statusCode; },
        statusCode: function() { return statusCode; },
        statusMessage: function() { return ''; },
        headers: headersFn,
        header: function(name) { var v = lookupStr(name); return v === null ? '' : v; },
        cookie: function(name) {
          var cs = parseSetCookies();
          for (var i = 0; i < cs.length; i++) if (cs[i][0] === name) return cs[i][1];
          return null;
        },
        cookies: function() {
          var cs = parseSetCookies(); var m = {};
          for (var i = 0; i < cs.length; i++) m[cs[i][0]] = cs[i][1];
          return m;
        },
        raw: function() { return resp; },
        toString: function() { return bodyText; }
      };
    }
    _j.__wrapResp = __wrapResp;

    // java.post(url, body, headers?) — headers 为 JS 对象（对应 Rhino 的 Map）
    if (!_j.post) {
      _j.post = function(url, body, headers) {
        if (typeof http === "undefined" || !http.post) throw new Error("http.post 不可用");
        var h = headers || {};
        if (typeof h === 'string') { try { h = JSON.parse(h); } catch(_) { h = {}; } }
        var resp = http.post(String(url), body === undefined || body === null ? '' : String(body), { headers: h });
        return __wrapResp(resp, String(url));
      };
    }
    // java.connect(url, headerJson?) — GET，header 为 JSON 字符串
    if (!_j.connect) {
      _j.connect = function(url, header) {
        if (typeof http === "undefined" || !http.get) throw new Error("http.get 不可用");
        var h = {};
        if (typeof header === 'string' && header) { try { h = JSON.parse(header); } catch(_) { h = {}; } }
        else if (header && typeof header === 'object') { h = header; }
        var resp = http.get(String(url), { headers: h });
        return __wrapResp(resp, String(url));
      };
    }
    // java.get(url, headers?) — GET，headers 为 JS 对象（Jsoup 语义）
    if (!_j.get) {
      _j.get = function(url, headers) {
        if (typeof http === "undefined" || !http.get) throw new Error("http.get 不可用");
        var h = headers || {};
        if (typeof h === 'string') { try { h = JSON.parse(h); } catch(_) { h = {}; } }
        var resp = http.get(String(url), { headers: h });
        return __wrapResp(resp, String(url));
      };
    }
  }
})();

// --- cookie 对象（对应 Android AnalyzeUrl 绑定的 CookieStore） ---
(function() {
  if (typeof cookie === 'undefined' && typeof __cookieOp === 'function') {
    globalThis.cookie = {
      getCookie: function(url) {
        try { return __cookieOp('get', String(url), '') || ''; } catch(_) { return ''; }
      },
      setCookie: function(url, c) {
        try { __cookieOp('set', String(url), String(c === null || c === undefined ? '' : c)); } catch(_) {}
      },
      replaceCookie: function(url, c) {
        try { __cookieOp('set', String(url), String(c === null || c === undefined ? '' : c)); } catch(_) {}
      },
      removeCookie: function(url) {
        try { __cookieOp('remove', String(url), ''); } catch(_) {}
      },
      getKey: function(url, key) {
        var c = this.getCookie(url);
        var parts = c.split(';');
        for (var i = 0; i < parts.length; i++) {
          var kv = parts[i].split('=');
          if (kv.length >= 2 && kv[0].trim() === String(key)) return kv.slice(1).join('=').trim();
        }
        return '';
      }
    };
  }
})();
`;
}

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

// --- java.md5Encode / java.md5Encode16 兼容 ---
// Android Legado 的 API 书源经常使用 java.md5Encode 计算请求签名。
// QuickJS 没有 Java/Rhino 的原生方法，因此提供一个纯 JS 实现；只在宿主
// 没有同名函数时注入，避免覆盖未来的原生桥接。输入按 UTF-8 编码，结果
// 与 Android MD5Utils.md5Encode 一致（32 位小写十六进制字符串）。
(function() {
  var _j = typeof java !== "undefined" ? java : globalThis.java;
  if (!_j || _j.md5Encode) return;

  function utf8Binary(value) {
    var str = String(value);
    var out = '';
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) {
        out += String.fromCharCode(c);
      } else if (c < 0x800) {
        out += String.fromCharCode(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
        out += String.fromCharCode(
          0xf0 | (cp >> 18),
          0x80 | ((cp >> 12) & 0x3f),
          0x80 | ((cp >> 6) & 0x3f),
          0x80 | (cp & 0x3f)
        );
      } else {
        out += String.fromCharCode(
          0xe0 | (c >> 12),
          0x80 | ((c >> 6) & 0x3f),
          0x80 | (c & 0x3f)
        );
      }
    }
    return out;
  }

  function add32(a, b) { return (a + b) | 0; }
  function cmn(q, a, b, x, s, t) {
    return add32(((add32(add32(a, q), add32(x, t)) << s) |
      (add32(add32(a, q), add32(x, t)) >>> (32 - s))), b);
  }
  function ff(a, b, c, d, x, s, t) { return cmn((b & c) | ((~b) & d), a, b, x, s, t); }
  function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & (~d)), a, b, x, s, t); }
  function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
  function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | (~d)), a, b, x, s, t); }

  function md5cycle(state, block) {
    var a = state[0], b = state[1], c = state[2], d = state[3];
    a = ff(a,b,c,d,block[0],7,-680876936); d = ff(d,a,b,c,block[1],12,-389564586); c = ff(c,d,a,b,block[2],17,606105819); b = ff(b,c,d,a,block[3],22,-1044525330);
    a = ff(a,b,c,d,block[4],7,-176418897); d = ff(d,a,b,c,block[5],12,1200080426); c = ff(c,d,a,b,block[6],17,-1473231341); b = ff(b,c,d,a,block[7],22,-45705983);
    a = ff(a,b,c,d,block[8],7,1770035416); d = ff(d,a,b,c,block[9],12,-1958414417); c = ff(c,d,a,b,block[10],17,-42063); b = ff(b,c,d,a,block[11],22,-1990404162);
    a = ff(a,b,c,d,block[12],7,1804603682); d = ff(d,a,b,c,block[13],12,-40341101); c = ff(c,d,a,b,block[14],17,-1502002290); b = ff(b,c,d,a,block[15],22,1236535329);
    a = gg(a,b,c,d,block[1],5,-165796510); d = gg(d,a,b,c,block[6],9,-1069501632); c = gg(c,d,a,b,block[11],14,643717713); b = gg(b,c,d,a,block[0],20,-373897302);
    a = gg(a,b,c,d,block[5],5,-701558691); d = gg(d,a,b,c,block[10],9,38016083); c = gg(c,d,a,b,block[15],14,-660478335); b = gg(b,c,d,a,block[4],20,-405537848);
    a = gg(a,b,c,d,block[9],5,568446438); d = gg(d,a,b,c,block[14],9,-1019803690); c = gg(c,d,a,b,block[3],14,-187363961); b = gg(b,c,d,a,block[8],20,1163531501);
    a = gg(a,b,c,d,block[13],5,-1444681467); d = gg(d,a,b,c,block[2],9,-51403784); c = gg(c,d,a,b,block[7],14,1735328473); b = gg(b,c,d,a,block[12],20,-1926607734);
    a = hh(a,b,c,d,block[5],4,-378558); d = hh(d,a,b,c,block[8],11,-2022574463); c = hh(c,d,a,b,block[11],16,1839030562); b = hh(b,c,d,a,block[14],23,-35309556);
    a = hh(a,b,c,d,block[1],4,-1530992060); d = hh(d,a,b,c,block[4],11,1272893353); c = hh(c,d,a,b,block[7],16,-155497632); b = hh(b,c,d,a,block[10],23,-1094730640);
    a = hh(a,b,c,d,block[13],4,681279174); d = hh(d,a,b,c,block[0],11,-358537222); c = hh(c,d,a,b,block[3],16,-722521979); b = hh(b,c,d,a,block[6],23,76029189);
    a = hh(a,b,c,d,block[9],4,-640364487); d = hh(d,a,b,c,block[12],11,-421815835); c = hh(c,d,a,b,block[15],16,530742520); b = hh(b,c,d,a,block[2],23,-995338651);
    a = ii(a,b,c,d,block[0],6,-198630844); d = ii(d,a,b,c,block[7],10,1126891415); c = ii(c,d,a,b,block[14],15,-1416354905); b = ii(b,c,d,a,block[5],21,-57434055);
    a = ii(a,b,c,d,block[12],6,1700485571); d = ii(d,a,b,c,block[3],10,-1894986606); c = ii(c,d,a,b,block[10],15,-1051523); b = ii(b,c,d,a,block[1],21,-2054922799);
    a = ii(a,b,c,d,block[8],6,1873313359); d = ii(d,a,b,c,block[15],10,-30611744); c = ii(c,d,a,b,block[6],15,-1560198380); b = ii(b,c,d,a,block[13],21,1309151649);
    a = ii(a,b,c,d,block[4],6,-145523070); d = ii(d,a,b,c,block[11],10,-1120210379); c = ii(c,d,a,b,block[2],15,718787259); b = ii(b,c,d,a,block[9],21,-343485551);
    state[0] = add32(state[0], a); state[1] = add32(state[1], b);
    state[2] = add32(state[2], c); state[3] = add32(state[3], d);
  }

  function md5Encode(value) {
    var str = utf8Binary(value);
    var n = str.length;
    var state = [1732584193, -271733879, -1732584194, 271733878];
    var i;
    for (i = 64; i <= n; i += 64) {
      var block = [];
      for (var j = 0; j < 64; j += 4) {
        block[j >> 2] = (str.charCodeAt(i - 64 + j) & 0xff) |
          ((str.charCodeAt(i - 64 + j + 1) & 0xff) << 8) |
          ((str.charCodeAt(i - 64 + j + 2) & 0xff) << 16) |
          ((str.charCodeAt(i - 64 + j + 3) & 0xff) << 24);
      }
      md5cycle(state, block);
    }
    str = str.substring(i - 64);
    var tail = [];
    for (var k = 0; k < 64; k++) tail[k >> 2] = tail[k >> 2] || 0;
    for (var p = 0; p < str.length; p++) tail[p >> 2] |= (str.charCodeAt(p) & 0xff) << ((p % 4) * 8);
    tail[str.length >> 2] |= 0x80 << ((str.length % 4) * 8);
    if (str.length > 55) { md5cycle(state, tail); for (var z = 0; z < 16; z++) tail[z] = 0; }
    tail[14] = n * 8;
    tail[15] = Math.floor(n / 0x20000000);
    md5cycle(state, tail);
    var hex = '';
    for (var q = 0; q < 4; q++) {
      for (var r = 0; r < 4; r++) {
        var byte = (state[q] >> (r * 8)) & 0xff;
        hex += ('0' + byte.toString(16)).slice(-2);
      }
    }
    return hex;
  }

  _j.md5Encode = md5Encode;
  _j.md5Encode16 = function(value) { return md5Encode(value).substring(8, 24); };
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
	        console.log('[Polyfill] java.ajax called: ' + String(url).substring(0, 80));
	        return '';
	      };
	      _j.ajax._isMock = true; // 标记为 mock，让 getAjaxPolyfill 替换为真实实现
	    }
	    if (!_j.put) {
	      _j.put = function(key, value) {
	        console.log('[Polyfill] java.put: ' + key + '=' + (typeof value === 'string' ? value.substring(0, 40) : JSON.stringify(value)));
	        if (!globalThis.__javaStore) globalThis.__javaStore = {};
	        globalThis.__javaStore[key] = value;
	        // Android AnalyzeRule.put 返回 value，书源经常把它直接拼接到 URL。
	        return value;
	      };
	    }
	    if (!_j.get) {
	      _j.get = function(key) {
	        var store = globalThis.__javaStore || {};
	        return store[key] !== undefined ? store[key] : '';
	      };
	    }
	    if (!_j.getVerificationCode) {
	      _j.getVerificationCode = function(imgUrl) {
	        console.log('[Polyfill] java.getVerificationCode: ' + (imgUrl || '').substring(0, 80));
	        // QuickJS 原生桥可用时走同步阻塞（与 Android Legado 行为一致）：
	        // __captchaOp 由 napi_bridge 注入，内部泵事件循环等主线程弹窗返回
	        if (typeof __captchaOp === 'function') {
	          return String(__captchaOp(String(imgUrl || '')) || '');
	        }
	        // Worker 环境：通过 postMessage 请求主线程显示验证码弹窗
	        if (typeof parentPort !== 'undefined' && typeof parentPort.postMessage === 'function') {
	          var msgId = Date.now() + '_' + Math.random().toString(36).substring(2, 8);
	          return new Promise(function(resolve) {
	            var listener = function(event) {
	              var data = event.data;
	              if (data && data.type === 'captcha_result' && data.id === msgId) {
	                parentPort.removeEventListener('message', listener);
	                resolve(data.value || '');
	              }
	            };
	            parentPort.addEventListener('message', listener);
	            parentPort.postMessage({ type: 'captcha', url: imgUrl, id: msgId });
	            // 60秒超时
	            setTimeout(function() {
	              parentPort.removeEventListener('message', listener);
	              resolve('');
	            }, 60000);
	          });
	        }
	        // 非 Worker 环境：尝试全局回调
	        if (typeof globalThis.__showCaptcha === 'function') {
	          return globalThis.__showCaptcha(imgUrl);
	        }
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
	    if (!_j.startBrowserAwait) {
	      _j.startBrowserAwait = function(url, title) {
	        console.log('[java.startBrowserAwait] ' + (title || '') + ': ' + url);
	        // 如果宿主注册了 __startBrowserAwait 回调，用它加载 URL 并返回 HTML
	        if (typeof globalThis.__startBrowserAwait === 'function') {
	          var html = globalThis.__startBrowserAwait(url);
	          if (html) {
	            return { body: function() { return html; } };
	          }
	        }
	        // 无回调时返回空 HTML
	        return { body: function() { return ''; } };
	      };
	    }
	    if (!_j.log) {
	      _j.log = function(msg) {
	        console.log('[java.log] ' + String(msg));
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

	// --- Array.prototype.at 兼容（ES2022，QuickJS 0.15 不支持） ---
	(function() {
	  if (!Array.prototype.at) {
	    Array.prototype.at = function(n) {
	      n = +n;
	      if (n < 0) n += this.length;
	      return n >= 0 && n < this.length ? this[n] : undefined;
	    };
	  }
	  if (!String.prototype.at) {
	    String.prototype.at = function(n) {
	      n = +n;
	      if (n < 0) n += this.length;
	      return n >= 0 && n < this.length ? this.charAt(n) : undefined;
	    };
	  }
	})();

	// --- org.jsoup Jsoup.parse 兼容 shim ---
	// 很多书源用 Jsoup.parse(html).select(".class").attr("attr") 提取页面元素
	// 支持链式调用: parse(html).select('.a').toArray().at(-1).select('a')
	(function() {
	  // 从 HTML 片段中按 CSS 选择器提取匹配的标签信息
	  // 返回 [{tagMatch, fullTag, pos, innerHtml, innerText}, ...]
	  function selectTags(html, css) {
	    var items = [];
	    if (!css) return items;
	    // 支持 .class、tag、tag.class、#id、多选择器（逗号分隔）
	    var selectors = css.split(',');
	    for (var si = 0; si < selectors.length; si++) {
	      var sel = selectors[si].trim();
	      if (!sel) continue;
	      // 去掉伪类如 :eq(0)
	      var colonIdx = sel.indexOf(':');
	      if (colonIdx > 0) sel = sel.substring(0, colonIdx).trim();

	      var tagName = '', className = '', idName = '';
	      // 解析选择器: tag.class#id
	      var parts = sel.match(/^([a-zA-Z0-9]+)?(?:\.([a-zA-Z0-9_-]+))?(?:#([a-zA-Z0-9_-]+))?$/);
	      if (parts) {
	        tagName = parts[1] || '';
	        className = parts[2] || '';
	        idName = parts[3] || '';
	      } else if (sel.indexOf('.') === 0) {
	        className = sel.substring(1);
	      } else if (sel.indexOf('#') === 0) {
	        idName = sel.substring(1);
	      } else {
	        tagName = sel;
	      }

			      // 构建正则 — 同时支持双引号和单引号的 class/id 属性
		      // 不使用 \b（在 TS 模板字符串中存在转义问题），直接用 className 字面匹配
		      // 实际 HTML 中类名冲突（如 notag-container）概率极低
		      var reStr = '<([a-zA-Z0-9]+)[^>]*';
		      if (className) {
		        reStr += '\\\\s(class|CLASS)\\\\s*=\\\\s*(?:';
		        reStr += '"[^"]*' + className + '[^"]*"';
		        reStr += "|'[^']*" + className + "[^']*'";
		        reStr += ')';
		      }
		      if (idName) {
		        reStr += '\\\\s(id|ID)\\\\s*=\\\\s*(?:';
		        reStr += '"[^"]*' + idName + '[^"]*"';
		        reStr += "|'[^']*" + idName + "[^']*'";
		        reStr += ')';
		      }
		      reStr += '[^>]*>';
		      try {
		        console.log('[Jsoup] css=' + css + ' re=' + reStr.substring(0, 150));
		        var re = new RegExp(reStr, 'gi');
		        var m;
	        while ((m = re.exec(html)) !== null) {
	          if (tagName && m[1].toLowerCase() !== tagName.toLowerCase()) continue;
	            (function(tagMatch, fullTag, pos) {
	              items.push(makeElement(html, tagMatch, fullTag, pos));
	            })(m[1], m[0], m.index);
	        }
	      } catch(_) {}
	    }
	    return items;
	  }

	  // 获取当前元素的完整 innerHTML，正确处理 div 等同名标签嵌套。
	  // 旧实现直接查找第一个 </tag>，会把 tag-container 截断到第一个子 div。
	  function getInnerHtml(html, tagMatch, fullTag, pos) {
	    var contentStart = pos + fullTag.length;
	    var lowerHtml = html.toLowerCase();
	    var lowerTag = tagMatch.toLowerCase();
	    var openToken = '<' + lowerTag;
	    var closeToken = '</' + lowerTag + '>';
	    var cursor = contentStart;
	    var depth = 1;
	    while (cursor < html.length) {
	      var nextOpen = lowerHtml.indexOf(openToken, cursor);
	      var nextClose = lowerHtml.indexOf(closeToken, cursor);
	      if (nextClose < 0) return html.substring(contentStart);
	      // 避免把 <divider> 误判为 <div>。
	      var validOpen = nextOpen >= 0;
	      if (validOpen) {
	        var boundary = lowerHtml.charAt(nextOpen + openToken.length);
	        validOpen = boundary === '>' || boundary === '/' || boundary === ' ' || boundary === '\\t' || boundary === '\\r' || boundary === '\\n';
	      }
	      if (validOpen && nextOpen < nextClose) {
	        var openEnd = lowerHtml.indexOf('>', nextOpen + openToken.length);
	        if (openEnd < 0) return html.substring(contentStart);
	        if (lowerHtml.charAt(openEnd - 1) !== '/') depth++;
	        cursor = openEnd + 1;
	      } else {
	        depth--;
	        if (depth === 0) return html.substring(contentStart, nextClose);
	        cursor = nextClose + closeToken.length;
	      }
	    }
	    return html.substring(contentStart);
	  }

	  // 创建一个 Element 对象，支持 .select/.attr/.text/.html
	  function makeElement(html, tagMatch, fullTag, pos) {
	    return {
	      attr: function(name) {
	        var am = fullTag.match(new RegExp(name + '\\\\s*=\\\\s*"([^"]*)"', 'i'));
	        if (am) return am[1];
	        var am2 = fullTag.match(new RegExp(name + "\\\\s*=\\\\s*'([^']*)'", 'i'));
	        return am2 ? am2[1] : '';
	      },
	      text: function() {
	        return getInnerHtml(html, tagMatch, fullTag, pos).replace(/<[^>]+>/g, '').trim();
	      },
	      html: function() {
	        return getInnerHtml(html, tagMatch, fullTag, pos);
	      },
	      // 链式 select：在当前元素的 innerHTML 中查找
	      select: function(css) {
	        var inner = this.html();
	        var subItems = selectTags(inner, css);
	        return makeElements(inner, subItems);
	      }
	    };
	  }

	  // 创建 Elements 类数组对象（同时是真正的数组，支持 .at()/.toArray()/.select()）
	  function makeElements(html, items) {
	    // 用真数组作为基础，使 .at()/.forEach()/for...of 等原生方法可用
	    var els = items.slice();
	    // Elements 上的方法（非可枚举，不干扰 for...in）
	    Object.defineProperty(els, 'attr', {
	      value: function(name) { return items.length > 0 ? items[0].attr(name) : ''; }
	    });
	    Object.defineProperty(els, 'text', {
	      value: function() {
	        return items.length > 0 ? items[0].text() : '';
	      }
	    });
	    Object.defineProperty(els, 'html', {
	      value: function() {
	        return items.length > 0 ? items[0].html() : '';
	      }
	    });
	    Object.defineProperty(els, 'eq', {
	      value: function(i) {
	        return items[i] || { attr:function(){return '';}, text:function(){return '';}, html:function(){return '';}, select:function(){return makeElements('', []);} };
	      }
	    });
	    Object.defineProperty(els, 'first', {
	      value: function() { return items[0] || null; }
	    });
	    Object.defineProperty(els, 'last', {
	      value: function() { return items[items.length - 1] || null; }
	    });
	    Object.defineProperty(els, 'isEmpty', {
	      value: function() { return items.length === 0; }
	    });
	    Object.defineProperty(els, 'size', {
	      value: function() { return items.length; }
	    });
	    Object.defineProperty(els, 'get', {
	      value: function(i) { return items[i] || null; }
	    });
		    Object.defineProperty(els, 'toArray', {
		      value: function() { return items.slice(); }
		    });
		    Object.defineProperty(els, 'each', {
		      value: function(fn) { for (var i = 0; i < items.length; i++) fn(items[i]); }
		    });
	    Object.defineProperty(els, 'select', {
	      value: function(css) {
	        // 对所有元素的 innerHTML 做 select，合并结果
	        var all = [];
	        for (var i = 0; i < items.length; i++) {
	          var inner = items[i].html();
	          var sub = selectTags(inner, css);
	          for (var j = 0; j < sub.length; j++) all.push(sub[j]);
	        }
	        return makeElements(html, all);
	      }
	    });
	    return els;
	  }

		  if (typeof org === 'undefined') {
		    globalThis.org = {
		      jsoup: {
		        Jsoup: {
		          parse: function(html) {
		            console.log('[Jsoup] parse called, html len=' + (html ? html.length : 0));
		            return {
		              select: function(css) {
		                var items = selectTags(html, css);
		                console.log('[Jsoup] select "' + css + '" found ' + items.length + ' items');
		                return makeElements(html, items);
		              },
	              text: function() { return html.replace(/<[^>]+>/g, '').trim(); },
	              attr: function(name) {
	                var m2 = html.match(new RegExp(name + '\\\\s*=\\\\s*"([^"]*)"', 'i'));
	                return m2 ? m2[1] : '';
	              }
	            };
	          }
	        }
	      }
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
