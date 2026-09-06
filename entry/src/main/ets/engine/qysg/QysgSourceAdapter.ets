import {
  BookSource,
  BookSourceBookInfo,
  BookSourceChapter,
  BookSourceFormat,
} from '../../model/BookSource';
import { SearchResult } from '../../model/SearchResult';
import { SourceAdapter, SourceContentResult, SourceExploreItem } from '../source/SourceAdapter';
import { decodeQysgArray, normalizeQysgTomatoTocUrl } from './QysgSourceCodec';
import { mapQysgBooks, mapQysgChapters, mapQysgContent, mapQysgInfo } from './QysgResultMapper';
import { QysgRuntimeManager } from './QysgRuntimeManager';

function mapExploreItem(raw: Object, index: number): SourceExploreItem {
  const value = (raw && typeof raw === 'object' ? raw : {}) as Record<string, Object>;
  const title = String(value['title'] || value['name'] || ('分类' + (index + 1)));
  const url = String(value['url'] || '');
  const js = String(value['js'] || '');
  const type = Number(value['type'] || 0);
  const width = Number(value['width'] || 0);
  let flexBasisPercent = 1 / 3;
  if (width === 1) flexBasisPercent = 1 / 2;
  else if (width === 3) flexBasisPercent = 1;
  return {
    id: 'qysg-' + index + '-' + title,
    title: title,
    target: url,
    actionJs: js || undefined,
    kind: !url && !js ? 'heading' : (type === 1 ? 'webview' : 'books'),
    flexBasisPercent: flexBasisPercent,
    adapterPayload: JSON.stringify(value),
  };
}

export class QysgSourceAdapter implements SourceAdapter {
  canSearch(source: BookSource): boolean {
    return source.sourceFormat === BookSourceFormat.QYSG && source.enabled;
  }

  canExplore(source: BookSource): boolean {
    return this.canSearch(source) && source.enabledExplore;
  }

  async search(source: BookSource, keyword: string, page: number,
    isAborted?: () => boolean): Promise<SearchResult[]> {
    console.info('[QysgAdapter] search source=' + source.sourceName + ' keyword=' + keyword + ' page=' + page);
    const raw = await QysgRuntimeManager.invoke(source, 'search', [keyword, page, 'searchone'], isAborted);
    const results = mapQysgBooks(raw, source);
    console.info('[QysgAdapter] search mapped=' + results.length + ' rawBytes=' + raw.length);
    return results;
  }

  async getExploreItems(source: BookSource): Promise<SourceExploreItem[]> {
    const raw = await QysgRuntimeManager.invoke(source, 'getfinds', []);
    return decodeQysgArray(raw).map((item: Object, index: number): SourceExploreItem => mapExploreItem(item, index));
  }

  async explore(source: BookSource, item: SourceExploreItem, page: number): Promise<SearchResult[]> {
    if (item.kind === 'heading') return [];
    if (item.kind === 'webview') throw new Error('该发现项需要前台 WebView');
    const raw = await QysgRuntimeManager.invoke(source, 'find', [item.target, page]);
    return mapQysgBooks(raw, source);
  }

  async getBookInfo(source: BookSource, noteUrl: string): Promise<BookSourceBookInfo> {
    const raw = await QysgRuntimeManager.invoke(source, 'info', [noteUrl]);
    return mapQysgInfo(raw, source, noteUrl);
  }

  async getToc(source: BookSource, tocUrl: string, bookUrl: string = ''): Promise<BookSourceChapter[]> {
    const normalizedTocUrl = normalizeQysgTomatoTocUrl(tocUrl);
    if (normalizedTocUrl !== tocUrl) {
      console.warn('[QysgAdapter] normalized Tomato multi-detail URL to official directory:',
        normalizedTocUrl);
    }
    const raw = await QysgRuntimeManager.invoke(source, 'chapter', [normalizedTocUrl, bookUrl]);
    return mapQysgChapters(raw, source);
  }

  async getContent(source: BookSource, contentUrl: string, bookUrl: string = ''): Promise<SourceContentResult> {
    const raw = await QysgRuntimeManager.invoke(source, 'content', [contentUrl, bookUrl]);
    return mapQysgContent(raw, source, contentUrl);
  }
}

export const globalQysgSourceAdapter = new QysgSourceAdapter();
