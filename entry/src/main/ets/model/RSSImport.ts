/**
 * RSS 导入相关类型
 */
import { RSSSource } from './RSSSource';

export interface RSSImportPreview {
  source: RSSSource;
  status: string;
  checked: boolean;
}
