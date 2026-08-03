import { AiSourceAgent, AiStep, AiStepResult } from '../engine/ai/AiSourceAgent';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import {
  AiSourceBatchSummary, AiSourceCandidate, AiSourceCandidateStatus,
  createAiSourceBatchSummary
} from '../model/AiSourceDiscovery';
import {
  AiGeneratedSourceSaveResult, AiGeneratedSourceSaveService
} from './AiGeneratedSourceSaveService';

export interface AiSourceBatchCallbacks {
  onCandidateChanged?: (candidate: AiSourceCandidate) => void;
  onSummaryChanged?: (summary: AiSourceBatchSummary) => void;
  onRequestWebView?: (url: string, reason: string) => Promise<string>;
  onBatchError?: (message: string) => void;
}

function copyCandidate_(candidate: AiSourceCandidate): AiSourceCandidate {
  return {
    ...candidate,
    samples: candidate.samples.slice(),
    logs: candidate.logs.slice(),
  };
}

/** 串行编排 Agent，避免全局 WebView 和 Agent 可变状态发生竞争。 */
export class AiSourceBatchGenerateService {
  private stopRequested_: boolean = false;

  requestStop(): void {
    this.stopRequested_ = true;
  }

  private emit_(candidate: AiSourceCandidate, callbacks: AiSourceBatchCallbacks): void {
    callbacks.onCandidateChanged?.(copyCandidate_(candidate));
  }

  private emitSummary_(summary: AiSourceBatchSummary, callbacks: AiSourceBatchCallbacks): void {
    callbacks.onSummaryChanged?.({ ...summary, createdSourceIds: summary.createdSourceIds.slice() });
  }

  private setStatus_(candidate: AiSourceCandidate, status: AiSourceCandidateStatus,
    message: string, callbacks: AiSourceBatchCallbacks): void {
    candidate.status = status;
    if (message) candidate.stepSummary = message;
    this.emit_(candidate, callbacks);
  }

  private appendLog_(candidate: AiSourceCandidate, message: string,
    callbacks: AiSourceBatchCallbacks): void {
    const safe = (message || '')
      .replace(/authorization\s*[:=]\s*[^\s,;]+/ig, 'authorization:[已隐藏]')
      .replace(/cookie\s*[:=]\s*[^\s,;]+/ig, 'cookie:[已隐藏]')
      .replace(/(?:api[_ -]?key|token|password|passwd)\s*[:=]\s*[^\s,;]+/ig, '[敏感信息已隐藏]');
    candidate.logs = [...candidate.logs, safe].slice(-200);
    this.emit_(candidate, callbacks);
  }

  private markCancelled_(candidate: AiSourceCandidate, callbacks: AiSourceBatchCallbacks): void {
    this.setStatus_(candidate, 'cancelled', '未执行（已请求停止）', callbacks);
  }

  private async loadExisting_(candidate: AiSourceCandidate): Promise<BookSource | null> {
    await AppDatabase.getInstance().waitForInit();
    const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
    if (candidate.existingSourceId > 0) return await dao.getSourceById(candidate.existingSourceId);
    return await AiGeneratedSourceSaveService.findExistingByNormalizedUrl(candidate.homepageUrl);
  }

  private markSaveResult_(candidate: AiSourceCandidate, result: AiGeneratedSourceSaveResult,
    summary: AiSourceBatchSummary, callbacks: AiSourceBatchCallbacks): void {
    candidate.savedSourceId = result.sourceId;
    if (result.status === 'created') {
      candidate.status = 'created';
      summary.created++;
      if (result.sourceId > 0 && !summary.createdSourceIds.includes(result.sourceId)) {
        summary.createdSourceIds.push(result.sourceId);
      }
    } else if (result.status === 'updated') {
      candidate.status = 'updated';
      summary.updated++;
    } else if (result.status === 'unchanged') {
      candidate.status = 'unchanged';
      summary.unchanged++;
    } else {
      candidate.status = 'skipped';
      summary.skipped++;
    }
    candidate.stepSummary = result.message;
    this.emit_(candidate, callbacks);
    this.emitSummary_(summary, callbacks);
  }

  async run(context: Context, keyword: string, candidates: AiSourceCandidate[],
    allowUpdateExisting: boolean, callbacks: AiSourceBatchCallbacks): Promise<AiSourceBatchSummary> {
    this.stopRequested_ = false;
    const summary = createAiSourceBatchSummary();
    const selected = candidates.filter((candidate: AiSourceCandidate): boolean => candidate.selected);
    for (const sourceCandidate of selected) {
      const candidate = copyCandidate_(sourceCandidate);
      if (this.stopRequested_) {
        summary.cancelled++;
        this.markCancelled_(candidate, callbacks);
        this.emitSummary_(summary, callbacks);
        continue;
      }
      if (!candidate.safe || !candidate.homepageUrl) {
        summary.skipped++;
        this.setStatus_(candidate, 'skipped', '地址待确认或不安全，未执行', callbacks);
        this.emitSummary_(summary, callbacks);
        continue;
      }
      if (candidate.duplicate !== 'none' && !allowUpdateExisting) {
        summary.skipped++;
        this.setStatus_(candidate, 'skipped', '已有书源，未允许更新', callbacks);
        this.emitSummary_(summary, callbacks);
        continue;
      }

      this.setStatus_(candidate, 'running', '正在初始化 AI Agent', callbacks);
      const agent = new AiSourceAgent({
        onStepUpdate: (result: AiStepResult): void => {
          candidate.currentStep = result.step;
          candidate.stepSummary = result.summary || result.label;
          this.emit_(candidate, callbacks);
        },
        onLog: (message: string): void => { this.appendLog_(candidate, message, callbacks); },
        onRequestWebView: (url: string, reason: string): Promise<string> => {
          candidate.status = 'waiting_user';
          candidate.stepSummary = '当前网站需要人工验证';
          this.emit_(candidate, callbacks);
          return callbacks.onRequestWebView ? callbacks.onRequestWebView(url, reason) : Promise.resolve('');
        },
      });

      try {
        await agent.init(context);
        if (!agent.isConfigured()) {
          const message = '请先配置 AI API 和模型';
          summary.failed++;
          candidate.error = message;
          this.setStatus_(candidate, 'failed', message, callbacks);
          callbacks.onBatchError?.(message);
          this.emitSummary_(summary, callbacks);
          break;
        }
        const results = await agent.analyze(candidate.homepageUrl, keyword);
        const compile = results[AiStep.COMPILE];
        const generated = agent.getCompiledBookSource();
        if (!compile || compile.status !== 'done' || !generated) {
          summary.failed++;
          const message = compile?.summary || '书源未通过全链路验证';
          candidate.error = message;
          this.setStatus_(candidate, 'failed', message, callbacks);
          this.emitSummary_(summary, callbacks);
          continue;
        }

        const existing = candidate.duplicate !== 'none' ? await this.loadExisting_(candidate) :
          await AiGeneratedSourceSaveService.findExistingByNormalizedUrl(generated.sourceUrl);
        let saveResult: AiGeneratedSourceSaveResult;
        if (existing && allowUpdateExisting) {
          saveResult = await AiGeneratedSourceSaveService.updateGeneratedSource(
            existing, generated, 'AI 搜书发现批量更新，测试书名：' + keyword, true);
        } else if (existing) {
          saveResult = {
            status: 'skipped', sourceId: existing.id, changedFields: [], message: '已有书源，未允许更新'
          };
        } else {
          saveResult = await AiGeneratedSourceSaveService.createGeneratedSource(generated, false);
        }
        this.markSaveResult_(candidate, saveResult, summary, callbacks);
      } catch (e) {
        const message = (e as Error).message || String(e);
        summary.failed++;
        candidate.error = message;
        this.setStatus_(candidate, 'failed', message, callbacks);
        this.emitSummary_(summary, callbacks);
      }
    }

    this.emitSummary_(summary, callbacks);
    return summary;
  }
}
