import { BookSource } from '../../model/BookSource';

export const DISABLE_COOKIE_HEADER = 'X-Legado-Disable-Cookie';
export const REQUEST_GROUP_HEADER = 'X-Legado-Request-Group';

interface RateRecord {
  time: number;
  frequency: number;
  accessLimit: number;
  interval: number;
}

/** 把 Android Legado 的书源网络配置落实到每次实际请求。 */
export class SourceNetworkPolicy {
  private static records_: Map<string, RateRecord> = new Map();

  static timeout(_source: BookSource, fallback: number = 60000): number {
    // respondTime 与 Android 一致，是上次校验测得的响应耗时，不是请求超时配置。
    // 把它用于下一次请求会形成反馈循环：一次 700ms 的成功会让后续请求在 700ms 被误杀。
    return Math.max(1000, fallback);
  }

  static headers(source: BookSource, headers: Record<string, string>): Record<string, string> {
    const result: Record<string, string> = { ...headers };
    if (!source.enabledCookieJar) result[DISABLE_COOKIE_HEADER] = '1';
    if (source.checkRequestGroup) result[REQUEST_GROUP_HEADER] = source.checkRequestGroup;
    return result;
  }

  static async wait(source: BookSource): Promise<void> {
    const parsed = this.parseRate_(source.concurrentRate || '');
    if (!parsed) return;
    const key = source.sourceUrl || source.sourceName;
    if (!key) return;
    while (true) {
      const now = Date.now();
      let record = this.records_.get(key);
      if (!record || record.accessLimit !== parsed.accessLimit || record.interval !== parsed.interval ||
        now >= record.time + record.interval) {
        record = {
          time: now, frequency: 1,
          accessLimit: parsed.accessLimit, interval: parsed.interval
        };
        this.records_.set(key, record);
        return;
      }
      if (record.frequency < record.accessLimit) {
        record.frequency++;
        return;
      }
      const waitMs = Math.max(1, record.time + record.interval - now);
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, waitMs));
    }
  }

  private static parseRate_(value: string): RateRecord | null {
    const text = value.trim();
    if (!text || text === '0') return null;
    const separator = text.indexOf('/');
    const accessLimit = separator > 0 ? Number(text.substring(0, separator)) : 1;
    const interval = Number(separator > 0 ? text.substring(separator + 1) : text);
    if (!Number.isInteger(accessLimit) || !Number.isInteger(interval) ||
      accessLimit <= 0 || interval <= 0) return null;
    return { time: 0, frequency: 0, accessLimit: accessLimit, interval: interval };
  }
}
