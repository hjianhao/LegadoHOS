/**
 * QuickJS NAPI Bridge for HarmonyOS Legado
 *
 * 提供 ArkTS 调用 QuickJS JavaScript 引擎的能力，
 * 包含书源脚本执行所需的全部 API polyfill。
 *
 * 编译: 见 BUILD.gn
 * 依赖: QuickJS (quickjs.c/quickjs-libc.c), HarmonyOS NAPI
 */

#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <cstring>
#include <cstdlib>
#include <thread>
#include <chrono>

#include "quickjs.h"
#include "quickjs-libc.h"
#include "napi/native_api.h"
#include "node_api.h"
#include "uv.h"

// ============================================================
// 全局状态管理
// ============================================================

struct ScriptEngineContext {
  JSRuntime *rt;
  JSContext *ctx;
  std::mutex mutex;
  napi_env env = nullptr;             // 创建该引擎的线程的 napi_env
  napi_ref http_callback = nullptr;   // 该引擎的 HTTP 回调
  napi_ref cookie_callback = nullptr; // 该引擎的 Cookie 操作回调
};

static std::unordered_map<int64_t, ScriptEngineContext*> g_engines;
static int64_t g_next_engine_id = 1;
static std::mutex g_global_mutex;

// ============================================================
// JS Http Module — 通过 ArkTS 回调实现网络请求
// ============================================================

// 存储待处理的 HTTP 请求
struct HttpRequest {
  int64_t requestId;
  std::string url;
  std::string method;    // "GET" / "POST"
  std::string body;
  std::string headers;   // JSON string
  std::string result;
  std::string respHeaders; // 响应头 JSON string（含 set-cookie）
  int statusCode = 0;
  bool completed;
  bool error;
  std::string errorMsg;
};

static std::unordered_map<int64_t, HttpRequest*> g_pending_requests;
static int64_t g_next_request_id = 1;
static std::mutex g_request_mutex;

// ============================================================
// Cookie 操作桥（JS __cookieOp → ArkTS CookieStore）
// ============================================================

struct CookieOpRequest {
  int64_t requestId;
  std::string result;
  bool completed;
};

static std::unordered_map<int64_t, CookieOpRequest*> g_pending_cookie_ops;
static int64_t g_next_cookie_op_id = 1;
static std::mutex g_cookie_op_mutex;

/**
 * JS 全局函数: __cookieOp(op, url, value) → string
 * op: "get" / "set" / "remove"
 * 同步阻塞等待 ArkTS 侧处理（与 http.get/post 同一模式）
 */
static JSValue js_cookie_op(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
  if (argc < 2) return JS_NewString(ctx, "");

  const char *op = JS_ToCString(ctx, argv[0]);
  const char *url = JS_ToCString(ctx, argv[1]);
  const char *value = nullptr;
  if (argc >= 3 && JS_IsString(argv[2])) {
    value = JS_ToCString(ctx, argv[2]);
  }

  auto req = new CookieOpRequest();
  {
    std::lock_guard<std::mutex> lock(g_cookie_op_mutex);
    req->requestId = g_next_cookie_op_id++;
    req->completed = false;
    g_pending_cookie_ops[req->requestId] = req;
  }
  int64_t req_id = req->requestId;

  ScriptEngineContext* engine = (ScriptEngineContext*)JS_GetContextOpaque(ctx);
  bool dispatched = false;
  if (engine && engine->cookie_callback && engine->env) {
    napi_env env = engine->env;
    napi_value cb;
    napi_get_reference_value(env, engine->cookie_callback, &cb);

    napi_value args[4];
    napi_create_int64(env, req_id, &args[0]);
    napi_create_string_utf8(env, op ? op : "", NAPI_AUTO_LENGTH, &args[1]);
    napi_create_string_utf8(env, url ? url : "", NAPI_AUTO_LENGTH, &args[2]);
    napi_create_string_utf8(env, value ? value : "", NAPI_AUTO_LENGTH, &args[3]);

    napi_value global;
    napi_get_global(env, &global);
    napi_value result;
    napi_call_function(env, global, cb, 4, args, &result);
    dispatched = true;
  }

  // ArkTS 侧是同步处理（读内存缓存），正常会在进入循环前完成
  int waited = 0;
  while (dispatched && !req->completed && waited < 5000) {
    uv_loop_t *loop = nullptr;
    if (engine && engine->env && napi_get_uv_event_loop(engine->env, &loop) == napi_ok && loop) {
      uv_run(loop, UV_RUN_NOWAIT);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    waited += 1;
  }

  JSValue out = JS_NewString(ctx, req->result.c_str());
  {
    std::lock_guard<std::mutex> lock(g_cookie_op_mutex);
    g_pending_cookie_ops.erase(req_id);
  }
  delete req;
  if (op) JS_FreeCString(ctx, op);
  if (url) JS_FreeCString(ctx, url);
  if (value) JS_FreeCString(ctx, value);
  return out;
}

// ArkTS 侧注册的回调函数（已移至 per-engine，见 ScriptEngineContext）

// 从响应头 JSON 构建 JS headers 对象（含 set-cookie，供 java.post/connect 读取）
static JSValue build_headers_js(JSContext *ctx, const std::string& headers_json) {
  if (!headers_json.empty()) {
    JSValue parsed = JS_ParseJSON(ctx, headers_json.c_str(), headers_json.size(), "<resp-headers>");
    if (!JS_IsException(parsed) && JS_IsObject(parsed)) {
      return parsed;
    }
    if (JS_IsException(parsed)) {
      JS_FreeValue(ctx, JS_GetException(ctx));
    }
    JS_FreeValue(ctx, parsed);
  }
  return JS_NewObject(ctx);
}

/**
 * JS 函数: http.get(url, options)
 * 在 JS 中: let resp = http.get("https://...", {headers: {...}})
 * 返回: {statusCode: 200, body: {json: () => ..., text: () => ...}}
 */
static JSValue js_http_get(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv) {
  if (argc < 1) return JS_ThrowTypeError(ctx, "http.get: url required");

  const char *url = JS_ToCString(ctx, argv[0]);
  if (!url) return JS_ThrowTypeError(ctx, "http.get: invalid url");

  // 解析 options
  const char *headers_json = "{}";
  int64_t timeout_ms = 30000;

  if (argc >= 2 && JS_IsObject(argv[1])) {
    JSValue headers_val = JS_GetPropertyStr(ctx, argv[1], "headers");
    if (!JS_IsUndefined(headers_val)) {
      JSValue json_str = JS_JSONStringify(ctx, headers_val, JS_UNDEFINED, JS_UNDEFINED);
      if (!JS_IsException(json_str)) {
        headers_json = JS_ToCString(ctx, json_str);
        JS_FreeValue(ctx, json_str);
      }
    }
    JS_FreeValue(ctx, headers_val);

    JSValue timeout_val = JS_GetPropertyStr(ctx, argv[1], "timeout");
    if (!JS_IsUndefined(timeout_val)) {
      int32_t t;
      JS_ToInt32(ctx, &t, timeout_val);
      if (t > 0) timeout_ms = t;
    }
    JS_FreeValue(ctx, timeout_val);
  }

  // 创建 HTTP 请求
  auto req = new HttpRequest();
  {
    std::lock_guard<std::mutex> lock(g_request_mutex);
    req->requestId = g_next_request_id++;
    req->url = url;
    req->method = "GET";
    req->headers = headers_json;
    req->completed = false;
    req->error = false;
    g_pending_requests[req->requestId] = req;
  }

  int64_t req_id = req->requestId;

  // 调用 ArkTS 回调发起真正的 HTTP 请求（使用当前引擎的 env）
  ScriptEngineContext* engine = (ScriptEngineContext*)JS_GetContextOpaque(ctx);
  if (engine && engine->http_callback && engine->env) {
    napi_env env = engine->env;
    napi_value cb;
    napi_get_reference_value(env, engine->http_callback, &cb);

    napi_value args[4];
    napi_create_int64(env, req_id, &args[0]);
    napi_create_string_utf8(env, url, NAPI_AUTO_LENGTH, &args[1]);
    napi_create_string_utf8(env, "GET", NAPI_AUTO_LENGTH, &args[2]);
    napi_create_string_utf8(env, headers_json, NAPI_AUTO_LENGTH, &args[3]);

    napi_value global;
    napi_get_global(env, &global);
    napi_value result;
    napi_call_function(env, global, cb, 4, args, &result);
  }

  JS_FreeCString(ctx, url);

  // 等待请求完成（同步阻塞，JS 引擎单线程）
  // 使用当前引擎的事件循环泵，避免死锁
  int waited = 0;
  while (!req->completed && waited < timeout_ms) {
    uv_loop_t *loop = nullptr;
    if (engine && engine->env && napi_get_uv_event_loop(engine->env, &loop) == napi_ok && loop) {
      uv_run(loop, UV_RUN_NOWAIT);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    waited += 2;
  }

  JSValue resp_obj = JS_NewObject(ctx);

  if (req->error) {
    JS_SetPropertyStr(ctx, resp_obj, "statusCode",
                      JS_NewInt32(ctx, 0));
    JS_SetPropertyStr(ctx, resp_obj, "errorMsg",
                      JS_NewString(ctx, req->errorMsg.c_str()));
  } else {
    int sc = req->statusCode > 0 ? req->statusCode : 200;
    JS_SetPropertyStr(ctx, resp_obj, "statusCode",
                      JS_NewInt32(ctx, sc));

    // body.text() 方法
    JSValue body_obj = JS_NewObject(ctx);
    std::string body_text = req->result;

    JSValue text_func = JS_NewCFunction(ctx, [](JSContext *ctx2, JSValueConst this_val,
                                                 int, JSValueConst *) -> JSValue {
      // 从 _text 属性读取实际响应体（闭包无法捕获 std::string by value）
      JSValue text_val = JS_GetPropertyStr(ctx2, this_val, "_text");
      if (JS_IsString(text_val)) {
        return JS_DupValue(ctx2, text_val);  // 返回 _text 的副本
      }
      JS_FreeValue(ctx2, text_val);
      return JS_NewString(ctx2, "");
    }, "text", 0);
    JS_SetPropertyStr(ctx, body_obj, "text", text_func);

    // body.json() 方法 - 解析 JSON
    JSValue json_func = JS_NewCFunction(ctx, [](JSContext *ctx2, JSValueConst this_val,
                                                 int, JSValueConst *) -> JSValue {
      const char *text = "";
      JSValue text_val = JS_GetPropertyStr(ctx2, this_val, "_text");
      if (!JS_IsUndefined(text_val)) {
        text = JS_ToCString(ctx2, text_val);
      }
      JSValue json_val = JS_ParseJSON(ctx2, text, strlen(text), "<response>");
      JS_FreeCString(ctx2, text);
      JS_FreeValue(ctx2, text_val);
      return json_val;
    }, "json", 0);
    JS_SetPropertyStr(ctx, body_obj, "json", json_func);

    // 存储 body 文本供 json() 方法使用
    JS_SetPropertyStr(ctx, body_obj, "_text",
                      JS_NewStringLen(ctx, body_text.c_str(), body_text.length()));

    JS_SetPropertyStr(ctx, resp_obj, "body", body_obj);

    // baseUrl
    JS_SetPropertyStr(ctx, resp_obj, "baseUrl",
                      JS_NewString(ctx, req->url.c_str()));

    // headers 对象（真实响应头；无数据时退化为空对象）
    JSValue headers_obj = build_headers_js(ctx, req->respHeaders);
    JS_SetPropertyStr(ctx, resp_obj, "headers", headers_obj);
  }

  // 清理
  {
    std::lock_guard<std::mutex> lock(g_request_mutex);
    g_pending_requests.erase(req_id);
  }
  delete req;

  return resp_obj;
}

/**
 * JS 函数: http.post(url, body, options)
 */
static JSValue js_http_post(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
  if (argc < 1) return JS_ThrowTypeError(ctx, "http.post: url required");

  const char *url = JS_ToCString(ctx, argv[0]);
  if (!url) return JS_ThrowTypeError(ctx, "http.post: invalid url");

  const char *body = "";
  const char *headers_json = "{}";
  int64_t timeout_ms = 30000;

  if (argc >= 2 && JS_IsString(argv[1])) {
    body = JS_ToCString(ctx, argv[1]);
  }

  if (argc >= 3 && JS_IsObject(argv[2])) {
    JSValue h = JS_GetPropertyStr(ctx, argv[2], "headers");
    if (!JS_IsUndefined(h)) {
      JSValue json_str = JS_JSONStringify(ctx, h, JS_UNDEFINED, JS_UNDEFINED);
      if (!JS_IsException(json_str)) {
        headers_json = JS_ToCString(ctx, json_str);
        JS_FreeValue(ctx, json_str);
      }
    }
    JS_FreeValue(ctx, h);
  }

  // 和 GET 类似的请求处理...
  auto req = new HttpRequest();
  {
    std::lock_guard<std::mutex> lock(g_request_mutex);
    req->requestId = g_next_request_id++;
    req->url = url;
    req->method = "POST";
    req->body = body;
    req->headers = headers_json;
    req->completed = false;
    g_pending_requests[req->requestId] = req;
  }

  int64_t req_id = req->requestId;

  ScriptEngineContext* engine = (ScriptEngineContext*)JS_GetContextOpaque(ctx);

  if (engine && engine->http_callback && engine->env) {
    napi_env env = engine->env;
    napi_value cb;
    napi_get_reference_value(env, engine->http_callback, &cb);

    napi_value args[5];
    napi_create_int64(env, req_id, &args[0]);
    napi_create_string_utf8(env, url, NAPI_AUTO_LENGTH, &args[1]);
    napi_create_string_utf8(env, "POST", NAPI_AUTO_LENGTH, &args[2]);
    napi_create_string_utf8(env, headers_json, NAPI_AUTO_LENGTH, &args[3]);
    napi_create_string_utf8(env, body, NAPI_AUTO_LENGTH, &args[4]);

    napi_value global;
    napi_get_global(env, &global);
    napi_value result;
    napi_call_function(env, global, cb, 5, args, &result);
  }

  // 等待完成...（同步阻塞，处理事件循环避免死锁）
  int waited = 0;
  while (!req->completed && waited < timeout_ms) {
    uv_loop_t *loop = nullptr;
    if (engine && engine->env && napi_get_uv_event_loop(engine->env, &loop) == napi_ok && loop) {
      uv_run(loop, UV_RUN_NOWAIT);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    waited += 2;
  }

  JSValue resp_obj = JS_NewObject(ctx);
  int post_sc = req->statusCode > 0 ? req->statusCode : (req->error ? 0 : 200);
  JS_SetPropertyStr(ctx, resp_obj, "statusCode", JS_NewInt32(ctx, post_sc));

  JSValue body_obj = JS_NewObject(ctx);
  std::string body_text = req->result;
  JS_SetPropertyStr(ctx, body_obj, "_text",
                    JS_NewStringLen(ctx, body_text.c_str(), body_text.length()));
  JS_SetPropertyStr(ctx, resp_obj, "body", body_obj);
  JS_SetPropertyStr(ctx, resp_obj, "baseUrl", JS_NewString(ctx, url));
  JS_SetPropertyStr(ctx, resp_obj, "headers", build_headers_js(ctx, req->respHeaders));

  {
    std::lock_guard<std::mutex> lock(g_request_mutex);
    g_pending_requests.erase(req_id);
  }
  delete req;

  JS_FreeCString(ctx, url);

  return resp_obj;
}

// ============================================================
// JS Base64 Module
// ============================================================

static JSValue js_base64_encode(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
  if (argc < 1) return JS_NewString(ctx, "");
  const char *str = JS_ToCString(ctx, argv[0]);
  if (!str) return JS_NewString(ctx, "");

  // 简化的 Base64 编码（生产环境用 OpenSSL 或鸿蒙 crypto API）
  static const char b64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t len = strlen(str);
  std::string result;
  result.reserve((len + 2) / 3 * 4);

  for (size_t i = 0; i < len; i += 3) {
    unsigned char b0 = str[i];
    unsigned char b1 = i + 1 < len ? str[i + 1] : 0;
    unsigned char b2 = i + 2 < len ? str[i + 2] : 0;
    result += b64[b0 >> 2];
    result += b64[((b0 & 0x03) << 4) | (b1 >> 4)];
    result += (i + 1 < len) ? b64[((b1 & 0x0F) << 2) | (b2 >> 6)] : '=';
    result += (i + 2 < len) ? b64[b2 & 0x3F] : '=';
  }

  JS_FreeCString(ctx, str);
  return JS_NewString(ctx, result.c_str());
}

static JSValue js_base64_decode(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
  if (argc < 1) return JS_NewString(ctx, "");
  const char *str = JS_ToCString(ctx, argv[0]);
  if (!str) return JS_NewString(ctx, "");

  size_t len = strlen(str);
  std::string result;

  auto b64_idx = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };

  for (size_t i = 0; i < len && str[i] != '='; i += 4) {
    int b0 = b64_idx(str[i]);
    int b1 = b64_idx(str[i + 1]);
    int b2 = b64_idx(str[i + 2]);
    int b3 = b64_idx(str[i + 3]);
    if (b0 < 0 || b1 < 0) break;
    result += (char)((b0 << 2) | (b1 >> 4));
    if (b2 >= 0) result += (char)(((b1 & 0x0F) << 4) | (b2 >> 2));
    if (b3 >= 0) result += (char)(((b2 & 0x03) << 6) | b3);
  }

  JS_FreeCString(ctx, str);
  return JS_NewString(ctx, result.c_str());
}

// ============================================================
// JS 引擎创建 / 销毁 (NAPI 导出)
// ============================================================

static napi_value CreateEngine(napi_env env, napi_callback_info info) {
  auto *ctx = new ScriptEngineContext();
  ctx->env = env;  // 保存当前线程的 napi_env
  ctx->rt = JS_NewRuntime();
  ctx->ctx = JS_NewContext(ctx->rt);
  JS_SetContextOpaque(ctx->ctx, ctx);  // 绑定引擎指针到上下文，供 http.get/post 查找

  // ---- 注入标准 ES 库 ----

	// ---- 注入标准 ES 库 ----
	  js_init_module_std(ctx->ctx, "std");

  // ---- 注入 http 模块 ----
  JSValue http_obj = JS_NewObject(ctx->ctx);
  JS_SetPropertyStr(ctx->ctx, http_obj, "get",
                    JS_NewCFunction(ctx->ctx, js_http_get, "get", 2));
  JS_SetPropertyStr(ctx->ctx, http_obj, "post",
                    JS_NewCFunction(ctx->ctx, js_http_post, "post", 3));
  JS_SetPropertyStr(ctx->ctx, http_obj, "timeout", JS_NewInt32(ctx->ctx, 30000));

  // 注册到全局: globalThis.http = {get, post, ...}
  JSValue global = JS_GetGlobalObject(ctx->ctx);
  JS_SetPropertyStr(ctx->ctx, global, "http", http_obj);

  // ---- 注入 Cookie 操作桥 ----
  JS_SetPropertyStr(ctx->ctx, global, "__cookieOp",
                    JS_NewCFunction(ctx->ctx, js_cookie_op, "__cookieOp", 3));

  // ---- 注入 Base64 ----
  JSValue base64_obj = JS_NewObject(ctx->ctx);
  JS_SetPropertyStr(ctx->ctx, base64_obj, "encode",
                    JS_NewCFunction(ctx->ctx, js_base64_encode, "encode", 1));
  JS_SetPropertyStr(ctx->ctx, base64_obj, "decode",
                    JS_NewCFunction(ctx->ctx, js_base64_decode, "decode", 1));
  JS_SetPropertyStr(ctx->ctx, global, "Base64", base64_obj);

  // ---- JS Polyfills (java compat) ----
  // javaString(s) → String(s)
  const char *polyfill =
    "if (typeof javaString === 'undefined') {"
    "  globalThis.javaString = function(s) { return String(s); };"
    "}"
    "if (typeof javaArrayList === 'undefined') {"
    "  globalThis.javaArrayList = function(arr) { return Array.isArray(arr) ? arr : [arr]; };"
    "}"
    "if (typeof java === 'undefined') {"
    "  globalThis.java = { net: { URL: globalThis.URL } };"
    "}"
    "if (typeof TextDecoder === 'undefined') {"
    "  globalThis.TextDecoder = class {"
    "    constructor() {}"
    "    decode(buf) { return String.fromCharCode.apply(null, new Uint8Array(buf)); }"
    "  };"
    "}"
    "// 保留字兼容: result 对象自动注入 baseUrl"
    "globalThis._resultPolyfill = function(obj, baseUrl) {"
    "  if (obj && typeof obj === 'object' && !obj.baseUrl) {"
    "    Object.defineProperty(obj, 'baseUrl', { value: baseUrl, writable: true });"
    "  }"
    "  return obj;"
    "};";

  JS_Eval(ctx->ctx, polyfill, strlen(polyfill), "<polyfill>", JS_EVAL_TYPE_GLOBAL);

  JS_FreeValue(ctx->ctx, global);

  int64_t engine_id;
  {
    std::lock_guard<std::mutex> lock(g_global_mutex);
    engine_id = g_next_engine_id++;
    g_engines[engine_id] = ctx;
  }

  // 无需保存全局 env — 每个引擎有自己的 env
  //（RegisterHttpHandler 会将回调关联到具体引擎）

  napi_value result;
  napi_create_int64(env, engine_id, &result);
  return result;
}

static napi_value DestroyEngine(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int64_t engine_id;
  napi_get_value_int64(env, argv[0], &engine_id);

  std::lock_guard<std::mutex> lock(g_global_mutex);
  auto it = g_engines.find(engine_id);
  if (it != g_engines.end()) {
    JS_FreeContext(it->second->ctx);
    JS_FreeRuntime(it->second->rt);
    delete it->second;
    g_engines.erase(it);
  }

  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

/**
 * 执行 JavaScript 代码并返回结果
 * 参数: engineId, script(string)
 * 返回: JSON string 或 error string
 */
static napi_value ExecuteScript(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int64_t engine_id;
  napi_get_value_int64(env, argv[0], &engine_id);

  // 先获取脚本长度，再动态分配缓冲区（避免 64KB 固定缓冲区截断长脚本）
  size_t script_len;
  napi_get_value_string_utf8(env, argv[1], nullptr, 0, &script_len);
  std::vector<char> script_buf(script_len + 1);
  napi_get_value_string_utf8(env, argv[1], script_buf.data(), script_buf.size(), &script_len);

  ScriptEngineContext *ctx = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_global_mutex);
    auto it = g_engines.find(engine_id);
    if (it != g_engines.end()) ctx = it->second;
  }

  if (!ctx) {
    napi_throw_error(env, "ENGINE_NOT_FOUND", "QuickJS engine not found");
    return nullptr;
  }

  std::lock_guard<std::mutex> lock(ctx->mutex);

  JSValue result = JS_Eval(ctx->ctx, script_buf.data(), script_len,
                           "<source>", JS_EVAL_TYPE_GLOBAL);

  napi_value napi_result;
  if (JS_IsException(result)) {
    JSValue exc = JS_GetException(ctx->ctx);
    const char *exc_str = JS_ToCString(ctx->ctx, exc);
    napi_create_string_utf8(env, exc_str ? exc_str : "Unknown error",
                            NAPI_AUTO_LENGTH, &napi_result);
    JS_FreeCString(ctx->ctx, exc_str);
    JS_FreeValue(ctx->ctx, exc);
  } else {
    // 将 JS 结果转为 JSON string
    JSValue json_val = JS_JSONStringify(ctx->ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    if (!JS_IsException(json_val)) {
      const char *json_str = JS_ToCString(ctx->ctx, json_val);
      napi_create_string_utf8(env, json_str ? json_str : "null",
                              NAPI_AUTO_LENGTH, &napi_result);
      JS_FreeCString(ctx->ctx, json_str);
    } else {
      napi_create_string_utf8(env, "null", NAPI_AUTO_LENGTH, &napi_result);
    }
    JS_FreeValue(ctx->ctx, json_val);
  }
  JS_FreeValue(ctx->ctx, result);

  return napi_result;
}

/**
 * 执行函数调用
 * 参数: engineId, functionName(string), argsJson(string)
 * 返回: JSON string
 */
static napi_value CallFunction(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int64_t engine_id;
  napi_get_value_int64(env, argv[0], &engine_id);

  char func_name[256];
  size_t func_len;
  napi_get_value_string_utf8(env, argv[1], func_name, sizeof(func_name), &func_len);

  char args_json[65536];
  size_t args_len;
  napi_get_value_string_utf8(env, argv[2], args_json, sizeof(args_json), &args_len);

  ScriptEngineContext *ctx = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_global_mutex);
    auto it = g_engines.find(engine_id);
    if (it != g_engines.end()) ctx = it->second;
  }

  if (!ctx) {
    napi_throw_error(env, "ENGINE_NOT_FOUND", "QuickJS engine not found");
    return nullptr;
  }

  std::lock_guard<std::mutex> lock(ctx->mutex);

  // 解析 args JSON → JS 数组
  JSValue args_val = JS_ParseJSON(ctx->ctx, args_json, args_len, "<args>");
  if (JS_IsException(args_val)) {
    napi_throw_error(env, "INVALID_ARGS", "Cannot parse arguments JSON");
    return nullptr;
  }

  // 获取全局函数
  JSValue global = JS_GetGlobalObject(ctx->ctx);
  JSValue func = JS_GetPropertyStr(ctx->ctx, global, func_name);
  JS_FreeValue(ctx->ctx, global);

  if (!JS_IsFunction(ctx->ctx, func)) {
    JS_FreeValue(ctx->ctx, func);
    JS_FreeValue(ctx->ctx, args_val);
    napi_throw_error(env, "FUNC_NOT_FOUND", "Function not found");
    return nullptr;
  }

  // 构建参数数组
  uint32_t arr_len;
  JS_ToUint32(ctx->ctx, &arr_len, JS_GetPropertyStr(ctx->ctx, args_val, "length"));

  std::vector<JSValue> js_args;
  for (uint32_t i = 0; i < arr_len; i++) {
    JSValue arg = JS_GetPropertyUint32(ctx->ctx, args_val, i);
    js_args.push_back(arg);
  }

  JSValue result = JS_Call(ctx->ctx, func, JS_UNDEFINED,
                           js_args.size(), js_args.data());

  // 清理 args
  for (auto &a : js_args) JS_FreeValue(ctx->ctx, a);
  JS_FreeValue(ctx->ctx, args_val);
  JS_FreeValue(ctx->ctx, func);

  napi_value napi_result;
  if (JS_IsException(result)) {
    JSValue exc = JS_GetException(ctx->ctx);
    const char *exc_str = JS_ToCString(ctx->ctx, exc);
    napi_create_string_utf8(env, exc_str ? exc_str : "Unknown error",
                            NAPI_AUTO_LENGTH, &napi_result);
    JS_FreeCString(ctx->ctx, exc_str);
    JS_FreeValue(ctx->ctx, exc);
  } else {
    JSValue json_val = JS_JSONStringify(ctx->ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    if (!JS_IsException(json_val)) {
      const char *json_str = JS_ToCString(ctx->ctx, json_val);
      napi_create_string_utf8(env, json_str ? json_str : "null",
                              NAPI_AUTO_LENGTH, &napi_result);
      JS_FreeCString(ctx->ctx, json_str);
    } else {
      napi_create_string_utf8(env, "null", NAPI_AUTO_LENGTH, &napi_result);
    }
    JS_FreeValue(ctx->ctx, json_val);
  }
  JS_FreeValue(ctx->ctx, result);

  return napi_result;
}

/**
 * HTTP 请求完成回调（由 ArkTS 侧调用）
 * 参数: requestId, body, isError[, headersJson, statusCode]
 */
static napi_value OnHttpResponse(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value argv[5];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int64_t request_id;
  napi_get_value_int64(env, argv[0], &request_id);

  char response_body[65536];
  size_t body_len;
  napi_get_value_string_utf8(env, argv[1], response_body, sizeof(response_body), &body_len);

  bool is_error;
  napi_get_value_bool(env, argv[2], &is_error);

  char headers_json[16384];
  size_t headers_len = 0;
  headers_json[0] = '\0';
  if (argc >= 4) {
    napi_get_value_string_utf8(env, argv[3], headers_json, sizeof(headers_json), &headers_len);
  }

  int32_t status_code = 0;
  if (argc >= 5) {
    napi_get_value_int32(env, argv[4], &status_code);
  }

  std::lock_guard<std::mutex> lock(g_request_mutex);
  auto it = g_pending_requests.find(request_id);
  if (it != g_pending_requests.end()) {
    if (is_error) {
      it->second->error = true;
      it->second->errorMsg = response_body;
    } else {
      it->second->result = response_body;
    }
    if (headers_len > 0) {
      it->second->respHeaders.assign(headers_json, headers_len);
    }
    it->second->statusCode = status_code;
    it->second->completed = true;
  }

  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

/**
 * Cookie 操作完成回调（由 ArkTS 侧调用）
 * 参数: requestId, result(string)
 */
static napi_value OnCookieResponse(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int64_t request_id;
  napi_get_value_int64(env, argv[0], &request_id);

  char result_buf[16384];
  size_t result_len;
  napi_get_value_string_utf8(env, argv[1], result_buf, sizeof(result_buf), &result_len);

  std::lock_guard<std::mutex> lock(g_cookie_op_mutex);
  auto it = g_pending_cookie_ops.find(request_id);
  if (it != g_pending_cookie_ops.end()) {
    it->second->result.assign(result_buf, result_len);
    it->second->completed = true;
  }

  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

/**
 * 注册 ArkTS 侧的 Cookie 操作回调
 * 参数: engineId, callback(requestId, op, url, value)
 */
static napi_value RegisterCookieHandler(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int64_t engine_id;
  napi_get_value_int64(env, argv[0], &engine_id);

  ScriptEngineContext *engine = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_global_mutex);
    auto it = g_engines.find(engine_id);
    if (it != g_engines.end()) engine = it->second;
  }

  if (engine) {
    if (engine->cookie_callback) {
      napi_delete_reference(engine->env, engine->cookie_callback);
    }
    napi_create_reference(env, argv[1], 1, &engine->cookie_callback);
    engine->env = env;
  }

  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

/**
 * 注册 ArkTS 侧的 HTTP 请求回调
 * 参数: engineId, callback
 */
static napi_value RegisterHttpHandler(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  int64_t engine_id;
  napi_get_value_int64(env, argv[0], &engine_id);

  ScriptEngineContext *engine = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_global_mutex);
    auto it = g_engines.find(engine_id);
    if (it != g_engines.end()) engine = it->second;
  }

  if (engine) {
    // 释放旧引用
    if (engine->http_callback) {
      napi_delete_reference(engine->env, engine->http_callback);
    }
    napi_create_reference(env, argv[1], 1, &engine->http_callback);
    engine->env = env;
  }

  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

// ============================================================
// NAPI 模块注册
// ============================================================

extern "C" {
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    { "createEngine", nullptr, CreateEngine, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "destroyEngine", nullptr, DestroyEngine, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "executeScript", nullptr, ExecuteScript, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "callFunction", nullptr, CallFunction, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "onHttpResponse", nullptr, OnHttpResponse, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "registerHttpHandler", nullptr, RegisterHttpHandler, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "onCookieResponse", nullptr, OnCookieResponse, nullptr, nullptr, nullptr, napi_default, nullptr },
    { "registerCookieHandler", nullptr, RegisterCookieHandler, nullptr, nullptr, nullptr, napi_default, nullptr },
  };

  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
}

static napi_module quickjsModule = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = nullptr,
  .nm_register_func = Init,
  .nm_modname = "quickjs_bridge",
  .nm_priv = nullptr,
  .reserved = { 0 },
};
extern "C" __attribute__((constructor)) void RegisterQuickJSModule(void) {
  napi_module_register(&quickjsModule);
}
