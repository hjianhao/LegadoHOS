/**
 * 换源数据传递 — 跨页面传递选中的书源信息
 *
 * ChangeSourcePage 选择源后存入 selectedSource，
 * 调用页（BookInfoPage / ReadPage）在 onPageShow 中读取并处理。
 * 处理完毕后置为 null，避免重复触发。
 */
import { SearchResult } from '../model/SearchResult';

export class SourceSwitchStore {
  /** 用户选中的新书源 */
  static selectedSource: SearchResult | null = null;
}
