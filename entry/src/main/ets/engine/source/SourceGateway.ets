/** 统一书源入口：Legado 规则和 qysg WebView 运行时在这里分派。 */
import { BookType } from '../../model/Book';
import {
  BookSource,
  BookSourceBookInfo,
  BookSourceChapter,
  BookSourceFormat,
} from '../../model/BookSource';
import { SearchResult, mergeSearchResults } from '../../model/SearchResult';
import { globalQysgSourceAdapter } from '../qysg/QysgSourceAdapter';
import { SourceAdapter, SourceContentResult, SourceExploreItem } from './SourceAdapter';
import { globalSourceExecutor } from './SourceExecutor';

function adapterFor(source: BookSource): SourceAdapter | null {
  return source.sourceFormat === BookSourceFormat.QYSG ? globalQysgSourceAdapter : null;
}

export class SourceGateway {
  canSearch(source: BookSource): boolean {
    const adapter = adapterFor(source);
    return adapter ? adapter.canSearch(source) : !!source.enabled && !!source.ruleSearchUrl;
  }

  canExplore(source: BookSource): boolean {
    const adapter = adapterFor(source);
    return adapter ? adapter.canExplore(source) : !!source.enabledExplore &&
      (!!source.exploreUrl || !!source.ruleExplores);
  }

  async search(keyword: string, sources: BookSource[],
    onProgress?: (merged: SearchResult[], processed: number, total: number) => void,
    page: number = 1, isAborted?: () => boolean): Promise<SearchResult[]> {
    const active = sources.filter((source: BookSource): boolean => this.canSearch(source));
    if (active.length === 0) return [];
    const concurrency = Math.max(1, Math.min(AppStorage.get<number>('searchConcurrency') || 16, active.length));
    const collected: SearchResult[] = [];
    let nextIndex = 0;
    let processed = 0;
    const runOne = async (source: BookSource): Promise<void> => {
      let items: SearchResult[] = [];
      try {
        const adapter = adapterFor(source);
        if (adapter) items = await adapter.search(source, keyword, page, isAborted);
        else items = await globalSourceExecutor.search(keyword, [source], undefined, page, isAborted);
        if (!(isAborted && isAborted())) collected.push(...items);
      } catch (error) {
        console.error('[SourceGateway] search failed for ' + source.sourceName + ': ' + String(error));
      } finally {
        processed++;
        if (onProgress && !(isAborted && isAborted())) {
          onProgress(mergeSearchResults(collected), processed, active.length);
        }
      }
    };
    const worker = async (): Promise<void> => {
      while (nextIndex < active.length) {
        if (isAborted && isAborted()) return;
        const index = nextIndex++;
        await runOne(active[index]);
      }
    };
    const workers: Promise<void>[] = [];
    for (let i = 0; i < concurrency; i++) workers.push(worker());
    await Promise.all(workers);
    return mergeSearchResults(collected);
  }

  async getExploreItems(source: BookSource): Promise<SourceExploreItem[]> {
    const adapter = adapterFor(source);
    if (!adapter) return [];
    return await adapter.getExploreItems(source);
  }

  async explore(source: BookSource, item: SourceExploreItem, page: number = 1): Promise<SearchResult[]> {
    const adapter = adapterFor(source);
    if (!adapter) return [];
    return await adapter.explore(source, item, page);
  }

  async getBookInfo(source: BookSource, noteUrl: string): Promise<BookSourceBookInfo> {
    const adapter = adapterFor(source);
    return adapter ? await adapter.getBookInfo(source, noteUrl) :
      await globalSourceExecutor.getBookInfo(source, noteUrl);
  }

  async getToc(source: BookSource, tocUrl: string, bookUrl?: string,
    onProgress?: (loaded: number) => void): Promise<BookSourceChapter[]> {
    const adapter = adapterFor(source);
    return adapter ? await adapter.getToc(source, tocUrl, bookUrl) :
      await globalSourceExecutor.getToc(source, tocUrl, onProgress);
  }

  async getContentResult(source: BookSource, contentUrl: string, bookUrl?: string,
    preserveImages: boolean = false): Promise<SourceContentResult> {
    const adapter = adapterFor(source);
    if (adapter) return await adapter.getContent(source, contentUrl, bookUrl);
    const raw = await globalSourceExecutor.getContent(source, contentUrl, bookUrl, preserveImages);
    return { type: source.sourceType as BookType, raw: raw, baseUrl: contentUrl };
  }

  async getContent(source: BookSource, contentUrl: string, bookUrl?: string,
    preserveImages: boolean = false): Promise<string> {
    const result = await this.getContentResult(source, contentUrl, bookUrl, preserveImages);
    return result.raw;
  }
}

export const globalSourceGateway = new SourceGateway();
