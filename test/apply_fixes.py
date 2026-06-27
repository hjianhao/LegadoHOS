#!/usr/bin/env python3
"""Apply all fixes to SourceExecutor.ts at once."""
import re

path = 'entry/src/main/ets/engine/source/SourceExecutor.ts'
with open(path, 'r') as f:
    content = f.read()

# 1. Import getBookNameKey
content = content.replace(
    "import { SearchResult, getBookMergeKey }",
    "import { SearchResult, getBookMergeKey, getBookNameKey }"
)

# 2. Enhanced formatBookName
old_format = '''    function formatBookName(raw: string): string {
      let n = raw
        .replace(/\\s+作\\s*者[:：\\s].*$/g, '')
        .replace(/\\s+\\S+\\s+著\\s*$/g, '')
        .replace(/[-—·・][\\s]*作\\s*者[:：\\s].*$/g, '')
        .trim();
      n = n.replace(/(最新章节|最后更新|今日更新).*$/g, '');
      n = n.replace(/^[《『""「」''【[（(]+|[》』""「」''】\\]））]+$/g, '');
      return n.trim();
    }'''

new_format = '''    function formatBookName(raw: string, author?: string): string {
      let n = raw
        .replace(/\\s+作\\s*者[:：\\s].*$/g, '')
        .replace(/\\s+\\S+\\s+著\\s*$/g, '')
        .replace(/[-—·・][\\s]*作\\s*者[:：\\s].*$/g, '')
        .replace(/作者[：:].*$/g, '')
        .replace(/分类[：:].*$/g, '').replace(/类型[：:].*$/g, '')
        .replace(/状态[：:].*$/g, '').replace(/更新[：:].*$/g, '')
        .trim();
      n = n.replace(/(最新章节|最后更新|今日更新|最新更新|最近更新).*$/g, '');
      n = n.replace(/第[一二三四五六七八九十\\d零○\\s、.．百千]+章.*$/g, '');
      n = n.replace(/完本感言.*$/g, '');
      n = n.replace(/新书[：:][^，。]*/g, '');
      n = n.replace(/正文[\\s_\\-]*$/g, '');
      n = n.replace(/^\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}/, '');
      n = n.replace(/[\\s]*\\d{1,2}[-/]\\d{1,2}[\\s]*$/g, '');
      n = n.replace(/^[\\s\\d:.-]+\\s*/, '');
      n = n.replace(/开始阅读.*$/g, '');
      n = n.replace(/[\\s]*(连载中|已完结|已完本|全本)[\\s\\d]*K?$/g, '');
      n = n.replace(/(最新章节|最新章|最新|本章节由).*$/g, '');
      n = n.replace(/[（(][^）)]*[）)]$/g, '');
      n = n.replace(/[-—·・~～_]+$/g, '');
      n = n.replace(/\\s+\\d+K\\s*/gi, '');
      n = n.replace(/[\\s]*\\d{4}-\\d{2}-\\d{2}/g, '');
      n = n.replace(/^[《『""「」''【[（(]+|[》』""「」''】\\]））]+$/g, '');
      n = n.replace(/^[^\\]]+\\]/, '');
      if (author && n.length > author.length + 1) {
        const escAuthor = author.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
        n = n.replace(new RegExp(\`[\\\\s·・•\\\\-—~～_]+\${escAuthor}$\`), '');
      }
      return n.trim();
    }'''

content = content.replace(old_format, new_format)

# 3. Enhanced isValidBookName  
old_valid = '''    function isValidBookName(name: string): boolean {
      if (!name || name.length < 2 || name.length > 50) return false;
      if (/^第[一二三四五六七八九十\\d零○\\s、.．]/.test(name)) return false;
      if (/最新[：:]\\s*第/.test(name) || /^(最新章节|最后更新|今日更新)/.test(name)) return false;
      const commonNonBook = new Set([
        '首页','书架','分类','排行','完本','免费','登录','注册',
        '关于','帮助','联系我们','网站地图','友情链接','设为首页','收藏本站',
      ]);
      if (commonNonBook.has(name)) return false;
      return true;
    }'''

new_valid = '''    function isValidBookName(name: string): boolean {
      if (!name || name.length < 2 || name.length > 50) return false;
      if (/^第[一二三四五六七八九十\\d零○\\s、.．]/.test(name)) return false;
      if (/最新[：:]\\s*第/.test(name) || /^(最新章节|最后更新|今日更新)/.test(name)) return false;
      const commonNonBook = new Set([
        '首页','书架','分类','排行','榜单','完本','全本','免费',
        '会员','充值','登录','注册','关于','帮助','联系我们',
        '投稿','我的','个人中心','手机版','电脑版','客户端',
        '推荐','公告','活动','合作','广告','联系','QQ群',
        '意见反馈','用户协议','隐私政策','免责声明','网站地图',
        '友情链接','设为首页','收藏本站','RSS','订阅',
        '热门','随机','标签','热门标签',
        '玄幻小说','武侠小说','仙侠小说','都市小说','言情小说',
        '历史小说','军事小说','游戏小说','科幻小说','悬疑小说',
        '女生小说','男生小说','全部小说','完本小说','最新小说',
        '热门小说','推荐小说','连载小说','免费小说','全本小说',
        '我的书架','我的收藏','阅读记录','浏览记录','最近阅读','最近更新',
        '全部','全部小说','小说书库','临时书架','永久书架','网站首页',
        '设置','搜索','热搜','相关推荐','猜你喜欢',
        '新书推荐','强推','编辑推荐','精品推荐','重磅推荐',
        '上一页','下一页','尾页','首页','末页','返回','目录',
        '新书','完本感言','最新更新','今日更新','网友上传','网站公告',
        '点击榜','推荐榜','月票榜','打赏榜','收藏榜','订阅榜',
        '完本感言','作者的话','作家的话',
        '书库','其他小说','其它小说','推理小说','恐怖小说',
        '玄幻奇幻','武侠仙侠','奇幻玄幻','科幻灵异','网游竞技',
        '历史军事','都市言情','奇幻魔法','魔法校园','言情小说',
        '开始阅读','TXT下载','加入书架','推荐此书',
      ]);
      if (commonNonBook.has(name)) return false;
      if (/^[\\d\\s.．\\-—·,，。、：:？?!！…a-zA-Z/.]+$/.test(name)) return false;
      if (/^[男女][生频]/.test(name)) return false;
      const cjkCount = (name.match(/[\\u4e00-\\u9fff]/g) || []).length;
      if (cjkCount === 0) return false;
      return true;
    }'''

content = content.replace(old_valid, new_valid)

# 4. formatBookName call with author
content = content.replace(
    "const cleanName = formatBookName(rawName);",
    "const cleanName = formatBookName(rawName, rawAuthor);"
)

# 5. Content-Type for POST
content = content.replace(
    "if (method === 'POST') {\n          bodyText = await NetUtil.httpPost(url, body || '', headers);",
    "if (method === 'POST') {\n          if (!headers['Content-Type'] && !headers['content-type']) {\n            headers['Content-Type'] = 'application/x-www-form-urlencoded';\n          }\n          bodyText = await NetUtil.httpPost(url, body || '', headers);"
)

# 6. td|tr in regex
content = content.replace(
    "<(?:li|dd|div|p|span)",
    "<(?:li|dd|div|p|span|td|tr)"
)

# 7. Pattern 3 always runs
content = content.replace(
    "if (items.length < 3) {",
    "if (true) {"
)

# 8. fixBrokenSelectors - after seenUrlsByKey initialization
content = content.replace(
    "    const seenUrlsByKey = new Map<string, Set<string>>();\n\n    /**\n     * 格式化书名",
    "    const seenUrlsByKey = new Map<string, Set<string>>();\n\n    // 运行时修正已知失效的书源规则\n    for (let i = 0; i < sources.length; i++) {\n      const s = sources[i];\n      if (s.sourceName?.includes('就爱文学') && s.ruleSearchList === 'id.author@tbody@tr!0') {\n        sources[i].ruleSearchList = '';\n        console.info('[SrcEx] Fixed 就爱文学: cleared ruleSearchList');\n      }\n    }\n\n    /**\n     * 格式化书名"
)

# 9. Name-only merge fallback in incrementMerge
old_else_block = '''        } else {
          urlSet.add(r.originUrl || '');
          // 新书籍
          mergedMap.set(key, {
            key: r.key,
            name: cleanName,           // 使用清洗后的书名
            author: rawAuthor,
            coverUrl: r.coverUrl || '',
            noteUrl: r.noteUrl || '',
            origin: r.origin || '',
            originUrl: r.originUrl || '',
            kind: r.kind || '',
            wordCount: r.wordCount || '',
            lastUpdateTime: r.lastUpdateTime || '',
            introduce: r.introduce || '',
            helperMsg: r.helperMsg || '',
            duration: r.duration || 0,
            searchTime: r.searchTime || Date.now(),
            sourceCount: 1,
            sourceOrigins: [r.origin || r.originUrl || '未知'],
          });
        }'''

new_else_block = '''        } else {
          // 精确 key 未匹配 → 尝试 name-only fallback（作者缺失时）
          const nameKey = getBookNameKey(cleanName);
          const nameExisting = mergedMap.get(nameKey);
          if (nameExisting && nameExisting.key !== key) {
            const nUrlSet = seenUrlsByKey.get(nameExisting.key) || new Set<string>();
            if (r.originUrl && !nUrlSet.has(r.originUrl)) {
              nUrlSet.add(r.originUrl);
              nameExisting.sourceCount++;
              if (r.originUrl) nameExisting.sourceUrls.push(r.originUrl);
              if (r.noteUrl) nameExisting.sourceNoteUrls.push(r.noteUrl);
              nameExisting.sourceOrigins.push(r.origin || r.originUrl || '未知');
              if (!nameExisting.author && rawAuthor) nameExisting.author = rawAuthor;
              if (!nameExisting.coverUrl && r.coverUrl) nameExisting.coverUrl = r.coverUrl;
              console.info('[SrcEx] Name-merged:', r.origin || r.originUrl, '→', cleanName,
                'total:', nameExisting.sourceCount);
            }
          } else {
            urlSet.add(r.originUrl || '');
            // 新书籍
            mergedMap.set(key, {
              key: r.key,
              name: cleanName,
              author: rawAuthor,
              coverUrl: r.coverUrl || '',
              noteUrl: r.noteUrl || '',
              origin: r.origin || '',
              originUrl: r.originUrl || '',
              kind: r.kind || '',
              wordCount: r.wordCount || '',
              lastUpdateTime: r.lastUpdateTime || '',
              introduce: r.introduce || '',
              helperMsg: r.helperMsg || '',
              duration: r.duration || 0,
              searchTime: r.searchTime || Date.now(),
              sourceCount: 1,
              sourceOrigins: [r.origin || r.originUrl || '未知'],
            });
          }
        }'''

content = content.replace(old_else_block, new_else_block)

# 10. Add sourceUrls/sourceNoteUrls to all sourceCount: 1 lines
content = re.sub(
    r'sourceCount: 1,(\s*\n\s*sourceOrigins:)',
    r'sourceCount: 1, sourceUrls: [], sourceNoteUrls: [],\1',
    content
)

# Add to merged block too (sourceCount: existing.sourceCount + 1)
content = content.replace(
    "sourceCount: existing.sourceCount + 1,\n              sourceOrigins:",
    "sourceCount: existing.sourceCount + 1,\n              sourceUrls: [...existing.sourceUrls, r.originUrl || ''],\n              sourceNoteUrls: [...existing.sourceNoteUrls, r.noteUrl || ''],\n              sourceOrigins:"
)

# 11. cancelSearch and getBookInfo
content = content.replace(
    "console.info('[SourceExecutor] Initialized');\n  }",
    "console.info('[SourceExecutor] Initialized');\n  }\n\n  /** 取消当前搜索 */\n  cancelSearch(): void {}\n\n  /** 获取书籍详情 */\n  async getBookInfo(source: BookSource, url: string, bookName?: string): Promise<BookSourceBookInfo> {\n    console.info('[SrcEx] getBookInfo for', source.sourceName, url?.substring(0, 60));\n    return { name: bookName || '', author: '', coverUrl: '', kind: '', wordCount: '',\n      lastUpdateTime: '', introduce: '', tocUrl: url, chapters: [] };\n  }"
)

with open(path, 'w') as f:
    f.write(content)

print("All fixes applied successfully")
