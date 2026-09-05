import { globalQysgSourceAdapter } from '../engine/qysg/QysgSourceAdapter';
import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { BookSourceChangeNotifier } from './BookSourceChangeNotifier';
import { CheckConfig, CheckResult, CheckStageProgress, SourceChecker } from './SourceChecker';
import { SourceCheckConfigStore } from './SourceCheckConfigStore';
import { applyCheckResultToSource } from './SourceCheckPersistence';
import { BackgroundRunningManager } from './BackgroundRunningManager';
import { SettingsStore } from '../data/preferences/SettingsStore';

const NOTIFICATION_ID = 2107;

export interface SourceCheckSnapshot {
  running: boolean;
  cancelled: boolean;
  completed: number;
  total: number;
  currentMessage: string;
  results: CheckResult[];
  errorMessage: string;
}

type SnapshotListener = (snapshot: SourceCheckSnapshot) => void;

export class SourceCheckService {
  private static instance_: SourceCheckService;
  static getInstance(): SourceCheckService {
    if (!SourceCheckService.instance_) SourceCheckService.instance_ = new SourceCheckService();
    return SourceCheckService.instance_;
  }

  private checker_: SourceChecker | null = null;
  private stopWantAgent_: object | null = null;
  private listeners_: Set<SnapshotListener> = new Set();
  private snapshot_: SourceCheckSnapshot = {
    running: false, cancelled: false, completed: 0, total: 0,
    currentMessage: '', results: [], errorMessage: ''
  };

  getSnapshot(): SourceCheckSnapshot {
    return {
      running: this.snapshot_.running,
      cancelled: this.snapshot_.cancelled,
      completed: this.snapshot_.completed,
      total: this.snapshot_.total,
      currentMessage: this.snapshot_.currentMessage,
      results: this.snapshot_.results.slice(),
      errorMessage: this.snapshot_.errorMessage,
    };
  }

  subscribe(listener: SnapshotListener): void {
    this.listeners_.add(listener);
    listener(this.getSnapshot());
  }

  unsubscribe(listener: SnapshotListener): void { this.listeners_.delete(listener); }

  async start(sourceIds: number[], config: CheckConfig, context: common.Context): Promise<boolean> {
    if (this.snapshot_.running || sourceIds.length === 0) return false;
    await SettingsStore.getInstance().init(context);
    await SourceCheckConfigStore.save(config);
    this.snapshot_ = {
      running: true, cancelled: false, completed: 0, total: sourceIds.length,
      currentMessage: '准备校验…', results: [], errorMessage: ''
    };
    this.emit_();
    this.publish_('书源校验', '准备校验 0/' + sourceIds.length);
    await this.startBackground_(context);
    this.publish_('书源校验', '准备校验 0/' + sourceIds.length);
    this.run_(sourceIds, config, context).catch((error: Error) => {
      console.error('[SourceCheckService] run failed:', error.message);
    });
    return true;
  }

  cancel(): void {
    if (!this.snapshot_.running) return;
    this.snapshot_.cancelled = true;
    this.snapshot_.currentMessage = '正在停止…';
    this.checker_?.cancel();
    this.emit_();
  }

  clearResults(): void {
    if (this.snapshot_.running) return;
    this.snapshot_ = {
      running: this.snapshot_.running, cancelled: this.snapshot_.cancelled,
      completed: 0, total: 0, currentMessage: '', results: [], errorMessage: ''
    };
    this.emit_();
  }

  private async run_(sourceIds: number[], config: CheckConfig, context: common.Context): Promise<void> {
    const pendingWrites: Promise<void>[] = [];
    try {
      await AppDatabase.getInstance().waitForInit();
      const table = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const sources: BookSource[] = [];
      for (const id of sourceIds) {
        const source = await table.getSourceById(id);
        if (source) sources.push(source);
      }
      this.snapshot_.total = sources.length;
      this.checker_ = new SourceChecker(config, globalQysgSourceAdapter);
      await this.checker_.checkSources(sources,
        (completed: number, total: number, result: CheckResult): void => {
          this.snapshot_.completed = completed;
          this.snapshot_.total = total;
          this.snapshot_.currentMessage = result.sourceName + ' · ' + (result.status === 'success' ? '通过' : '失败');
          this.snapshot_.results = [...this.snapshot_.results, result];
          const source = sources.find((item: BookSource): boolean => item.sourceUrl === result.sourceUrl);
          if (source) {
            applyCheckResultToSource(source, result, config.timeout);
            pendingWrites.push(table.updateSource(source));
          }
          this.publish_('书源校验', this.snapshot_.currentMessage + '  ' + completed + '/' + total);
          this.emit_();
        }, config.concurrency,
        (progress: CheckStageProgress): void => {
          this.snapshot_.currentMessage = progress.sourceName + ' · ' + progress.detail.name + '：' + progress.detail.message;
          this.emit_();
        });
      await Promise.all<void>(pendingWrites);
      BookSourceChangeNotifier.notify();
    } catch (error) {
      if (!this.snapshot_.cancelled) this.snapshot_.errorMessage = (error as Error).message || String(error);
    } finally {
      const cancelled = this.snapshot_.cancelled;
      const success = this.snapshot_.results.filter((item: CheckResult): boolean => item.status === 'success').length;
      const failed = this.snapshot_.results.length - success;
      this.snapshot_.running = false;
      this.snapshot_.currentMessage = cancelled ? '校验已停止' : '校验完成：通过 ' + success + '，失败 ' + failed;
      this.checker_ = null;
      this.publish_('书源校验' + (cancelled ? '已停止' : '完成'), this.snapshot_.currentMessage);
      this.emit_();
      await this.stopBackground_(context);
    }
  }

  private emit_(): void {
    const snapshot = this.getSnapshot();
    this.listeners_.forEach((listener: SnapshotListener) => listener(snapshot));
  }

  private publish_(title: string, text: string): void {
    try {
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: { contentType: 0, normal: { title: title, text: text } },
      };
      if (this.stopWantAgent_ && this.snapshot_.running) {
        request.actionButtons = [{ title: '停止', wantAgent: this.stopWantAgent_ }];
      }
      notificationManager.publish(request, (error: Error) => {
        if (error) console.warn('[SourceCheckService] notification:', error.message);
      });
    } catch (error) {
      console.warn('[SourceCheckService] notification:', (error as Error).message);
    }
  }

  private async startBackground_(context: common.Context): Promise<void> {
    try {
      this.stopWantAgent_ = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'io.hjianhao.aireader', abilityName: 'MainAbility',
          parameters: { sourceCheckAction: 'stop' } }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: NOTIFICATION_ID + 1,
      });
      await BackgroundRunningManager.acquire(context, 'source-check');
    } catch (error) {
      const err = error as Error;
      console.warn('[SourceCheckService] background start:', err.message || String(error));
    }
  }

  private async stopBackground_(context: common.Context): Promise<void> {
    try { await BackgroundRunningManager.release(context, 'source-check'); }
    catch (error) {
      const err = error as Error;
      console.warn('[SourceCheckService] background stop:', err.message || String(error));
    }
    this.stopWantAgent_ = null;
  }
}
