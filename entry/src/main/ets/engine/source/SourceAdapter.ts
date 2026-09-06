import { BookSource, BookSourceBookInfo, BookSourceChapter } from '../../model/BookSource';
import { SearchResult } from '../../model/SearchResult';
import { BookType } from '../../model/Book';

export interface SourceExploreItem {
  id: string;
  title: string;
  target: string;
  actionJs?: string;
  kind: 'books' | 'webview' | 'heading';
  flexBasisPercent: number;
  adapterPayload?: string;
}

export interface SourceContentResult {
  type: BookType;
  raw: string;
  baseUrl: string;
}

export interface SourceAdapter {
  canSearch(source: BookSource): boolean;
  canExplore(source: BookSource): boolean;
  search(source: BookSource, keyword: string, page: number, isAborted?: () => boolean): Promise<SearchResult[]>;
  getExploreItems(source: BookSource): Promise<SourceExploreItem[]>;
  explore(source: BookSource, item: SourceExploreItem, page: number): Promise<SearchResult[]>;
  getBookInfo(source: BookSource, noteUrl: string): Promise<BookSourceBookInfo>;
  getToc(source: BookSource, tocUrl: string, bookUrl?: string): Promise<BookSourceChapter[]>;
  getContent(source: BookSource, contentUrl: string, bookUrl?: string): Promise<SourceContentResult>;
}
