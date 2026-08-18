/**
 * QuickJS 纯 JS 加密 polyfill（java.createSymmetricCrypto 等桥接）
 *
 * 背景：Android Legado 的 JS 环境通过 java.createSymmetricCrypto() 提供对称加密
 * （JsEncodeUtils.kt → hutool SymmetricCrypto）。我们的 QuickJS 桥接没有 Java
 * 互操作，且 cryptoFramework 是异步 API，无法在同步 JS 求值中使用；AES 是标准
 * 公开算法，纯 JS 实现即可对齐 Android 语义：
 * - createSymmetricCrypto(transformation, key, iv?)：key/iv 按 UTF-8 转字节数组，
 *   transformation 形如 "AES/CBC/PKCS5Padding"（Android JsEncodeUtils.kt 70-73 行）
 * - 返回对象：encryptBase64(data) / encryptHex(data) / encrypt(data) / decrypt(data) / decryptStr(data)
 *   （hutool SymmetricCrypto 同名方法）
 * - decrypt 输入自动识别：全 hex 字符按 hex 解码，否则按 Base64（hutool SecureUtil.decode）
 *
 * 仅实现 AES（128/192/256，CBC/ECB，PKCS5/PKCS7/NoPadding）。DES/3DES 等未实现，
 * 调用时抛错而不是返回错误结果（书源 JS 侧通常有 try-catch 兜底）。
 *
 * 注入点：JsExpressionEvaluator.buildContextScript() 开头。脚本幂等（typeof 保护），
 * 主线程 ScriptEngine（全局对象持久）只真正执行一次；Worker 每次求值重复执行无副作用。
 */
export const JS_CRYPTO_POLYFILL: string = `(function () {
  "use strict";
  if (typeof globalThis.java === "undefined") { globalThis.java = {}; }
  var java = globalThis.java;
  if (typeof java.createSymmetricCrypto !== "undefined") { return; }

  // ---------- UTF-8 ----------
  function utf8Encode(str) {
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) {
        bytes.push(c);
      } else if (c < 0x800) {
        bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      } else if (c < 0xd800 || c >= 0xe000) {
        bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      } else {
        i++;
        var c2 = str.charCodeAt(i);
        var cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
        bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      }
    }
    return bytes;
  }
  function utf8Decode(bytes) {
    var out = "";
    var i = 0;
    while (i < bytes.length) {
      var b1 = bytes[i++] & 0xff;
      if (b1 < 0x80) {
        out += String.fromCharCode(b1);
      } else if ((b1 & 0xe0) === 0xc0) {
        out += String.fromCharCode(((b1 & 0x1f) << 6) | ((bytes[i++] & 0xff) & 0x3f));
      } else if ((b1 & 0xf0) === 0xe0) {
        out += String.fromCharCode(((b1 & 0x0f) << 12) | (((bytes[i++] & 0xff) & 0x3f) << 6) | ((bytes[i++] & 0xff) & 0x3f));
      } else if ((b1 & 0xf8) === 0xf0) {
        var cp = ((b1 & 0x07) << 18) | (((bytes[i++] & 0xff) & 0x3f) << 12) | (((bytes[i++] & 0xff) & 0x3f) << 6) | ((bytes[i++] & 0xff) & 0x3f);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      }
    }
    return out;
  }

  // ---------- Base64 / Hex ----------
  var B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function b64Encode(bytes) {
    var out = "";
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i] & 0xff, b1 = (i + 1 < bytes.length) ? (bytes[i + 1] & 0xff) : 0, b2 = (i + 2 < bytes.length) ? (bytes[i + 2] & 0xff) : 0;
      out += B64_ALPHABET[b0 >> 2];
      out += B64_ALPHABET[((b0 & 3) << 4) | (b1 >> 4)];
      out += (i + 1 < bytes.length) ? B64_ALPHABET[((b1 & 0xf) << 2) | (b2 >> 6)] : "=";
      out += (i + 2 < bytes.length) ? B64_ALPHABET[b2 & 0x3f] : "=";
    }
    return out;
  }
  function b64Decode(str) {
    var clean = String(str).replace(/\\s/g, "").replace(/=+$/, "");
    var bytes = [];
    for (var i = 0; i < clean.length; i += 4) {
      var b0 = B64_ALPHABET.indexOf(clean.charAt(i));
      var b1 = B64_ALPHABET.indexOf(clean.charAt(i + 1));
      var b2 = B64_ALPHABET.indexOf(clean.charAt(i + 2));
      var b3 = B64_ALPHABET.indexOf(clean.charAt(i + 3));
      if (b0 < 0 || b1 < 0) { break; }
      bytes.push((b0 << 2) | (b1 >> 4));
      if (b2 >= 0 && i + 2 < clean.length) { bytes.push(((b1 & 0xf) << 4) | (b2 >> 2)); }
      if (b3 >= 0 && i + 3 < clean.length) { bytes.push(((b2 & 3) << 6) | b3); }
    }
    return bytes;
  }
  function hexEncode(bytes) {
    var out = "";
    for (var i = 0; i < bytes.length; i++) {
      var h = (bytes[i] & 0xff).toString(16);
      out += h.length === 1 ? "0" + h : h;
    }
    return out;
  }
  function hexDecode(str) {
    var s = String(str);
    var bytes = [];
    for (var i = 0; i + 1 < s.length; i += 2) {
      bytes.push(parseInt(s.substr(i, 2), 16));
    }
    return bytes;
  }
  function isHexString(str) {
    var s = String(str);
    if (s.length < 2) { return false; }
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70))) { return false; }
    }
    return true;
  }

  // ---------- AES ----------
  // S-box（FIPS-197 附录 A 标准表，硬编码避免生成算法出错）
  var SBOX = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
  ];
  var RSBOX = [];
  for (var si = 0; si < 256; si++) { RSBOX[SBOX[si]] = si; }
  var RCON = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

  function keyExpansion(keyBytes) {
    var nk = keyBytes.length / 4;
    var nr = nk + 6;
    var total = 4 * (nr + 1);
    var w = [];
    for (var i = 0; i < nk; i++) {
      w[i] = ((keyBytes[4 * i] & 0xff) << 24) | ((keyBytes[4 * i + 1] & 0xff) << 16) | ((keyBytes[4 * i + 2] & 0xff) << 8) | (keyBytes[4 * i + 3] & 0xff);
    }
    for (var i = nk; i < total; i++) {
      var temp = w[i - 1];
      if (i % nk === 0) {
        // RotWord：循环左移一个字节，再 SubWord，最后异或 RCON
        temp = ((temp << 8) | (temp >>> 24)) >>> 0;
        temp = ((SBOX[(temp >>> 24) & 0xff] << 24) | (SBOX[(temp >>> 16) & 0xff] << 16) | (SBOX[(temp >>> 8) & 0xff] << 8) | SBOX[temp & 0xff]);
        temp ^= (RCON[i / nk] << 24);
      } else if (nk > 6 && i % nk === 4) {
        temp = ((SBOX[(temp >>> 24) & 0xff] << 24) | (SBOX[(temp >>> 16) & 0xff] << 16) | (SBOX[(temp >>> 8) & 0xff] << 8) | SBOX[temp & 0xff]);
      }
      w[i] = (w[i - nk] ^ temp) >>> 0;
    }
    return { nr: nr, w: w };
  }

  // 状态为 s[column][row]
  function addRoundKey(s, w, round) {
    for (var c = 0; c < 4; c++) {
      var k = w[round * 4 + c] >>> 0;
      s[c][0] ^= (k >>> 24) & 0xff;
      s[c][1] ^= (k >>> 16) & 0xff;
      s[c][2] ^= (k >>> 8) & 0xff;
      s[c][3] ^= k & 0xff;
    }
  }
  function subBytes(s, box) {
    for (var c = 0; c < 4; c++) {
      s[c][0] = box[s[c][0]];
      s[c][1] = box[s[c][1]];
      s[c][2] = box[s[c][2]];
      s[c][3] = box[s[c][3]];
    }
  }
  // ShiftRows：第 r 行循环左移 r 字节（inv 时右移）
  function shiftRows(s, inv) {
    for (var r = 1; r < 4; r++) {
      var row = [s[0][r], s[1][r], s[2][r], s[3][r]];
      for (var c = 0; c < 4; c++) {
        s[c][r] = inv ? row[(c + 4 - r) % 4] : row[(c + r) % 4];
      }
    }
  }
  function xtime(a) { return ((a << 1) ^ ((a & 0x80) ? 0x1b : 0)) & 0xff; }
  // GF(2^8) 乘法（系数 2/3/9/11/13/14）
  function gfMul(a, n) {
    a &= 0xff;
    var r = 0;
    while (n > 0) {
      if (n & 1) { r ^= a; }
      a = xtime(a);
      n >>= 1;
    }
    return r & 0xff;
  }
  function mixColumns(s, inv) {
    for (var c = 0; c < 4; c++) {
      var a0 = s[c][0], a1 = s[c][1], a2 = s[c][2], a3 = s[c][3];
      if (!inv) {
        var t = a0 ^ a1 ^ a2 ^ a3;
        s[c][0] = (a0 ^ xtime(a0 ^ a1) ^ t) & 0xff;
        s[c][1] = (a1 ^ xtime(a1 ^ a2) ^ t) & 0xff;
        s[c][2] = (a2 ^ xtime(a2 ^ a3) ^ t) & 0xff;
        s[c][3] = (a3 ^ xtime(a3 ^ a0) ^ t) & 0xff;
      } else {
        s[c][0] = (gfMul(a0, 14) ^ gfMul(a1, 11) ^ gfMul(a2, 13) ^ gfMul(a3, 9)) & 0xff;
        s[c][1] = (gfMul(a0, 9) ^ gfMul(a1, 14) ^ gfMul(a2, 11) ^ gfMul(a3, 13)) & 0xff;
        s[c][2] = (gfMul(a0, 13) ^ gfMul(a1, 9) ^ gfMul(a2, 14) ^ gfMul(a3, 11)) & 0xff;
        s[c][3] = (gfMul(a0, 11) ^ gfMul(a1, 13) ^ gfMul(a2, 9) ^ gfMul(a3, 14)) & 0xff;
      }
    }
  }

  // 单块 AES（无模式处理）。输入/输出均为 16 字节数组，encrypt 决定方向
  function aesBlock(data, offset, kx, encrypt) {
    var s = [[], [], [], []];
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        s[c][r] = data[offset + c * 4 + r] & 0xff;
      }
    }
    if (encrypt) {
      addRoundKey(s, kx.w, 0);
      for (var round = 1; round < kx.nr; round++) {
        subBytes(s, SBOX);
        shiftRows(s, false);
        mixColumns(s, false);
        addRoundKey(s, kx.w, round);
      }
      subBytes(s, SBOX);
      shiftRows(s, false);
      addRoundKey(s, kx.w, kx.nr);
    } else {
      addRoundKey(s, kx.w, kx.nr);
      for (var round = kx.nr - 1; round >= 1; round--) {
        shiftRows(s, true);
        subBytes(s, RSBOX);
        addRoundKey(s, kx.w, round);
        mixColumns(s, true);
      }
      shiftRows(s, true);
      subBytes(s, RSBOX);
      addRoundKey(s, kx.w, 0);
    }
    var out = [];
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        out.push(s[c][r] & 0xff);
      }
    }
    return out;
  }

  function pkcs7Pad(data) {
    var padLen = 16 - (data.length % 16);
    var out = data.slice();
    for (var i = 0; i < padLen; i++) { out.push(padLen); }
    return out;
  }
  function pkcs7Unpad(data) {
    if (!data.length || data.length % 16 !== 0) { return data; }
    var padLen = data[data.length - 1] & 0xff;
    if (padLen < 1 || padLen > 16) { return data; }
    return data.slice(0, data.length - padLen);
  }

  // 分组处理 + CBC 链接。CBC XOR 在此统一处理（加密：明文⊕IV/前块；解密：输出⊕IV/前块）
  function aesProcessBytes(inputBytes, keyBytes, ivBytes, mode, padding, encrypt) {
    var data = encrypt ? pkcs7Pad(inputBytes) : inputBytes;
    if (data.length % 16 !== 0) { throw new Error("AES input length not multiple of 16"); }
    var kx = keyExpansion(keyBytes);
    var iv = null;
    if (mode === "CBC" && ivBytes) { iv = ivBytes.slice(0, 16); }
    var out = [];
    for (var offset = 0; offset < data.length; offset += 16) {
      if (mode === "CBC" && iv && encrypt) {
        // CBC 加密：当前明文块先与 IV/前一个密文块异或
        for (var i = 0; i < 16; i++) { data[offset + i] = (data[offset + i] & 0xff) ^ (iv[i] & 0xff); }
      }
      var block = aesBlock(data, offset, kx, encrypt);
      if (mode === "CBC" && iv) {
        if (encrypt) {
          iv = block.slice();
        } else {
          // CBC 解密：解密输出与 IV（首块）/前一个密文块（后续块）异或
          var prev = data.slice(offset, offset + 16);
          for (var i = 0; i < 16; i++) { block[i] = (block[i] & 0xff) ^ (iv[i] & 0xff); }
          iv = prev;
        }
      }
      for (var i = 0; i < 16; i++) { out.push(block[i] & 0xff); }
    }
    return encrypt ? out : (padding === "NOPADDING" ? out : pkcs7Unpad(out));
  }

  function aesProcess(str, keyBytes, ivBytes, mode, padding, encrypt) {
    return aesProcessBytes(utf8Encode(str), keyBytes, ivBytes, mode, padding, encrypt);
  }

  // ---------- java bridge ----------
  function createSymmetricCrypto(transformation, key, iv) {
    var parts = String(transformation || "").split("/");
    var alg = parts[0] ? parts[0].toUpperCase() : "";
    var mode = parts[1] ? parts[1].toUpperCase() : "ECB";
    var padding = parts[2] ? parts[2].toUpperCase() : "PKCS5PADDING";
    if (alg !== "AES") {
      throw new Error("createSymmetricCrypto: unsupported algorithm '" + alg + "' (only AES implemented)");
    }
    if (mode !== "CBC" && mode !== "ECB") {
      throw new Error("createSymmetricCrypto: unsupported mode '" + mode + "'");
    }
    if (padding !== "PKCS5PADDING" && padding !== "PKCS7PADDING" && padding !== "NOPADDING") {
      throw new Error("createSymmetricCrypto: unsupported padding '" + padding + "'");
    }
    var keyBytes = (typeof key === "string") ? utf8Encode(key) : (Array.isArray(key) ? key : null);
    if (!keyBytes || (keyBytes.length !== 16 && keyBytes.length !== 24 && keyBytes.length !== 32)) {
      throw new Error("createSymmetricCrypto: AES key must be 16/24/32 bytes, got " + (keyBytes ? keyBytes.length : "null"));
    }
    var ivBytes = null;
    if (iv !== null && iv !== undefined && iv !== "") {
      ivBytes = (typeof iv === "string") ? utf8Encode(iv) : (Array.isArray(iv) ? iv : null);
      if (mode === "CBC" && ivBytes && ivBytes.length !== 16) {
        throw new Error("createSymmetricCrypto: CBC iv must be 16 bytes, got " + ivBytes.length);
      }
    }
    if (mode === "CBC" && !ivBytes) {
      throw new Error("createSymmetricCrypto: CBC requires iv");
    }
    var obj = {
      encryptBase64: function (data) { return b64Encode(aesProcess(String(data), keyBytes, ivBytes, mode, padding, true)); },
      encryptHex: function (data) { return hexEncode(aesProcess(String(data), keyBytes, ivBytes, mode, padding, true)); },
      encrypt: function (data) { return aesProcess(String(data), keyBytes, ivBytes, mode, padding, true); },
      decrypt: function (data) {
        var s = String(data);
        var bytes = isHexString(s) ? hexDecode(s) : b64Decode(s);
        return aesProcessBytes(bytes, keyBytes, ivBytes, mode, padding, false);
      },
      decryptStr: function (data) {
        return utf8Decode(obj.decrypt(data));
      }
    };
    return obj;
  }
  java.createSymmetricCrypto = createSymmetricCrypto;

  // Android URLEncoder.encode(str, "UTF-8")：字母数字与 .-*_ 保留，空格→+，其余 %XX
  if (typeof java.encodeURI === "undefined") {
    java.encodeURI = function (str) {
      return encodeURIComponent(String(str)).replace(/%20/g, "+")
        .replace(/[!~*'()]/g, function (c) {
          return "%" + c.charCodeAt(0).toString(16).toUpperCase();
        });
    };
  }

  // Android JsExtensions.base64Decode(str)：Base64 解码为 UTF-8 String
  if (typeof java.base64Decode === "undefined") {
    java.base64Decode = function (str) {
      return utf8Decode(b64Decode(String(str)));
    };
  }
})();`;
