/** qysg 返回对象到现有领域模型的映射。 */
import { BookType } from '../../model/Book';
import {
  BookSource,
  BookSourceBookInfo,
  BookSourceChapter,
  BookSourceType,
} from '../../model/BookSource';
import { SearchResult } from '../../model/SearchResult';
import { qysgAbsoluteUrl, qysgContentType, decodeQysgArray, decodeQysgObject } from './QysgSourceCodec';

function value(object: Record<string, Object>, ...keys: string[]): string {
  for (const key of keys) {
    const item = object[key];
    if (item !== undefined && item !== null && String(item).trim()) return String(item);
  }
  return '';
}

function boolValue(object: Record<string, Object>, ...keys: string[]): boolean {
  for (const key of keys) {
    const item = object[key];
    if (item === true || item === 'true' || item === 1 || item === '1') return true;
  }
  return false;
}

export function mapQysgBook(raw: Object, source: BookSource): SearchResult {
  const item = (raw && typeof raw === 'object' ? raw : {}) as Record<string, Object>;
  const bookUrl = qysgAbsoluteUrl(source.sourceUrl, value(item, 'bookUrl', 'url', 'bookurl'));
  const contentType = qysgContentType(item['type'], source.sourceType);
  return {
    key: source.sourceUrl + '\n' + bookUrl,
    name: value(item, 'name', 'bookName', 'title'),
    author: value(item, 'author', 'writer'),
    coverUrl: qysgAbsoluteUrl(source.sourceUrl, value(item, 'coverUrl', 'cover', 'image')),
    noteUrl: bookUrl,
    origin: source.sourceName,
    originUrl: source.sourceUrl,
    kind: value(item, 'kind', 'category', 'typeName'),
    wordCount: value(item, 'wordCount', 'words'),
    lastUpdateTime: value(item, 'lastUpdateTime', 'updateTime', 'lastUpdate'),
    latestChapterTitle: value(item, 'latestChapterTitle', 'latestChapter', 'lastChapter'),
    introduce: value(item, 'intro', 'introduce', 'description'),
    helperMsg: '',
    duration: 0,
    searchTime: Date.now(),
    sourceCount: 1,
    sourceOrigins: [source.sourceName],
    sourceOriginUrls: [source.sourceUrl],
    sourceNoteUrls: [bookUrl],
    contentType: contentType,
  };
}

export function mapQysgBooks(raw: string, source: BookSource): SearchResult[] {
  return decodeQysgArray(raw)
    .map((item: Object): SearchResult => mapQysgBook(item, source))
    .filter((item: SearchResult): boolean => !!item.name && !!item.noteUrl);
}

export function mapQysgInfo(raw: string, source: BookSource, requestedUrl: string): BookSourceBookInfo {
  const item = decodeQysgObject(raw);
  const tocUrl = qysgAbsoluteUrl(source.sourceUrl, value(item, 'tocUrl', 'tocURL', 'chapterUrl')) || requestedUrl;
  const type = qysgContentType(item['type'], source.sourceType);
  const info: BookSourceBookInfo = {
    name: value(item, 'name', 'bookName', 'title'),
    author: value(item, 'author', 'writer'),
    coverUrl: qysgAbsoluteUrl(source.sourceUrl, value(item, 'coverUrl', 'cover', 'image')),
    introduce: value(item, 'intro', 'introduce', 'description'),
    kind: value(item, 'kind', 'category', 'typeName'),
    wordCount: value(item, 'wordCount', 'words'),
    lastUpdateTime: value(item, 'lastUpdateTime', 'updateTime', 'lastUpdate'),
    latestChapterTitle: value(item, 'latestChapterTitle', 'latestChapter', 'lastChapter'),
    tocUrl: tocUrl,
    contentType: type,
    chapters: [],
  };
  return info;
}

export function mapQysgChapters(raw: string, source: BookSource): BookSourceChapter[] {
  return decodeQysgArray(raw).map((value: Object, index: number): BookSourceChapter => {
    const item = (value && typeof value === 'object' ? value : {}) as Record<string, Object>;
    const itemIndex = Number(item['index']);
    return {
      title: valueOfChapter(item, 'name', 'title', 'chapterName') || ('第' + (index + 1) + '章'),
      url: qysgAbsoluteUrl(source.sourceUrl, valueOfChapter(item, 'chapterId', 'url', 'chapterUrl')),
      index: Number.isFinite(itemIndex) ? itemIndex : index,
      isVolume: boolValue(item, 'isVolume', 'volume'),
      isVip: boolValue(item, 'isVip', 'vip'),
      isPay: boolValue(item, 'isPay', 'pay'),
      updateTime: valueOfChapter(item, 'updateTime', 'lastUpdateTime'),
      tag: valueOfChapter(item, 'tag'),
    };
  }).filter((item: BookSourceChapter): boolean => !!item.url || !!item.isVolume);
}

function valueOfChapter(object: Record<string, Object>, ...keys: string[]): string {
  for (const key of keys) {
    if (object[key] !== undefined && object[key] !== null) return String(object[key]);
  }
  return '';
}

export function mapQysgContent(raw: string, source: BookSource, requestedUrl: string): {
  type: BookType;
  raw: string;
  baseUrl: string;
} {
  const value = raw || '';
  const type = value.trim().startsWith('{') ? decodeQysgObject(value)['type'] : undefined;
  const content = value.trim().startsWith('{') ? valueOfChapter(decodeQysgObject(value), 'content', 'data', 'url') : value;
  return {
    type: qysgContentType(type, source.sourceType) as BookType,
    raw: content || value,
    baseUrl: requestedUrl || source.sourceUrl,
  };
}
