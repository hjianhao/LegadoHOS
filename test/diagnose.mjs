/**
 * 全量诊断：测试每个源的搜索结果提取
 * 对 test/source.json 中每个源搜索"冲出四合院"，
 * 分析 CSS 提取和正则兜底的解析效果
 */

import * as cheerio from 'cheerio';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT_MS = 15000;
const SEARCH_KEYWORD = '冲出四合院';

// ====== 工具函数 ======

function getBaseUrl(rawUrl) {
  if (!rawUrl) return '';
  return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
}

function buildSearchUrl(template, keyword, page, baseUrl) {
  if (!template || template.trimStart().startsWith('@js:')) return null;
  let url = template;
  const encoded = encodeURIComponent(keyword);
  url = url.replace(/\{\{cookie\.[^}]*\}\}/g, '');
  url = url.replace(/\{\{key\}\}/g, encoded).replace(/\{\{keyword\}\}/g, encoded)
    .replace(/\{\{page\}\}/g, String(page)).replace(/\{\{pageNum\}\}/g, String(page + 1));
  url = url.replace(/\{\{[^}]*\}\}/g, '').replace(/<js>[\s\S]*?<\/js>/gi, '');
  // 合并多行
  url = url.replace(/\n\s*\n/g, '\n').replace(/\n\s*/g, '');
  while (url.includes('@js:')) {
    const jsIdx = url.indexOf('@js:');
    const jsonOptStart = url.indexOf(',{', jsIdx);
    url = jsonOptStart > jsIdx ? url.substring(0, jsIdx) + url.substring(jsonOptStart) : url.substring(0, jsIdx);
  }
  const pageGroupMatch = url.match(/<([^<>]+)>/);
  if (pageGroupMatch) {
    const items = pageGroupMatch[1].split(',');
    url = url.replace(pageGroupMatch[0], items[Math.min(page - 1, items.length - 1)].trim());
  }
  let jsonRaw = '';
  const jsonMatch = url.match(/^(.+?),?\s*(\{[\s\S]*\})$/);
  if (jsonMatch) { url = jsonMatch[1].trim(); jsonRaw = jsonMatch[2]; }
  if (!url.startsWith('http') && baseUrl) {
    url = baseUrl.replace(/\/+$/, '') + (url.startsWith('/') ? url : '/' + url);
  }
  let method = 'GET';
  let body = '';
  if (jsonRaw) {
    try {
      const opts = JSON.parse(jsonRaw.replace(/'/g, '"').replace(/([{,]\s*)(\w+)(\s*:)/g, '$1"$2"$3'));
      if (opts.method) method = opts.method.toUpperCase();
      if (opts.body) body = opts.body.replace(/\{\{key\}\}/g, encoded).replace(/\{\{keyword\}\}/g, encoded);
    } catch (_e) {}
  }
  url = url.trim();
  return url ? { url, method, body } : null;
}

async function fetchUrl(url, method = 'GET', body = null) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    const opts = { method, headers, signal: controller.signal };
    if (body && method === 'POST') { headers['Content-Type'] = 'application/x-www-form-urlencoded'; opts.body = body; }
    const resp = await fetch(url, opts);
    return await resp.text();
  } finally { clearTimeout(timeout); }
}

function normalizeCssRule(rule) {
  if (!rule) return rule;
  if (rule.startsWith('@css:')) return rule.slice(5);
  if (rule.includes('||')) return normalizeCssRule(rule.split('||')[0]);
  rule = rule.replace(/@text\b/g, '').replace(/@href\b/g, '').replace(/@src\b/g, '');
  rule = rule.replace(/@@/g, '.').replace(/id\./g, '#');
  rule = rule.replace(/([a-zA-Z0-9_*-])\s*@\s*(?=[a-zA-Z#.])/g, '$1 ');
  // 处理位置索引：保留 a.N 格式，但不影响 CSS
  return rule;
}

function extractAttr($el, rule) {
  let attrSuffix = 'text';
  let cssSel = rule;
  const m = rule.match(/^(.*?)@(text|href|src|html|ownText)$/i);
  if (m) { cssSel = m[1].trim(); attrSuffix = m[2].toLowerCase(); }
  cssSel = normalizeCssRule(cssSel);
  try {
    const $found = cssSel ? $el.find(cssSel) : $el;
    if ($found.length === 0) return '';
    const first = $found.first();
    switch (attrSuffix) {
      case 'text': return first.text().trim();
      case 'href': return first.attr('href') || '';
      case 'src': return first.attr('src') || '';
      case 'html': return first.html() || '';
      default: return first.text().trim();
    }
  } catch (_e) { return ''; }
}

function extractWithCSS($, source, baseUrl) {
  const rs = source.ruleSearch || {};
  const ruleList = rs.bookList || rs.list || '';
  const ruleName = rs.name || '';
  const ruleAuthor = rs.author || '';
  const ruleCover = rs.coverUrl || rs.cover || '';
  const ruleNoteUrl = rs.bookUrl || rs.noteUrl || '';
  if (!ruleList) return [];
  const cssSel = normalizeCssRule(ruleList);
  const items = [];
  try {
    const $items = $(cssSel);
    if ($items.length === 0) return [];
    $items.each((idx, el) => {
      const $el = $(el);
      let name = '';
      if (ruleName) name = extractAttr($el, ruleName);
      if (!name) { const $a = $el.find('a').first(); name = $a.text().trim(); }
      if (!name) name = $el.text().trim();
      if (!name || name.length < 1) return;
      if (name.length < 2 || name.length > 40) return;
      const cleaned = name.replace(/\s+作\s*者[:：\s].*$/g, '').replace(/\s+\S+\s+著\s*$/g, '').trim();
      if (!cleaned) return;
      // 过滤非书籍
      if (/^第[一二三四五六七八九十\d零○\s、.．]/.test(cleaned)) return;
      if (/最新[：:]\s*第/.test(cleaned) || /^(最新章节|最后更新|今日更新)/.test(cleaned)) return;
      const navWords = ['首页','书架','分类','排行','榜单','完本','全本','免费','会员','充值','登录','注册','关于','帮助','联系我们','投稿','我的','个人中心','手机版','电脑版','客户端','推荐','公告','活动','合作','广告','联系','QQ群','意见反馈','用户协议','隐私政策','免责声明','网站地图','友情链接','设为首页','收藏本站','RSS','订阅','热门','随机','标签','热门标签','全部小说','全部','设置','搜索','热搜','猜你喜欢','上一页','下一页','尾页','首页','末页','返回','目录','点击榜','推荐榜','月票榜','打赏榜','收藏榜','订阅榜','玄幻小说','武侠小说','仙侠小说','都市小说','言情小说','历史小说','军事小说','游戏小说','科幻小说','悬疑小说','女生小说','男生小说','完本小说','最新小说','热门小说','推荐小说','连载小说','免费小说','全本小说','书名','作者','分类','状态','字数','更新','更新时间','最后更新','最新章节','章节','简介','操作','查看','点击'];
      if (navWords.includes(cleaned)) return;
      let author = ruleAuthor ? extractAttr($el, ruleAuthor) : '';
      let coverUrl = '';
      if (ruleCover) coverUrl = extractAttr($el, ruleCover);
      if (!coverUrl) { const $img = $el.find('img').first(); coverUrl = $img.attr('src') || $img.attr('data-src') || ''; }
      let noteUrl = '';
      if (ruleNoteUrl) noteUrl = extractAttr($el, ruleNoteUrl);
      if (!noteUrl) { const $a = $el.find('a').first(); noteUrl = $a.attr('href') || ''; }
      if (!noteUrl) return;
      if (noteUrl && !noteUrl.startsWith('http')) noteUrl = baseUrl + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
      if (coverUrl && !coverUrl.startsWith('http') && !coverUrl.startsWith('data:')) coverUrl = baseUrl + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
      items.push({ name, author, coverUrl, noteUrl });
    });
  } catch (e) { /* ignore */ }
  return items;
}

function getJsonPath(obj, path) {
  if (!path || !obj) return undefined;
  if (path.includes('||')) { for (const alt of path.split(/\|\|/)) { const v = getJsonPath(obj, alt.trim()); if (v !== undefined && v !== null && v !== '') return v; } return undefined; }
  const parts = path.replace(/^\$\.?/, '').split('.');
  let current = obj;
  for (const part of parts) {
    if (current == null) return undefined;
    const am = part.match(/^(\w+)(?:\[(\d+|\*)])?$/);
    if (am) { const [_, key, index] = am; current = Array.isArray(current) ? (index === '*' || !index ? current[0]?.[key] : current[parseInt(index)]?.[key]) : current[key]; }
    else { current = current[part]; }
  }
  return current;
}

function extractJsonResults(json, source, baseUrl) {
  const rs = source.ruleSearch || {};
  const ruleList = rs.bookList || rs.list || '';
  const ruleName = rs.name || '';
  const ruleAuthor = rs.author || '';
  const ruleCover = rs.coverUrl || rs.cover || '';
  const ruleNoteUrl = rs.bookUrl || rs.noteUrl || '';
  let list = null;
  if (ruleList) { const raw = getJsonPath(json, ruleList); if (Array.isArray(raw)) list = raw; }
  if (!list) { if (Array.isArray(json)) list = json; else for (const p of ['data', 'list', 'items', 'results', 'books']) { const raw = json[p]; if (Array.isArray(raw)) { list = raw; break; } } }
  if (!list) return [];
  return list.map(item => ({
    name: String(getJsonPath(item, ruleName) || item.novelName || item.name || item.title || ''),
    author: String(getJsonPath(item, ruleAuthor) || item.authorName || item.author || ''),
    coverUrl: String(getJsonPath(item, ruleCover) || ''),
    noteUrl: String(getJsonPath(item, ruleNoteUrl) || item.noteUrl || item.bookUrl || item.id || ''),
  })).filter(i => i.name);
}

/** 正则兜底：从 HTML 中提取书名候选 */
function extractBookNamesFromHtml(html, baseUrl) {
  const items = [];
  const seen = new Set();

  function isBookPath(url) { return /(?:\/book\/|\/novel\/|\/read\/|\/txt\/|\/info\/|\/chapter\/|\d{5,})/i.test(url); }
  function isBookTitle(text) {
    if (!text || text.length < 2 || text.length > 40) return false;
    const cleaned = text.replace(/\s+作\s*者[:：\s].*$/g, '').replace(/\s+\S+\s+著\s*$/g, '').trim();
    if (!cleaned) return false;
    if (/^第[一二三四五六七八九十\d零○\s、.．]/.test(cleaned)) return false;
    if (/最新[：:]\s*第/.test(cleaned) || /^(最新章节|最后更新|今日更新)/.test(cleaned)) return false;
    const commonNonBook = ['首页','书架','分类','排行','榜单','完本','全本','免费','会员','充值','登录','注册','关于','帮助','联系我们','投稿','我的','个人中心','手机版','电脑版','客户端','推荐','公告','活动','合作','广告','联系','QQ群','意见反馈','用户协议','隐私政策','免责声明','网站地图','友情链接','设为首页','收藏本站','RSS','订阅','热门','随机','标签','热门标签','玄幻小说','武侠小说','仙侠小说','都市小说','言情小说','历史小说','军事小说','游戏小说','科幻小说','悬疑小说','女生小说','男生小说','全部小说','完本小说','最新小说','热门小说','推荐小说','连载小说','免费小说','全本小说','我的书架','我的收藏','阅读记录','浏览记录','最近阅读','最近更新','全部','全部小说','小说书库','临时书架','永久书架','网站首页','设置','搜索','热搜','相关推荐','猜你喜欢','新书推荐','强推','编辑推荐','精品推荐','重磅推荐','上一页','下一页','尾页','首页','末页','返回','目录','新书','完本感言','最新更新','今日更新','网友上传','网站公告','点击榜','推荐榜','月票榜','打赏榜','收藏榜','订阅榜','书库','其他小说','其它小说','推理小说','恐怖小说','玄幻奇幻','武侠仙侠','奇幻玄幻','科幻灵异','网游竞技','历史军事','都市言情','奇幻魔法','魔法校园','言情小说','网游小说','穿越小说','修真小说','玄幻魔法','武侠修真','恐怖灵异','侦探推理','东方传奇','王朝争霸','江湖武侠','未来幻想','灵异鬼怪','探险揭秘','历史传记','特种军旅','竞技','魔幻女强','都市婚姻','百合之恋','同人美文','穿越架空','王室贵族','乡土布衣','官职商战','间谍暗战','唯美言情','诗歌文集','奇幻修真','异术超能','饿狼小说','文桑小说','文桑视界','就爱看文学网','就爱文学网','就爱文学','蚂蚁文学','零零小说','独步小说网','必去小说网','关于七猫','七猫招聘','七猫小说','七猫免费小说','联系我们','关于我们','点此举报','网站公告','书名','作者','分类','状态','字数','更新','更新时间','最后更新','最新章节','章节','简介','操作','查看','点击','推荐'];
    if (commonNonBook.some(w => cleaned === w)) return false;
    const cjkCount = (cleaned.match(/[\u4e00-\u9fff]/g) || []).length;
    if (cjkCount === 0) return false;
    if (/^[\d\s.．\-—·,，。、：:？?!！…]+$/.test(cleaned)) return false;
    return true;
  }

  // 1. h2/h3/h4 中的 <a>
  const hR = /<h([2-4])[^>]*>[\s]*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,50})<\/a>[\s]*<\/h\1>/gi;
  let m;
  while ((m = hR.exec(html)) !== null) {
    const text = m[3].trim(); let url = m[2].trim();
    if (isBookTitle(text) && !seen.has(text)) { if (url.startsWith('#') || url.startsWith('javascript:')) continue; seen.add(text); if (url && !url.startsWith('http')) url = (baseUrl||'') + (url.startsWith('/')?url:'/'+url); items.push({name:text,url}); }
  }
  // 2. li/dd/div/p/span 内的 <a>
  const lR = /<(?:li|dd|div|p|span)[^>]*>[\s]*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,40})<\/a>/gi;
  while ((m = lR.exec(html)) !== null) {
    const text = m[2].trim(); let url = m[1].trim();
    if (url.startsWith('#') || url.startsWith('javascript:')) continue;
    if (isBookTitle(text) && (isBookPath(url) || !seen.has(text))) { if (!seen.has(text)) { seen.add(text); if (url && !url.startsWith('http')) url = (baseUrl||'') + (url.startsWith('/')?url:'/'+url); items.push({name:text,url}); } }
  }
  // 3. 普通 <a> 标签（不足 3 个时补充）
  if (items.length < 3) {
    const pR = /<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,30})<\/a>/gi;
    while ((m = pR.exec(html)) !== null) {
      const text = m[2].trim(); let url = m[1].trim();
      if (url.startsWith('#') || url.startsWith('javascript:')) continue;
      if (isBookTitle(text) && isBookPath(url) && !seen.has(text)) { seen.add(text); if (url && !url.startsWith('http')) url = (baseUrl||'') + (url.startsWith('/')?url:'/'+url); items.push({name:text,url}); }
    }
  }
  return items.slice(0, 30);
}

/** 清理书名：移除最新章节信息、作者信息等噪声 */
function cleanBookName(name, author) {
  let n = name;
  // 移除常见后缀
  n = n.replace(/\s+作\s*者[:：\s].*$/g, '');
  n = n.replace(/\s+\S+\s+著\s*$/g, '');
  n = n.replace(/[-—·・][\s]*作\s*者[:：\s].*$/g, '');
  n = n.replace(/作者[：:].*$/g, '');
  n = n.replace(/分类[：:].*$/g, '');
  n = n.replace(/类型[：:].*$/g, '');
  n = n.replace(/状态[：:].*$/g, '');
  n = n.replace(/更新[：:].*$/g, '');
  // 章节相关
  n = n.replace(/(最新章节|最后更新|今日更新|最新更新|最近更新).*$/g, '');
  n = n.replace(/第[一二三四五六七八九十\d零○\s、.．百千]+章.*$/g, '');
  n = n.replace(/^[《『""「」''【[（(]+|[》』""「」''】\])）]+$/g, '');
  n = n.replace(/^[^\]]+\]/, '');
  n = n.replace(/完本感言.*$/g, '');
  n = n.replace(/新书[：:][^，。]*/g, '');
  n = n.replace(/^\d{4}[-/]\d{1,2}[-/]\d{1,2}/, '');
  n = n.replace(/[\s]*\d{1,2}[-/]\d{1,2}[\s]*$/g, '');
  n = n.replace(/开始阅读.*$/g, '');
  n = n.replace(/[\s]*(连载中|已完结|已完本|全本)[\s\d]*K?$/g, '');
  n = n.replace(/[\s]*连载[中完闭]?[\s\d]*K?$/g, '');
  n = n.replace(/(最新章节|最新章|最新|本章节由).*$/g, '');
  if (author && n.length > author.length + 1) {
    const esc = author.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    n = n.replace(new RegExp(`[\\s·・•\\-—~～_]+${esc}$`), '');
  }
  return n.trim();
}

// ====== 主诊断函数 ======

async function diagnoseSource(source, index, total) {
  const name = source.bookSourceName || '?';
  const rs = source.ruleSearch || {};
  const rb = source.ruleBookInfo || {};
  const searchUrl = source.searchUrl || '';
  const baseUrl = getBaseUrl(source.bookSourceUrl || '');
  const isJsonApi = (rb.author || '').startsWith('$.') || (rb.author || '').startsWith('@json:');

  process.stdout.write(`[${index}/${total}] ${name}... `);

  if (!searchUrl) { console.log('⏭️ 无 searchUrl'); return null; }

  const built = buildSearchUrl(searchUrl, SEARCH_KEYWORD, 1, baseUrl);
  if (!built) { console.log('⏭️ URL构建失败'); return null; }

  let body;
  try {
    body = await fetchUrl(built.url, built.method, built.body);
    if (!body || body.length < 50) { console.log(`❌ 响应太短 ${body?.length||0} bytes`); return null; }
  } catch (e) { console.log(`❌ ${e.message?.substring(0,60)}`); return null; }

  const sourceInfo = {
    name, searchUrl, baseUrl, bodyLength: body.length,
    ruleSearchList: rs.bookList || rs.list || '',
    ruleSearchName: rs.name || '',
    ruleSearchAuthor: rs.author || '',
    ruleSearchCover: rs.coverUrl || rs.cover || '',
    ruleSearchNoteUrl: rs.bookUrl || rs.noteUrl || '',
    ruleBookInfoAuthor: rb.author || '',
    isJsonApi,
    cssResults: [], jsonResults: [], regexResults: [], issues: [],
  };

  // JSON 提取
  let isJson = false;
  if (body.trimStart().startsWith('{') || body.trimStart().startsWith('[')) {
    try {
      const json = JSON.parse(body);
      isJson = true;
      sourceInfo.jsonResults = extractJsonResults(json, source, baseUrl);
    } catch (_e) {}
  }

  // CSS 提取
  if (!isJson && sourceInfo.ruleSearchList) {
    try {
      const $ = cheerio.load(body);
      sourceInfo.cssResults = extractWithCSS($, source, baseUrl);
    } catch (_e) { sourceInfo.issues.push(`CSS解析错误: ${_e.message}`); }
  }

  // 如果 CSS 结果 < 5，也跑正则兜底
  if (sourceInfo.cssResults.length < 5) {
    const raw = extractBookNamesFromHtml(body, baseUrl);
    sourceInfo.regexResults = raw.map((item, idx) => {
      let fbName = item.name;
      let fbAuthor = '';
      const am = fbName.match(/^(.+?)[\s]*[-—·・][\s]*作\s*者[:：\s](.+)$/);
      if (am) { fbName = am[1].trim(); fbAuthor = am[2].trim(); }
      const cleaned = cleanBookName(fbName, fbAuthor);
      return { name: cleaned, author: fbAuthor, url: item.url, rawName: item.name };
    }).filter(r => r.name && r.name.length >= 2);
  }

  // 分析问题
  const primaryResults = sourceInfo.jsonResults.length > 0 ? sourceInfo.jsonResults : sourceInfo.cssResults;
  const hasTarget = primaryResults.some(r => r.name.includes('冲出四合院') || r.name.includes('四合院'));

  // 检查书名中是否仍含章节信息
  for (const r of primaryResults.slice(0, 5)) {
    const cleaned = cleanBookName(r.name);
    if (cleaned !== r.name) sourceInfo.issues.push(`书名需清洗: "${r.name}" → "${cleaned}"`);
    if (/最新章节|最新更新|第.+章/.test(r.name)) {
      sourceInfo.issues.push(`书名含章节信息: "${r.name}"`);
    }
  }

  // 检查作者
  const hasAuthor = primaryResults.some(r => r.author);
  if (primaryResults.length > 0 && !hasAuthor) {
    // 检查正则兜底有没有作者
    const regexHasAuthor = sourceInfo.regexResults.some(r => r.author);
    if (!regexHasAuthor) {
      sourceInfo.issues.push('所有源结果均无作者');
    }
  }

  // 检查封面
  const hasCover = primaryResults.some(r => r.coverUrl);
  if (primaryResults.length > 0 && !hasCover) {
    sourceInfo.issues.push('所有结果均无封面');
  }

  // 摘要
  const extra = sourceInfo.regexResults.length > 0 ? ` +regex=${sourceInfo.regexResults.length}` : '';
  const tag = sourceInfo.jsonResults.length > 0 ? 'JSON' : (sourceInfo.cssResults.length > 0 ? 'CSS' : 'regex');
  const authorTag = hasAuthor ? '' : ' ❌无作者';
  console.log(`${tag}=${primaryResults.length}${extra}${authorTag}${hasTarget?' ✓含目标':''}`);

  return sourceInfo;
}

// ====== 运行 ======

async function main() {
  const raw = fs.readFileSync(path.resolve(__dirname, 'source.json'), 'utf-8');
  const allSources = JSON.parse(raw);
  console.log(`共 ${allSources.length} 个书源\n`);

  // 分类统计
  let jsonOk = 0, jsonWithAuthor = 0;
  let cssOk = 0, cssWithAuthor = 0;
  let regexOk = 0;
  let failed = 0;
  let noAuthorReport = []; // 无作者的源

  const results = [];
  const concurrency = 5;
  let idx = 0;

  async function worker() {
    while (idx < allSources.length) {
      const i = idx++;
      const info = await diagnoseSource(allSources[i], i + 1, allSources.length);
      if (info) {
        results.push(info);
        if (info.jsonResults.length > 0) {
          jsonOk++;
          if (info.jsonResults.some(r => r.author)) jsonWithAuthor++;
        }
        if (info.cssResults.length > 0) {
          cssOk++;
          if (info.cssResults.some(r => r.author)) cssWithAuthor++;
        }
        if (info.regexResults.length > 0) regexOk++;
        if (info.issues.some(i => i.includes('无作者'))) noAuthorReport.push(info.name);
      } else {
        failed++;
      }
    }
  }

  const workers = Array(concurrency).fill().map(() => worker());
  await Promise.all(workers);

  // ====== 总报告 ======

  console.log('\n========== 诊断报告 ==========\n');
  console.log(`成功获取响应: ${results.length}/${allSources.length}`);
  console.log(`JSON 提取成功: ${jsonOk}（含作者: ${jsonWithAuthor}）`);
  console.log(`CSS 提取成功: ${cssOk}（含作者: ${cssWithAuthor}）`);
  console.log(`正则补充结果: ${regexOk}`);
  console.log(`请求失败: ${failed}\n`);

  // 无作者的源
  if (noAuthorReport.length > 0) {
    console.log(`=== 无作者的源 (${noAuthorReport.length}) ===`);
    for (const src of noAuthorReport) {
      const info = results.find(r => r.name === src);
      if (!info) continue;
      const r = info;
      console.log(`\n【${r.name}】`);
      console.log(`  搜索URL: ${r.searchUrl.substring(0, 60)}`);
      console.log(`  类型: ${r.isJsonApi ? 'JSON API' : 'HTML'}`);
      console.log(`  ruleSearchAuthor: ${r.ruleSearchAuthor || '(空)'}`);
      console.log(`  响应: ${r.bodyLength} bytes`);
      if (r.jsonResults.length > 0) {
        console.log(`  JSON结果(${r.jsonResults.length}):`);
        r.jsonResults.slice(0, 5).forEach((item, i) => {
          console.log(`    ${i+1}. "${item.name}" 作者="${item.author}" 封面=${item.coverUrl.substring(0,40)}`);
        });
      } else if (r.cssResults.length > 0) {
        console.log(`  CSS结果(${r.cssResults.length}):`);
        r.cssResults.slice(0, 5).forEach((item, i) => {
          console.log(`    ${i+1}. "${item.name}" 作者="${item.author}" 封面=${item.coverUrl.substring(0,40)}`);
        });
      }
      if (r.regexResults.length > 0) {
        console.log(`  正则结果(${r.regexResults.length}):`);
        r.regexResults.slice(0, 5).forEach((item, i) => {
          console.log(`    ${i+1}. "${item.name}" 作者="${item.author}" (原始="${item.rawName}")`);
        });
      }
      r.issues.forEach(issue => console.log(`  ⚠️  ${issue}`));
    }
  }

  // 书名含章节信息的源
  console.log(`\n=== 书名含章节信息的源 ===`);
  for (const r of results) {
    const chapterIssues = r.issues.filter(i => i.includes('章节'));
    if (chapterIssues.length > 0) {
      console.log(`【${r.name}】`);
      chapterIssues.forEach(i => console.log(`  ⚠️  ${i}`));
    }
  }

  // 修复建议
  console.log(`\n=== 修复建议 ===`);
  if (noAuthorReport.length > 0) {
    console.log(`\n📌 作者提取失败 (${noAuthorReport.length}个源):`);
    console.log(`  - 这些源的 ruleSearchAuthor CSS 选择器不匹配页面结构`);
    console.log(`  建议: 修正源配置中的 ruleSearch.author 选择器，或验证正则兜底的作者提取`);
  }
}

main().catch(console.error);
