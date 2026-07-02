/**
 * 换源管理器
 *
 * 当一本书有多个可用的书源时，对比各源的质量，
 * 支持手动选择最优源或自动切换。
 */
import { BookSource } from '../../model/BookSource';
import { globalSourceExecutor } from './SourceExecutor';
import { BookSourceRepository } from '../../data/repository/BookSourceRepository';
import { HtmlUtil } from '../../util/HtmlUtil';

export interface SourceCompareResult {
  source: BookSource;
  name: string;
  author: string;
  coverUrl: string;
  chapterCount: number;
  lastUpdateTime: string;
  error?: string;
}

export class SourceSwitcher {
  private sourceRepo: BookSourceRepository;

  constructor() {
    this.sourceRepo = new BookSourceRepository();
  }

  /**
   * 查找一本书的所有可用书源
   * @param bookName 书名
   * @param author 作者
   * @returns 可用的书源列表（含元数据对比）
   */
  async findAvailableSources(
    bookName: string,
    author: string,
  ): Promise<SourceCompareResult[]> {
    const sources = await this.sourceRepo.getEnabledSources();
    const results: SourceCompareResult[] = [];

    // 并行检查所有源
    const promises = sources.map(async (source) => {
      try {
        // 用书源搜索这本书
        const searchResults = await globalSourceExecutor.search(
          `${bookName} ${author}`,
          [source]
        );

        // 找到最匹配的结果
        const match = searchResults.find(
          r => r.name.includes(bookName) || bookName.includes(r.name)
        ) || searchResults[0];

        if (!match) {
          results.push({
            source, name: '', author: '', coverUrl: '',
            chapterCount: 0, lastUpdateTime: '',
            error: '未找到匹配',
          });
          return;
        }

        // 获取详细信息和目录
        try {
          const info = await globalSourceExecutor.getBookInfo(source, match.noteUrl);
          const chapters = await globalSourceExecutor.getToc(source, info?.tocUrl || match.noteUrl);

          results.push({
            source,
            name: info?.name || match.name,
            author: info?.author || match.author,
            coverUrl: info?.coverUrl || match.coverUrl,
            chapterCount: chapters.length,
            lastUpdateTime: info?.lastUpdateTime || match.lastUpdateTime,
          });
        } catch {
          results.push({
            source,
            name: match.name, author: match.author,
            coverUrl: match.coverUrl, chapterCount: 0,
            lastUpdateTime: '',
            error: '获取详情失败',
          });
        }
      } catch (err) {
        results.push({
          source, name: '', author: '', coverUrl: '',
          chapterCount: 0, lastUpdateTime: '',
          error: `请求失败: ${err.message}`,
        });
      }
    });

    await Promise.allSettled(promises);

    // 排序：有结果的优先，章节数多的优先
    results.sort((a, b) => {
      const aScore = a.chapterCount - (a.error ? 9999 : 0);
      const bScore = b.chapterCount - (b.error ? 9999 : 0);
      return bScore - aScore;
    });

    return results;
  }

  /**
   * 自动选择最优书源
   * 策略：章节数最多 && 无错误 && 最近更新
   */
  autoSelect(results: SourceCompareResult[]): SourceCompareResult | null {
    const valid = results.filter(r => !r.error && r.chapterCount > 0);
    if (valid.length === 0) return null;

    // 选章节最多的
    valid.sort((a, b) => b.chapterCount - a.chapterCount);
    return valid[0];
  }
}
