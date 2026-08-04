import { AiSourceAgent, AiStep, AiStepResult } from '../engine/ai/AiSourceAgent';
import { BookSource } from '../model/BookSource';
import {
  AiSourceBatchSummary, AiSourceCandidate, AiSourceCandidateStatus,
  createAiSourceBatchSummary
} from '../model/AiSourceDiscovery';

export interface AiSourceBatchCallbacks {
  onCandidateChanged?: (candidate: AiSourceCandidate) => void;
  /** 全链路完成后的内存书源；由页面交给预览式导入，而不是在这里直接入库。 */
  onSourceReady?: (candidate: AiSourceCandidate, source: BookSource) => void;
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

        // 批量分析只负责生成并验证书源，不在这里写入数据库。页面会把所有成功项
        // 一次性交给与普通“导入书源”相同的预览对话框，由用户逐项勾选后再入库。
        const readySource: BookSource = { ...generated } as BookSource;
        const now = Date.now();
        readySource.id = 0;
        readySource.enabled = false;
        readySource.group = readySource.group.trim() || 'AI生成';
        readySource.isAiGenerated = true;
        readySource.createTime = readySource.createTime || now;
        // 让预览导入能把已有同 URL 书源标为“更新”，而不是把成功结果误判为“已有”。
        readySource.updateTime = now;
        candidate.status = 'ready';
        candidate.stepSummary = 'AI 分析完成，等待选择导入';
        candidate.savedSourceId = 0;
        summary.ready++;
        callbacks.onSourceReady?.(copyCandidate_(candidate), readySource);
        this.emit_(candidate, callbacks);
        this.emitSummary_(summary, callbacks);
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
